"""The ETag must be lifted VERBATIM from the response header.

`format_etag` (backend/api_v3/services/_optimistic_lock.py) builds the header from
`updated_at.isoformat()`, which renders UTC as `+00:00`. The JSON body serializes the
same instant as `...Z`. So an ETag reconstructed from `data["updated_at"]` differs from
the header by a handful of bytes, and `require_if_match` compares byte-for-byte —
a guaranteed 412 STALE_WRITE. This already bit the MCP invoice tools.

The tests below prove three things in order:
  1. the fixture is NOT vacuous — the two candidate strings really do differ;
  2. the client's lifted value is the HEADER one, and the write succeeds;
  3. the bug, re-injected by hand, is caught RED with exit code 6.
"""
from __future__ import annotations

import httpx
import pytest

from uku_cli.errors import ConflictError

from .conftest import build_client

#: What `format_etag` emits: `W/"<updated_at.isoformat()>"` -> `+00:00`.
HEADER_ETAG = 'W/"2026-08-03T10:00:00+00:00"'
#: What the same instant looks like in the JSON body.
BODY_UPDATED_AT = "2026-08-03T10:00:00Z"
#: The tempting, wrong reconstruction.
RECONSTRUCTED_ETAG = f'W/"{BODY_UPDATED_AT}"'


def invoice_api(request: httpx.Request) -> httpx.Response:
    """A miniature of the real optimistic-lock contract."""
    if request.method == "GET":
        if request.url.path.endswith("/mark-paid"):
            # The REAL router: an action sub-route is POST-only. Starlette answers 405.
            return httpx.Response(405, json={
                "error": {"code": "METHOD_NOT_ALLOWED",
                          "message": "Method not allowed for this resource"}})
        return httpx.Response(
            200,
            json={"data": {"id": 7, "status": "sent", "updated_at": BODY_UPDATED_AT}},
            headers={"ETag": HEADER_ETAG},
        )
    if_match = request.headers.get("If-Match")
    if if_match is None:
        return httpx.Response(428, json={
            "error": {"code": "PRECONDITION_REQUIRED",
                      "message": "If-Match header required for financial writes."}
        })
    if if_match != HEADER_ETAG:  # byte-for-byte, exactly like require_if_match
        return httpx.Response(412, json={
            "error": {"code": "STALE_WRITE", "message": "If-Match ETag is stale."}
        })
    return httpx.Response(200, json={"data": {"id": 7, "status": "paid"}})


def test_fixture_is_not_vacuous():
    """Guard the guard: if these ever coincide, every test below passes for free."""
    assert HEADER_ETAG != RECONSTRUCTED_ETAG


def test_etag_is_lifted_from_the_header_verbatim():
    client = build_client(invoice_api)
    result = client.read_for_update("/invoices/7")

    assert result.etag == HEADER_ETAG
    # The value must NOT have been derived from the body.
    assert result.etag != RECONSTRUCTED_ETAG
    assert result.etag != f'W/"{result.data["updated_at"]}"'


def test_write_using_the_header_etag_succeeds():
    client = build_client(invoice_api)
    etag = client.read_for_update("/invoices/7").etag

    result = client.post("/invoices/7/mark-paid", json_body={}, if_match=etag)
    assert result.status_code == 200
    assert result.data["status"] == "paid"


def test_bug_injected_body_reconstructed_etag_is_rejected():
    """RED case — the exact mistake, re-injected.

    Rebuild the ETag from the body's `updated_at` the way a "simplification" would,
    and the server refuses with 412 -> exit code 6.
    """
    client = build_client(invoice_api)
    row = client.read_for_update("/invoices/7").data

    injected = f'W/"{row["updated_at"]}"'  # <-- the bug
    assert injected == RECONSTRUCTED_ETAG

    with pytest.raises(ConflictError) as caught:
        client.post("/invoices/7/mark-paid", json_body={}, if_match=injected)

    assert caught.value.code == "STALE_WRITE"
    assert caught.value.exit_code == 6


def test_missing_if_match_is_a_precondition_error():
    client = build_client(invoice_api)
    with pytest.raises(ConflictError) as caught:
        client.post("/invoices/7/mark-paid", json_body={})
    assert caught.value.code == "PRECONDITION_REQUIRED"
    assert caught.value.exit_code == 6


def test_if_match_auto_reads_the_resource_path(run_cli, capsys):
    """`--if-match auto` on a PATCH of the resource itself GETs that same path."""
    exit_code = run_cli(
        ["api", "PATCH", "/invoices/7", "--if-match", "auto", "--yes", "-d", '{"status":"paid"}'],
        invoice_api,
    )
    assert exit_code == 0
    assert "paid" in capsys.readouterr().out


def test_if_match_from_supplies_the_etag_for_a_write_only_action_route(run_cli, capsys):
    """An action sub-route is POST-only, so the ETag must come from the resource path."""
    exit_code = run_cli(
        ["api", "POST", "/invoices/7/mark-paid",
         "--if-match-from", "/invoices/7", "--yes"],
        invoice_api,
    )
    assert exit_code == 0
    assert "paid" in capsys.readouterr().out


def test_if_match_auto_on_a_write_only_route_explains_itself(run_cli, capsys):
    """Regression: `auto` used to GET the POST-only action route and die on a 405
    with no hint. It must now name --if-match-from and point at the resource path."""
    exit_code = run_cli(
        ["api", "POST", "/invoices/7/mark-paid", "--if-match", "auto", "--yes"],
        invoice_api,
    )
    message = capsys.readouterr().err

    assert exit_code == 2  # usage error, not a confusing METHOD_NOT_ALLOWED
    assert "--if-match-from" in message
    assert "/invoices/7" in message


def test_if_match_and_if_match_from_together_is_a_usage_error(run_cli):
    exit_code = run_cli(
        ["api", "POST", "/invoices/7/mark-paid", "--if-match", HEADER_ETAG,
         "--if-match-from", "/invoices/7", "--yes"],
        invoice_api,
    )
    assert exit_code == 2
