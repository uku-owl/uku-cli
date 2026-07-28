#!/usr/bin/env bash
# dry-run — --dry-run prints the request, sends nothing, and never reveals the
# API key in clear text on either stream.
. "$(dirname "$0")/../lib/harness.sh"

setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "POST", "path": "/api/v3/tasks",
      "response": {"status": 201, "body": {"data": {"id": 1}}} },
    { "method": "GET",  "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} }
  ]
}
JSON
start_server

# ── a write ──────────────────────────────────────────────────────────
uku tasks create --data '{"title":"Prepare Q1 filing"}' --yes --dry-run
assert_status 0 '--dry-run exits 0'
assert_no_requests '--dry-run sends nothing'
assert_err_contains '[dry-run] would send:' 'it announces itself'
assert_err_contains "POST $UKU_BASE_URL/api/v3/tasks" 'the method and URL are shown'
assert_err_contains 'body: {"title":"Prepare Q1 filing"}' 'the body is shown'
assert_err_contains "X-Uku-Company: $TEST_COMPANY" 'the company header is shown'

# the key: masked, and the raw value absent from BOTH streams
assert_err_contains 'X-API-Key: uku_live_…TAIL' 'the key is shown masked'
assert_err_not_contains "$TEST_API_KEY" 'the raw key is NOT on stderr'
assert_out_not_contains "$TEST_API_KEY" 'the raw key is NOT on stdout'

# ── CURRENT BEHAVIOUR, and it is inconsistent (see the KNOWN ISSUES list in tests/run.sh #2) ──
# A single-record --dry-run without --yes is refused by confirm_write (exit 4)
# before do_request's dry-run printer is ever reached — even though nothing
# would be sent. run_batch, by contrast, deliberately skips the confirm under
# --dry-run, so `… create --batch @f --dry-run` works with no --yes at all.
# Locking in what it does today so a refactor has to decide on purpose.
reset_requests
uku tasks create --data '{"title":"x"}' --dry-run
assert_status 4 'a single --dry-run write without --yes is refused (exit 4) — KNOWN ISSUE #2'
assert_no_requests '--dry-run alone sends nothing'

# ── a read ───────────────────────────────────────────────────────────
reset_requests
uku clients list --q hello --dry-run
assert_status 0 '--dry-run on a read exits 0'
assert_no_requests '--dry-run on a read sends nothing'
assert_err_contains 'GET ' 'the read request is printed'
assert_err_contains 'q=hello' 'the encoded query is part of the printed URL'
assert_err_contains 'no body' 'a GET is shown as having no body'

# ── extra headers and --if-match are shown too ───────────────────────
reset_requests
uku api PATCH /api/v3/tasks/1 --data '{"title":"x"}' --yes --dry-run \
    --header 'X-Trace: abc' --if-match 'W/"v1"'
assert_status 0 '--dry-run with extra headers exits 0'
assert_no_requests 'still nothing sent'
assert_err_contains 'X-Trace: abc' 'a custom header is shown'
assert_err_contains 'If-Match: W/"v1"' 'the If-Match value is shown'
assert_err_not_contains "$TEST_API_KEY" 'the raw key stays absent'

finish
