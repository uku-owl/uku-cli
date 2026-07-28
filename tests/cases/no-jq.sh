#!/usr/bin/env bash
# no-jq — the README's promise: "jq is used for pretty tables when present,
# but is never required" and "--json always gives you raw JSON". This file is
# the only place that promise is checked against a box that genuinely has no
# jq — every other case runs with the developer's real jq on PATH.
#
# hide_cmd (tests/lib/harness.sh) makes `command -v jq` fail while every other
# external tool bin/uku reaches for (curl, python3, shasum, column, …) stays
# resolvable, via a symlink farm. Section 0 proves the helper itself works
# before anything is built on top of it. Because jq is hidden, assertions in
# this file do NOT pipe $OUT through jq — that would silently re-hide the very
# thing under test — they match on the literal (already-JSON-shaped or
# manually-built) strings bin/uku itself produced.
. "$(dirname "$0")/../lib/harness.sh"

# ── 0. hide_cmd self-check ────────────────────────────────────────────
setup_case
server_script <<'JSON'
{ "routes": [] }
JSON
start_server
hide_cmd jq
assert_true 'jq is not resolvable once hidden' \
  sh -c '! command -v jq >/dev/null 2>&1'
assert_true 'curl is still resolvable' \
  sh -c 'command -v curl >/dev/null 2>&1'
assert_true 'python3 is still resolvable' \
  sh -c 'command -v python3 >/dev/null 2>&1'
teardown_case

# ── 1. the headline promise: a plain list still works, real data out ──
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200,
                   "body": {"data":[{"id":1,"name":"Acme","status":"active","type":"co"}],
                            "meta":{"total":1,"offset":0,"limit":50}}} }
  ]
}
JSON
start_server
hide_cmd jq

uku clients list
assert_status 0 'clients list still exits 0 with no jq'
assert_out_contains '"name": "Acme"' 'and the real data is on stdout'
assert_out_contains '"id": 1' 'the whole row is there, not a stub'
assert_err_empty 'nothing about the missing jq leaks into a clean read'
teardown_case

# ── 2. --all: warns it can only show page one, still succeeds ─────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200,
                   "body": {"data":[{"id":1,"name":"Acme"}],
                            "meta":{"total":4,"offset":0,"limit":50}}} }
  ]
}
JSON
start_server
hide_cmd jq

uku clients list --all
assert_status 0 '--all still exits 0 with no jq'
assert_err_contains '--all needs jq to combine pages' 'and says exactly why'
assert_err_contains 'showing the first page only' 'and what it did instead'
assert_out_contains '"name": "Acme"' 'the first page is still real data'
assert_request_count 1 'only one page was ever fetched — jq is what combines pages'
teardown_case

# ── 3. --fields: warns, shows every field, still exits 0 ──────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200,
                   "body": {"data":[{"id":1,"name":"Acme","status":"active","type":"co"}],
                            "meta":{"total":1}}} }
  ]
}
JSON
start_server
hide_cmd jq

uku clients list --fields id,name
assert_status 0 '--fields still exits 0 with no jq'
assert_err_contains '--fields needs jq to select keys from JSON output' 'and says why'
assert_err_contains 'showing every field' 'and what it did instead'
assert_out_contains '"status": "active"' 'a field NOT named in --fields is still shown'
assert_out_contains '"type": "co"' 'every field, not just the ones asked for'
teardown_case

# ── 4. --skip-existing REFUSES outright — exit 1, nothing sent ────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "POST", "path": "/api/v3/tasks",
      "response": {"status": 201, "body": {"data": {"id": 101}}} }
  ]
}
JSON
start_server
hide_cmd jq

LINES="$CASE_DIR/tasks.jsonl"
printf '{"title":"one"}\n' > "$LINES"

uku tasks create --batch @"$LINES" --yes --skip-existing --match-on title
assert_status 1 '--skip-existing without jq is a usage error, not a best-effort guess'
assert_err_contains '--skip-existing needs jq to compare a field exactly' 'and says why'
assert_err_contains 'Nothing was sent' 'and is explicit that nothing went out'
assert_no_requests 'not even the match-probe GET was sent'
teardown_case

# ── 5. uku doctor: still runs and reports something sensible ──────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/VERSION",       "response": {"status": 200, "body": "0.3.0\n"} },
    { "method": "GET", "path": "/api/v3/members", "response": {"status": 200, "body": {"data": [{"id": 1}]}} }
  ]
}
JSON
start_server
hide_cmd jq

uku doctor
assert_status 0 'doctor (text) still exits 0 with no jq'
assert_out_contains 'uku doctor' 'the heading is still there'
assert_out_contains 'curl present' 'individual checks still render'
assert_out_contains 'jq missing' 'and it correctly reports its own missing dependency'
assert_out_contains 'signed in' 'the credential check still ran (no jq needed for that path)'
teardown_case

# ── 5b. uku doctor --json emits real JSON with no jq on the box ──────
# This section used to pin a broken behaviour: without jq, --json printed the
# raw "level|message" accumulator rows verbatim — no braces, no quoting, not
# JSON — and still exited 0, so a script parsing it got garbage and no signal.
# That contradicted the README twice over ("jq is never required", "--json
# always gives you raw JSON"), and it broke on precisely the bare machine that
# `doctor` exists to diagnose. Fixed: the object is now assembled in pure bash
# with _json_str, the same escaping the batch ledger already relies on.
# Both paths must agree on shape, so assert the shape, not the text.
setup_case
server_script <<'JSON'
{ "routes": [ { "method": "GET", "path": "/VERSION", "response": {"status": 200, "body": "0.3.0\n"} } ] }
JSON
start_server
clear_env_creds
# hide_cmd replaces PATH for this whole shell, not just for the CLI, so the
# absolute path to the real jq has to be captured BEFORE hiding it — otherwise
# the assertions below would silently have no parser either.
REAL_JQ="$(command -v jq)"
hide_cmd jq

uku doctor --json
assert_status 0 'doctor --json exits 0'
assert_out_contains '{"checks":[' 'the object opens the way the jq path does'
assert_out_contains '"level":"warn"' 'levels are quoted JSON strings'
assert_out_contains '"ok":true' 'the verdict is a JSON boolean, not a word'
# The real proof is that a parser accepts it. assert_true runs its arguments
# directly — no shell — so each one is passed as its own word.
assert_true 'the output parses as JSON' "$REAL_JQ" -e . "$OUT_FILE"
assert_true 'checks is a non-empty array' \
  "$REAL_JQ" -e '.checks | type == "array" and length > 0' "$OUT_FILE"
assert_true 'jq-missing is reported as one of the checks' \
  "$REAL_JQ" -e '[.checks[].message] | any(test("jq missing"))' "$OUT_FILE"
teardown_case

# ── 6. --batch with no jq: still runs end to end, JSON output by hand ──
# _batch_emit, _canon_line, _body_id and the per-line "is this a JSON object?"
# check all carry an explicit non-jq fallback (bin/uku:1076-1097, 993-995,
# 1198), so a plain batch (no --skip-existing) is NOT one of the places the
# promise breaks — pinned here as the good case, for contrast with §5b.
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "POST", "path": "/api/v3/tasks",
      "responses": [
        {"status": 201, "body": {"data": {"id": 101}}},
        {"status": 201, "body": {"data": {"id": 102}}}
      ] }
  ]
}
JSON
start_server
hide_cmd jq

LINES="$CASE_DIR/tasks.jsonl"
printf '{"title":"one"}\n{"title":"two"}\n' > "$LINES"

uku tasks create --batch @"$LINES" --yes
assert_status 0 'a plain batch still exits 0 with no jq'
assert_request_count 2 'both lines were sent'
assert_out_contains '"outcome":"created"' 'each result line is hand-built valid-shaped JSON'
assert_out_contains '"id":"101"' 'and carries the real id the server returned'
assert_out_contains '"id":"102"' 'for both lines'
assert_err_contains '2 created' 'the human summary on stderr is unaffected'
RID="$(ls "$UKU_CONFIG_HOME/batches" 2>/dev/null | head -n1)"
assert_true 'the ledger was still written (the ledger never needed jq)' test -n "$RID"
teardown_case

finish
