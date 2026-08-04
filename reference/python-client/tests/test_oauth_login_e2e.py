"""REAL end-to-end test of `uku auth login` — loopback OAuth 2.1 + PKCE.

Every other test in this package runs against `httpx.MockTransport`. This one does not
mock anything: it drives `uku_cli.oauth.login()` against a genuinely running Tornado
server (`backend/handlers/oauth_handlers.py`, served by the MAIN uku app — not api-v3,
not the MCP server), redeems a real authorization code, and then proves the minted
bearer works by calling the real `GET /api/v3/auth/me`.

HOW TO RUN
----------
    bash uku_cli/tests/run_oauth_e2e.sh              # full suite
    bash uku_cli/tests/run_oauth_e2e.sh -k replay    # one case

Never `pytest uku_cli/tests/test_oauth_login_e2e.py` directly — with no environment it
skips, by design (a plain `pytest` run of the package must stay green and offline).
The runner is what makes it real: it picks a company/person in your LOCAL dev DB,
forges a logged-in session, clears the OAuth rate-limit buckets, and cleans every
artifact up afterwards. Read its header for what it writes.

PREREQUISITES
-------------
* PostgreSQL + Redis up (`bash setup_dev.sh` once), and the `oauth_refresh_token`
  migration applied — the runner checks and tells you the command if not.
* A company on an API-eligible plan with a MANAGE_ACCOUNT member — the runner finds it.
* The uku app (8885) and api-v3 (8890) — started by this module if not already up, and
  torn down again only if this module started them.

THE ONE THING THAT IS SIMULATED
-------------------------------
A human clicking "Allow". The runner forges the session cookie a password login would
have left behind; this module then does what the browser does — GET the consent page,
read `_xsrf` + `consent_blob` out of the returned form, POST it back, follow the 302.
The server is never stubbed, patched or bypassed: registration, consent, code issuance,
PKCE verification, token minting and bearer authentication are all the shipping code.

WHAT EACH CASE PROVES
---------------------
* registration        loopback `http://127.0.0.1:<port>/…` really is accepted, and a
                      non-loopback plain-http URI really is refused (non-vacuity).
* cli_login           `oauth.login()` itself — its loopback listener, favicon 404
                      branch, `state` check and token POST — works against the wire,
                      and the token it returns authenticates on `/api/v3/auth/me`.
* replay              a re-used authorization code is refused AND the key it minted
                      stops working (asserted over the wire, not in the DB).
* pkce                a wrong `code_verifier` is refused, and the SAME code then
                      succeeds with the right one (so the refusal was PKCE-specific).
* financials_granted  the consent checkbox does grant `financials` to a MANAGE_ACCOUNT
                      holder — asserted FIRST, so the two refusal cases below cannot
                      pass by the checkbox being inert.
* financials_forged   `scope=financials` on the authorize request is ignored.
* financials_denied   ticking the box without MANAGE_ACCOUNT issues no code at all.
* refresh             `grant_type=refresh_token` returns a working access token, and
                      replaying a rotated refresh token kills the whole family.
* bogus_bearer        the non-vacuity anchor: a 401 from `/auth/me` really does mean
                      "rejected", so the two revocation cases above prove something.

KNOWN RED (server-side half — config only)
------------------------------------------
`test_discovery_metadata_points_at_the_server_that_served_it` still fails on any
deployment whose `[api_v3] app_base_url` does not name that deployment — including the
stock dev inis, where it defaults to `https://app.getuku.com`. Do not weaken it: the
misconfiguration is real and belongs fixed in the ini.

What CHANGED is the blast radius. `_discover` now validates the document per RFC 8414
§3.3 — `issuer` and every endpoint must be on the origin the metadata was fetched from,
and the fetch does not follow redirects — so `uku auth login --base-url
http://127.0.0.1:8885` against such a server now REFUSES with `OAUTH_ISSUER_MISMATCH`
instead of silently driving the browser to production. Unit coverage for that fence
(mocked transport, no live server) is in `tests/test_oauth_discovery.py`.
"""
from __future__ import annotations

import os
import re
import secrets
import subprocess
import sys
import threading
import time
import urllib.parse
from dataclasses import dataclass
from pathlib import Path

import httpx
import pytest

# Mirrors `backend.api_v3.services.auth_service.PERSONAL_KEY_SCOPES`. Duplicated as a
# literal on purpose: the import fence forbids reaching into `backend`, and a test that
# asserts against the server's own constant could not detect the constant changing.
BASE_SCOPES = ["read", "write"]
FINANCIALS = "financials"

REPO_ROOT = Path(__file__).resolve().parents[2]     # -> uku_service/
_STARTUP_TIMEOUT_S = 90.0
_POLL_INTERVAL_S = 0.25

# The consent page's own markup — see `_render_consent_page`. Tornado writes the XSRF
# field with double quotes and the handler's own fields with single quotes.
_XSRF_RE = re.compile(r'name="_xsrf"\s+value="([^"]+)"')
_BLOB_RE = re.compile(r"name='consent_blob'\s+value='([^']+)'")
_FINANCIALS_CHECKBOX_RE = re.compile(r"name='grant_financials'")
_COMPANY_SELECT_RE = re.compile(r"name='company_id'")


# --------------------------------------------------------------------------- #
# Configuration — env only, and a skip that names exactly what is missing.
# --------------------------------------------------------------------------- #

@dataclass(frozen=True)
class E2EConfig:
    base: str               # http://127.0.0.1:8885   (main app: OAuth endpoints)
    v3_base: str            # http://127.0.0.1:8890/api/v3
    company_id: int
    company_name: str
    company_uuid: str
    admin_person: int
    admin_cookie: str       # signed `sid` for a MANAGE_ACCOUNT holder
    plain_person: int | None
    plain_cookie: str | None
    plain_administers_any: bool     # holds MANAGE_ACCOUNT on SOME offered account
    no_plain_reason: str

    @property
    def v3_origin(self) -> str:
        return self.v3_base.split("/api/v3")[0].rstrip("/")


@pytest.fixture(scope="session")
def cfg() -> E2EConfig:
    required = (
        "UKU_OAUTH_E2E_BASE", "UKU_OAUTH_E2E_V3_BASE", "UKU_OAUTH_E2E_COMPANY_ID",
        "UKU_OAUTH_E2E_COMPANY_UUID", "UKU_OAUTH_E2E_ADMIN_PERSON",
        "UKU_OAUTH_E2E_ADMIN_COOKIE",
    )
    missing = [name for name in required if not os.environ.get(name, "").strip()]
    if missing:
        pytest.skip(
            "OAuth login e2e suite not configured — missing " + ", ".join(missing) + ".\n"
            "This suite needs a live server and a forged consent session, which only the "
            "runner can set up. Fix: bash uku_cli/tests/run_oauth_e2e.sh"
        )

    base = os.environ["UKU_OAUTH_E2E_BASE"].rstrip("/")
    v3_base = os.environ["UKU_OAUTH_E2E_V3_BASE"].rstrip("/")
    for target in (base, v3_base):
        lowered = target.lower()
        if any(p in lowered for p in ("app.getuku", "app.uku", "prod.", "production.", "://live.")):
            pytest.exit(f"SAFETY STOP: OAuth e2e target looks like production: {target}")

    return E2EConfig(
        base=base,
        v3_base=v3_base,
        company_id=int(os.environ["UKU_OAUTH_E2E_COMPANY_ID"]),
        company_name=os.environ.get("UKU_OAUTH_E2E_COMPANY_NAME", ""),
        company_uuid=os.environ["UKU_OAUTH_E2E_COMPANY_UUID"],
        admin_person=int(os.environ["UKU_OAUTH_E2E_ADMIN_PERSON"]),
        admin_cookie=os.environ["UKU_OAUTH_E2E_ADMIN_COOKIE"],
        plain_person=int(os.environ["UKU_OAUTH_E2E_PLAIN_PERSON"])
        if os.environ.get("UKU_OAUTH_E2E_PLAIN_PERSON") else None,
        plain_cookie=os.environ.get("UKU_OAUTH_E2E_PLAIN_COOKIE") or None,
        plain_administers_any=os.environ.get("UKU_OAUTH_E2E_PLAIN_ADMINISTERS_ANY") == "1",
        no_plain_reason=os.environ.get("UKU_OAUTH_E2E_NO_PLAIN_REASON", "not configured"),
    )


# --------------------------------------------------------------------------- #
# Server lifecycle — reuse what is already up, tear down only what we started.
# --------------------------------------------------------------------------- #

def _probe(url: str, timeout: float = 2.0) -> int | None:
    try:
        return httpx.get(url, timeout=timeout).status_code
    except httpx.HTTPError:
        return None


def _tail(path: Path, lines: int = 40) -> str:
    try:
        return "\n".join(path.read_text(errors="replace").splitlines()[-lines:])
    except OSError as exc:
        return f"(no log: {exc})"


def _stop_group(proc: subprocess.Popen) -> None:
    """SIGTERM the process GROUP, then SIGKILL what is left.

    `proc.terminate()` alone is not enough: it signals only the direct child, and a
    dev-mode api-v3 has a reload child that then survives holding the port.
    """
    import signal

    try:
        group = os.getpgid(proc.pid)
    except OSError:                                     # already reaped
        return
    for sig, grace in ((signal.SIGTERM, 10), (signal.SIGKILL, 5)):
        try:
            os.killpg(group, sig)
        except OSError:
            return
        try:
            proc.wait(timeout=grace)
            # The parent is gone; make sure no sibling in the group outlived it.
            try:
                os.killpg(group, 0)
            except OSError:
                return                                  # group is empty — done
        except subprocess.TimeoutExpired:
            continue


@pytest.fixture(scope="session")
def live_servers(cfg, tmp_path_factory) -> E2EConfig:
    """The main uku app (OAuth endpoints) and api-v3 (the bearer's proving ground)."""
    log_dir = tmp_path_factory.mktemp("oauth_e2e_logs")
    started: list[tuple[str, subprocess.Popen]] = []

    def ensure(url: str, argv: list[str], label: str, log_name: str) -> None:
        if _probe(url) == 200:
            return                                  # already running — reuse, never manage
        log_path = log_dir / log_name
        handle = log_path.open("w")
        proc = subprocess.Popen(
            argv, cwd=str(REPO_ROOT), stdout=handle, stderr=subprocess.STDOUT,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            # Own process group, so teardown can signal the WHOLE tree. api-v3 runs
            # with `[api_v3] autoreload=true` in dev inis and forks a reload child;
            # terminating just the parent leaves that child holding port 8890, and the
            # next run then silently "reuses" a server nobody is managing.
            start_new_session=True,
        )
        started.append((label, proc))
        deadline = time.monotonic() + _STARTUP_TIMEOUT_S
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                pytest.fail(f"{label} exited during startup (rc={proc.returncode}).\n"
                            f"--- tail of {log_path} ---\n{_tail(log_path)}")
            if _probe(url) == 200:
                return
            time.sleep(_POLL_INTERVAL_S)
        pytest.fail(f"{label} did not become ready at {url} within {_STARTUP_TIMEOUT_S:.0f}s.\n"
                    f"--- tail of {log_path} ---\n{_tail(log_path)}")

    try:
        # The unauthenticated discovery document doubles as the main app's readiness
        # probe — it is served by the very handler module under test.
        ensure(f"{cfg.base}/.well-known/oauth-authorization-server",
               [sys.executable, "server.py"], "uku app", "uku.log")
        ensure(f"{cfg.v3_origin}/api/v3/health",
               [sys.executable, "api_v3_server.py"], "api-v3", "apiv3.log")
        yield cfg
    finally:
        for label, proc in reversed(started):
            if proc.poll() is not None:
                continue
            _stop_group(proc)
            print(f"[oauth-e2e] stopped {label} (pid {proc.pid})")


# --------------------------------------------------------------------------- #
# Wire helpers — a browser, spelled out.
# --------------------------------------------------------------------------- #

def _pkce_pair() -> tuple[str, str]:
    """Deliberately NOT `uku_cli.oauth._pkce_pair`: if the CLI's S256 derivation were
    wrong, reusing it here would make every fixture agree with the bug."""
    import base64
    import hashlib

    verifier = secrets.token_urlsafe(64)
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return verifier, base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def _register(cfg: E2EConfig, redirect_uri: str, name: str = "uku-cli-e2e") -> str:
    response = httpx.post(f"{cfg.base}/oauth/register",
                          json={"client_name": name, "redirect_uris": [redirect_uri]},
                          timeout=30.0)
    assert response.status_code == 201, f"register failed: {response.status_code} {response.text[:300]}"
    client_id = response.json().get("client_id")
    assert client_id, f"register returned no client_id: {response.text[:300]}"
    return client_id


def _authorize_url(cfg: E2EConfig, *, client_id: str, redirect_uri: str,
                   challenge: str, state: str, scope: str | None = None) -> str:
    params = {
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
    }
    if scope is not None:
        params["scope"] = scope
    return f"{cfg.base}/oauth/authorize?" + urllib.parse.urlencode(params)


def _get_consent_page(url: str, session_cookie: str) -> httpx.Response:
    """GET the consent page as a signed-in browser would.

    The `Cookie` header is built by hand rather than handed to httpx's jar: Tornado
    sets `_xsrf` with `Secure` (`server.py`: `xsrf_cookie_kwargs`), and a cookie jar
    correctly refuses to send a Secure cookie back over plain http — the consent POST
    would then fail XSRF for a reason that has nothing to do with the flow.
    """
    return httpx.get(url, headers={"Cookie": f"sid={session_cookie}"},
                     follow_redirects=False, timeout=30.0)


def _post_consent(url: str, session_cookie: str, page_html: str, *, company_id: int,
                  grant_financials: bool = False, decision: str = "approve",
                  follow_redirects: bool = False) -> httpx.Response:
    xsrf = _XSRF_RE.search(page_html)
    blob = _BLOB_RE.search(page_html)
    assert xsrf and blob, (
        "consent page carried no _xsrf/consent_blob — the session forge probably did not "
        f"log anyone in. Page starts: {page_html[:400]!r}"
    )
    form = {
        "_xsrf": xsrf.group(1),
        "consent_blob": blob.group(1),
        "company_id": str(company_id),
        "decision": decision,
    }
    if grant_financials:
        form["grant_financials"] = "1"
    # Same string in the cookie and the field: Tornado unmasks both sides and compares.
    return httpx.post(url, data=form,
                      headers={"Cookie": f"sid={session_cookie}; _xsrf={xsrf.group(1)}"},
                      follow_redirects=follow_redirects, timeout=30.0)


def _code_from(response: httpx.Response) -> str:
    assert response.status_code in (302, 303), (
        f"expected a redirect carrying the authorization code, got {response.status_code}: "
        f"{response.text[:300]}"
    )
    query = urllib.parse.parse_qs(urllib.parse.urlparse(response.headers["Location"]).query)
    assert "code" in query, f"redirect carried no code: {response.headers['Location']}"
    return query["code"][0]


def _exchange(cfg: E2EConfig, *, code: str, verifier: str, client_id: str,
              redirect_uri: str) -> httpx.Response:
    return httpx.post(f"{cfg.base}/oauth/token", data={
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": redirect_uri,
        "client_id": client_id,
        "code_verifier": verifier,
    }, timeout=30.0)


def _refresh(cfg: E2EConfig, *, refresh_token: str, client_id: str) -> httpx.Response:
    return httpx.post(f"{cfg.base}/oauth/token", data={
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": client_id,
    }, timeout=30.0)


def _whoami(cfg: E2EConfig, token: str) -> httpx.Response:
    """The bearer's proving ground. No `X-Uku-Company` on purpose — for a bearer the
    tenant is derived from the key row, and sending one would mask a tenancy bug."""
    return httpx.get(f"{cfg.v3_base}/auth/me",
                     headers={"Authorization": f"Bearer {token}"}, timeout=30.0)


@dataclass
class Grant:
    client_id: str
    redirect_uri: str
    verifier: str
    code: str
    payload: dict


def _grant(cfg: E2EConfig, session_cookie: str, *, company_id: int | None = None,
           grant_financials: bool = False, scope: str | None = None,
           port: int = 53999, exchange: bool = True) -> Grant:
    """Register → authorize → consent → (optionally) redeem. The whole browser hop."""
    redirect_uri = f"http://127.0.0.1:{port}/callback"
    client_id = _register(cfg, redirect_uri)
    verifier, challenge = _pkce_pair()
    state = secrets.token_urlsafe(16)
    url = _authorize_url(cfg, client_id=client_id, redirect_uri=redirect_uri,
                         challenge=challenge, state=state, scope=scope)

    page = _get_consent_page(url, session_cookie)
    assert page.status_code == 200, f"consent GET returned {page.status_code}: {page.text[:300]}"
    assert _COMPANY_SELECT_RE.search(page.text), (
        "consent page rendered without a company picker — the forged session is not "
        "recognised as an API-enabled member. This is a broken fixture, not a product "
        f"failure. Page: {page.text[:600]!r}"
    )

    redirect = _post_consent(url, session_cookie, page.text,
                             company_id=company_id or cfg.company_id,
                             grant_financials=grant_financials)
    code = _code_from(redirect)
    payload: dict = {}
    if exchange:
        response = _exchange(cfg, code=code, verifier=verifier,
                             client_id=client_id, redirect_uri=redirect_uri)
        assert response.status_code == 200, (
            f"token exchange failed: {response.status_code} {response.text[:400]}"
        )
        payload = response.json()
    return Grant(client_id=client_id, redirect_uri=redirect_uri,
                 verifier=verifier, code=code, payload=payload)


# --------------------------------------------------------------------------- #
# 1. Discovery
# --------------------------------------------------------------------------- #

def test_discovery_metadata_points_at_the_server_that_served_it(live_servers):
    """RFC 8414 §3.3: the client must be able to trust `issuer`.

    `uku_cli.oauth._discover` takes `authorization_endpoint` / `token_endpoint` /
    `registration_endpoint` straight from this document and uses them verbatim. If the
    document names a DIFFERENT origin than the one the user asked for, `uku auth login`
    silently opens that origin's consent page and posts the authorization code there.
    """
    cfg = live_servers
    metadata = httpx.get(f"{cfg.base}/.well-known/oauth-authorization-server", timeout=30.0)
    assert metadata.status_code == 200
    body = metadata.json()

    assert body["issuer"].rstrip("/") == cfg.base, (
        f"discovery advertises issuer {body['issuer']!r} but was served by {cfg.base!r}. "
        "`uku auth login` follows the advertised endpoints without validating the issuer, "
        "so against this server it would drive the browser to the WRONG origin."
    )
    for name in ("authorization_endpoint", "token_endpoint", "registration_endpoint"):
        assert body[name].startswith(cfg.base), f"{name} points off-origin: {body[name]}"
    assert body["code_challenge_methods_supported"] == ["S256"]
    # `financials` must never be advertised — it is granted out-of-band by the consent
    # checkbox, and listing it would invite connectors to request it.
    assert FINANCIALS not in body["scopes_supported"]


# --------------------------------------------------------------------------- #
# 2. Dynamic client registration (RFC 7591)
# --------------------------------------------------------------------------- #

def test_register_accepts_a_loopback_redirect_uri(live_servers):
    """`_valid_redirect_uri` allows plain-http loopback by design — the whole native-app
    flow rests on it. Uses a port bound for real, as `oauth.login()` does."""
    cfg = live_servers
    import http.server

    httpd = http.server.HTTPServer(("127.0.0.1", 0), http.server.BaseHTTPRequestHandler)
    try:
        redirect_uri = f"http://127.0.0.1:{httpd.server_address[1]}/callback"
    finally:
        httpd.server_close()

    response = httpx.post(f"{cfg.base}/oauth/register",
                          json={"client_name": "uku-cli-e2e-registration",
                                "redirect_uris": [redirect_uri]}, timeout=30.0)
    assert response.status_code == 201, f"{response.status_code}: {response.text[:300]}"
    body = response.json()
    assert body["client_id"]
    assert body["redirect_uris"] == [redirect_uri]
    assert body["token_endpoint_auth_method"] == "none"
    assert "refresh_token" in body["grant_types"]
    assert "client_secret" not in body, "a public client must never be issued a secret"


def test_register_refuses_a_non_loopback_plain_http_redirect_uri(live_servers):
    """Non-vacuity for the case above: loopback is an exception, not a hole."""
    cfg = live_servers
    for bad in ("http://example.com/callback",          # plain http, not loopback
                "https://example.com/cb#frag",          # fragment
                "notaurl"):                             # no netloc
        response = httpx.post(f"{cfg.base}/oauth/register",
                              json={"client_name": "uku-cli-e2e-bad",
                                    "redirect_uris": [bad]}, timeout=30.0)
        assert response.status_code == 400, f"{bad!r} was accepted: {response.text[:200]}"
        assert response.json()["error"] == "invalid_redirect_uri"


# --------------------------------------------------------------------------- #
# 3. The CLI's own login(), end to end
# --------------------------------------------------------------------------- #

def _pin_discovery_if_off_origin(cfg: E2EConfig, monkeypatch) -> bool:
    """Force `login()` to use THIS server's endpoints when discovery names another.

    Only applied when the advertised document is genuinely off-origin (see
    `test_discovery_metadata_points_at_the_server_that_served_it`, which fails loudly in
    that case). On a correctly configured server this patch is not installed at all and
    `login()` runs its real `_discover` path. Without it, a dev box whose
    `[api_v3] app_base_url` is unset would send this test to production.
    """
    from uku_cli import oauth as oauth_mod

    try:
        body = httpx.get(f"{cfg.base}/.well-known/oauth-authorization-server", timeout=10.0).json()
        if body.get("authorization_endpoint", "").startswith(cfg.base):
            return False
    except (httpx.HTTPError, ValueError):
        return False

    monkeypatch.setattr(oauth_mod, "_discover", lambda *_a, **_k: {
        "authorization_endpoint": f"{cfg.base}/oauth/authorize",
        "token_endpoint": f"{cfg.base}/oauth/token",
        "registration_endpoint": f"{cfg.base}/oauth/register",
    })
    return True


def test_cli_login_end_to_end(live_servers, monkeypatch):
    """Drive `uku_cli.oauth.login()` itself — the code `uku auth login` actually runs.

    The only substitution is `webbrowser.open`, which here starts a thread that plays
    the human: it fetches the consent page `login()` built, approves it, and follows the
    302 into `login()`'s own loopback listener. Everything `login()` does — dynamic
    registration, the S256 challenge, `_await_callback`, the `state` comparison, the
    form-encoded token POST — runs unmodified against the live server.
    """
    cfg = live_servers
    from uku_cli import oauth as oauth_mod

    pinned = _pin_discovery_if_off_origin(cfg, monkeypatch)
    # A broken consent hop would otherwise idle for the product's full 5 minutes.
    monkeypatch.setattr(oauth_mod, "LOGIN_TIMEOUT_SECONDS", 60)

    browser_error: list[BaseException] = []
    opened: list[str] = []

    def fake_open(url: str) -> bool:
        opened.append(url)

        def drive() -> None:
            try:
                page = _get_consent_page(url, cfg.admin_cookie)
                assert page.status_code == 200, f"consent GET {page.status_code}: {page.text[:300]}"
                # follow_redirects: the 302 must actually reach login()'s listener.
                _post_consent(url, cfg.admin_cookie, page.text, company_id=cfg.company_id,
                              follow_redirects=True)
            except BaseException as exc:                  # noqa: BLE001 — reported below
                browser_error.append(exc)

        threading.Thread(target=drive, daemon=True).start()
        return True

    monkeypatch.setattr(oauth_mod.webbrowser, "open", fake_open)

    try:
        login_result = oauth_mod.login(cfg.base, open_browser=True)
        token, scope = login_result.access_token, login_result.scope
    except BaseException:
        if browser_error:
            raise AssertionError(f"the simulated browser failed: {browser_error[0]!r}") from browser_error[0]
        raise

    assert not browser_error, f"the simulated browser failed: {browser_error[0]!r}"
    assert opened, "login() never opened a browser URL"
    assert opened[0].startswith(cfg.base), (
        f"login() drove the browser to {opened[0][:120]!r}, not to {cfg.base!r}"
        + (" (discovery had to be pinned for this test to stay local)" if pinned else "")
    )
    assert token.startswith("uku_"), f"unexpected access-token shape: {token[:12]!r}"
    assert sorted(scope.split()) == sorted(BASE_SCOPES), (
        f"a browser login must grant exactly {BASE_SCOPES}, got {scope!r}"
    )
    # Renewal material, over the wire. Without all three the CLI cannot run
    # `grant_type=refresh_token`, and a 24h access token means a daily browser login.
    assert login_result.refresh_token, (
        "login() surfaced no refresh_token — the access token expires in 24h"
    )
    assert login_result.client_id, "login() kept no client_id; the refresh grant is bound to it"
    assert login_result.token_endpoint.startswith(cfg.base), (
        f"login() recorded an off-origin token endpoint: {login_result.token_endpoint!r}"
    )

    # The token is only real if the API accepts it.
    me = _whoami(cfg, token)
    assert me.status_code == 200, f"/auth/me rejected the minted token: {me.status_code} {me.text[:300]}"
    data = me.json()["data"]
    assert data["person_id"] == cfg.admin_person
    assert data["company_id"] == cfg.company_uuid
    assert data["company_account_id"] == cfg.company_id
    assert data["key_kind"] == "personal"
    assert sorted(data["scopes"]) == sorted(BASE_SCOPES)
    assert FINANCIALS not in data["scopes"]


# --------------------------------------------------------------------------- #
# 4. Single-use codes and PKCE
# --------------------------------------------------------------------------- #

def test_whoami_rejects_a_bogus_bearer(live_servers):
    """Non-vacuity anchor for every revocation assertion below.

    Those cases conclude "the key was revoked" from a 401 on `/auth/me`. That inference
    is only sound if a 401 means *rejected* rather than "this endpoint always says no" —
    which is what this pins, alongside the 200s the same cases assert beforehand.
    """
    cfg = live_servers
    response = _whoami(cfg, "uku_live_" + secrets.token_urlsafe(24))
    assert response.status_code in (401, 403), (
        f"/auth/me answered {response.status_code} to a token that was never issued — "
        "the revocation assertions in this module would prove nothing."
    )


def test_authorization_code_replay_is_refused_and_revokes_the_minted_key(live_servers):
    """OAuth 2.1: a code is single-use, and reuse revokes what it minted.

    Revocation is asserted over the wire — the first bearer must stop authenticating —
    rather than by reading `api_key.is_deleted`, which would only prove a column moved.
    """
    cfg = live_servers
    grant = _grant(cfg, cfg.admin_cookie, port=54001)
    token = grant.payload["access_token"]
    assert _whoami(cfg, token).status_code == 200, "the freshly minted token did not work"

    replay = _exchange(cfg, code=grant.code, verifier=grant.verifier,
                       client_id=grant.client_id, redirect_uri=grant.redirect_uri)
    assert replay.status_code == 400, f"a replayed code was accepted: {replay.text[:300]}"
    assert replay.json()["error"] == "invalid_grant"

    after = _whoami(cfg, token)
    assert after.status_code in (401, 403), (
        "the replay did not revoke the key it minted — the leaked-code backstop is "
        f"inert. /auth/me still answered {after.status_code}."
    )


def test_wrong_code_verifier_is_rejected_and_the_right_one_still_works(live_servers):
    """PKCE is mandatory. The second half is the non-vacuity check: a code that was
    refused for a bad verifier must still redeem with the correct one, proving the
    refusal was the PKCE comparison and not a generally dead code."""
    cfg = live_servers
    grant = _grant(cfg, cfg.admin_cookie, port=54002, exchange=False)

    wrong, _ = _pkce_pair()
    bad = _exchange(cfg, code=grant.code, verifier=wrong,
                    client_id=grant.client_id, redirect_uri=grant.redirect_uri)
    assert bad.status_code == 400, f"a wrong code_verifier was accepted: {bad.text[:300]}"
    body = bad.json()
    assert body["error"] == "invalid_grant"
    assert "PKCE" in body.get("error_description", ""), body

    good = _exchange(cfg, code=grant.code, verifier=grant.verifier,
                     client_id=grant.client_id, redirect_uri=grant.redirect_uri)
    assert good.status_code == 200, (
        f"the correct verifier was refused too ({good.status_code}: {good.text[:300]}) — "
        "the rejection above proves nothing about PKCE."
    )
    assert _whoami(cfg, good.json()["access_token"]).status_code == 200


def test_a_mismatched_redirect_uri_is_rejected_at_the_token_endpoint(live_servers):
    """The code is bound to the redirect URI it was issued for."""
    cfg = live_servers
    grant = _grant(cfg, cfg.admin_cookie, port=54003, exchange=False)
    response = _exchange(cfg, code=grant.code, verifier=grant.verifier,
                         client_id=grant.client_id,
                         redirect_uri="http://127.0.0.1:54004/callback")
    assert response.status_code == 400, f"a swapped redirect_uri was accepted: {response.text[:300]}"
    assert response.json()["error"] == "invalid_grant"


# --------------------------------------------------------------------------- #
# 5. The financials fences
# --------------------------------------------------------------------------- #

def test_financials_checkbox_grants_financials_to_a_manage_account_holder(live_servers):
    """Asserted FIRST and deliberately: if the checkbox were inert, both refusal cases
    below would pass without proving anything."""
    cfg = live_servers
    redirect_uri = "http://127.0.0.1:54005/callback"
    client_id = _register(cfg, redirect_uri)
    verifier, challenge = _pkce_pair()
    url = _authorize_url(cfg, client_id=client_id, redirect_uri=redirect_uri,
                         challenge=challenge, state=secrets.token_urlsafe(16))

    page = _get_consent_page(url, cfg.admin_cookie)
    assert page.status_code == 200
    assert _FINANCIALS_CHECKBOX_RE.search(page.text), (
        "the consent page offered no financials checkbox to a MANAGE_ACCOUNT holder — "
        f"person {cfg.admin_person} on company {cfg.company_id}"
    )

    code = _code_from(_post_consent(url, cfg.admin_cookie, page.text,
                                    company_id=cfg.company_id, grant_financials=True))
    response = _exchange(cfg, code=code, verifier=verifier,
                         client_id=client_id, redirect_uri=redirect_uri)
    assert response.status_code == 200, f"{response.status_code}: {response.text[:300]}"
    scopes = response.json()["scope"].split()
    assert FINANCIALS in scopes, f"the ticked checkbox did not grant financials: {scopes}"

    me = _whoami(cfg, response.json()["access_token"])
    assert me.status_code == 200
    assert FINANCIALS in me.json()["data"]["scopes"], "the API does not see the granted scope"


def test_a_forged_scope_parameter_cannot_grant_financials(live_servers):
    """`/oauth/register` is unauthenticated, so any client can ask for anything. The
    authorize request's `scope` param must never reach the granted scope."""
    cfg = live_servers
    grant = _grant(cfg, cfg.admin_cookie, port=54006,
                   scope="read write financials admin", grant_financials=False)
    scopes = grant.payload["scope"].split()
    assert sorted(scopes) == sorted(BASE_SCOPES), (
        f"a forged scope parameter was honoured: {scopes}"
    )
    me = _whoami(cfg, grant.payload["access_token"])
    assert me.status_code == 200
    assert sorted(me.json()["data"]["scopes"]) == sorted(BASE_SCOPES)


def test_financials_without_manage_account_issues_no_code_at_all(live_servers):
    """Ticking the box as a non-administrator is a dead end, not a downgrade: the
    handler renders an explainer and mints nothing."""
    cfg = live_servers
    if not cfg.plain_cookie:
        pytest.skip(f"no non-admin identity available — {cfg.no_plain_reason}")

    redirect_uri = "http://127.0.0.1:54007/callback"
    client_id = _register(cfg, redirect_uri)
    _, challenge = _pkce_pair()
    url = _authorize_url(cfg, client_id=client_id, redirect_uri=redirect_uri,
                         challenge=challenge, state=secrets.token_urlsafe(16))

    page = _get_consent_page(url, cfg.plain_cookie)
    assert page.status_code == 200, f"consent GET {page.status_code}: {page.text[:300]}"
    assert _COMPANY_SELECT_RE.search(page.text), (
        f"person {cfg.plain_person} could not reach a consent page for company "
        f"{cfg.company_id} — broken fixture, not a product failure"
    )
    # The render check is deliberately coarse: the checkbox is drawn for anyone holding
    # MANAGE_ACCOUNT on ANY offered account (a Solo tenant administers their own
    # person-type account, so this is common), and the CHOSEN company is re-checked on
    # submit. Assert that documented contract exactly, not a stricter one.
    drawn = bool(_FINANCIALS_CHECKBOX_RE.search(page.text))
    assert drawn == cfg.plain_administers_any, (
        f"financials checkbox drawn={drawn} for person {cfg.plain_person}, but they "
        f"administer some offered account={cfg.plain_administers_any}. The page must "
        "offer the box iff MANAGE_ACCOUNT is held somewhere."
    )

    # Forge it anyway — this is the attack the server-side re-check exists to stop, and
    # the only fence that matters. It is reachable by hand whether or not the box was
    # drawn, because the request is just form fields.
    response = _post_consent(url, cfg.plain_cookie, page.text, company_id=cfg.company_id,
                             grant_financials=True)
    assert response.status_code == 200, (
        f"expected the dead-end explainer, got {response.status_code} "
        f"-> {response.headers.get('Location', '')[:200]}"
    )
    assert "Location" not in response.headers, (
        "a code was issued despite the forged financials grant: "
        f"{response.headers['Location'][:200]}"
    )
    assert "Financial access not allowed" in response.text, response.text[:400]


def test_a_non_admin_login_grants_only_the_base_scopes(live_servers):
    """The same identity, consenting honestly, still gets a working personal key."""
    cfg = live_servers
    if not cfg.plain_cookie:
        pytest.skip(f"no non-admin identity available — {cfg.no_plain_reason}")

    grant = _grant(cfg, cfg.plain_cookie, port=54008)
    assert sorted(grant.payload["scope"].split()) == sorted(BASE_SCOPES)
    me = _whoami(cfg, grant.payload["access_token"])
    assert me.status_code == 200
    assert me.json()["data"]["person_id"] == cfg.plain_person
    assert FINANCIALS not in me.json()["data"]["scopes"]


# --------------------------------------------------------------------------- #
# 6. The refresh grant
# --------------------------------------------------------------------------- #

def test_refresh_grant_returns_a_working_token(live_servers):
    cfg = live_servers
    grant = _grant(cfg, cfg.admin_cookie, port=54009)
    assert grant.payload.get("refresh_token"), (
        "the token response carried no refresh_token — the access token now expires in "
        "24h, so without one every connection needs a fresh browser login daily"
    )
    assert grant.payload["expires_in"] == 24 * 3600

    response = _refresh(cfg, refresh_token=grant.payload["refresh_token"],
                        client_id=grant.client_id)
    assert response.status_code == 200, f"{response.status_code}: {response.text[:300]}"
    rotated = response.json()
    assert rotated["refresh_token"] != grant.payload["refresh_token"], (
        "the refresh token was not rotated — reuse detection cannot work without rotation"
    )
    assert sorted(rotated["scope"].split()) == sorted(BASE_SCOPES)

    me = _whoami(cfg, rotated["access_token"])
    assert me.status_code == 200, f"the refreshed token does not work: {me.text[:300]}"
    assert me.json()["data"]["person_id"] == cfg.admin_person


def test_replaying_a_rotated_refresh_token_kills_the_family(live_servers):
    """RFC 9700 §4.14.2 reuse detection: the replay must not merely fail, it must revoke
    the lineage — including the access key the successful rotation minted."""
    cfg = live_servers
    grant = _grant(cfg, cfg.admin_cookie, port=54010)
    first = grant.payload["refresh_token"]

    rotated = _refresh(cfg, refresh_token=first, client_id=grant.client_id)
    assert rotated.status_code == 200, rotated.text[:300]
    live_token = rotated.json()["access_token"]
    assert _whoami(cfg, live_token).status_code == 200

    replay = _refresh(cfg, refresh_token=first, client_id=grant.client_id)
    assert replay.status_code == 400, f"a replayed refresh token was accepted: {replay.text[:300]}"
    assert replay.json()["error"] == "invalid_grant"

    assert _whoami(cfg, live_token).status_code in (401, 403), (
        "reuse detection did not revoke the family's live access key"
    )
    dead = _refresh(cfg, refresh_token=rotated.json()["refresh_token"],
                    client_id=grant.client_id)
    assert dead.status_code == 400, "the rotated refresh token survived the family revoke"


def test_refresh_requires_the_client_it_was_issued_to(live_servers):
    """A public client has no secret, so `client_id` is the only binding there is."""
    cfg = live_servers
    grant = _grant(cfg, cfg.admin_cookie, port=54011)
    other = _register(cfg, "http://127.0.0.1:54012/callback")

    response = _refresh(cfg, refresh_token=grant.payload["refresh_token"], client_id=other)
    assert response.status_code == 400, f"another client redeemed the token: {response.text[:300]}"
    assert response.json()["error"] == "invalid_grant"
    # The legitimate client must be unharmed by someone else's failed attempt.
    ok = _refresh(cfg, refresh_token=grant.payload["refresh_token"], client_id=grant.client_id)
    assert ok.status_code == 200, f"the rightful client was locked out: {ok.text[:300]}"
