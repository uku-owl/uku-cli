#!/usr/bin/env bash
# exit-codes — the stable exit-code contract, one test per code.
#   0 ok · 1 usage · 2 auth (401/403) · 3 API error · 4 write refused
#   5 network · 6 conflict (412)
. "$(dirname "$0")/../lib/harness.sh"

setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/tasks",
      "response": {"status": 401, "body": {"error": {"code": "UNAUTHENTICATED", "message": "bad key"}}} },
    { "method": "GET", "path": "/api/v3/members",
      "response": {"status": 403, "body": {"error": {"code": "SCOPE_DENIED", "message": "needs an All key"}}} },
    { "method": "GET", "path": "/api/v3/products",
      "response": {"status": 404, "body": {"error": {"code": "NOT_FOUND"}}} },
    { "method": "PATCH", "path": "/api/v3/tasks/99",
      "response": {"status": 412, "body": {"error": {"code": "STALE_WRITE"}}} }
  ]
}
JSON
start_server

# ── 0 — a successful read ────────────────────────────────────────────
uku clients list
assert_status 0 'exit 0 — a successful read'

# ── 1 — usage ────────────────────────────────────────────────────────
reset_requests
uku definitely-not-a-command
assert_status 1 'exit 1 — unknown command'
assert_err_contains 'unknown command' 'unknown command says so'
assert_no_requests 'a usage error sends nothing'

reset_requests
uku tasks list --not-a-flag
assert_status 1 'exit 1 — unknown flag'
assert_no_requests 'an unknown flag sends nothing'

# ── 2 — auth ─────────────────────────────────────────────────────────
reset_requests
uku tasks list
assert_status 2 'exit 2 — HTTP 401 is an auth failure'
assert_err_contains 'HTTP 401' '401 is named in the message'

reset_requests
uku members list
assert_status 2 'exit 2 — HTTP 403 is an auth failure'
assert_err_contains 'All-scope key' '403 with a scope code explains the All key'

# not signed in at all is also exit 2, and reaches no network
reset_requests
clear_env_creds
uku clients list
assert_status 2 'exit 2 — no credentials at all'
assert_err_contains 'Not signed in' 'the message says how to sign in'
assert_no_requests 'an unauthenticated run sends nothing'
export UKU_API_KEY="$TEST_API_KEY" UKU_COMPANY="$TEST_COMPANY"

# ── 3 — API error ────────────────────────────────────────────────────
reset_requests
uku products list
assert_status 3 'exit 3 — a non-auth HTTP error'
assert_err_contains 'HTTP 404' 'the status is reported'

# ── 4 — write refused ────────────────────────────────────────────────
reset_requests
uku tasks create --data '{"title":"x"}'
assert_status 4 'exit 4 — a write with no --yes and no TTY'
assert_err_contains 'Refusing a non-interactive write' 'the refusal explains itself'

# ── 5 — network ──────────────────────────────────────────────────────
# port 1 on loopback: nothing listens there. A write is used deliberately —
# GET carries curl --retry, which would make this slow.
reset_requests
uku api POST /api/v3/tasks --data '{"title":"x"}' --yes --base http://127.0.0.1:1
assert_status 5 'exit 5 — the API could not be reached'
assert_err_contains 'network error' 'a network failure says so'
assert_no_requests 'the fixture server saw nothing'

# ── 6 — conflict (412) ───────────────────────────────────────────────
reset_requests
# --by-id: `tasks patch <id>` now PROBES an id-shaped argument for a task
# whose TITLE is that string (tests/cases/ref-safety.sh §1). That probe is a GET
# on the list endpoint, which this fixture deliberately answers 401/500 — so the
# flag says "this really is an id" and keeps the test about the code under test.
uku tasks patch 99 --by-id --data '{"title":"y"}' --yes
assert_status 6 'exit 6 — HTTP 412 is its own exit code'
assert_err_contains 'HTTP 412' '412 is named'
assert_err_contains 'Nothing was written' 'the user is told nothing was written'
assert_request_count 1 '412 is never retried'

finish
