#!/usr/bin/env bash
# ref-safety — the ways a reference to a record could aim a WRITE at the wrong
# one. Every section here was executed against this fixture and observed doing
# the wrong thing before the fix; each one is that observation, inverted.
#
#   1  an id-shaped NAME ("12345678", "CAFE-1") bypassed resolution entirely
#   2  a whitespace-only reference resolved by substring and wrote
#   3  one page of 100 was trusted while meta.total said 4000
#   4  a newline or tab in a name split the row, so a fragment won the match
#   5  `uku batch show ../profiles/default` printed a live API key on stdout
#   6  --dry-run previewed the resolution GET instead of the write
#   7  a 5xx on a READ handed back the write remedy
. "$(dirname "$0")/../lib/harness.sh"

# ─────────────────────────────────────────────────────────────────────
# 1 — an id-shaped argument on a WRITE is still probed for a name
#
# OBSERVED BEFORE THE FIX: with a client whose NAME is "12345678",
#   uku clients patch "12345678" --data … --yes
# sent exactly one request — PATCH /api/v3/clients/12345678 — with no lookup
# and no announcement. In an accounting firm this is routine, not exotic: a
# Nordic client is referred to by its registry code.
# ─────────────────────────────────────────────────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data":[{"id":900,"name":"12345678"}],"meta":{"total":1}}} },
    { "method": "PATCH", "path_regex": "^/api/v3/clients/[0-9]+$",
      "response": {"status": 200, "body": {"data":{"id":900}}} },
    { "method": "GET", "path_regex": "^/api/v3/clients/[0-9]+$",
      "response": {"status": 200, "body": {"data":{"id":900}}} }
  ]
}
JSON
start_server

note '1 — the collision is found and REFUSED, and no write is sent'
uku clients patch 12345678 --data '{"vat":"x"}' --yes
assert_status 1 'a reference that is both an id and a name is a usage error'
assert_request_count 1 'only the read-only probe reached the server'
assert_request 1 method GET 'and it was a GET'
assert_request 1 path /api/v3/clients 'on the list endpoint, the same one a name uses'
assert_err_contains 'id-shaped' 'the refusal says why the argument is unclear'
assert_err_contains '900' 'and names the record whose NAME it is'
assert_err_contains '--by-id' 'with the flag that means "the id"'
assert_err_contains '--by-name' 'and the flag that means "the name"'
assert_err_contains 'Nothing was written' 'and states plainly that nothing changed'

note '1b — --by-id means the id: no probe at all, straight to that record'
reset_requests
uku clients patch 12345678 --by-id --data '{"vat":"x"}' --yes
assert_status 0 '--by-id resolves the standoff'
assert_request_count 1 'and costs nothing extra — no probe'
assert_request 1 method PATCH
assert_request 1 path /api/v3/clients/12345678 'the write went to the id'

note '1c — --by-name means the name: it resolves, and the write goes elsewhere'
reset_requests
uku clients patch 12345678 --by-name --data '{"vat":"x"}' --yes
assert_status 0 '--by-name resolves the standoff too'
assert_request_count 2 'lookup + write'
assert_request 2 method PATCH
assert_request 2 path /api/v3/clients/900 'and the write went to the record with that NAME'
assert_err_contains 'client 900' 'which is announced before it happens'

note '1d — a READ keeps the cheap passthrough: an id costs no request'
reset_requests
uku clients get 12345678
assert_status 0 'the read succeeds'
assert_request_count 1 'one request — the get itself, no probe'
assert_request 1 path /api/v3/clients/12345678 'straight to the record'

note '1e — the probe runs AFTER the confirm gate, so a refused write sends nothing'
reset_requests
uku clients patch 12345678 --data '{"vat":"x"}'
assert_status 4 'no --yes and no TTY is still exit 4'
assert_no_requests 'and the probe never ran — nothing at all was sent'

teardown_case

# ── 1f — no collision: the probe costs one GET and then gets out of the way ──
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data":[],"meta":{"total":0}}} },
    { "method": "PATCH", "path_regex": "^/api/v3/clients/[0-9]+$",
      "response": {"status": 200, "body": {"data":{"id":41}}} }
  ]
}
JSON
start_server
uku clients patch 41 --data '{"vat":"x"}' --yes
assert_status 0 'an id that is nobody’s name writes as it always did'
assert_request_count 2 'the probe, then the write'
assert_request 1 method GET 'probe first'
assert_request 2 method PATCH 'then the write'
assert_request 2 path /api/v3/clients/41 'to the id that was given'
teardown_case

# ─────────────────────────────────────────────────────────────────────
# 2 — a whitespace-only reference
#
# OBSERVED BEFORE THE FIX:
#   uku clients patch " " --data '{"vat":"x"}' --yes
# announced `→ client 11 — Acme Ltd` and PATCHed it — the substring pass
# matches every name that contains a space.
# ─────────────────────────────────────────────────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data":[{"id":11,"name":"Acme Ltd"}],"meta":{"total":1}}} },
    { "method": "PATCH", "path_regex": "^/api/v3/clients/[0-9]+$",
      "response": {"status": 200, "body": {"data":{"id":11}}} }
  ]
}
JSON
start_server

note '2 — a single space names nothing, and nothing is sent'
uku clients patch " " --data '{"vat":"x"}' --yes
assert_status 1 'a whitespace-only reference is a usage error'
assert_no_requests 'and it is refused before any request at all'
assert_err_contains 'empty' 'the message says the reference is empty'
assert_err_not_contains 'Acme Ltd' 'no record was ever chosen'

note '2b — the same on a read'
reset_requests
uku clients get "   "
assert_status 1 'a whitespace-only reference is refused on a read too'
assert_no_requests 'nothing sent'

note '2c — a reference longer than the cap is refused, not percent-encoded'
reset_requests
LONGREF="$(awk 'BEGIN{ s=""; for(i=0;i<300;i++) s=s "x"; print s }')"
uku clients get "$LONGREF"
assert_status 1 'a 300-character reference is a usage error'
assert_no_requests 'and nothing was encoded or sent'
assert_err_contains 'the limit is 200' 'the cap is named'

note '2d — surrounding whitespace is trimmed, not matched on'
reset_requests
uku clients get "  Acme Ltd  "
assert_status 0 'a padded name still resolves'
assert_request 1 query 'q=Acme%20Ltd&limit=100' 'and the query carries the trimmed value'
assert_err_contains 'client 11' 'to the record it names'

teardown_case

# ─────────────────────────────────────────────────────────────────────
# 3 — one page of 100 vs meta.total
#
# OBSERVED BEFORE THE FIX: with meta.total 4000 and ONE row returned,
#   uku clients patch "Smith" --data … --yes
# resolved to that single row and wrote to it. The design comment claimed a
# server that ignores `q` "degrades to too many matches — never to acting on
# the wrong record"; that only held when two rows IN THE PAGE matched.
# ─────────────────────────────────────────────────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data":[{"id":11,"name":"Smith Ltd"}],"meta":{"total":4000}}} },
    { "method": "PATCH", "path_regex": "^/api/v3/clients/[0-9]+$",
      "response": {"status": 200, "body": {"data":{"id":11}}} }
  ]
}
JSON
start_server

note '3 — a match the lookup could not prove unique is refused'
uku clients patch "Smith" --data '{"vat":"x"}' --yes
assert_status 1 'an unprovable match is a usage error'
assert_request_count 1 'only the lookup was sent — no write followed'
assert_request 1 method GET 'and it was a GET'
assert_err_contains '4000' 'the refusal quotes the total the API reported'
assert_err_contains 'never examined' 'and says what it could not see'

note '3b — a read is held to the same rule: a match nobody can prove is not used'
reset_requests
uku clients get "Smith"
assert_status 1 'the read refuses too'
assert_request_count 1 'the lookup, and nothing else'

teardown_case

# ─────────────────────────────────────────────────────────────────────
# 4 — control characters in a name
#
# OBSERVED BEFORE THE FIX: jq -r '"\(.id)\t\(.name)"' emits a RAW newline, so a
# client named "Acme\nLtd" became two rows. The fragment "Acme" then matched
# EXACTLY, beat the real "Acme Ltd" to it, and the write went to id 900 while
# the CLI announced `→ client 900 — Acme` — a name that record does not have.
# ─────────────────────────────────────────────────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data":[{"id":900,"name":"Acme\nLtd"},{"id":41,"name":"Acme Ltd"}],"meta":{"total":2}}} },
    { "method": "PATCH", "path_regex": "^/api/v3/clients/[0-9]+$",
      "response": {"status": 200, "body": {"data":{"id":900}}} }
  ]
}
JSON
start_server

note '4 — one record is one row, so no fragment can manufacture an exact match'
uku clients patch "Acme" --data '{"vat":"x"}' --yes
assert_status 1 'two records contain "Acme", so it is ambiguous and refused'
assert_request_count 1 'the lookup only — nothing was written'
assert_err_contains 'refusing to guess' 'the standing doctrine applies'
assert_err_contains '900' 'the record with the newline in its name is a candidate'
assert_err_contains '41' 'and so is the one without'

note '4b — the candidate listing is one line per record, control chars neutralised'
assert_err_not_contains '
    Ltd' 'a name with a newline never becomes a second, id-less row'

teardown_case

# ── 4c — a backslash in the reference is a value, not an escape sequence ──
# OBSERVED BEFORE THE FIX: `awk -v v="$q"` processes escapes in the assignment,
# so a client actually named `AB\nCD` could never be matched by that string —
# and the refusal then listed the very record it had just refused.
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data":[{"id":11,"name":"AB\\nCD"}],"meta":{"total":1}}} },
    { "method": "GET", "path_regex": "^/api/v3/clients/[0-9]+$",
      "response": {"status": 200, "body": {"data":{"id":11}}} }
  ]
}
JSON
start_server
uku clients get 'AB\nCD'
assert_status 0 'a name containing a backslash matches itself'
assert_request_count 2 'lookup + get'
assert_request 2 path /api/v3/clients/11 'and resolves to the record that has it'
teardown_case

# ─────────────────────────────────────────────────────────────────────
# 5 — `uku batch show` reads a ledger, never a path
#
# OBSERVED BEFORE THE FIX, on HEAD and on the released v0.3.0:
#   $ uku batch show ../profiles/default
#   UKU_COMPANY=…
#   UKU_KEY=uku_live_…            ← on stdout, exit 0
# cmd_batch show passed its argument to _ledger_file with no validation, while
# run_batch called _valid_name on the same value. The CLI now ships a skill
# telling agents to run `uku batch show <run-id>` from a breadcrumb.
# ─────────────────────────────────────────────────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "POST", "path": "/api/v3/tasks",
      "response": {"status": 201, "body": {"data":{"id":7}}} }
  ]
}
JSON
start_server
write_profile default
set_active_profile default

# A real run first: `..` only escapes once the batches directory exists, and a
# machine that has ever run a batch has it. This is the state the leak was
# found in, not a contrived one.
printf '%s\n' '{"title":"x"}' > "$CASE_DIR/lines.jsonl"
uku tasks create --batch @"$CASE_DIR/lines.jsonl" --yes >/dev/null 2>&1
assert_true 'a batch run has created the ledger directory' \
  test -d "$UKU_CONFIG_HOME/batches"
assert_true 'and the profile with the live key is one level up' \
  test -f "$UKU_CONFIG_HOME/profiles/default"

note '5 — a run-id containing a path is refused, and the key stays in the file'
uku batch show ../profiles/default
assert_status 1 'a path is not a run-id'
assert_out_not_contains 'uku_live_' 'the API key is NOT on stdout'
assert_out_not_contains 'UKU_KEY' 'nor the line it lives on'
assert_err_contains 'run-id' 'the refusal names what a run-id is'
assert_true 'the profile file itself is untouched' \
  grep -q 'UKU_KEY=' "$UKU_CONFIG_HOME/profiles/default"

note '5b — an absolute path is refused the same way'
uku batch show /etc/passwd
assert_status 1 'an absolute path is not a run-id either'
assert_out_not_contains 'root:' 'and nothing of the file reached stdout'

note '5c — a well-formed run-id that does not exist is an ordinary miss'
uku batch show no-such-run
assert_status 1 'still exit 1'
assert_err_contains 'no such batch run' 'but the message is about a missing run, not a bad name'

note '5d — the sibling path, --run-id, was already validated and stays so'
reset_requests
uku tasks create --batch @"$CASE_DIR/lines.jsonl" --run-id '../evil' --yes
assert_status 1 'a --run-id containing a path is refused'
assert_no_requests 'before anything is sent'

teardown_case

# ─────────────────────────────────────────────────────────────────────
# 6 — --dry-run previews the request the user asked about
#
# OBSERVED BEFORE THE FIX: do_request's dry-run branch exits on the FIRST
# request, which since name resolution moved in front of the write is the
# lookup. `uku clients patch "Acme Ltd" … --dry-run` printed
#   [dry-run] would send:  GET …/api/v3/clients?q=Acme%20Ltd&limit=100
# and exited 0. `--client` on a list showed nothing at all.
# ─────────────────────────────────────────────────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data":[{"id":41,"name":"Acme Ltd"}],"meta":{"total":1}}} },
    { "method": "GET", "path": "/api/v3/tasks",
      "response": {"status": 200, "body": {"data":[],"meta":{"total":0}}} }
  ]
}
JSON
start_server

note '6 — the preview is the PATCH, with the resolved id in the path'
uku clients patch "Acme Ltd" --data '{"name":"X"}' --dry-run --yes
assert_status 0 'a dry run exits 0'
assert_request_count 1 'the resolution GET really ran — it is a harmless read'
assert_request 1 method GET 'and it was the lookup'
assert_err_contains '[dry-run] would send' 'a preview was printed'
assert_err_contains 'PATCH' 'and it is the PATCH the user asked about'
assert_err_contains '/api/v3/clients/41' 'aimed at the id that was resolved'
assert_err_contains '{"name":"X"}' 'carrying the body that was supplied'

note '6b — --client on a list previews the list, not the client lookup'
reset_requests
uku tasks list --client "Acme Ltd" --dry-run
assert_status 0 'exit 0'
assert_request_count 1 'the client lookup ran'
assert_err_contains 'GET' 'and the preview is a GET'
assert_err_contains '/api/v3/tasks' 'on the endpoint the command names'
assert_err_contains 'client_id=41' 'with the resolved filter already in the query'

note '6c — a dry-run write by id previews the write, not the collision probe'
reset_requests
uku clients patch 41 --data '{"name":"X"}' --dry-run --yes
assert_status 0 'exit 0'
assert_err_contains 'PATCH' 'the preview is the PATCH'
assert_err_contains '/api/v3/clients/41' 'to the record named'

teardown_case

# ─────────────────────────────────────────────────────────────────────
# 7 — a 5xx remedy is not the same sentence for a read as for a write
#
# OBSERVED BEFORE THE FIX: a 500 on `uku clients list` ended with
#   → the outcome is unknown — GET the resource to see whether the write landed
# Nothing was written. An agent acting on that goes looking for a change that
# was never attempted.
# ─────────────────────────────────────────────────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET",  "path": "/api/v3/clients",
      "response": {"status": 500, "body": {"error": {"code": "INTERNAL"}}} },
    { "method": "POST", "path": "/api/v3/tasks",
      "response": {"status": 500, "body": {"error": {"code": "INTERNAL"}}} }
  ]
}
JSON
start_server

note '7 — a 5xx on a READ says nothing was written'
uku clients list
assert_status 3 'a 500 is an API error'
assert_err_contains 'nothing was written — this was a read' 'and the read is told so'
assert_err_not_contains 'whether the write landed' 'never the write remedy'

note '7a — and under --agent the same split reaches the envelope'
reset_requests
uku clients list --agent
assert_status 3 'still exit 3'
assert_out_contains 'Nothing was written' 'the error text says nothing was written'
assert_out_not_contains 'whether the write landed' 'and the hint is not the write remedy'

note '7b — a 5xx on a WRITE keeps the unknown-outcome remedy'
reset_requests
uku api POST /api/v3/tasks --data '{"title":"x"}' --yes
assert_status 3 'a 500 on a write is an API error'
assert_err_contains 'whether the write landed' 'and the remedy is to go and look'

teardown_case

finish
