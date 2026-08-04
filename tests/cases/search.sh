#!/usr/bin/env bash
# search — ONE --q, fanned out over the list endpoints that have a name field.
#
# C4: it is a UNION — the list fan-out PLUS the API's own /api/v3/search. The
# header used to say "there is no server-side global search to lean on", which
# was false and is the reason the drift gate is anchored to the API now.
#
# What is worth pinning: the request count (fan-out + one), that `tasks` is not
# counted twice, that a server WITHOUT /search degrades instead of failing, and
# that an endpoint which ERRORS is reported as failed rather than folded into
# "0 results" — telling someone their firm has no such client when nobody
# actually looked is the worst thing a search can do.
. "$(dirname "$0")/../lib/harness.sh"

setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data":[{"id":41,"name":"Acme Ltd"},{"id":43,"name":"Acme Holding"}],"meta":{"total":2}}} },
    { "method": "GET", "path": "/api/v3/tasks",
      "response": {"status": 200, "body": {"data":[],"meta":{"total":0}}} },
    { "method": "GET", "path": "/api/v3/members",
      "response": {"status": 500, "body": {"error":{"code":"INTERNAL","message":"boom"}}} },
    { "method": "GET", "path": "/api/v3/products",
      "response": {"status": 200, "body": {"data":[{"id":9,"name":"Acme retainer"}],"meta":{"total":1}}} },
    { "method": "GET", "path": "/api/v3/projects",
      "response": {"status": 200, "body": {"data":[],"meta":{"total":0}}} }
  ]
}
JSON
start_server

note '1 — the fan-out: one request per resource, the same --q on each'
uku search "acme" --limit 3
assert_request_count 6 'five list endpoints plus the server-side /search'
assert_request 1 path /api/v3/clients
assert_request 1 query 'q=acme&limit=3' 'the query is the --q a list already takes; --limit is per endpoint'
assert_request 2 path /api/v3/tasks
assert_request 3 path /api/v3/members
assert_request 4 path /api/v3/products
assert_request 5 path /api/v3/projects
assert_request 5 query 'q=acme&limit=3' 'every endpoint gets the same query'

note '2 — what each endpoint returned is reported per endpoint'
assert_out_contains '"query":"acme"' 'the query is echoed'
assert_out_contains '"resource":"clients"' 'clients is reported'
assert_out_contains '"count":2' 'with its own count'
assert_out_contains '"id": 41' 'and the records the API returned, spliced out byte for byte'
assert_out_contains '"count":0' 'an endpoint with no hits reports zero'

note '3 — a FAILING endpoint is reported as failed, never as zero results'
assert_out_contains '"resource":"members","path":"/api/v3/members","ok":false' 'members is marked not-ok'
assert_out_contains '"status":500' 'with the status the server gave'
assert_out_contains '"count":null' 'and NO count — nobody looked, so there is no number'
assert_status 3 'the run exits 3 because an endpoint failed'

note '4 — --agent says it in the summary too'
reset_requests
uku search "acme" --agent
assert_status 3 'the exit code is unchanged under --agent'
assert_out_contains '"ok":true' 'the envelope is still a well-formed result'
assert_out_contains 'FAILED and were not searched' 'and the summary refuses to imply zero'

note '5 — when every endpoint answers, the run exits 0'
teardown_case
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path_prefix": "/api/v3/",
      "response": {"status": 200, "body": {"data":[{"id":1,"name":"Acme Ltd","title":"Acme Ltd"}],"meta":{"total":1}}} }
  ]
}
JSON
start_server
uku search "acme"
assert_status 0 'all five answered → exit 0'
assert_request_count 6 'still one request each, plus /search'
assert_request 1 query 'q=acme&limit=10' 'the default --limit is 10, per endpoint'
assert_out_contains '"count":1' 'each endpoint reports its own hits'
assert_out_not_contains '"ok":false' 'nothing is marked failed'

note '6 — usage'
reset_requests
uku search
assert_status 1 'a search with no query is a usage error'
assert_no_requests 'and sends nothing'
assert_err_contains 'usage: uku search' 'with the usage line'

reset_requests
uku search acme ltd
assert_status 1 'two bare words are refused rather than silently half-used'
assert_no_requests 'nothing sent'
assert_err_contains 'takes ONE query' 'and it says to quote it'

finish
