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

# ── --fields is accepted, and (not a TTY) does not change the output ──
# table() falls back to render() whenever stdout is not a TTY, so column
# selection is a TTY-only affordance. See KNOWN ISSUE #4 in tests/run.sh — this is the
# documented behaviour, not a bug, but it is easy to expect otherwise.
reset_requests
uku clients list --fields id,name
assert_status 0 '--fields is accepted'
assert_true 'stdout is still full raw JSON' sh -c "printf '%s' '$OUT' | jq -e '.data[0].status == \"active\"' >/dev/null"
assert_out_contains '"meta"' 'including the fields --fields did not name'

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

finish
