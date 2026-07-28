#!/usr/bin/env bash
# retry-429 / 5xx — rate limits and server errors.
#
# Doctrine: a 429'd READ may be waited out and retried; a 429'd or 5xx'd WRITE
# is NEVER retried, because the CLI cannot know whether it landed.
#
# NOTE (measured, see KNOWN ISSUE #3 in tests/run.sh): reads also carry curl's own
# `--retry 2`, and curl retries 429/5xx responses itself. So a rate-limited read
# is sent up to THREE times by curl before the CLI's own "wait for the reset
# window, then retry once" logic ever sees the 429. The counts below are the
# measured truth, not the doctrine's headline.
. "$(dirname "$0")/../lib/harness.sh"

# ── 1. a rate-limited read: curl's 3 attempts, then the CLI waits + retries ──
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "responses": [
        {"status": 429, "body": {"error": {"code": "RATE_LIMITED"}},
         "headers": {"X-RateLimit-Limit": "30", "X-RateLimit-Remaining": "0",
                     "X-RateLimit-Tier": "read", "X-RateLimit-Reset": "{{now+2}}"}},
        {"status": 429, "body": {"error": {"code": "RATE_LIMITED"}},
         "headers": {"X-RateLimit-Reset": "{{now+2}}"}},
        {"status": 429, "body": {"error": {"code": "RATE_LIMITED"}},
         "headers": {"X-RateLimit-Limit": "30", "X-RateLimit-Remaining": "0",
                     "X-RateLimit-Tier": "read", "X-RateLimit-Reset": "{{now+2}}"}},
        {"status": 200, "body": {"data": [{"id": 1}], "meta": {"total": 1}}}
      ] }
  ]
}
JSON
start_server

uku clients list
assert_status 0 'a rate-limited read eventually succeeds'
assert_out_contains '"id": 1' 'the caller gets the successful page'
assert_err_contains 'waiting 2s for the window to reset, then retrying this read once' \
  'the CLI announces the wait and the single retry'
assert_request_count 4 'curl retries the 429 twice, then the CLI waits and retries once'
teardown_case

# ── 2. a rate-limited WRITE is never retried ─────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "POST", "path": "/api/v3/tasks",
      "response": {"status": 429, "body": {"error": {"code": "RATE_LIMITED"}},
                   "headers": {"X-RateLimit-Limit": "30", "X-RateLimit-Remaining": "0",
                               "X-RateLimit-Tier": "write", "X-RateLimit-Reset": "{{now+2}}"}} }
  ]
}
JSON
start_server

uku api POST /api/v3/tasks --data '{"title":"x"}' --yes
assert_status 5 'a 429 on a write is exit 5 (network / retry-later)'
assert_request_count 1 'the write was sent exactly once and never retried'
assert_err_contains 'HTTP 429' 'the rate limit is named'
assert_err_contains 'A WRITE must not be retried' 'the message states the doctrine'
assert_err_contains 'GET to check whether it landed' 'and tells the caller what to do instead'

# ── 2b. the spent write budget is remembered, and paces the NEXT write ──
# The 429 above recorded remaining=0 for the write bucket. With a max wait of
# 0s the CLI must refuse to block — and send nothing.
reset_requests
UKU_RL_MAX_WAIT=0 uku api POST /api/v3/tasks --data '{"title":"y"}' --yes
assert_status 5 'a spent write budget beyond the wait cap is refused'
assert_err_contains 'Refusing to block that long' 'it says it refused rather than blocked'
assert_err_contains 'nothing was sent' 'and that nothing was sent'
assert_no_requests 'the paced write really did send nothing'
teardown_case

# ── 3. a 5xx on a write is never auto-retried ────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "POST", "path": "/api/v3/tasks",
      "response": {"status": 500, "body": {"error": {"code": "INTERNAL"}}} },
    { "method": "PATCH", "path": "/api/v3/clients/5",
      "response": {"status": 503, "body": {"error": {"code": "UNAVAILABLE"}}} }
  ]
}
JSON
start_server

uku api POST /api/v3/tasks --data '{"title":"x"}' --yes
assert_status 3 'a 500 on a write is an API error'
assert_request_count 1 'a 500 write is sent exactly once'
assert_err_contains 'HTTP 500' 'the status is reported'

reset_requests
uku clients patch 5 --data '{"name":"x"}' --yes
assert_status 3 'a 503 on a write is an API error'
assert_request_count 1 'a 503 write is sent exactly once'
teardown_case

# ── 4. a 5xx on a READ is retried — by curl, not by the CLI ──────────
# `case "$method" in GET|HEAD) args+=(--retry 2 …)` in do_request. Pinned here
# because it is invisible from the CLI's own code path and triples the load a
# failing read puts on the API.
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 500, "body": {"error": {"code": "INTERNAL"}}} }
  ]
}
JSON
start_server

uku clients list
assert_status 3 'a 500 on a read is an API error'
assert_request_count 3 'curl --retry 2 sends a failing read three times'

finish
