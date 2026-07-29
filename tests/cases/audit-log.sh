#!/usr/bin/env bash
# audit-log — S9 (2026-07-29 security audit): the local receipt at
# $UKU_CONFIG_HOME/audit.log promised "no bodies, no keys", but `uku api`
# writes log the request path VERBATIM, and that path can carry a query
# string — `POST /api/v3/tasks?q=Acme%20Ltd` puts a client's name in a file
# SECURITY.md described as keyless. And nothing ever rotated it: Rain's first
# real day of use produced 125 lines with no cap in sight.
#
# This case pins both fixes:
#   1. the query string never reaches audit.log, only the bare path.
#   2. the log rotates once it crosses the size/line threshold, keeps 0600 on
#      both generations, loses no entry, and a rotation FAILURE (unwritable
#      config dir) still lets the write that triggered the check succeed —
#      because _audit's whole contract is "a logging problem never breaks an
#      accounting write" (every branch ends `|| true` / `return 0`).
. "$(dirname "$0")/../lib/harness.sh"

_mode() { # PATH — 0600-style octal mode, portable across BSD/GNU stat
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

# ── 1. query string stripped from the recorded path ──────────────────
setup_case
server_script <<'JSON'
{ "routes": [
  { "method": "POST", "path": "/api/v3/tasks",
    "response": {"status": 201, "body": {"data": {"id": 7}}} }
] }
JSON
start_server

uku api POST /api/v3/tasks --query 'q=Acme Ltd' --data '{"title":"x"}' --yes
assert_status 0 'the write itself succeeds'

LOG="$UKU_CONFIG_HOME/audit.log"
assert_file_exists "$LOG" 'audit.log was created'

if grep -q 'Acme' "$LOG" 2>/dev/null; then
  _tap_fail 'no query string (client name) in audit.log' "$(cat "$LOG" 2>/dev/null)"
else
  _tap_ok 'no query string (client name) in audit.log'
fi
if grep -Eq '\?' "$LOG" 2>/dev/null; then
  _tap_fail 'no literal "?" anywhere in audit.log' "$(cat "$LOG" 2>/dev/null)"
else
  _tap_ok 'no literal "?" anywhere in audit.log'
fi
if grep -Fq '/api/v3/tasks' "$LOG" 2>/dev/null; then
  _tap_ok 'the bare path is still recorded (a receipt still says WHICH endpoint)'
else
  _tap_fail 'the bare path is still recorded' "$(cat "$LOG" 2>/dev/null)"
fi

teardown_case

# ── 2. rotation: line-count threshold ─────────────────────────────────
setup_case
server_script <<'JSON'
{ "routes": [
  { "method": "POST", "path": "/api/v3/tasks",
    "response": {"status": 201, "body": {"data": {"id": 42}}} }
] }
JSON
start_server

LOG="$UKU_CONFIG_HOME/audit.log"
mkdir -p "$UKU_CONFIG_HOME"
# Seed 10,000 lines directly — driving the CLI 10k times would blow the
# suite's time budget. The seeded content is what must survive rotation
# unaltered, one generation back, so it doubles as the "loses no entry" check.
awk 'BEGIN{for(i=1;i<=10000;i++) printf "2026-01-01T00:00:00Z\tenv\tPOST\t/api/v3/seed\t201\n"}' > "$LOG"
chmod 600 "$LOG"
SEED_LINES="$(wc -l < "$LOG" | tr -d '[:space:]')"
assert_equals "$SEED_LINES" "10000" 'seed file has exactly 10,000 lines before the triggering write'

uku api POST /api/v3/tasks --data '{"title":"x"}' --yes
assert_status 0 'the write that crosses the threshold still succeeds'

assert_file_exists "$LOG" 'audit.log exists after rotation'
assert_file_exists "$LOG.1" 'audit.log.1 (the rolled-over generation) exists'

ROLLED_LINES="$(wc -l < "$LOG.1" | tr -d '[:space:]')"
assert_equals "$ROLLED_LINES" "10000" 'all 10,000 seeded lines survived, unaltered, in audit.log.1'

if grep -q 'seed' "$LOG" 2>/dev/null; then
  _tap_fail 'the fresh audit.log does not carry the old generation' "$(cat "$LOG")"
else
  _tap_ok 'the fresh audit.log does not carry the old generation'
fi
if grep -Fq '/api/v3/tasks' "$LOG" 2>/dev/null; then
  _tap_ok 'the triggering write itself landed in the NEW audit.log — nothing lost'
else
  _tap_fail 'the triggering write itself landed in the NEW audit.log' "$(cat "$LOG")"
fi

MODE_LOG="$(_mode "$LOG")"
MODE_ROLLED="$(_mode "$LOG.1")"
assert_equals "$MODE_LOG" "600" 'audit.log is 0600 after rotation'
assert_equals "$MODE_ROLLED" "600" 'audit.log.1 is 0600 after rotation'

teardown_case

# ── 3. rotation FAILS (no write permission on the config dir) — the write
#    that triggered the check must still succeed, because a receipt for an
#    accountant must never be the reason a real write appears to fail. ──
setup_case
server_script <<'JSON'
{ "routes": [
  { "method": "POST", "path": "/api/v3/tasks",
    "response": {"status": 201, "body": {"data": {"id": 99}}} }
] }
JSON
start_server

LOG="$UKU_CONFIG_HOME/audit.log"
mkdir -p "$UKU_CONFIG_HOME"
awk 'BEGIN{for(i=1;i<=10000;i++) printf "2026-01-01T00:00:00Z\tenv\tPOST\t/api/v3/seed\t201\n"}' > "$LOG"
chmod 600 "$LOG"
# No write permission on the directory: `mv` (the rotation) cannot rename
# anything in it, but appending to the EXISTING file "$LOG" needs only
# write permission on the file itself, not on its parent directory — so the
# write must still land.
chmod 500 "$UKU_CONFIG_HOME"

uku api POST /api/v3/tasks --data '{"title":"x"}' --yes
assert_status 0 'the write succeeds even though rotation could not run'

if grep -Fq '/api/v3/tasks' "$LOG" 2>/dev/null; then
  _tap_ok 'the entry still landed in audit.log when rotation failed'
else
  _tap_fail 'the entry still landed in audit.log when rotation failed' "$(cat "$LOG" 2>/dev/null)"
fi
if [ -e "$LOG.1" ]; then
  _tap_fail 'no audit.log.1 was created (rotation genuinely could not run)' "$(ls -la "$UKU_CONFIG_HOME")"
else
  _tap_ok 'no audit.log.1 was created (rotation genuinely could not run)'
fi

# restore so teardown_case's rm -rf can actually delete the tree
chmod 700 "$UKU_CONFIG_HOME" 2>/dev/null || true

finish
