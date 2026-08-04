"""Server error taxonomy -> typed exception -> exit code.

An agent branches on `$?`. If this mapping drifts, agents start string-matching human
messages, which is exactly what the exit-code contract exists to prevent.
"""
from __future__ import annotations

import httpx
import pytest

from uku_cli import errors
from uku_cli.errors import (
    AuthError,
    ConflictError,
    ForbiddenError,
    NotFoundError,
    RateLimitError,
    ServerError,
    UkuError,
    ValidationError,
)

from .conftest import build_client, error_response, json_response


@pytest.mark.parametrize(
    "status, code, expected_type, expected_exit",
    [
        (400, "VALIDATION_ERROR", ValidationError, 2),
        (422, "INVALID_FILTER_VALUE", ValidationError, 2),
        (415, "UNSUPPORTED_MIME", ValidationError, 2),
        (401, "UNAUTHORIZED", AuthError, 3),
        (403, "FORBIDDEN", ForbiddenError, 4),
        (403, "FINANCIAL_SCOPE_REQUIRED", ForbiddenError, 4),
        (403, "SUBSCRIPTION_READ_ONLY", ForbiddenError, 4),
        (404, "NOT_FOUND", NotFoundError, 5),
        (409, "INVOICE_LOCKED", ConflictError, 6),
        (409, "TIMER_ALREADY_RUNNING", ConflictError, 6),
        (412, "STALE_WRITE", ConflictError, 6),
        (428, "PRECONDITION_REQUIRED", ConflictError, 6),
        (429, "RATE_LIMIT_EXCEEDED", RateLimitError, 7),
        (500, "INTERNAL_ERROR", ServerError, 8),
        (503, "WEBHOOKS_COMING_SOON", ServerError, 8),
    ],
)
def test_status_maps_to_typed_error_and_exit_code(status, code, expected_type, expected_exit):
    client = build_client(lambda request: error_response(status, code))
    with pytest.raises(expected_type) as caught:
        client.get("/anything")
    assert caught.value.exit_code == expected_exit
    assert caught.value.code == code


@pytest.mark.parametrize("code", ["MISSING_COMPANY", "INVALID_COMPANY", "MISSING_AUTH"])
def test_credential_setup_failures_at_400_are_auth_not_validation(code):
    """These are 400s, but the fix is "supply a company/key", not "change your data".

    Mapping them to 2 would send an agent into a retry loop with different payloads.
    """
    client = build_client(lambda request: error_response(400, code))
    with pytest.raises(AuthError) as caught:
        client.get("/clients")
    assert caught.value.exit_code == errors.EXIT_AUTH


def test_details_are_carried_through_to_the_envelope():
    details = [{"field": "title", "message": "Field required", "type": "missing"}]
    client = build_client(lambda request: error_response(400, "VALIDATION_ERROR", "bad", details))
    with pytest.raises(ValidationError) as caught:
        client.post("/tasks", json_body={})
    assert caught.value.to_envelope()["error"]["details"] == details


def test_request_id_is_captured_for_support():
    client = build_client(lambda request: error_response(
        500, "INTERNAL_ERROR", headers={"X-Request-ID": "req-123"}
    ))
    with pytest.raises(ServerError) as caught:
        client.get("/clients")
    assert caught.value.request_id == "req-123"


def test_non_json_error_body_does_not_crash_or_dump_html():
    """A proxy/LB can answer with an HTML page. Say so; don't paste it into context."""
    client = build_client(lambda request: httpx.Response(
        502, text="<html><body>Bad Gateway</body></html>"
    ))
    with pytest.raises(ServerError) as caught:
        client.get("/clients")
    assert "<html>" not in caught.value.message
    assert caught.value.exit_code == 8


def test_transport_failure_is_a_server_error_not_a_generic_one():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("no route to host")

    client = build_client(handler)
    with pytest.raises(ServerError) as caught:
        client.get("/clients")
    assert caught.value.code == "CONNECTION_FAILED"
    assert caught.value.exit_code == 8


def test_unmapped_status_degrades_to_generic_exit_1():
    client = build_client(lambda request: error_response(418, "TEAPOT"))
    with pytest.raises(UkuError) as caught:
        client.get("/clients")
    assert caught.value.exit_code == errors.EXIT_GENERIC


# --------------------------------------------------------------------------- #
# 429 is the ONLY retried status, and it must honor Retry-After.
# --------------------------------------------------------------------------- #

def test_rate_limit_is_retried_reusing_the_same_idempotency_key(monkeypatch):
    monkeypatch.setattr("uku_cli.client.time.sleep", lambda seconds: None)
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        if len(seen) == 1:
            return error_response(429, "RATE_LIMIT_EXCEEDED", headers={"Retry-After": "2"})
        return json_response({"data": {"id": 1}}, status=201)

    result = build_client(handler).post("/tasks", json_body={"title": "x"})

    assert result.status_code == 201
    assert len(seen) == 2
    # A fresh key on the retry would let the server create a second row.
    assert seen[0].headers["idempotency-key"] == seen[1].headers["idempotency-key"]


def test_retry_after_is_honored_and_capped(monkeypatch):
    slept: list[float] = []
    monkeypatch.setattr("uku_cli.client.time.sleep", lambda seconds: slept.append(seconds))

    client = build_client(lambda request: error_response(
        429, "RATE_LIMIT_EXCEEDED", headers={"Retry-After": "99999"}
    ))
    with pytest.raises(RateLimitError):
        client.get("/clients")
    assert slept and all(s <= 60 for s in slept)


def test_server_errors_are_never_retried():
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return error_response(500, "INTERNAL_ERROR")

    with pytest.raises(ServerError):
        build_client(handler).post("/tasks", json_body={})
    assert len(seen) == 1
