#!/usr/bin/env bash
# names — a record can be named by its id, by its NAME, or by a URL you pasted.
#
# The three things this file exists to pin, because each one is a way a CLI
# that writes invoices could act on the wrong record:
#   * an id costs NOTHING — no lookup request is made for it;
#   * exactly one match is used, and the choice is stated on stderr with the id;
#   * anything else — several matches, no match, a URL from another host —
#     REFUSES and sends nothing.
. "$(dirname "$0")/../lib/harness.sh"

# ─────────────────────────────────────────────────────────────────────
# 1 — resolving a name through the same --q a list already sends
# ─────────────────────────────────────────────────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients", "responses": [
      {"status": 200, "body": {"data":[{"id":41,"name":"Acme Ltd"}],"meta":{"total":1}}},
      {"status": 200, "body": {"data":[{"id":41,"name":"Acme"},{"id":42,"name":"Acme"},{"id":43,"name":"Acme Holding"}],"meta":{"total":3}}},
      {"status": 200, "body": {"data":[{"id":41,"name":"Acme Ltd"},{"id":43,"name":"Acme Holding"}],"meta":{"total":2}}},
      {"status": 200, "body": {"data":[{"id":50,"name":"Baltic Foods"},{"id":51,"name":"Nordic Books"}],"meta":{"total":2}}},
      {"status": 200, "body": {"data":[{"id":7,"name":"Zenith Books"},{"id":8,"name":"Nordic Foods"}],"meta":{"total":2}}},
      {"status": 200, "body": {"data":[{"id":41,"name":"Acme"},{"id":42,"name":"Acme"}],"meta":{"total":2}}},
      {"status": 200, "body": {"data":[{"id":41,"name":"Acme Ltd"}],"meta":{"total":1}}}
    ] },
    { "method": "GET",   "path_regex": "^/api/v3/clients/[0-9]+$",
      "response": {"status": 200, "body": {"data":{"id":41,"name":"Acme Ltd"}}} },
    { "method": "PATCH", "path_regex": "^/api/v3/clients/[0-9]+$",
      "response": {"status": 200, "body": {"data":{"id":41,"name":"Acme Ltd"}}} }
  ]
}
JSON
start_server

note '1 — an id passes straight through: no lookup, no second request'
uku clients get 41
assert_status 0 'clients get <id> exits 0'
assert_request_count 1 'an id costs exactly one request — the get itself'
assert_request 1 path /api/v3/clients/41 'and it goes straight to the record'
assert_err_not_contains '→ client' 'nothing was resolved, so nothing is announced'

note '2 — a unique name resolves, and the CLI says which record it chose'
reset_requests
uku clients get "Acme Ltd"
assert_status 0 'a name that matches exactly one record works'
assert_request_count 2 'one lookup + the get'
assert_request 1 path /api/v3/clients 'the lookup is the list endpoint the command already names'
assert_request 1 query 'q=Acme%20Ltd&limit=100' 'with the same --q a list sends'
assert_request 2 path /api/v3/clients/41 'the resolved id is what gets fetched'
assert_err_contains 'client 41' 'the chosen record is named on stderr'
assert_err_contains 'Acme Ltd' 'with the value that matched'

note '3 — several EXACT matches refuse, list the candidates, and send nothing else'
reset_requests
uku clients get "Acme"
assert_status 1 'an ambiguous name is a usage error'
assert_request_count 1 'only the lookup was sent — no get followed'
assert_err_contains '2 clients match' 'it says how many matched'
assert_err_contains 'refusing to guess' 'and that it will not choose for you'
assert_err_contains '41' 'the first candidate id is listed'
assert_err_contains '42' 'the second candidate id is listed'
assert_err_contains 'pass the id' 'the remedy is to pass an id'

note '3b — several SUBSTRING matches refuse the same way'
reset_requests
uku clients get "Acme"
assert_status 1 'a substring that matches several records is refused too'
assert_request_count 1 'nothing beyond the lookup'
assert_err_contains 'refusing to guess' 'same doctrine, no guessing'
assert_err_contains '43' 'the substring candidates are listed with their ids'

note '4 — no match refuses, and offers what the query did bring back'
reset_requests
uku clients get "Nope Ltd"
assert_status 1 'an unmatched name is a usage error'
assert_request_count 1 'the lookup, and nothing else'
assert_err_contains "no client named 'Nope Ltd'" 'it says plainly that nothing matched'
assert_err_contains 'Baltic Foods' 'and offers what the query DID bring back, rather than picking one of them'
assert_err_contains '50' 'with their ids, so the next command can name one'
assert_err_contains 'uku search' 'and points at the wider look'

note '5 — a unique SUBSTRING match is used (and named)'
reset_requests
uku clients get "zen"
assert_status 0 'a unique substring resolves'
assert_request_count 2 'lookup + get'
assert_request 2 path /api/v3/clients/7 'to the one record that contained it'
assert_err_contains 'Zenith Books' 'and says which one'

note '6 — an ambiguous name on a WRITE refuses before anything is written'
reset_requests
uku clients patch "Acme" --data '{"name":"nope"}' --yes
assert_status 1 'the write is refused as a usage error'
assert_request_count 1 'only the read-only lookup reached the server'
assert_request 1 method GET 'and it was a GET — no write was attempted'
assert_err_contains 'refusing to guess' 'for the same reason as a read'

note '7 — a unique name on a write resolves and the write goes to that id'
reset_requests
uku clients patch "Acme Ltd" --data '{"status":"active"}' --yes
assert_status 0 'the write succeeds'
assert_request_count 2 'lookup + write'
assert_request 2 method PATCH
assert_request 2 path /api/v3/clients/41 'the write went to the resolved id'
assert_err_contains 'client 41' 'and the record it chose was stated before writing'

teardown_case

# ─────────────────────────────────────────────────────────────────────
# 2 — a URL you pasted, and the host check that makes it safe
# ─────────────────────────────────────────────────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path_regex": "^/api/v3/(clients|tasks|invoices)/[0-9]+$",
      "response": {"status": 200, "body": {"data":{"id":41}}} }
  ]
}
JSON
start_server

note '8 — a URL on the configured host resolves to its last id-shaped segment'
uku clients get "$UKU_BASE_URL/whatever/the/route/is/41"
assert_status 0 'a pasted URL works'
assert_request_count 1 'and needs NO lookup — the id is in the URL'
assert_request 1 path /api/v3/clients/41 'the last id in the URL is the id'
assert_err_contains 'client 41' 'the CLI says what it read out of the URL'

note '8b — it works for a resource that has no name field at all'
reset_requests
uku invoices get "$UKU_BASE_URL/x/41?tab=rows#top"
assert_status 0 'an invoice URL resolves'
assert_request 1 path /api/v3/invoices/41 'query string and fragment are not part of the id'

note '9 — a URL on a FOREIGN host is refused and nothing is sent'
reset_requests
uku clients get "http://127.0.0.1.example.com/clients/41"
assert_status 1 'a foreign host is a usage error'
assert_no_requests 'nothing was sent anywhere'
assert_err_contains '127.0.0.1.example.com' 'the refusal names the host that was pasted'
assert_err_contains "can't name a record here" 'and says why it cannot be used'

note '9b — the same host on a different PORT is a different host'
reset_requests
uku clients get "http://127.0.0.1:1/clients/41"
assert_status 1 'a port mismatch is refused'
assert_no_requests 'nothing sent'

note '9c — a URL with no id-shaped segment is refused'
reset_requests
uku clients get "$UKU_BASE_URL/clients/new"
assert_status 1 'a URL that names no record is a usage error'
assert_no_requests 'nothing sent'
assert_err_contains 'no id-shaped segment' 'and says exactly what is missing'

# ── aliases: singular and plural are ONE code path ───────────────────
note '10 — every singular alias reaches the same code path as its plural'
reset_requests
uku client get 41
assert_status 0 'uku client get works'
assert_request 1 path /api/v3/clients/41 'and lands on the clients endpoint'
reset_requests
uku task get 41
assert_status 0 'uku task get works'
assert_request 1 path /api/v3/tasks/41 'tasks'
reset_requests
uku invoice get 41
assert_status 0 'uku invoice get works'
assert_request 1 path /api/v3/invoices/41 'invoices'

note '10b — an alias is the same command in `uku --help --agent`, not a second one'
reset_requests
uku client --help --agent
assert_status 0 'uku client --help --agent exits 0'
assert_out_contains '"command":"clients"' 'the alias describes the canonical command'
assert_out_contains '"aliases":["client"]' 'and declares itself as its alias'
assert_no_requests 'help is offline'

note '10c — the alias is declared surface, so the gate can see it'
for a in client task invoice member product project contract; do
  if "$UKU_BIN" --dump-surface | grep -q "^cmdalias [a-z]* $a\$"; then
    _tap_ok "surface declares the alias '$a'"
  else
    _tap_fail "surface declares the alias '$a'" "no cmdalias fact for $a"
  fi
done

teardown_case

# ─────────────────────────────────────────────────────────────────────
# 3 — --client: resolve a name once, then filter by the id
# ─────────────────────────────────────────────────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data":[{"id":41,"name":"Acme Ltd"}],"meta":{"total":1}}} },
    { "method": "GET", "path": "/api/v3/tasks", "responses": [
      {"status": 200, "body": {"data":[{"id":5,"title":"VAT","client_id":41}],"meta":{"total":1}}},
      {"status": 200, "body": {"data":[{"id":5,"title":"VAT","client_id":41}],"meta":{"total":1}}},
      {"status": 200, "body": {"data":[{"id":5,"title":"VAT","client_id":41},{"id":6,"title":"Payroll","client_id":99}],"meta":{"total":2}}},
      {"status": 200, "body": {"data":[{"id":7,"title":"no client_id on this row"},{"id":8,"title":"nor this one","client_id":null}],"meta":{"total":2}}}
    ] },
    { "method": "POST", "path": "/api/v3/tasks",
      "response": {"status": 201, "body": {"data":{"id":9}}} }
  ]
}
JSON
start_server

note '11 — --client <name> resolves, then filters by client_id'
uku tasks list --client "Acme Ltd"
assert_status 0 'tasks list --client <name> works'
assert_request_count 2 'one lookup + the list'
assert_request 1 path /api/v3/clients 'the lookup goes to clients'
assert_request 2 path /api/v3/tasks
assert_request_contains 2 query 'client_id=41' 'and the list carries the resolved id'
assert_err_contains 'client 41' 'the resolved client is named'

note '11b — --client with an ID costs no lookup at all'
reset_requests
uku tasks list --client 41
assert_status 0 'an id works too'
assert_request_count 1 'and makes no lookup request'
assert_request_contains 1 query 'client_id=41' 'it is sent as it stands'

note '11c — the filter is VERIFIED against the rows that came back'
assert_out_contains '"client_id": 41' 'every returned row belongs to the client asked for'
assert_status 0 'so the command succeeds'

note '11d — a row belonging to ANOTHER client proves the API ignored the filter'
reset_requests
uku tasks list --client 41
assert_status 3 'the command fails (exit 3 — an API-behaviour fact)'
assert_request_count 1 'the check costs no extra request — it reads the rows already fetched'
assert_err_contains 'did not apply that filter' 'it says the endpoint ignored the parameter'
assert_err_contains 'client_id 99' 'and names the row that proves it'
assert_err_contains 'refusing to hand it back' 'rather than pass off an unfiltered list as an answer'

note '11e — a row with no client_id (or a null one) is not a mismatch'
reset_requests
uku tasks list --client 41
assert_status 0 'absence proves nothing, so it does not trip the check'
assert_out_contains 'no client_id on this row' 'and the rows are still returned'

note '12 — --client where the records carry no client_id is a usage error'
reset_requests
uku clients list --client "Acme Ltd"
assert_status 1 'clients list --client is refused'
assert_no_requests 'and nothing — not even a lookup — is sent'
assert_err_contains 'Use --q' 'it names the flag that does work there'

note '13 — --client never reaches a write, and never a --batch line'
reset_requests
printf '{"title":"one"}\n' > "$CASE_DIR/t.jsonl"
uku tasks create --batch @"$CASE_DIR/t.jsonl" --client "Acme Ltd" --yes
assert_status 1 'a batch with --client is a usage error'
assert_no_requests 'no lookup, no creates'
assert_err_contains 'cannot be applied to a batch' 'and says why'

reset_requests
uku tasks create --data '{"title":"one"}' --client "Acme Ltd" --yes
assert_status 1 'a single write with --client is a usage error'
assert_no_requests 'nothing sent'

note '14 — resolving needs jq; without it the CLI refuses instead of guessing'
reset_requests
hide_cmd jq
uku tasks list --client 41
assert_status 1 '--client without jq is a usage error'
assert_no_requests 'and it refuses UP FRONT — the filter it could not verify was never sent'
assert_err_contains '--client needs jq' 'saying which promise it cannot keep'

uku clients get "Acme Ltd"
assert_status 1 'a name without jq is a usage error'
assert_no_requests 'and it refuses BEFORE sending the lookup'
assert_err_contains 'needs jq' 'saying what is missing'
assert_err_contains 'Pass the id instead' 'and what to do instead'

reset_requests
uku clients get 41
assert_status 0 'an id still works without jq — nothing has to be compared'
assert_request_count 1

finish
