#!/usr/bin/env bash
# write-safety — the single most important property in the suite:
# a write with no --yes and no TTY exits 4 and sends ZERO requests.
#
# Every write shape the CLI offers is checked, because the gate lives in
# confirm_write() and each command has to reach it.
. "$(dirname "$0")/../lib/harness.sh"

setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "POST",   "path": "/api/v3/tasks",
      "response": {"status": 201, "body": {"data": {"id": 7}}} },
    { "method": "PATCH",  "path": "/api/v3/clients/5",
      "response": {"status": 200, "body": {"data": {"id": 5}}} },
    { "method": "DELETE", "path": "/api/v3/tasks/5",
      "response": {"status": 204, "body": ""} },
    { "method": "POST",   "path": "/api/v3/invoices",
      "response": {"status": 201, "body": {"data": {"id": 9}}} },
    { "method": "POST",   "path": "/api/v3/time-entries",
      "response": {"status": 201, "body": {"data": {"id": 3}}} }
  ]
}
JSON
start_server

_refuses() { # LABEL — assert the last `uku` run refused and sent nothing
  assert_status 4 "$1 — exit 4"
  assert_no_requests "$1 — nothing was sent"
}

reset_requests; uku tasks create --data '{"title":"x"}';                 _refuses 'tasks create'
reset_requests; uku clients patch 5 --data '{"name":"x"}';               _refuses 'clients patch'
reset_requests; uku invoices create --data '{"client_id":1}';            _refuses 'invoices create'
reset_requests; uku time create --data '{"task_id":1,"person_id":1,"start":"2026-01-01T09:00:00Z"}'
                                                                          _refuses 'time create'
reset_requests; uku api POST /api/v3/tasks --data '{"title":"x"}';       _refuses 'api POST'
reset_requests; uku api PATCH /api/v3/clients/5 --data '{"name":"x"}';   _refuses 'api PATCH'
reset_requests; uku api DELETE /api/v3/tasks/5;                          _refuses 'api DELETE'

# a batch is one confirm for the whole file — and without it, nothing is sent
printf '{"title":"a"}\n{"title":"b"}\n' > "$CASE_DIR/lines.jsonl"
reset_requests; uku tasks create --batch @"$CASE_DIR/lines.jsonl";       _refuses 'tasks create --batch'

# ── the flip side: --yes really does send ────────────────────────────
reset_requests
uku tasks create --data '{"title":"x"}' --yes
assert_status 0 '--yes lets the write through'
assert_request_count 1 '--yes sends exactly one request'
assert_request 1 method POST
assert_request 1 path /api/v3/tasks
assert_request 1 body '{"title":"x"}' 'the body arrives verbatim'
assert_request 1 Content-Type 'application/json'

# ── a read is never gated ────────────────────────────────────────────
reset_requests
uku clients list
assert_status 0 'a read needs no confirmation'
assert_request_count 1 'the read was sent'

# ── malformed JSON is refused BEFORE the confirm, and sends nothing ──
reset_requests
uku tasks create --data '{"title": ' --yes
assert_status 1 'invalid --data JSON is a usage error'
assert_err_contains "isn't valid JSON" 'the message names the problem'
assert_no_requests 'invalid JSON is never sent'

# ── the time-entry guard: duration without end would open a timer ────
reset_requests
uku time create --data '{"task_id":1,"person_id":1,"start":"2026-01-01T09:00:00Z","duration":3600}' --yes
assert_status 1 'a duration-without-end time entry is refused'
assert_err_contains 'RUNNING TIMER' 'the guard explains what would have happened'
assert_no_requests 'the guarded write is never sent'

# with an end it goes through
reset_requests
uku time create --data '{"task_id":1,"person_id":1,"start":"2026-01-01T09:00:00Z","end":"2026-01-01T10:00:00Z"}' --yes
assert_status 0 'start+end is accepted'
assert_request_count 1 'the valid time entry was sent'

# ── C3 — Idempotency-Key ─────────────────────────────────────────────────
# The API stores a keyed POST's response for 24h and replays it rather than
# acting twice. Uncovered paths ignore the header, so sending one is never an
# error; the cost of NOT sending one is a write whose outcome is unknowable
# after a timeout.
note 'C3 — writes carry an idempotency key, reads do not'

reset_requests
uku tasks create --data '{"title":"one"}' --yes
assert_status 0 'a create goes through'
_ik="$(request_field 1 Idempotency-Key)"
assert_true 'the write carried an Idempotency-Key' sh -c "[ -n '$_ik' ]"
assert_true 'and it is within the 200-character limit the API enforces' \
  sh -c "[ ${#_ik} -le 200 ]"

reset_requests
uku tasks list
assert_request_empty 1 Idempotency-Key 'a read carries none — there is nothing to replay'

# The honest limitation, pinned so nobody later assumes otherwise: a key is
# minted PER PROCESS. Two runs of the same command are two writes, and that is
# correct — they really are two requests to create something.
note 'C3 — two runs mint different keys; sameness must be asked for'
reset_requests
uku tasks create --data '{"title":"a"}' --yes
_k_run1="$(request_field 1 Idempotency-Key)"
reset_requests
uku tasks create --data '{"title":"a"}' --yes
_k_run2="$(request_field 1 Idempotency-Key)"
assert_true 'two separate runs mint DIFFERENT keys' \
  sh -c "[ '$_k_run1' != '$_k_run2' ]"

# ...which is why --idempotency-key exists: it is how a caller says "this is
# the same write I already tried", which cannot be inferred from the request.
reset_requests
uku --idempotency-key 'agent-retry-42' tasks create --data '{"title":"a"}' --yes
assert_request 1 Idempotency-Key 'agent-retry-42' '--idempotency-key is sent verbatim'
reset_requests
uku --idempotency-key 'agent-retry-42' tasks create --data '{"title":"a"}' --yes
assert_request 1 Idempotency-Key 'agent-retry-42' 'and is stable across runs, which is the whole point'

note 'C3 — the key is validated before anything is sent'
reset_requests
uku --idempotency-key "$(printf 'a%.0s' $(seq 1 201))" tasks create --data '{"title":"a"}' --yes
assert_status 1 'a key over the API 200-char limit is a usage error here, not a 400 from the wire'
assert_err_contains '200' 'and the limit is named'
assert_no_requests 'nothing sent — the write outcome is never left ambiguous by our own bad input'

reset_requests
uku --idempotency-key 'a
b' tasks create --data '{"title":"a"}' --yes
assert_status 1 'a newline in the key is refused'
assert_err_contains 'single line' 'because it would forge a header in the curl config'
assert_no_requests 'nothing sent'

finish
