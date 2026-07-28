#!/usr/bin/env bash
# retry-429 / 5xx — rate limits and server errors.
#
# Doctrine: a 429'd READ may be waited out and retried; a 429'd or 5xx'd WRITE
# is NEVER retried, because the CLI cannot know whether it landed.
#
# An HTTP status is NEVER a reason to re-send automatically. curl's own
# `--retry` disagreed — it counts 408/429/5xx as retryable — so a rate-limited
# read used to hit the limiter three times before the CLI's own "wait for the
# reset window, then retry once" logic ever saw the 429. That is gone; the only
# automatic re-send left on a read is the CLI's own, once, after the wait.
. "$(dirname "$0")/../lib/harness.sh"

# ── 1. a rate-limited read: the CLI waits for the reset, then retries ONCE ──
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "responses": [
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
assert_request_count 2 'the 429 reached the CLI itself: one attempt, one retry after the wait'
teardown_case

# ── 1b. a read that stays rate limited is retried exactly once, then reported ──
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 429, "body": {"error": {"code": "RATE_LIMITED"}},
                   "headers": {"X-RateLimit-Limit": "30", "X-RateLimit-Remaining": "0",
                               "X-RateLimit-Tier": "read", "X-RateLimit-Reset": "{{now+2}}"}} }
  ]
}
JSON
start_server

uku clients list
assert_status 5 'a read that stays rate limited is exit 5'
assert_request_count 2 'the wait-and-retry happens once, and only once — no loop'
assert_err_contains 'HTTP 429' 'and the rate limit is reported to the caller'
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
# --by-id: `clients patch <id>` now PROBES an id-shaped argument for a client
# whose NAME is that string (tests/cases/ref-safety.sh §1). That probe is a GET
# on the list endpoint, which this fixture deliberately answers 401/500 — so the
# flag says "this really is an id" and keeps the test about the code under test.
uku clients patch 5 --by-id --data '{"name":"x"}' --yes
assert_status 3 'a 503 on a write is an API error'
assert_request_count 1 'a 503 write is sent exactly once'
teardown_case

# ── 4. a 5xx on a READ is sent ONCE ──────────────────────────────────
# A 500 is an answer from the server, not a transport failure, so nothing
# re-sends it. (It used to be sent three times: curl's own --retry.)
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
assert_request_count 1 'a failing read is sent exactly once — an HTTP status is never re-sent'
teardown_case

# ── 5. a TRANSPORT failure is what a read retries on — once, and reads only ──
# Nothing reaches the fixture here (the base is a dead loopback port), so the
# count comes from the curl spy: one line per curl invocation.
setup_case
server_script <<'JSON'
{ "routes": [] }
JSON
start_server
enable_curl_spy
DEAD='http://127.0.0.1:1'

uku --base "$DEAD" clients list
assert_status 5 'an unreachable host is a network error (exit 5)'
assert_equals "$(grep -c 'api/v3/clients' "$CURL_ARGV_LOG" | tr -d '[:space:]')" '2' \
  'a GET that never connected is re-issued exactly once'
assert_err_contains 'could not reach' 'and then reported, not retried forever'

: > "$CURL_ARGV_LOG"
uku --base "$DEAD" api POST /api/v3/tasks --data '{"title":"x"}' --yes
assert_status 5 'an unreachable write is also exit 5'
assert_equals "$(grep -c 'api/v3/tasks' "$CURL_ARGV_LOG" | tr -d '[:space:]')" '1' \
  'but a WRITE is never re-issued — an interrupted POST may still have landed'

finish
