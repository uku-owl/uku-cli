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
      "response": {"status": 412, "body": {"error": {"code": "STALE_WRITE"}}} },
    { "method": "GET", "path": "/api/v3/contracts",
      "response": {"status": 400, "body": {"error": {"code": "MISSING_COMPANY", "message": "X-Uku-Company header is required"}}} },
    { "method": "GET", "path": "/api/v3/projects",
      "response": {"status": 400, "body": {"error": {"code": "VALIDATION_ERROR", "message": "q must be at least 2 characters"}}} },
    { "method": "POST", "path": "/api/v3/time-entries",
      "response": {"status": 409, "body": {"error": {"code": "IDEMPOTENCY_KEY_REUSED", "message": "That Idempotency-Key was used with a different body."}}} }
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

# ── 400 — the commonest real failure, and the suite had never scripted one ──
# The whole 400 class was untested: the only match for it anywhere in
# tests/cases was `head -c 400`, a byte count. 400 is what the API actually
# returns for the most common misconfiguration there is.
reset_requests
uku contracts list
assert_status 3 'exit 3 — HTTP 400 is an API error'
assert_err_contains 'HTTP 400' '400 is named in the message'
assert_err_contains 'MISSING_COMPANY' 'and so is the error code the API sent'

# MISSING_COMPANY is an AUTH-configuration failure wearing a 400. It maps to
# exit 3 (api) today, which tells an agent "your data was wrong" — so it retries
# with different data and loops forever. The fix is exit 2, and it is a
# deliberate break of the documented code meanings, so it is deferred to the
# batched exit-code change (refactoring-cli.md § 5.3) rather than smuggled in
# here. This assertion pins TODAY's behaviour so that change is visible when it
# lands, not so it is endorsed.
assert_status 3 'MISSING_COMPANY is exit 3 today — see refactoring-cli.md 5.3'

reset_requests
uku projects list
assert_status 3 'a validation 400 is also exit 3'
assert_err_contains 'at least 2 characters' 'the API message reaches the user verbatim'

# ── 409 — arrived with idempotency keys (C3) and was likewise untested ──
reset_requests
uku time create --data '{"task_id":1,"person_id":1,"start":"2026-01-01T09:00:00Z","end":"2026-01-01T10:00:00Z"}' --yes
assert_status 3 'exit 3 — HTTP 409 is an API error'
assert_err_contains 'HTTP 409' '409 is named'
assert_err_contains 'IDEMPOTENCY_KEY_REUSED' 'and the code says WHICH conflict it was'
assert_request_count 1 'a 409 is never retried — the first attempt may have landed'

finish
