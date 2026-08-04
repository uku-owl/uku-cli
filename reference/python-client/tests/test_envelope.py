"""The `{data, meta, warnings}` envelope must be unwrapped in exactly one place."""
from __future__ import annotations

import httpx

from .conftest import build_client, json_response, oauth_credentials


def test_paginated_envelope_is_split_into_parts():
    meta = {"total": 42, "limit": 50, "offset": 0, "has_more": False}
    client = build_client(lambda request: json_response(
        {"data": [{"id": 1}, {"id": 2}], "meta": meta}
    ))
    result = client.get("/clients")

    assert result.data == [{"id": 1}, {"id": 2}]
    assert result.meta == meta
    assert result.warnings is None


def test_warnings_are_preserved():
    warnings = [{"code": "DEPRECATED_FILTER", "message": "use `q`"}]
    client = build_client(lambda request: json_response(
        {"data": {"id": 1}, "warnings": warnings}
    ))
    assert client.get("/clients/1").warnings == warnings


def test_single_envelope_unwraps_to_the_object():
    client = build_client(lambda request: json_response({"data": {"id": 7, "name": "Acme"}}))
    assert client.get("/clients/7").data == {"id": 7, "name": "Acme"}


def test_body_without_a_data_key_passes_through_untouched():
    """`/capabilities` aside, some endpoints answer a bare document. Don't mangle it."""
    client = build_client(lambda request: json_response({"status": "ok", "components": {}}))
    result = client.get("/health")
    assert result.data == {"status": "ok", "components": {}}
    assert result.meta is None


def test_204_yields_no_data():
    client = build_client(lambda request: httpx.Response(204))
    result = client.delete("/notes/3")
    assert result.data is None
    assert result.status_code == 204


def test_envelope_round_trips_for_output():
    client = build_client(lambda request: json_response(
        {"data": [{"id": 1}], "meta": {"total": 1, "limit": 50, "has_more": False}}
    ))
    assert client.get("/clients").envelope() == {
        "data": [{"id": 1}],
        "meta": {"total": 1, "limit": 50, "has_more": False},
    }


# --------------------------------------------------------------------------- #
# Auth-header mode branch — a bearer token derives its tenant server-side, so
# sending X-Uku-Company alongside it would be misleading noise.
# --------------------------------------------------------------------------- #

def test_key_mode_sends_api_key_and_company():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(request.headers)
        return json_response({"data": {}})

    build_client(handler).get("/auth/me")
    assert seen["x-api-key"] == "uku_live_test"
    assert seen["x-uku-company"] == "11111111-2222-3333-4444-555555555555"
    assert "authorization" not in seen


def test_oauth_mode_sends_bearer_and_no_company():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(request.headers)
        return json_response({"data": {}})

    build_client(handler, oauth_credentials()).get("/auth/me")
    assert seen["authorization"] == "Bearer uku_live_oauth"
    assert "x-uku-company" not in seen
    assert "x-api-key" not in seen


def test_anonymous_mode_sends_no_credential_at_all():
    """`/capabilities` is unauthenticated — asking "what can this API do?" must work
    before `uku auth login` has ever run."""
    from uku_cli.auth import Credentials

    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(request.headers)
        return json_response({"data": {"entities": {}}})

    anonymous = Credentials(mode="anonymous", base_url="https://api.test")
    build_client(handler, anonymous).get("/capabilities")
    assert "authorization" not in seen
    assert "x-api-key" not in seen
    assert "x-uku-company" not in seen


def test_writes_mint_an_idempotency_key_and_reads_do_not():
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return json_response({"data": {}})

    client = build_client(handler)
    client.get("/tasks")
    client.post("/tasks", json_body={"title": "x"})

    assert "idempotency-key" not in seen[0].headers
    assert len(seen[1].headers["idempotency-key"]) >= 32


def test_explicit_idempotency_key_is_honored():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen.update(request.headers)
        return json_response({"data": {}})

    build_client(handler).post("/tasks", json_body={}, idempotency_key="fixed-key")
    assert seen["idempotency-key"] == "fixed-key"
