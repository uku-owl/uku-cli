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

finish
