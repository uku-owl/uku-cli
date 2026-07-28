#!/usr/bin/env bash
# pagination — --all pages through every row, keeps the caller's filters, and
# stops. The row count has to be right, and the loop has to terminate.
. "$(dirname "$0")/../lib/harness.sh"

# ── 1. two pages, then stop ──────────────────────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "responses": [
        {"status": 200, "body": {"data": [{"id": 1, "name": "A"}, {"id": 2, "name": "B"}],
                                 "meta": {"total": 4, "offset": 0, "limit": 200}}},
        {"status": 200, "body": {"data": [{"id": 3, "name": "C"}, {"id": 4, "name": "D"}],
                                 "meta": {"total": 4, "offset": 2, "limit": 200}}},
        {"status": 200, "body": {"data": [], "meta": {"total": 4, "offset": 4, "limit": 200}}}
      ] }
  ]
}
JSON
start_server

uku clients list --all
assert_status 0 '--all exits 0'
assert_request_count 2 'it stops as soon as offset reaches total — no extra probe page'
assert_request 1 query 'limit=200&offset=0' 'the first page drives limit/offset itself'
assert_request 2 query 'limit=200&offset=2' 'the second page continues from what it received'
assert_equals "$(printf '%s' "$OUT" | jq -r '.data | length')" '4' 'all four rows are returned'
assert_equals "$(printf '%s' "$OUT" | jq -r '[.data[].id] | join(",")')" '1,2,3,4' 'in order, without duplicates'
assert_equals "$(printf '%s' "$OUT" | jq -r '.meta.total')" '4' 'the combined meta reports the total'
assert_equals "$(printf '%s' "$OUT" | jq -r '.meta.has_more')" 'false' 'and says there is no more'
teardown_case

# ── 2. --all keeps the caller's filters and overrides limit/offset ───
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/tasks",
      "response": {"status": 200, "body": {"data": [{"id": 9}], "meta": {"total": 1, "offset": 0}}} }
  ]
}
JSON
start_server

uku tasks list --all --status open --q 'ä' --limit 5 --offset 40
assert_status 0 '--all with filters exits 0'
assert_request_count 1 'one page was enough'
assert_request 1 query 'limit=200&offset=0&status=open&q=%C3%A4' \
  'the user filters survive; their limit/offset are replaced by the pager'
teardown_case

# ── 3. a single page without --all is one request, verbatim ──────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data": [{"id": 1}], "meta": {"total": 50, "offset": 0, "limit": 1}}} }
  ]
}
JSON
start_server

uku clients list --limit 1
assert_status 0 'a plain list exits 0'
assert_request_count 1 'without --all there is exactly one request'
assert_request 1 query 'limit=1' 'the caller controls limit'
assert_out_contains '"total": 50' 'the server meta is passed through untouched'

# --offset is passed straight through
reset_requests
uku clients list --limit 10 --offset 30
assert_request 1 query 'limit=10&offset=30' '--offset reaches the server'
teardown_case

# ── 4. an empty first page terminates the loop ───────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0, "offset": 0}}} }
  ]
}
JSON
start_server

uku clients list --all
assert_status 0 'an empty collection exits 0'
assert_request_count 1 'no second page is requested'
assert_equals "$(printf '%s' "$OUT" | jq -r '.data | length')" '0' 'zero rows'

finish
