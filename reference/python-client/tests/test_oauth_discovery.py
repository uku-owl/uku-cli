"""`_discover` must not follow a server to another origin. Mocked transport, no network.

The defect this pins: `/.well-known/oauth-authorization-server` reports whatever
`[api_v3] app_base_url` says, which defaults to `https://app.getuku.com` and is unset in
every dev ini. `_discover` used the advertised endpoints verbatim, so `uku auth login
--base-url http://127.0.0.1:8885` opened PRODUCTION's consent page and POSTed the
authorization code to production — a developer testing locally minting a real production
key against the wrong tenant.

The fix is client-side on purpose. The server config is a separate (also real) bug, but a
client that follows whatever a server tells it, to any origin, is the vulnerability.
"""
from __future__ import annotations

import httpx
import pytest

from uku_cli.config import url_origin
from uku_cli.errors import AuthError
from uku_cli.oauth import _discover

LOCAL = "http://127.0.0.1:8885"
PROD = "https://app.getuku.com"
WELL_KNOWN = "/.well-known/oauth-authorization-server"


def discover(handler, base_url: str = LOCAL):
    """Run `_discover` exactly as `login()` does — including `follow_redirects=True`,
    which is what makes the redirect-laundering case below meaningful."""
    with httpx.Client(transport=httpx.MockTransport(handler), follow_redirects=True) as client:
        return _discover(client, base_url)


def serving(document: object, status: int = 200):
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == WELL_KNOWN, f"unexpected fetch: {request.url}"
        return httpx.Response(status, json=document)

    return handler


def metadata(issuer: str, endpoint_origin: str | None = None) -> dict:
    origin = endpoint_origin or issuer
    return {
        "issuer": issuer,
        "authorization_endpoint": f"{origin}/oauth/authorize",
        "token_endpoint": f"{origin}/oauth/token",
        "registration_endpoint": f"{origin}/oauth/register",
    }


# --------------------------------------------------------------------------- #
# Accepted
# --------------------------------------------------------------------------- #

def test_a_matching_issuer_is_accepted_and_its_endpoints_are_used():
    """Non-vacuity for every refusal below: a correct document is still honored, and
    its endpoints are taken from the document rather than re-derived."""
    document = metadata(LOCAL)
    document["authorization_endpoint"] = f"{LOCAL}/oauth/authorize-v2"

    endpoints = discover(serving(document))

    assert endpoints["authorization_endpoint"] == f"{LOCAL}/oauth/authorize-v2"
    assert endpoints["token_endpoint"] == f"{LOCAL}/oauth/token"
    assert endpoints["registration_endpoint"] == f"{LOCAL}/oauth/register"


def test_a_trailing_slash_on_the_issuer_is_not_a_mismatch():
    """Origins are compared, not strings — `issuer` is routinely written with one."""
    document = metadata(LOCAL)
    document["issuer"] = LOCAL + "/"
    assert discover(serving(document))["token_endpoint"] == f"{LOCAL}/oauth/token"


def test_endpoints_absent_from_the_document_fall_back_to_the_base_url():
    document = {"issuer": LOCAL, "token_endpoint": f"{LOCAL}/oauth/token"}
    endpoints = discover(serving(document))
    assert endpoints["authorization_endpoint"] == f"{LOCAL}/oauth/authorize"
    assert endpoints["registration_endpoint"] == f"{LOCAL}/oauth/register"


# --------------------------------------------------------------------------- #
# Refused — the fence itself
# --------------------------------------------------------------------------- #

def test_an_off_origin_issuer_is_refused_with_both_origins_named():
    """The live case: a dev server on :8885 advertising production."""
    with pytest.raises(AuthError) as caught:
        discover(serving(metadata(PROD)))

    assert caught.value.code == "OAUTH_ISSUER_MISMATCH"
    assert caught.value.exit_code == 3
    message = caught.value.message
    # Actionable: BOTH origins, and the config knob that is actually wrong.
    assert LOCAL in message and "app.getuku.com" in message
    assert "app_base_url" in message


def test_an_off_origin_endpoint_is_refused_even_when_the_issuer_matches():
    """Half-honoring a document is the same hole: the browser follows the endpoint, not
    the issuer."""
    with pytest.raises(AuthError) as caught:
        discover(serving(metadata(LOCAL, endpoint_origin=PROD)))
    assert caught.value.code == "OAUTH_ENDPOINT_OFF_ORIGIN"
    assert caught.value.exit_code == 3


def test_a_document_with_no_issuer_is_refused():
    """RFC 8414 requires `issuer`. Treating its absence as "nothing to check" would let
    an attacker bypass the fence by simply omitting the field."""
    document = metadata(LOCAL)
    del document["issuer"]
    with pytest.raises(AuthError) as caught:
        discover(serving(document))
    assert caught.value.code == "OAUTH_ISSUER_MISSING"


@pytest.mark.parametrize("endpoint", ["notaurl", "javascript:alert(1)", "/oauth/authorize", ""])
def test_an_endpoint_that_is_not_an_absolute_http_url_is_never_used(endpoint):
    document = metadata(LOCAL)
    document["authorization_endpoint"] = endpoint
    if endpoint == "":
        # Falsy: treated as absent, so the on-origin default applies.
        assert discover(serving(document))["authorization_endpoint"] == f"{LOCAL}/oauth/authorize"
        return
    with pytest.raises(AuthError) as caught:
        discover(serving(document))
    assert caught.value.code == "OAUTH_ENDPOINT_OFF_ORIGIN"


def test_a_redirect_to_another_origin_cannot_launder_the_issuer():
    """The subtle bypass: 302 the well-known request to production, and production's
    document legitimately says `issuer: https://app.getuku.com`. Comparing against the
    FINAL URL would pass and send the login to production anyway.

    So the fetch does not follow redirects at all, and the anchor is always the base URL
    the user asked for.
    """
    seen: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(str(request.url))
        if request.url.host == "127.0.0.1":
            return httpx.Response(302, headers={"Location": f"{PROD}{WELL_KNOWN}"})
        return httpx.Response(200, json=metadata(PROD))

    endpoints = discover(handler)

    assert all(u.startswith(LOCAL) for u in seen), f"the redirect was followed: {seen}"
    assert endpoints["authorization_endpoint"] == f"{LOCAL}/oauth/authorize"


def test_a_nonsense_base_url_is_refused_before_anything_is_fetched():
    def handler(request: httpx.Request) -> httpx.Response:      # pragma: no cover
        pytest.fail(f"nothing should have been fetched, got {request.url}")

    with pytest.raises(AuthError) as caught:
        discover(handler, base_url="not-a-url")
    assert caught.value.code == "OAUTH_BAD_BASE_URL"


# --------------------------------------------------------------------------- #
# Unreadable document != untrusted document
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("response", [
    httpx.Response(404, json={"error": "nope"}),
    httpx.Response(200, text="<html>login</html>"),          # SPA catch-all
    httpx.Response(200, json=["not", "an", "object"]),
])
def test_an_unreadable_document_falls_back_to_the_base_url_rather_than_failing(response):
    """There is nothing to distrust here, and the defaults are on-origin by
    construction — so a server with no well-known document must still be usable."""
    endpoints = discover(lambda request: response)
    assert endpoints == {
        "authorization_endpoint": f"{LOCAL}/oauth/authorize",
        "token_endpoint": f"{LOCAL}/oauth/token",
        "registration_endpoint": f"{LOCAL}/oauth/register",
    }


def test_an_unreachable_server_falls_back_rather_than_failing():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused")

    assert discover(handler)["token_endpoint"] == f"{LOCAL}/oauth/token"


# --------------------------------------------------------------------------- #
# The origin comparison itself
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("url, expected", [
    ("https://app.getuku.com", "https://app.getuku.com"),
    ("https://APP.GetUku.com:443/oauth/token", "https://app.getuku.com"),
    ("http://127.0.0.1:8885/x", "http://127.0.0.1:8885"),
    ("http://example.com:80", "http://example.com"),
    ("notaurl", None),
    ("javascript:alert(1)", None),
    ("ftp://example.com", None),
    ("//example.com/path", None),
])
def test_url_origin_normalizes_only_what_is_safe_to_normalize(url, expected):
    assert url_origin(url) == expected


def test_loopback_spellings_are_deliberately_different_origins():
    """`localhost` and `127.0.0.1` are not interchangeable here. This is a string
    identity check on the authority the user typed, not a "same machine" check —
    resolving names would reintroduce exactly the ambiguity the fence removes."""
    assert url_origin("http://localhost:8885") != url_origin("http://127.0.0.1:8885")
