#!/usr/bin/env bash
# phase4 — C2 (tasks complete/reopen), C4 (the search union), C8/C13
# (capabilities). Everything here was verified against a real API v3 server on
# :8890 first; these pin the wire contract that was observed there.
. "$(dirname "$0")/../lib/harness.sh"

# ── C2 — the real completion path ────────────────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET",  "path": "/api/v3/tasks/41",
      "response": {"status": 200, "body": {"data": {"id": 41, "title": "Q3 close", "status": "new"}}} },
    { "method": "POST", "path": "/api/v3/tasks/41/complete",
      "response": {"status": 200, "body": {"data": {"id": 41, "status": "finished", "finished_at": "2026-08-04T09:00:00Z"}}} },
    { "method": "POST", "path": "/api/v3/tasks/41/reopen",
      "response": {"status": 200, "body": {"data": {"id": 41, "status": "in_progress", "finished_at": null}}} },
    { "method": "POST", "path": "/api/v3/tasks/42/complete",
      "response": {"status": 400, "body": {"error": {"code": "VALIDATION_ERROR", "message": "required checklist is incomplete"}}} },
    { "method": "POST", "path": "/api/v3/tasks/43/complete",
      "response": {"status": 422, "body": {"error": {"code": "VALIDATION_ERROR", "message": "task has no active client"}}} }
  ]
}
JSON
start_server

note '1 — complete posts to /complete, with NO body'
uku tasks complete 41 --by-id --yes
assert_status 0 'complete exits 0'
assert_request_count 1 'exactly one request'
assert_request 1 method POST 'it is a POST'
assert_request 1 path /api/v3/tasks/41/complete 'to the action sub-path, not PATCH /tasks/41'
assert_request_empty 1 body 'and it sends no body — the API takes none'
assert_out_contains 'finished' 'the new status comes back'

note '2 — the write is deliberate: no --yes, no TTY, nothing sent'
reset_requests
uku tasks complete 41 --by-id
assert_status 4 'exit 4 — a write still needs --yes'
assert_no_requests 'and nothing reached the server'

note '3 — reopen is its own path, not a status patch'
reset_requests
uku tasks reopen 41 --by-id --yes
assert_status 0 'reopen exits 0'
assert_request 1 path /api/v3/tasks/41/reopen 'POST /reopen'
assert_request_empty 1 body 'also bodyless'

note '4 — C3: the action paths are idempotency-covered, so a key must ride along'
reset_requests
uku tasks complete 41 --by-id --yes
assert_request_contains 1 Idempotency-Key 'uku-' 'an Idempotency-Key rides on the action'

note '5 — a completion-rule refusal is validation (C6), and nothing is retried'
reset_requests
uku tasks complete 42 --by-id --yes
assert_status 8 'exit 8 — HTTP 400 from a completion rule is validation'
assert_err_contains 'checklist' 'the API message reaches the user'
assert_request_count 1 'a 400 is never retried'

note '6 — 422 (no active client) is validation too, not an API error'
reset_requests
uku tasks complete 43 --by-id --yes
assert_status 8 'exit 8 — the 422 these endpoints really emit'

note '7 — neither takes --batch'
reset_requests
printf '{"x":1}\n' > "$CASE_DIR/b.jsonl"
uku tasks complete 41 --by-id --batch "@$CASE_DIR/b.jsonl" --yes
assert_status 1 'exit 1 — complete is one task, not a batch'
assert_no_requests 'nothing sent'
teardown_case

# ── C4 — search is a UNION, and the overlap is tasks alone ───────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data": [{"id": 1, "name": "Acme OU"}], "meta": {"total": 1}}} },
    { "method": "GET", "path": "/api/v3/tasks",
      "response": {"status": 200, "body": {"data": [{"id": 9, "title": "Acme close"}], "meta": {"total": 1}}} },
    { "method": "GET", "path": "/api/v3/members",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/products",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/projects",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/search",
      "response": {"status": 200, "body": {"data": {
        "invoices":  [{"id": 501, "invoice_number": "2026-1"}],
        "contacts":  [{"id": 77, "name": "Acme", "surname": "OU"}],
        "suppliers": [],
        "contracts": [],
        "tasks":     [{"id": 9, "title": "Acme close"}, {"id": 10, "title": "Acme VAT"}],
        "notes":     []
      }}} }
  ]
}
JSON
start_server

note '8 — the union calls BOTH halves'
uku search "Acme" --json
assert_status 0 'search exits 0'
assert_request_count 6 'five list endpoints plus /api/v3/search'
assert_out_contains '"kind":"union"' 'the payload says it is a union, not a fanout'
assert_out_contains '"server_search":true' 'and that the server half answered'

note '9 — the server half contributes what the fan-out cannot reach'
assert_out_contains '"resource":"invoices"' 'invoices came from /search'
assert_out_contains '"resource":"contacts"' 'so did contacts'
assert_out_contains '"resource":"notes"' 'and notes'

note '10 — the dedupe. /search returns TWO tasks, the fan-out returns ONE.'
note '     Non-vacuity first: the two halves must genuinely disagree, or a'
note '     union that double-counted would still look right.'
# The fixture is built so the two halves DISAGREE: /search returns 2 tasks,
# the fan-out 1. Assert that first — if they ever agree, everything below
# passes for free and stops testing the dedupe at all.
assert_equals "$(jq -r '.routes[] | select(.path == "/api/v3/search") | .response.body.data.tasks | length' "$SERVER_SCRIPT")" '2' \
  'the fixture really does return 2 tasks from /search'
assert_equals "$(printf '%s' "$OUT" | jq -r '[.resources[] | select(.resource == "tasks")] | .[0].count')" '1' \
  'while the fan-out reported 1 — the halves disagree, so the next check bites'
assert_equals "$(printf '%s' "$OUT" | jq -r '[.resources[].count] | add')" '4' \
  'total is 4 (client+task+invoice+contact); double-counting tasks would make it 6'
assert_equals "$(printf '%s' "$OUT" | jq -r '[.resources[] | select(.resource == "tasks")] | length')" '1' \
  'tasks appears ONCE in the union, not twice — /search'\''s copy is dropped'
assert_equals "$(printf '%s' "$OUT" | jq -r '[.resources[] | select(.resource == "tasks")] | .[0].path')" '/api/v3/tasks' \
  'and the one that survived is the fan-out'\''s, not /search'\''s'

note '11 — a server with no /search degrades, it does not fail'
teardown_case
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data": [{"id": 1, "name": "Acme"}], "meta": {"total": 1}}} },
    { "method": "GET", "path": "/api/v3/tasks",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/members",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/products",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/projects",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/search",
      "response": {"status": 404, "body": {"error": {"code": "NOT_FOUND"}}} }
  ]
}
JSON
start_server
uku search "Acme" --json
assert_status 0 'a missing /search is NOT a failure — the fan-out half answered'
assert_out_contains '"server_search":false' 'and the payload says so, rather than pretending'
assert_out_contains '"name": "Acme"' 'the client match still came back'

note '12 — but a REAL error from /search still fails, per the doctrine'
teardown_case
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/tasks",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/members",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/products",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/projects",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/search",
      "response": {"status": 500, "body": {"error": {"code": "INTERNAL"}}} }
  ]
}
JSON
start_server
uku search "Acme" --json
assert_status 3 'exit 3 — an HTTP 500 is a failed lookup, never "0 results"'
assert_out_contains '"ok":false' 'and it is marked failed in the payload'

note '13 — --limit is clamped to 20 for the server half, which 400s above it'
teardown_case
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/tasks",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/members",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/products",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/projects",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/search",
      "response": {"status": 200, "body": {"data": {"invoices": [], "contacts": [], "suppliers": [], "contracts": [], "tasks": [], "notes": []}}} }
  ]
}
JSON
start_server
uku search "Acme" --limit 50 --json
assert_status 0 'a --limit above the API bound still succeeds'
assert_request_contains 6 query 'limit=20' 'the server half is clamped to 20, not sent 50'
assert_request_contains 1 query 'limit=50' 'while the fan-out keeps the limit it was given'
teardown_case

# ── C8 / C13 — capabilities, and a --describe that stopped inventing ──
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/capabilities",
      "response": {"status": 200, "body": {"data": {
        "how_to_use": "ask here first",
        "company_timezone": "Europe/Tallinn",
        "entities": {
          "tasks": {"read": true, "create": true, "update": true, "delete": false},
          "teams": {"read": false, "create": false, "update": false, "delete": false,
                    "unavailable_because": "use the dedicated team endpoints. Read teams with GET /teams."}
        },
        "curated_tools": {"search": ["search"]},
        "not_available": []
      }}} }
  ]
}
JSON
start_server

note '14 — C8: capabilities answers with NO credential, like health'
clear_env_creds
uku capabilities --json
assert_status 0 'capabilities exits 0 with no key at all'
assert_request_count 1 'one request'
assert_request 1 path /api/v3/capabilities 'to /capabilities'
assert_request_contains 1 query 'surface=rest' 'defaulting to the rest surface'
assert_request_empty 1 'X-API-Key' 'and it sends no API key, because none is needed'
assert_out_contains 'curated_tools' 'the document comes back whole'

note '15 — the surface argument is passed through, and only rest|mcp are taken'
reset_requests
uku capabilities mcp --json
assert_status 0 'surface=mcp exits 0'
assert_request_contains 1 query 'surface=mcp' 'the mcp surface is requested'

reset_requests
uku capabilities sideways
assert_status 1 'exit 1 — an unknown surface is a usage error'
assert_no_requests 'and nothing was sent'

note '16 — `caps` is the documented alias'
reset_requests
export UKU_API_KEY="$TEST_API_KEY" UKU_COMPANY="$TEST_COMPANY"
uku caps --json
assert_status 0 'the alias works'

note '17 — C13: --describe ASKS, it no longer recites a built-in map'
reset_requests
uku api --describe
assert_status 0 '--describe exits 0'
assert_request_count 1 'it made a request'
assert_request 1 path /api/v3/capabilities 'and asked /capabilities'
assert_out_contains 'openapi.json' 'it names the authoritative document'
assert_out_not_contains 'resource map' 'the old hand-maintained map is gone'

note '18 — the describe filter is not a free regex (C9/C10 class)'
reset_requests
uku api --describe 'tasks;rm -rf /'
assert_status 1 'exit 1 — a resource name is alnum, dash, underscore'
assert_no_requests 'and it refuses before asking anything'
finish
