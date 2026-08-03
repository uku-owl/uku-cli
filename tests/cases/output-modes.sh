#!/usr/bin/env bash
# output-modes — what lands on stdout vs stderr, and in what shape.
#
# The contract an agent depends on: stdout is the machine's channel, stderr is
# the human's. Not a TTY ⇒ raw JSON, always.
. "$(dirname "$0")/../lib/harness.sh"

setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET",  "path": "/api/v3/clients",
      "response": {"status": 200,
                   "body": {"data":[{"id":1,"name":"Acme","status":"active"}],"meta":{"total":1,"offset":0,"limit":50}}} },
    { "method": "GET",  "path": "/api/v3/members",
      "response": {"status": 200, "body": {"data":[{"id":1}],"meta":{"total":1}}} },
    { "method": "POST", "path": "/api/v3/invoices",
      "response": {"status": 201, "body": {"data": {"id": 9}}} }
  ]
}
JSON
start_server

# ── not a TTY ⇒ raw JSON, byte-for-byte what the server sent ─────────
uku clients list
assert_status 0 'a list exits 0'
assert_equals "$OUT" '{"data": [{"id": 1, "name": "Acme", "status": "active"}], "meta": {"total": 1, "offset": 0, "limit": 50}}' \
  'stdout is the raw response body — no pretty-printing, no table'
assert_err_empty 'a successful read writes nothing to stderr'

# ── --json is the same thing, explicitly ─────────────────────────────
reset_requests
uku clients list --json
assert_status 0 '--json exits 0'
assert_true 'stdout is valid JSON' sh -c "printf '%s' '$OUT' | jq -e . >/dev/null"
assert_out_contains '"name": "Acme"' 'the payload is there'

# ── --fields projects the rows, in JSON too ──────────────────────────
# --json is the non-TTY default, so a flag that only worked on a TTY did
# nothing at all for a script or an agent. It now selects keys in both modes.
reset_requests
uku clients list --fields id,name
assert_status 0 '--fields is accepted'
assert_true 'stdout is still valid JSON' sh -c "printf '%s' '$OUT' | jq -e . >/dev/null"
assert_true 'each row carries exactly the named keys, in that order' \
  sh -c "printf '%s' '$OUT' | jq -e '.data[0] | keys_unsorted == [\"id\",\"name\"]' >/dev/null"
assert_true 'the values are the real ones' \
  sh -c "printf '%s' '$OUT' | jq -e '.data[0].id == 1 and .data[0].name == \"Acme\"' >/dev/null"
assert_true 'an unnamed field is gone, not just blank' \
  sh -c "printf '%s' '$OUT' | jq -e '.data[0] | has(\"status\") | not' >/dev/null"
assert_out_contains '"meta"' 'the envelope is left alone'
assert_err_empty 'and it is not warned about'

# a key no row has comes back null, so every row keeps the same shape
reset_requests
uku clients list --fields id,nope
assert_status 0 '--fields with an unknown key still exits 0'
assert_true 'the missing key is present and null' \
  sh -c "printf '%s' '$OUT' | jq -e '.data[0] | keys_unsorted == [\"id\",\"nope\"] and .nope == null' >/dev/null"

# without --fields nothing is projected — the raw body is still byte-for-byte
reset_requests
uku clients list
assert_equals "$OUT" '{"data": [{"id": 1, "name": "Acme", "status": "active"}], "meta": {"total": 1, "offset": 0, "limit": 50}}' \
  'and a list without --fields is untouched'

# --fields still needs a value
reset_requests
uku clients list --fields
assert_status 1 '--fields with no value is a usage error'
assert_err_contains 'needs a value' 'and says so'
assert_no_requests 'nothing sent'

# ── --quiet suppresses info(), and only info() ───────────────────────
reset_requests
uku invoices create --data '{"client_id":1}' --yes
assert_status 0 'an invoice create succeeds'
assert_err_contains 'Invoice created.' 'the info line goes to stderr by default'
assert_out_contains '"id": 9' 'the record itself goes to stdout'

reset_requests
uku invoices create --data '{"client_id":1}' --yes --quiet
assert_status 0 '--quiet still succeeds'
assert_err_not_contains 'Invoice created.' '--quiet suppresses the info line'
assert_out_contains '"id": 9' 'but never suppresses stdout'

reset_requests
uku invoices create --data '{"client_id":1}' --yes -q
assert_err_not_contains 'Invoice created.' '-q is the same flag'

# ── warnings and errors are NOT suppressed by --quiet ────────────────
reset_requests
uku definitely-not-a-command --quiet
assert_status 1 'an unknown command is still an error under --quiet'
assert_err_contains 'unknown command' 'the error still reaches stderr'

# ── NO_COLOR / --no-color: no escape sequences anywhere ──────────────
reset_requests
uku clients list --no-color
assert_status 0 '--no-color exits 0'
if printf '%s%s' "$OUT" "$ERR" | grep -q "$(printf '\033')"; then
  _tap_fail 'no ANSI escapes in the output' 'found an escape sequence'
else
  _tap_ok 'no ANSI escapes in the output'
fi

# ── the JSON contract of auth status ─────────────────────────────────
reset_requests
uku auth status --json
assert_status 0 'auth status --json exits 0'
assert_true 'auth status --json is one parseable object' \
  sh -c "printf '%s' '$OUT' | jq -e 'has(\"account\") and has(\"base\") and has(\"company\") and has(\"key_masked\") and has(\"valid\")' >/dev/null"

# ── --version / help write to stdout and touch nothing ───────────────
reset_requests
uku --version
assert_status 0 '--version exits 0'
assert_out_contains 'uku ' 'the version is on stdout'
assert_no_requests '--version is offline'

reset_requests
uku help batch
assert_status 0 'uku help batch exits 0'
assert_out_contains 'THE LEDGER' 'the batch help card is printed'
assert_no_requests 'help is offline'

reset_requests
uku --help
assert_status 0 '--help exits 0'
assert_out_contains 'EXIT CODES' 'the global usage lists the exit codes'
assert_no_requests 'help is offline'

teardown_case

# ── C5 — the API's warnings[] on a 2xx ───────────────────────────────
# A warning means the request SUCCEEDED and there is something about it the
# caller should know: TIME_ENTRY_OVERLAP is "your time entry was accepted and
# it overlaps one you already have". The CLI read .data and .meta and dropped
# warnings on the floor, so nobody was ever told.
#
# The channel split is the contract being pinned. stdout must stay exactly the
# API body — a warning that leaked into it would corrupt a parsed document —
# so warnings go to stderr, which also means --json callers still get them.
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/time-entries",
      "response": {"status": 200, "body": {
        "data": [{"id": 7}], "meta": {"total": 1},
        "warnings": [{"code": "TIME_ENTRY_OVERLAP", "message": "Time entry period overlaps an existing entry for this person."}]}} },
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data": [{"id": 1, "name": "Acme"}], "meta": {"total": 1}, "warnings": null}} }
  ]
}
JSON
start_server

note 'C5 — a warning reaches stderr, and stdout is untouched'
uku --json time list
assert_status 0 'the request succeeded — a warning is not a failure'
assert_err_contains 'TIME_ENTRY_OVERLAP' 'the code is on stderr'
assert_err_contains 'overlaps an existing entry' 'with the message the API sent'
# NOT assert_out_not_contains: under --json stdout is the RAW API body, and the
# body genuinely carries warnings[]. The property that matters is that the CLI
# adds nothing to stdout — the body is byte-for-byte what the server sent, and
# the human-readable line goes to the other channel.
assert_true 'stdout is still parseable JSON' \
  sh -c "printf '%s' '$OUT' | jq -e '.data' >/dev/null"
assert_true 'and stdout is the API body verbatim, with nothing spliced in' \
  sh -c "printf '%s' '$OUT' | jq -e '.warnings[0].code == \"TIME_ENTRY_OVERLAP\" and (.data|length) == 1' >/dev/null"
assert_out_not_contains '!' 'the rendered "  ! CODE: message" line is not on stdout'

# The TTY path is where interleaving would actually corrupt something: stdout
# there is a rendered table, not a document, and a warning printed into it
# would sit between the rows.
uku_tty time list
assert_status 0 'the same call on a real tty succeeds'
assert_err_contains 'TIME_ENTRY_OVERLAP' 'the warning is still on stderr there'

note 'C5 — --agent carries them in the envelope instead'
uku --agent time list
assert_status 0 'the agent run succeeds'
assert_true 'the envelope has a warnings key' \
  sh -c "printf '%s' '$OUT' | jq -e 'has(\"warnings\")' >/dev/null"
assert_true 'carrying the code the API sent' \
  sh -c "printf '%s' '$OUT' | jq -e '.warnings[0].code == \"TIME_ENTRY_OVERLAP\"' >/dev/null"
assert_err_not_contains 'TIME_ENTRY_OVERLAP' \
  'and NOT also on stderr — one document, not two channels to reconcile'

# Non-vacuity: if warnings were printed unconditionally, every assertion above
# would pass without the CLI ever reading the field.
note 'C5 — a response without warnings says nothing'
uku --json clients list
assert_status 0 'a clean response succeeds'
assert_err_not_contains '!' 'nothing is printed when there is nothing to say'

# uku() is a harness SHELL FUNCTION — it does not exist inside sh -c, which
# would silently run some other uku (or none) and assert nothing.
uku --agent clients list
assert_true 'and the agent envelope reports null rather than inventing an empty list' \
  sh -c "printf '%s' '$OUT' | jq -e '.warnings == null' >/dev/null"

finish
