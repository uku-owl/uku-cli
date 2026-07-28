#!/usr/bin/env bash
# api — the escape hatch that reaches any v3 endpoint.
. "$(dirname "$0")/../lib/harness.sh"

setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET",    "path": "/api/v3/time-entries",
      "response": {"status": 200, "body": {"data": [{"id": 5}], "meta": {"total": 1}}} },
    { "method": "POST",   "path": "/api/v3/tasks",
      "response": {"status": 201, "body": {"data": {"id": 77}}} },
    { "method": "DELETE", "path": "/api/v3/tasks/77",
      "response": {"status": 204, "body": ""} },
    { "method": "HEAD",   "path": "/api/v3/members",
      "response": {"status": 200, "body": ""} }
  ]
}
JSON
start_server

# ── GET with --query (repeatable) ────────────────────────────────────
uku api GET /api/v3/time-entries --query client_id=211310 --query limit=5
assert_status 0 'api GET exits 0'
assert_request_count 1
assert_request 1 method GET
assert_request 1 path /api/v3/time-entries
assert_request 1 query 'client_id=211310&limit=5' 'both --query pairs are sent, in order'
assert_out_contains '"id": 5' 'the body reaches stdout'

# a read through `uku api` needs no --yes
assert_status 0 'a GET through the escape hatch is not gated'

# ── the method is case-insensitive ───────────────────────────────────
reset_requests
uku api get /api/v3/time-entries
assert_status 0 'a lower-case method works'
assert_request 1 method GET 'and is upper-cased on the wire'

# ── a path without a leading slash gets one ──────────────────────────
reset_requests
uku api GET api/v3/time-entries
assert_status 0 'a path without a leading slash works'
assert_request 1 path /api/v3/time-entries 'the slash is added'

# ── POST with --data @file ───────────────────────────────────────────
reset_requests
printf '{"title":"from a file","client_id":211310}' > "$CASE_DIR/task.json"
uku api POST /api/v3/tasks --data @"$CASE_DIR/task.json" --yes
assert_status 0 'api POST --data @file exits 0'
assert_request_count 1
assert_request 1 method POST
assert_request 1 body '{"title":"from a file","client_id":211310}' 'the file contents are the body'
assert_request 1 Content-Type 'application/json'
assert_out_contains '"id": 77' 'the created record comes back'

# ── POST with --data @- (stdin) ──────────────────────────────────────
reset_requests
printf '{"title":"from stdin"}' > "$CASE_DIR/stdin.json"
uku_stdin "$CASE_DIR/stdin.json" api POST /api/v3/tasks --data @- --yes
assert_status 0 'api POST --data @- exits 0'
assert_request 1 body '{"title":"from stdin"}' 'stdin became the body'

# ── a missing --data file is a usage error, and sends nothing ────────
reset_requests
uku api POST /api/v3/tasks --data @"$CASE_DIR/nope.json" --yes
assert_status 1 'a missing --data file is a usage error'
assert_err_contains 'data file not found' 'and names it'
assert_no_requests 'nothing sent'

# ── DELETE is gated like any other write ─────────────────────────────
reset_requests
uku api DELETE /api/v3/tasks/77
assert_status 4 'a DELETE with no --yes is refused'
assert_no_requests 'nothing sent'

reset_requests
uku api DELETE /api/v3/tasks/77 --yes
assert_status 0 'a DELETE with --yes goes through'
assert_request 1 method DELETE
assert_request_empty 1 Content-Type 'a DELETE with no body sends no Content-Type'

# ── usage ────────────────────────────────────────────────────────────
reset_requests
uku api GET
assert_status 1 'api with no path is a usage error'
assert_err_contains 'usage: uku api' 'and prints the usage line'
assert_no_requests 'nothing sent'

reset_requests
uku api --describe
assert_status 0 '--describe exits 0'
assert_out_contains 'Uku API v3 — resource map' 'it prints the resource map'
assert_out_contains '/api/v3/time-entries' 'with the endpoints on it'
assert_no_requests '--describe is offline'

reset_requests
uku api --describe tasks
assert_status 0 '--describe <resource> exits 0'
assert_out_contains 'tasks' 'and filters to that resource'
assert_no_requests 'still offline'

finish
