#!/usr/bin/env bash
# smoke — the harness itself works end to end: server boots, the CLI talks to
# it, the request log records what arrived.
. "$(dirname "$0")/../lib/harness.sh"

setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": { "status": 200,
                    "body": {"data":[{"id":1,"name":"Acme"}],"meta":{"total":1,"offset":0,"limit":50}} } }
  ]
}
JSON
start_server

uku clients list
assert_status 0
assert_out_contains '"name": "Acme"' 'the response body reaches stdout'
assert_request_count 1
assert_request 1 method GET
assert_request 1 path /api/v3/clients

# the two auth headers the API contract requires
assert_request 1 X-API-Key "$TEST_API_KEY"
assert_request 1 X-Uku-Company "$TEST_COMPANY"
assert_request_contains 1 User-Agent 'uku-cli/'

# --version needs no server at all
uku --version
assert_status 0
assert_out_contains 'uku ' 'uku --version prints a version'

finish
