"""Loopback OAuth 2.1 + PKCE login. Needs ZERO server-side changes.

`backend/handlers/oauth_handlers.py::_valid_redirect_uri` already accepts plain-http
`localhost` / `127.0.0.1` / `::1` redirect URIs, so the standard native-app flow works
against the live authorization server as-is:

  1. bind a loopback socket on port 0 (the port must be known BEFORE registration,
     because the server exact-string-matches the redirect URI);
  2. `POST /oauth/register` (RFC 7591 dynamic registration, public client, no secret);
  3. open `/oauth/authorize` in the browser with `code_challenge_method=S256`;
  4. catch the redirect on the loopback listener, check `state`;
  5. `POST /oauth/token` (form-encoded) with the `code_verifier`.

The access token IS a freshly minted PERSONAL API key: `read`+`write`, never `admin`,
and `financials` ONLY when the consenting user holds Manage Account and ticks the
financial-data box on the consent screen. It EXPIRES after 24 hours — the token response
also carries a refresh token (rotated on every use), which is what keeps `uku` from
sending you back to the browser daily. Revocable in Settings → API Keys. The
authorization code is single-use with a 120s TTL and replaying it revokes what it
minted, so this flow must run exactly once per login.
"""
from __future__ import annotations

import base64
import hashlib
import http.server
import secrets
import sys
import time
import urllib.parse
import webbrowser
from dataclasses import dataclass

import httpx

from .config import same_origin, url_origin
from .errors import AuthError, CliError

CLIENT_NAME = "Uku CLI"
SCOPES = "read write"
LOGIN_TIMEOUT_SECONDS = 300


@dataclass(frozen=True)
class LoginResult:
    """Everything one browser login produced — including what renewal needs later.

    `refresh_token`, `client_id` and `token_endpoint` all have to survive to the next
    process: the access token dies in 24h, the refresh grant is bound to the client it
    was issued to (a public client has no secret, so `client_id` is the only binding
    there is), and the endpoint was origin-validated here rather than re-guessed there.
    """

    access_token: str
    scope: str
    refresh_token: str = ""
    client_id: str | None = None
    token_endpoint: str | None = None

# Encoded at use, not written as bytes literals — the copy is UTF-8 (em dashes).
_SUCCESS_HTML = """<!DOCTYPE html><html><head><meta charset="utf-8"><title>Uku CLI</title>
<style>body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
background:#f5f6f8;display:flex;justify-content:center;padding-top:12vh}
main{background:#fff;border-radius:12px;padding:32px;max-width:420px;text-align:center;
box-shadow:0 2px 12px rgba(0,0,0,.08)}h1{font-size:20px;margin:0 0 8px}
p{color:#555;font-size:14px}</style></head><body><main>
<h1>You are signed in</h1><p>Return to your terminal — you can close this tab.</p>
</main></body></html>""".encode("utf-8")

_FAILURE_HTML = """<!DOCTYPE html><html><head><meta charset="utf-8"><title>Uku CLI</title>
</head><body><h1>Sign-in failed</h1><p>Return to your terminal for details.</p></body></html>""".encode("utf-8")


class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    """Single-purpose: capture the authorization redirect, answer, and stop."""

    def do_GET(self) -> None:  # noqa: N802 (stdlib API)
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)

        if "code" not in params and "error" not in params:
            # Browsers cheerfully fetch /favicon.ico against the loopback origin; that
            # must not be mistaken for the callback (and must not consume the listener).
            self.send_response(404)
            self.end_headers()
            return

        self.server.oauth_result = {  # type: ignore[attr-defined]
            k: v[0] for k, v in params.items()
        }
        ok = "code" in params
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(_SUCCESS_HTML if ok else _FAILURE_HTML)

    def log_message(self, *args: object) -> None:
        """Silence the stdlib's stderr access log — it is noise in a CLI."""


def _pkce_pair() -> tuple[str, str]:
    verifier = secrets.token_urlsafe(64)
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return verifier, challenge


def _discover(http_client: httpx.Client, base_url: str) -> dict[str, str]:
    """RFC 8414 metadata, VALIDATED against the origin the user asked for.

    A discovery document is not information, it is an instruction: it says where to send
    the user's browser and where to POST the authorization code. Following it wherever it
    points is the vulnerability. `[api_v3] app_base_url` defaults to
    `https://app.getuku.com` and is unset in every dev ini, so a local server on `:8885`
    happily advertises PRODUCTION's endpoints — and `uku auth login --base-url
    http://127.0.0.1:8885` would then open production's consent page and mint a real
    production key against the wrong tenant.

    So, per RFC 8414 §3.3, `issuer` MUST be the origin that served the metadata, and every
    endpoint we are about to use must be on that same origin. A document that fails either
    check is refused outright — never "partially" honored, never followed.

    A document we could not read at all (connection error, non-200, non-JSON) is a
    different case: there is nothing to distrust, so we fall back to the documented
    defaults, which are derived from `base_url` and therefore on-origin by construction.
    """
    asked = url_origin(base_url)
    if asked is None:
        raise AuthError(
            f"{base_url!r} is not a usable server URL — expected something like "
            "https://app.getuku.com or http://127.0.0.1:8885.",
            code="OAUTH_BAD_BASE_URL",
        )

    defaults = {
        "authorization_endpoint": f"{base_url}/oauth/authorize",
        "token_endpoint": f"{base_url}/oauth/token",
        "registration_endpoint": f"{base_url}/oauth/register",
    }
    try:
        # follow_redirects=False, deliberately, even though the caller's client follows
        # them: a 302 to another origin would fetch a document that legitimately names
        # THAT origin as its issuer, so the issuer check would pass while every endpoint
        # still points away from the server the user asked for. Only a document served
        # directly by an origin may speak for it.
        response = http_client.get(
            f"{base_url}/.well-known/oauth-authorization-server", follow_redirects=False
        )
        if response.status_code != 200:
            return defaults
        body = response.json()
    except (httpx.HTTPError, ValueError):
        return defaults
    if not isinstance(body, dict):
        return defaults

    issuer = body.get("issuer")
    if not isinstance(issuer, str) or not issuer.strip():
        raise AuthError(
            f"{asked} served OAuth metadata with no `issuer`, so there is nothing to "
            "check its endpoints against. RFC 8414 requires it. Refusing to sign in: "
            "following unverified metadata can send your login — and the key it mints — "
            "to another deployment.",
            code="OAUTH_ISSUER_MISSING",
        )
    if not same_origin(issuer, base_url):
        raise AuthError(
            f"Refusing to sign in: you asked for {asked}, but its OAuth metadata claims "
            f"the issuer is {url_origin(issuer) or issuer!r}. Following that would open "
            f"the consent page at {url_origin(issuer) or issuer} and POST your "
            f"authorization code there — minting a key on that deployment, not on "
            f"{asked}.\n"
            f"This is a server misconfiguration, not something you can work around here: "
            f"set `[api_v3] app_base_url` to {asked} in the ini of the server running at "
            f"{asked}.",
            code="OAUTH_ISSUER_MISMATCH",
        )

    endpoints: dict[str, str] = {}
    for key, fallback in defaults.items():
        advertised = body.get(key)
        if not advertised:
            endpoints[key] = fallback
            continue
        if not isinstance(advertised, str) or not same_origin(advertised, base_url):
            raise AuthError(
                f"Refusing to sign in: {asked} advertises its {key.replace('_', ' ')} as "
                f"{advertised!r}, which is not on {asked}. An authorization server may "
                f"only point at itself; an off-origin endpoint is refused, not followed.\n"
                f"This is a server misconfiguration: set `[api_v3] app_base_url` to "
                f"{asked} in the ini of the server running at {asked}.",
                code="OAUTH_ENDPOINT_OFF_ORIGIN",
            )
        endpoints[key] = advertised
    return endpoints


def login(
    base_url: str,
    *,
    open_browser: bool = True,
    transport: httpx.BaseTransport | None = None,
) -> LoginResult:
    """Run the full flow. `transport` is a test seam (an `httpx.MockTransport`)."""
    base_url = base_url.rstrip("/")

    # Port 0 -> the OS picks a free port, which we learn BEFORE registering. The
    # authorization server exact-string-matches the redirect URI, so registering a
    # guessed port and binding another would fail at the redirect.
    httpd = http.server.HTTPServer(("127.0.0.1", 0), _CallbackHandler)
    httpd.oauth_result = None  # type: ignore[attr-defined]
    port = httpd.server_address[1]
    redirect_uri = f"http://127.0.0.1:{port}/callback"

    try:
        with httpx.Client(timeout=30.0, follow_redirects=True,
                          transport=transport) as http_client:
            endpoints = _discover(http_client, base_url)

            registration = http_client.post(
                endpoints["registration_endpoint"],
                json={"client_name": CLIENT_NAME, "redirect_uris": [redirect_uri]},
            )
            if registration.status_code not in (200, 201):
                raise AuthError(
                    f"Could not register the CLI as an OAuth client "
                    f"({registration.status_code}): {registration.text[:200]}",
                    code="OAUTH_REGISTRATION_FAILED",
                )
            client_id = registration.json().get("client_id")
            if not client_id:
                raise AuthError(
                    "The authorization server returned no client_id.",
                    code="OAUTH_REGISTRATION_FAILED",
                )

            verifier, challenge = _pkce_pair()
            state = secrets.token_urlsafe(24)
            authorize_url = endpoints["authorization_endpoint"] + "?" + urllib.parse.urlencode({
                "response_type": "code",
                "client_id": client_id,
                "redirect_uri": redirect_uri,
                "code_challenge": challenge,
                "code_challenge_method": "S256",
                "state": state,
                "scope": SCOPES,
            })

            # Progress goes to stderr: `uku auth login --json` emits its payload on
            # stdout, and an agent must not have to strip prose out of it.
            print(f"Opening your browser to sign in to {base_url} …", file=sys.stderr)
            print(f"If it does not open, visit:\n\n  {authorize_url}\n", file=sys.stderr)
            if open_browser:
                try:
                    webbrowser.open(authorize_url)
                except Exception:
                    pass

            result = _await_callback(httpd)

            if error := result.get("error"):
                raise AuthError(
                    f"Authorization was refused: {error}"
                    + (f" — {result['error_description']}" if result.get("error_description") else ""),
                    code="OAUTH_DENIED",
                )
            if not secrets.compare_digest(result.get("state", ""), state):
                raise AuthError(
                    "The authorization response carried the wrong `state` — "
                    "the login was not the one this CLI started. Aborting.",
                    code="OAUTH_STATE_MISMATCH",
                )

            # Single-use, 120s TTL; a replay revokes the key it minted. Exactly once.
            token_response = http_client.post(
                endpoints["token_endpoint"],
                data={
                    "grant_type": "authorization_code",
                    "code": result["code"],
                    "redirect_uri": redirect_uri,
                    "client_id": client_id,
                    "code_verifier": verifier,
                },
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )
            if token_response.status_code != 200:
                raise AuthError(
                    f"Token exchange failed ({token_response.status_code}): "
                    f"{token_response.text[:200]}",
                    code="OAUTH_TOKEN_FAILED",
                )
            payload = token_response.json()
            token = payload.get("access_token")
            if not token:
                raise AuthError("The token endpoint returned no access_token.",
                                code="OAUTH_TOKEN_FAILED")
            # A missing refresh_token is NOT fatal — the access token works for 24h — but
            # it costs the user a browser login a day, so say so rather than silently
            # degrading. (The server has issued one since 2026-08-03.)
            refresh_token = payload.get("refresh_token") or ""
            if not refresh_token:
                print("Note: this server issued no refresh token, so this sign-in "
                      "expires in 24h and will need repeating.", file=sys.stderr)
            return LoginResult(
                access_token=token,
                scope=payload.get("scope", SCOPES),
                refresh_token=refresh_token,
                client_id=client_id,
                token_endpoint=endpoints["token_endpoint"],
            )
    finally:
        httpd.server_close()


def _await_callback(httpd: http.server.HTTPServer) -> dict[str, str]:
    """Serve until the real callback arrives (ignoring favicon probes) or we time out."""
    httpd.timeout = 1.0
    deadline = time.monotonic() + LOGIN_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        httpd.handle_request()
        if (result := getattr(httpd, "oauth_result", None)) is not None:
            return result
    raise CliError(
        f"Timed out after {LOGIN_TIMEOUT_SECONDS}s waiting for the browser sign-in.",
        code="OAUTH_TIMEOUT",
    )
