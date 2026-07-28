#!/usr/bin/env bash
# retry-428 — PRECONDITION_REQUIRED means the server refused the write and
# NOTHING happened, which makes exactly one automatic resend safe.
#
# The CLI must: fetch the ETag from the most specific GETable path, re-send the
# original request ONCE carrying If-Match, and never loop.
. "$(dirname "$0")/../lib/harness.sh"

# ── 1. the happy heal: 428 → GET the ETag → re-send once with If-Match ──
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "PATCH", "path": "/api/v3/contracts/41219",
      "responses": [
        {"status": 428, "body": {"error": {"code": "PRECONDITION_REQUIRED"}}},
        {"status": 200, "body": {"data": {"id": 41219, "healed": true}}}
      ] },
    { "method": "GET", "path": "/api/v3/contracts/41219",
      "response": {"status": 200,
                   "body": {"data": {"id": 41219}},
                   "headers": {"ETag": "W/\"2026-07-27T09:23:28.783836+00:00\""}} }
  ]
}
JSON
start_server

uku api PATCH /api/v3/contracts/41219 --data '{"status":"sent"}' --yes
assert_status 0 'the healed write succeeds'
assert_out_contains '"healed": true' 'the SECOND response is what the caller gets'
assert_request_count 3 'exactly three requests: write, ETag read, write again'

assert_request 1 method PATCH 'request 1 is the original write'
assert_request 1 path /api/v3/contracts/41219
assert_request_empty 1 If-Match 'the original write carried no If-Match'

assert_request 2 method GET 'request 2 fetches the ETag'
assert_request 2 path /api/v3/contracts/41219 'from the resource itself'

assert_request 3 method PATCH 'request 3 is the resend'
assert_request 3 If-Match 'W/"2026-07-27T09:23:28.783836+00:00"' 'the resend carries the ETag as If-Match'
assert_request 3 body '{"status":"sent"}' 'the resend carries the ORIGINAL body'
teardown_case

# ── 2. it heals exactly ONCE — a second 428 is not healed again ──────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "PATCH", "path": "/api/v3/contracts/41219",
      "response": {"status": 428, "body": {"error": {"code": "PRECONDITION_REQUIRED"}}} },
    { "method": "GET", "path": "/api/v3/contracts/41219",
      "response": {"status": 200, "body": {"data": {"id": 41219}},
                   "headers": {"ETag": "W/\"v1\""}} }
  ]
}
JSON
start_server

uku api PATCH /api/v3/contracts/41219 --data '{"status":"sent"}' --yes
assert_status 3 'a still-428 resend is an API error (exit 3)'
assert_request_count 3 'never more than one heal: write, read, write — and stop'
assert_err_contains 'HTTP 428' 'the second 428 is reported'
teardown_case

# ── 3. a user-supplied --if-match is NEVER healed ────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "PATCH", "path": "/api/v3/contracts/41219",
      "response": {"status": 428, "body": {"error": {"code": "PRECONDITION_REQUIRED"}}} },
    { "method": "GET", "path": "/api/v3/contracts/41219",
      "response": {"status": 200, "body": {"data": {}}, "headers": {"ETag": "W/\"v2\""}} }
  ]
}
JSON
start_server

uku api PATCH /api/v3/contracts/41219 --data '{"x":1}' --yes --if-match 'W/"mine"'
assert_status 3 'a rejected --if-match is not healed'
assert_request_count 1 'exactly one request — no ETag fetch, no resend'
assert_request 1 If-Match 'W/"mine"' 'the value the user chose was the one sent'
assert_err_contains 'value you supplied was rejected' 'the message says the CLI is not retrying'
teardown_case

# ── 4. no GETable id in the path → nothing to heal with ──────────────
# POST /api/v3/tasks has no id segment, so _etag_candidates finds nothing and
# the 428 is reported straight through. Worth pinning: it is easy to assume a
# collection POST heals like a resource PATCH. It does not.
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "POST", "path": "/api/v3/tasks",
      "response": {"status": 428, "body": {"error": {"code": "PRECONDITION_REQUIRED"}}} }
  ]
}
JSON
start_server

uku api POST /api/v3/tasks --data '{"title":"x"}' --yes
assert_status 3 'a 428 on a collection POST is not healed — KNOWN ISSUE #9'
assert_request_count 1 'no ETag fetch was even attempted'
assert_err_contains 'no ETag could be found' 'the message explains why'
teardown_case

# ── 5. the ETag lookup walks UP to the parent resource ───────────────
# POST /contracts/41219/rows: "rows" is not an id, so the parent contract is
# the candidate — and the server accepts the parent's ETag (measured against
# the real API, per the comment in bin/uku).
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "POST", "path": "/api/v3/contracts/41219/rows",
      "responses": [
        {"status": 428, "body": {"error": {"code": "PRECONDITION_REQUIRED"}}},
        {"status": 201, "body": {"data": {"id": 66131}}}
      ] },
    { "method": "GET", "path": "/api/v3/contracts/41219/rows",
      "response": {"status": 200, "body": {"data": []}} },
    { "method": "GET", "path": "/api/v3/contracts/41219",
      "response": {"status": 200, "body": {"data": {"id": 41219}},
                   "headers": {"ETag": "W/\"parent\""}} }
  ]
}
JSON
start_server

uku api POST /api/v3/contracts/41219/rows --data '{"product_id":1}' --yes
assert_status 0 'the parent ETag heals a child-collection POST'
assert_request_count 3 'write, parent read, write again'
assert_request 2 path /api/v3/contracts/41219 'the collection path itself is skipped (no id)'
assert_request 3 If-Match 'W/"parent"' 'the resend carries the parent ETag'
teardown_case

# ── 6. the ETag read fails → report the 428, do not resend blind ─────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "PATCH", "path": "/api/v3/contracts/41219",
      "response": {"status": 428, "body": {"error": {"code": "PRECONDITION_REQUIRED"}}} },
    { "method": "GET", "path": "/api/v3/contracts/41219",
      "response": {"status": 200, "body": {"data": {"id": 41219}}} }
  ]
}
JSON
start_server

uku api PATCH /api/v3/contracts/41219 --data '{"x":1}' --yes
assert_status 3 'no ETag on the resource → the 428 stands'
assert_request_count 2 'the write was NOT resent without a version'
assert_request 1 method PATCH
assert_request 2 method GET

finish
