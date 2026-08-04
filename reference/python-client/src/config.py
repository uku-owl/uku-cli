"""Static configuration: base URL, config paths, request defaults, origin comparison.

Also the single place that decides WHERE a credential is allowed to travel
(`assert_base_url_safe`, `announce_destination`, `normalize_api_path`). Those live here,
beside `url_origin`/`same_origin`, because every trust decision in this CLI is an origin
comparison — `oauth._discover` validates discovery metadata against the origin the user
asked for, `client._token_endpoint` refuses to POST a refresh token off-origin, and
`auth.load_credentials` refuses to present a stored credential to another deployment.
One set of helpers, so those four cannot drift apart.
"""
from __future__ import annotations

import os
import sys
import urllib.parse
from pathlib import Path

from .errors import ValidationError

DEFAULT_BASE_URL = "https://app.getuku.com"
API_PREFIX = "/api/v3"

USER_AGENT = "uku-cli/1.0.0"
DEFAULT_TIMEOUT = 30.0

# 429 is the ONLY retried status (see client.py). Everything else is either the
# caller's problem or a state change we must not silently repeat.
MAX_RATE_LIMIT_RETRIES = 3
MAX_RETRY_SLEEP_SECONDS = 60

KEYRING_SERVICE = "uku-cli"
KEYRING_USERNAME = "default"


#: RFC 6761 spellings of "this machine", plus the one real dev convention among them
#: (`api.localhost:4000`). An explicit table, not a pattern guess: `127.0.0.2`, a LAN
#: address and a private hostname all count as REMOTE. The narrow list is what the docs
#: promise, so it is what the code implements.
LOOPBACK_HOSTS = frozenset({"localhost", "127.0.0.1", "::1"})

#: How long a keyring-style blocking call may take before we stop waiting. Lives here
#: with the other transport constants; used by `auth`.
KEYRING_TIMEOUT_SECONDS = 5.0


def resolve_base_url(explicit: str | None = None) -> str:
    """`--base-url` > `UKU_BASE_URL` > production.

    This is the ONE place a destination is settled, so it is also the one place the
    transport fence and the destination announcement run. Every path that is about to
    send a credential — `load_credentials`, `auth login`, `capabilities` — comes through
    here, which is precisely what makes the fence unbypassable.
    """
    base = (explicit or os.environ.get("UKU_BASE_URL") or DEFAULT_BASE_URL).strip().rstrip("/")
    assert_base_url_safe(base)
    announce_destination(base)
    return base


def url_host(url: str) -> str | None:
    """The destination host, lowercased, userinfo dropped. `None` if not http(s).

    Userinfo matters twice over: in `https://app.getuku.com@evil.example/` the
    destination is `evil.example`, and both the refusal and the announcement have to name
    THAT — a sentence reading "sending credentials to app.getuku.com@evil.example" invites
    exactly the glance that stops at the familiar word.
    """
    parsed = urllib.parse.urlsplit(url.strip())
    if parsed.scheme.lower() not in ("http", "https"):
        return None
    try:
        host = parsed.hostname
    except ValueError:          # unparseable authority
        return None
    return host.lower() if host else None


def is_loopback_host(host: str | None) -> bool:
    """Is this host the same machine? See `LOOPBACK_HOSTS` for why the list is narrow.

    Known and accepted: a loopback port forwarded elsewhere (an SSH tunnel) is
    indistinguishable from a local server from inside this process, and is treated
    as local.
    """
    if not host:
        return False
    host = host.strip().lower()
    if host.startswith("[") and host.endswith("]"):     # a bracketed IPv6 literal
        host = host[1:-1]
    return host in LOOPBACK_HOSTS or host.endswith(".localhost")


def assert_base_url_safe(base_url: str) -> None:
    """Refuse a base URL a credential must not travel to. Raises, or returns None.

    Two refusals, both BEFORE anything is sent:

    * not an absolute http(s) URL — a bare host, or junk like `notaurl`, must be refused
      rather than passed through. `httpx` would treat a bare host as a relative path and
      quietly append it to the previous base;
    * plain `http://` to anything but this machine — the bearer token, or the API key and
      company id, would travel unencrypted and readable to anyone on the path, and the
      CLI cannot tell afterwards that they were read. Loopback stays allowed on purpose:
      that is where every dev server and fixture lives, and nothing leaves the machine.
    """
    scheme = urllib.parse.urlsplit(base_url.strip()).scheme.lower()
    host = url_host(base_url)
    if host is None or url_origin(base_url) is None:
        raise ValidationError(
            f"{base_url!r} is not a usable Uku API base URL. Expected an absolute http(s) "
            f"URL, e.g. {DEFAULT_BASE_URL} or http://127.0.0.1:8885.",
            code="INVALID_BASE_URL",
        )
    if scheme == "http" and not is_loopback_host(host):
        raise ValidationError(
            f"Refusing to send Uku credentials in cleartext: the base URL is "
            f"http://{host}, which is not this machine. Your token (or API key and "
            f"company id) would travel unencrypted and readable to anyone on the path. "
            f"Use https://, or a loopback host for local development "
            f"(localhost, 127.0.0.1, [::1], *.localhost).",
            code="INSECURE_BASE_URL",
        )


_DESTINATION_ANNOUNCED = False


def reset_destination_announcement() -> None:
    """Called once at the top of `cli.main` — one announcement per INVOCATION."""
    global _DESTINATION_ANNOUNCED
    _DESTINATION_ANNOUNCED = False


def announce_destination(base_url: str) -> None:
    """One line on stderr when the credentials are not going to the default host.

    Deliberately written straight to `sys.stderr` rather than through any of the
    output-mode machinery: `--quiet` exists to silence progress chatter and `--json`
    exists to make stdout machine-readable, and WHERE YOUR KEY WENT is neither. An agent
    invoking `uku --json --quiet` is exactly the case this line is for — the supervising
    human reads stderr, and if they see a host they did not ask for, that is the signal.

    It is not a prompt and it stops nothing; `assert_base_url_safe` does the stopping.
    """
    global _DESTINATION_ANNOUNCED
    if _DESTINATION_ANNOUNCED:
        return
    if url_origin(base_url) == url_origin(DEFAULT_BASE_URL):
        return
    # Loopback is deliberately silent. Announcing it means a developer working against
    # their own machine sees this line on EVERY command all day, and a warning people
    # learn to skip stops working for the case it exists for — a real remote host that
    # is not production. Suppressing it here costs nothing: cross-origin credential use
    # is refused outright by `load_credentials`, and cleartext to a non-loopback host is
    # refused by `assert_base_url_safe`, so the surviving loopback case is a credential
    # deliberately minted for this machine being used on this machine.
    if is_loopback_host(url_host(base_url)):
        return
    _DESTINATION_ANNOUNCED = True
    # ASCII only, deliberately. This is the one line that must never fail to print: a
    # `→` or an em dash raises UnicodeEncodeError on a stderr opened with a non-UTF-8
    # encoding (a redirected pipe under LC_ALL=C, some CI log collectors), and a crash
    # here would suppress exactly the warning it exists to deliver.
    print(
        f"-> sending Uku credentials to {url_host(base_url)} "
        f"-- not the default {url_host(DEFAULT_BASE_URL)}",
        file=sys.stderr,
    )


def normalize_api_path(path: str) -> str:
    """A path relative to `API_PREFIX`, or a refusal. `..` is REJECTED, never resolved.

    `httpx` resolves dot segments when it merges a path onto `base_url`, so
    `/../../oauth/token` against `https://app.getuku.com/api/v3` becomes
    `https://app.getuku.com/oauth/token` — reached with the caller's credential attached.
    Same host and the user's own credential, so this is not privilege escalation, but it
    steps outside everything the CLI models about v3 (the envelope, the error taxonomy,
    the scopes) and `/oauth/token` in particular is the credential plane.

    Enforced in `client.request`, so it covers the curated commands too: `uku tasks get
    '../../oauth/token'` interpolates straight into `f"/tasks/{task_id}"`.
    """
    raw = path.strip()
    if url_origin(raw) is not None or raw.startswith("//"):
        raise ValidationError(
            f"Refusing the path {path!r}: a path is relative to {API_PREFIX}, not an "
            f"absolute URL. Use --base-url to change which server is called.",
            code="INVALID_PATH",
        )
    candidate = raw if raw.startswith("/") else "/" + raw
    # Both spellings: httpx does not decode `%2e%2e` into a dot segment, but a proxy in
    # front of the API may. Refuse both rather than reason about which layer normalizes.
    for form in (candidate, urllib.parse.unquote(candidate)):
        route = form.split("?", 1)[0].split("#", 1)[0]
        if any(segment == ".." for segment in route.split("/")):
            raise ValidationError(
                f"Refusing the path {path!r}: `..` would escape the {API_PREFIX} prefix "
                f"and send your credential to another route on the server. Pass a path "
                f"relative to {API_PREFIX}, e.g. /tasks/42.",
                code="INVALID_PATH",
            )
    return candidate


def url_origin(url: str) -> str | None:
    """`scheme://host[:port]`, normalized. `None` when this is not an absolute http(s) URL.

    Used by every OAuth trust decision (`oauth._discover`, `client._token_endpoint`), so
    the rules are deliberately strict:

    * anything without an `http`/`https` scheme and a host is `None` — `notaurl` or
      `javascript:…` must be REFUSED, never normalized into something that could match;
    * default ports fold away, scheme and host lowercase;
    * hostnames are NOT resolved. `http://localhost:8885` and `http://127.0.0.1:8885`
      are different origins here, on purpose — this is a string identity check, not a
      "same machine" check, and the URI the user typed is the whole authority.
    """
    parsed = urllib.parse.urlsplit(url.strip())
    scheme = parsed.scheme.lower()
    if scheme not in ("http", "https"):
        return None
    try:
        host, port = parsed.hostname, parsed.port
    except ValueError:          # unparseable port
        return None
    if not host:
        return None
    if port is None or port == (443 if scheme == "https" else 80):
        return f"{scheme}://{host.lower()}"
    return f"{scheme}://{host.lower()}:{port}"


def same_origin(url: str, other: str) -> bool:
    """True only when both are absolute http(s) URLs sharing one origin."""
    origin = url_origin(url)
    return origin is not None and origin == url_origin(other)


def config_dir() -> Path:
    """`$UKU_CONFIG_DIR` > `$XDG_CONFIG_HOME/uku` > `~/.config/uku`."""
    if override := os.environ.get("UKU_CONFIG_DIR"):
        return Path(override)
    xdg = os.environ.get("XDG_CONFIG_HOME")
    base = Path(xdg) if xdg else Path.home() / ".config"
    return base / "uku"


def credentials_path() -> Path:
    return config_dir() / "credentials.json"
