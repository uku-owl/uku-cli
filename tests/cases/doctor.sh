#!/usr/bin/env bash
# doctor — the one-screen self-check. Its --json shape is what an agent reads.
. "$(dirname "$0")/../lib/harness.sh"

# ── 1. a healthy run: parseable JSON, expected shape, exit 0 ─────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/VERSION",       "response": {"status": 200, "body": "0.3.0\n"} },
    { "method": "GET", "path": "/api/v3/members",
      "response": {"status": 200, "body": {"data": [{"id": 1}], "meta": {"total": 1}}} }
  ]
}
JSON
start_server

uku doctor --json
assert_status 0 'doctor exits 0 when nothing is failing'
assert_true 'doctor --json emits one parseable JSON object' \
  sh -c "printf '%s' '$OUT' | jq -e 'type == \"object\"' >/dev/null"
assert_true 'it has checks, fails, warnings and ok' \
  sh -c "printf '%s' '$OUT' | jq -e 'has(\"checks\") and has(\"fails\") and has(\"warnings\") and has(\"ok\")' >/dev/null"
assert_true 'checks is a non-empty array of {level,message}' \
  sh -c "printf '%s' '$OUT' | jq -e '(.checks | length) > 0 and (.checks | all(has(\"level\") and has(\"message\")))' >/dev/null"
assert_true 'every level is ok|warn|fail' \
  sh -c "printf '%s' '$OUT' | jq -e '.checks | all(.level == \"ok\" or .level == \"warn\" or .level == \"fail\")' >/dev/null"
assert_true 'a healthy run reports ok:true and fails:0' \
  sh -c "printf '%s' '$OUT' | jq -e '.ok == true and .fails == 0' >/dev/null"
assert_true 'it reports the credentials as valid' \
  sh -c "printf '%s' '$OUT' | jq -e '[.checks[] | select(.message | test(\"key valid\"))] | length == 1' >/dev/null"
assert_true 'it names the bash it is running under' \
  sh -c "printf '%s' '$OUT' | jq -e '[.checks[] | select(.message | test(\"^bash \"))] | length == 1' >/dev/null"
assert_true 'it reports the version lock between VERSION and UKU_VERSION' \
  sh -c "printf '%s' '$OUT' | jq -e '[.checks[] | select(.message | test(\"version lock\"))] | length == 1' >/dev/null"

# doctor validated the credentials against /members
assert_true 'doctor probed /api/v3/members' \
  sh -c "$PYTHON_BIN '$REQLOG_PY' dump '$REQ_LOG' | grep -q '/api/v3/members'"
teardown_case

# ── 2. rejected credentials are a FAIL and exit 1 ────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/VERSION", "response": {"status": 200, "body": "0.3.0\n"} },
    { "method": "GET", "path": "/api/v3/members",
      "response": {"status": 401, "body": {"error": {"code": "UNAUTHENTICATED"}}} }
  ]
}
JSON
start_server

uku doctor --json
assert_status 1 'doctor exits 1 when a required check fails'
assert_true 'ok is false and fails is at least 1' \
  sh -c "printf '%s' '$OUT' | jq -e '.ok == false and .fails >= 1' >/dev/null"
assert_true 'the rejected credential is the failing check' \
  sh -c "printf '%s' '$OUT' | jq -e '[.checks[] | select(.level == \"fail\" and (.message | test(\"were rejected\")))] | length == 1' >/dev/null"
teardown_case

# ── 3. offline: the probe must never abort the report (T3) ───────────
setup_case
server_script <<'JSON'
{ "routes": [] }
JSON
start_server
# point the CLI at a dead loopback port; the fixture stays up only so the
# harness guard is satisfied.
DEAD_BASE='http://127.0.0.1:1'

uku doctor --json --base "$DEAD_BASE"
assert_status 0 'doctor still exits 0 when the API is unreachable'
assert_true 'it reports being offline as a warning, not a failure' \
  sh -c "printf '%s' '$OUT' | jq -e '[.checks[] | select(.level == \"warn\" and (.message | test(\"offline\")))] | length == 1' >/dev/null"
assert_true 'and the report is still complete JSON' \
  sh -c "printf '%s' '$OUT' | jq -e '(.checks | length) > 3' >/dev/null"
teardown_case

# ── 4. no credentials at all: a warning, still exit 0 ────────────────
setup_case
server_script <<'JSON'
{ "routes": [ { "method": "GET", "path": "/VERSION", "response": {"status": 200, "body": "0.3.0\n"} } ] }
JSON
start_server
clear_env_creds

uku doctor --json
assert_status 0 'doctor with no credentials still exits 0'
assert_true 'and warns that nothing is signed in' \
  sh -c "printf '%s' '$OUT' | jq -e '[.checks[] | select(.level == \"warn\" and (.message | test(\"no credentials\")))] | length == 1' >/dev/null"
assert_true 'it does not claim a valid key' \
  sh -c "printf '%s' '$OUT' | jq -e '[.checks[] | select(.message | test(\"key valid\"))] | length == 0' >/dev/null"

# ── 5. the human (non --json) report is readable and still exits 0 ───
reset_requests
uku doctor
assert_status 0 'the text report exits 0'
# KNOWN ISSUE #8: in text mode the heading and the trailing blank lines go to
# stdout while every check line goes to stderr, so `uku doctor > report.txt`
# captures only the heading. --json puts everything on stdout.
assert_out_contains 'uku doctor' 'the heading is on STDOUT — KNOWN ISSUE #8'
assert_err_contains 'curl present' 'while the checks themselves are on stderr — KNOWN ISSUE #8'
assert_err_contains 'bash 3.2' 'including the bash version this ran under'

finish
