#!/usr/bin/env bash
# batch — bulk create from a JSONL file: the ledger, --resume, --stop-on-error,
# and the refusals that keep a batch from doing something surprising.
#
# The promise this feature makes is "re-running after an interruption cannot
# duplicate a record". That is what most of this file is about.
. "$(dirname "$0")/../lib/harness.sh"

# outcomes of the last batch run, comma-joined, in input order
outcomes() { printf '%s\n' "$OUT" | jq -r '.outcome' 2>/dev/null | tr '\n' ',' ; }
ids()      { printf '%s\n' "$OUT" | jq -r '.id // "-"' 2>/dev/null | tr '\n' ',' ; }
ledger()   { ls "$UKU_CONFIG_HOME/batches" 2>/dev/null | head -n1; }

# ── 1. the happy path: N lines → N creates, ledger written ───────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "POST", "path": "/api/v3/tasks",
      "responses": [
        {"status": 201, "body": {"data": {"id": 101}}},
        {"status": 201, "body": {"data": {"id": 102}}},
        {"status": 201, "body": {"data": {"id": 103}}}
      ] }
  ]
}
JSON
start_server

LINES="$CASE_DIR/tasks.jsonl"
{ printf '{"title":"one"}\n'
  printf '\n'
  printf '# a comment line is skipped\n'
  printf '{"title":"two"}\n'
  printf '{"title":"three"}\n'   # no trailing newline on purpose below
} > "$LINES"
printf '%s' '' >> "$LINES"

uku tasks create --batch @"$LINES" --yes
assert_status 0 'a clean batch exits 0'
assert_request_count 3 'one request per JSON line — blanks and comments skipped'
assert_equals "$(outcomes)" 'created,created,created,' 'every line reports created'
assert_equals "$(ids)" '101,102,103,' 'each result carries the id the server returned'
assert_request 1 body '{"title":"one"}' 'line 1 was sent verbatim'
assert_request 2 body '{"title":"two"}' 'the blank line and the comment were skipped'
assert_request 3 body '{"title":"three"}' 'a final line without a newline is still sent'
assert_err_contains '3 created' 'the human summary goes to stderr'
assert_err_contains 'ledger:' 'the ledger path is reported'

RID="$(ledger)"
assert_true 'a ledger file was written' test -n "$RID"
assert_file_exists "$UKU_CONFIG_HOME/batches/$RID" 'the ledger is on disk'
assert_equals "$(awk -F'\t' '$1=="ok"{n++} END{print n+0}' "$UKU_CONFIG_HOME/batches/$RID")" '3' \
  'the ledger holds three confirmed creates'
assert_equals "$(awk -F'\t' '$1=="send"{n++} END{print n+0}' "$UKU_CONFIG_HOME/batches/$RID")" '3' \
  'each line was recorded as sent BEFORE the request'
# the ledger must never hold client data — only a hash
if grep -q 'three' "$UKU_CONFIG_HOME/batches/$RID"; then
  _tap_fail 'the ledger stores a hash, never the line' 'found line content in the ledger'
else
  _tap_ok 'the ledger stores a hash, never the line'
fi

# uku batch list sees the run
reset_requests
uku batch list
assert_status 0 'uku batch list exits 0'
assert_out_contains "$RID" 'the run appears in the ledger listing'
assert_true 'batch list is JSON when not a TTY' sh -c "printf '%s' '$OUT' | jq -e '.[0].created == 3' >/dev/null"
assert_no_requests 'batch list is a local read'
teardown_case

# ── 2. --resume skips lines a previous run already created ───────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "POST", "path": "/api/v3/tasks",
      "responses": [
        {"status": 201, "body": {"data": {"id": 201}}},
        {"status": 201, "body": {"data": {"id": 202}}},
        {"status": 201, "body": {"data": {"id": 203}}}
      ] }
  ]
}
JSON
start_server

LINES="$CASE_DIR/tasks.jsonl"
printf '{"title":"a"}\n{"title":"b"}\n' > "$LINES"

uku tasks create --batch @"$LINES" --yes --run-id r1
assert_status 0 'the first run succeeds'
assert_request_count 2 'both lines were created'

# the run is picked up again with more work in the same file
printf '{"title":"c"}\n' >> "$LINES"

reset_requests
uku tasks create --batch @"$LINES" --yes --run-id r1 --resume
assert_status 0 'the resumed run exits 0'
assert_request_count 1 'ONLY the un-created line is sent — no duplicates'
assert_request 1 body '{"title":"c"}' 'and it is the right line'
assert_equals "$(outcomes)" 'skipped,skipped,created,' 'the first two are reported as skipped'
assert_out_contains 'LEDGER_HIT' 'the skip reason names the ledger'
assert_out_contains '"id":"201"' 'a skipped line still reports the id it already has'
assert_err_contains 'ledger already holds 2' 'the run says up front what the ledger holds'

# resuming a fully-created file sends nothing at all
reset_requests
uku tasks create --batch @"$LINES" --yes --run-id r1 --resume
assert_status 0 'resuming a finished run exits 0'
assert_no_requests 'a fully-created batch re-sends nothing'
assert_equals "$(outcomes)" 'skipped,skipped,skipped,' 'every line is a ledger hit'

# key ORDER and whitespace must not make the same record look new
reset_requests
printf '{ "title" : "a" }\n{"title":"b"}\n{"title":"c"}\n' > "$CASE_DIR/reordered.jsonl"
uku tasks create --batch @"$CASE_DIR/reordered.jsonl" --yes --run-id r1 --resume
assert_no_requests 'a re-formatted line still hashes to the same ledger entry'

# a re-run WITHOUT --resume deliberately creates them again (the ledger is opt-in)
reset_requests
uku tasks create --batch @"$LINES" --yes --run-id r1
assert_request_count 3 'without --resume the same file is created again — by design'
teardown_case

# ── 2b. a line the server REFUSED is re-sent by plain --resume ───────
# The distinction the ledger has to survive a crash for: a line for which a
# reply arrived and it was not a success created NOTHING, so it is FAILED and
# --resume re-sends it — which is exactly what the run's own summary tells the
# user to do. Only a line sent with no observed outcome is UNKNOWN (§3).
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "POST", "path": "/api/v3/tasks",
      "responses": [
        {"status": 201, "body": {"data": {"id": 210}}},
        {"status": 500, "body": {"error": {"code": "INTERNAL", "message": "boom"}}},
        {"status": 201, "body": {"data": {"id": 211}}}
      ] }
  ]
}
JSON
start_server

LINES="$CASE_DIR/tasks.jsonl"
printf '{"title":"a"}\n{"title":"b"}\n' > "$LINES"

uku tasks create --batch @"$LINES" --yes --run-id r2
assert_status 3 'a run with a failed line exits 3'
assert_request_count 2 'both lines were attempted (the default is to continue)'
assert_equals "$(outcomes)" 'created,failed,' 'the second line failed by itself'
assert_out_contains '"code":"INTERNAL"' 'the failure carries the API error code'
assert_err_contains 'resume:' 'the summary prints a resume command'
assert_equals "$(awk -F'\t' '$1=="ok"{n++} END{print n+0}' "$UKU_CONFIG_HOME/batches/r2")" '1' \
  'the ledger holds exactly the one that landed'
assert_equals "$(awk -F'\t' '$1=="fail"{n++} END{print n+0}' "$UKU_CONFIG_HOME/batches/r2")" '1' \
  'and records the failure'

reset_requests
uku tasks create --batch @"$LINES" --yes --run-id r2 --resume
assert_status 0 'the resume the summary suggested succeeds'
assert_request_count 1 'ONLY the refused line is re-sent'
assert_request 1 body '{"title":"b"}' 'and it is the line that failed'
assert_equals "$(outcomes)" 'skipped,created,' 'the created line is skipped, the refused one is created'
assert_out_not_contains 'UNKNOWN_OUTCOME' 'a definitively-rejected line is never called unknown'
assert_equals "$(awk -F'\t' '$1=="ok"{n++} END{print n+0}' "$UKU_CONFIG_HOME/batches/r2")" '2' \
  'the ledger now holds both creates'
teardown_case

# ── 3. a line caught in flight (send, never confirmed) is NOT re-sent ──
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "POST", "path": "/api/v3/tasks",
      "responses": [
        {"status": 201, "body": {"data": {"id": 301}}},
        {"status": 201, "body": {"data": {"id": 302}}},
        {"status": 201, "body": {"data": {"id": 303}}}
      ] }
  ]
}
JSON
start_server

LINES="$CASE_DIR/tasks.jsonl"
printf '{"title":"a"}\n{"title":"b"}\n' > "$LINES"
uku tasks create --batch @"$LINES" --yes --run-id inflight
assert_status 0 'the seed run succeeds'

# Simulate the interruption the ledger exists for: the POST left, the reply
# never arrived, so the `ok` row was never written and the ledger holds `send`
# alone. Dropping the ok rows reproduces exactly that state on disk — and is
# also the shape of a v0.3.0 ledger, which had no outcome rows to read.
LEDG="$UKU_CONFIG_HOME/batches/inflight"
grep -v '^ok	' "$LEDG" > "$LEDG.tmp" && mv "$LEDG.tmp" "$LEDG"
assert_equals "$(awk -F'\t' '$1=="send"{n++} END{print n+0}' "$LEDG")" '2' \
  'the ledger now holds two sent-but-unconfirmed lines'

reset_requests
uku tasks create --batch @"$LINES" --yes --run-id inflight --resume
assert_status 3 'an unresolved in-flight line fails the run (exit 3)'
assert_out_contains 'UNKNOWN_OUTCOME' 'the unresolved line is reported as unknown'
assert_out_contains 'may or may not exist' 'and explained'
assert_no_requests 'NOTHING is re-sent — a duplicate is worse than a gap'

# That refusal itself appended a `fail … UNKNOWN_OUTCOME` row. A local refusal
# is not an observed outcome, so it must NOT downgrade the line to "the server
# refused it" and make the next plain --resume send it.
reset_requests
uku tasks create --batch @"$LINES" --yes --run-id inflight --resume
assert_status 3 'a second plain --resume still refuses'
assert_out_contains 'UNKNOWN_OUTCOME' 'the line is still unknown, not failed'
assert_no_requests 'and still nothing is re-sent'

# --retry-unknown is the explicit opt-in to send it anyway
reset_requests
uku tasks create --batch @"$LINES" --yes --run-id inflight --resume --retry-unknown
assert_status 0 '--retry-unknown re-sends the unresolved lines'
assert_request_count 2 'both unresolved lines went out'
assert_err_contains 'outcome was unknown' 'and the CLI says it is doing so'
teardown_case

# ── 4. --stop-on-error halts; the default continues ──────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "POST", "path": "/api/v3/tasks",
      "response": {"status": 422, "body": {"error": {"code": "VALIDATION", "message": "nope"}}} }
  ]
}
JSON
start_server

LINES="$CASE_DIR/tasks.jsonl"
printf '{"title":"a"}\n{"title":"b"}\n{"title":"c"}\n' > "$LINES"

uku tasks create --batch @"$LINES" --yes
assert_status 3 'the default run exits 3 when lines failed'
assert_request_count 3 'the default is to keep going after a failed line'
assert_equals "$(outcomes)" 'failed,failed,failed,' 'each line failed on its own'

reset_requests
uku tasks create --batch @"$LINES" --yes --stop-on-error --run-id stopper
assert_status 3 '--stop-on-error exits 3'
assert_request_count 1 '--stop-on-error halts on the first failed line'
assert_err_contains 'stopped: line 1 failed (HTTP 422)' 'the summary names where it stopped'
teardown_case

# ── 5. a malformed line fails itself and never aborts the run ────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "POST", "path": "/api/v3/tasks",
      "responses": [ {"status": 201, "body": {"data": {"id": 401}}},
                     {"status": 201, "body": {"data": {"id": 402}}} ] }
  ]
}
JSON
start_server

LINES="$CASE_DIR/tasks.jsonl"
printf '{"title":"a"}\nnot json at all\n{"title":"b"}\n' > "$LINES"
uku tasks create --batch @"$LINES" --yes
assert_status 3 'a run containing a bad line exits 3'
assert_request_count 2 'the bad line was never sent; the good ones were'
assert_equals "$(outcomes)" 'created,failed,created,' 'the bad line failed alone'
assert_out_contains 'INVALID_JSON' 'the reason is machine-readable'
teardown_case

# ── 6. --dry-run reports every line and sends nothing ────────────────
setup_case
server_script <<'JSON'
{ "routes": [ { "method": "POST", "path": "/api/v3/tasks",
                "response": {"status": 201, "body": {"data": {"id": 1}}} } ] }
JSON
start_server

LINES="$CASE_DIR/tasks.jsonl"
printf '{"title":"a"}\n{"title":"b"}\n' > "$LINES"
uku tasks create --batch @"$LINES" --dry-run
assert_status 0 'a batch --dry-run exits 0 — and needs no --yes (unlike a single write)'
assert_no_requests 'a batch --dry-run sends nothing'
assert_equals "$(outcomes)" 'would_create,would_create,' 'every line is reported, not just the first'
assert_err_contains 'nothing was sent, no ledger was written' 'and no ledger is written'
assert_true 'no batches directory was created' test ! -d "$UKU_CONFIG_HOME/batches"
teardown_case

# ── 7. the refusals ──────────────────────────────────────────────────
setup_case
server_script <<'JSON'
{ "routes": [ { "method": "GET", "path": "/api/v3/tasks",
                "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} } ] }
JSON
start_server

LINES="$CASE_DIR/tasks.jsonl"
printf '{"title":"a"}\n' > "$LINES"

uku tasks list --batch @"$LINES"
assert_status 1 '--batch on a list is a usage error'
assert_err_contains 'it does nothing on a list' 'and says why'
assert_no_requests 'nothing sent'

reset_requests
uku tasks create --batch @"$LINES" --data '{"title":"x"}' --yes
assert_status 1 '--batch and --data together are refused'
assert_err_contains 'the batch file IS the data' 'and says why'
assert_no_requests 'nothing sent'

reset_requests
uku api PATCH /api/v3/tasks --batch @"$LINES" --yes
assert_status 1 '--batch only supports POST'
assert_err_contains 'only supports POST' 'and says so'
assert_no_requests 'nothing sent'

reset_requests
uku tasks create --batch @"$CASE_DIR/does-not-exist.jsonl" --yes
assert_status 1 'a missing batch file is a usage error'
assert_err_contains 'batch file not found' 'and names the file'
assert_no_requests 'nothing sent'

reset_requests
: > "$CASE_DIR/empty.jsonl"
uku tasks create --batch @"$CASE_DIR/empty.jsonl" --yes
assert_status 1 'an empty batch file is a usage error'
assert_err_contains 'no JSON lines' 'and says so'
assert_no_requests 'nothing sent'

reset_requests
uku tasks create --batch @"$LINES" --yes --skip-existing
assert_status 1 '--skip-existing without --match-on is refused'
assert_err_contains 'needs --match-on' 'and says so'
assert_no_requests 'nothing sent'

reset_requests
uku tasks create --batch @"$LINES" --yes --match-on title
assert_status 1 '--match-on without --skip-existing is refused'
assert_no_requests 'nothing sent'
teardown_case

# ── 8. --skip-existing --match-on: exact match skips, many matches refuse ──
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path_regex": "^/api/v3/tasks$",
      "responses": [
        {"status": 200, "body": {"data": [{"id": 11, "title": "unique one"}]}},
        {"status": 200, "body": {"data": [{"id": 21, "title": "Käibedeklaratsioon"},
                                          {"id": 22, "title": "Käibedeklaratsioon"}]}},
        {"status": 200, "body": {"data": []}}
      ] },
    { "method": "POST", "path": "/api/v3/tasks",
      "response": {"status": 201, "body": {"data": {"id": 99}}} }
  ]
}
JSON
start_server

LINES="$CASE_DIR/tasks.jsonl"
printf '{"title":"unique one"}\n{"title":"Käibedeklaratsioon"}\n{"title":"brand new"}\n' > "$LINES"
uku tasks create --batch @"$LINES" --yes --skip-existing --match-on title
assert_status 3 'an ambiguous match fails that line, so the run exits 3'
assert_equals "$(outcomes)" 'skipped,failed,created,' 'skip / refuse / create, in that order'
assert_out_contains 'MATCH_EXISTS' 'the exact single match is skipped'
assert_out_contains 'AMBIGUOUS_MATCH' 'two matches are refused, not guessed'
assert_out_contains 'refusing to guess which one this is' 'and explained'
assert_request_count 4 'three match queries plus one create'
assert_request 4 method POST 'only the genuinely new line was created'

finish
