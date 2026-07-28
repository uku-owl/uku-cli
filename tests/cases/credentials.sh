#!/usr/bin/env bash
# credentials — where the API key goes, and where it must not.
#
# The key must reach the server in X-API-Key and must NOT appear on curl's
# command line (a multi-user host can read that from `ps`). do_request writes
# the auth headers into a 0600 `curl -K` config file; enable_curl_spy records
# curl's full argv so that claim is actually observed, not assumed.
. "$(dirname "$0")/../lib/harness.sh"

setup_case
enable_curl_spy
server_script <<'JSON'
{
  "routes": [
    { "method": "GET",  "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET",  "path": "/api/v3/members",
      "response": {"status": 200, "body": {"data": [{"id": 1}], "meta": {"total": 1}}} },
    { "method": "POST", "path": "/api/v3/tasks",
      "response": {"status": 201, "body": {"data": {"id": 1}}} }
  ]
}
JSON
start_server

# ── the key reaches the server, in the header, on a read and on a write ──
uku clients list
assert_status 0 'read succeeds'
assert_request 1 X-API-Key "$TEST_API_KEY" 'the key arrives in X-API-Key'
assert_request 1 X-Uku-Company "$TEST_COMPANY" 'the company arrives in X-Uku-Company'
assert_request_empty 1 Authorization 'no Authorization header is used'

reset_requests
uku tasks create --data '{"title":"x"}' --yes
assert_status 0 'write succeeds'
assert_request 1 X-API-Key "$TEST_API_KEY" 'a write carries the key too'

# ── the key is never on curl's command line ──────────────────────────
assert_true 'curl was actually invoked (the spy recorded something)' \
  test -s "$CURL_ARGV_LOG"
if grep -qF "$TEST_API_KEY" "$CURL_ARGV_LOG"; then
  _tap_fail 'the API key never appears in curl argv' \
    "the key was found on a curl command line:
$(grep -nF "$TEST_API_KEY" "$CURL_ARGV_LOG" | head -3)"
else
  _tap_ok 'the API key never appears in curl argv'
fi
assert_true 'curl is given a -K config file instead' grep -q -- '-K ' "$CURL_ARGV_LOG"
# the request body is off argv as well (invoice/client PII is not in `ps`)
assert_true 'the request body is passed as --data-binary @file, not inline' \
  grep -q -- '--data-binary @' "$CURL_ARGV_LOG"
if grep -qF '{"title":"x"}' "$CURL_ARGV_LOG"; then
  _tap_fail 'the request body never appears in curl argv' \
    "the body was found on a curl command line"
else
  _tap_ok 'the request body never appears in curl argv'
fi

# ── a custom --header value is treated as a credential too (off argv) ──
reset_requests
uku clients list --header 'X-Secret: hunter2hunter2'
assert_status 0 'a custom header is accepted'
assert_request_count 1 'the request went out'
if grep -qF 'hunter2hunter2' "$CURL_ARGV_LOG"; then
  _tap_fail 'a --header value never appears in curl argv' 'found it on a curl command line'
else
  _tap_ok 'a --header value never appears in curl argv'
fi

# a --header with a newline would inject a second -K directive: refused
reset_requests
uku clients list --header "$(printf 'X-Bad: a\nheader = "X-API-Key: stolen"')"
assert_status 1 'a multi-line --header is a usage error'
assert_err_contains 'must be a single line' 'the refusal explains why'
assert_no_requests 'the injected header is never sent'

# a --header without a colon is refused
reset_requests
uku clients list --header 'nonsense'
assert_status 1 'a --header without a colon is refused'
assert_no_requests 'nothing sent'

# ── auth status masks the key ────────────────────────────────────────
reset_requests
uku auth status --json
assert_status 0 'auth status succeeds against a valid key'
assert_out_contains '"account":"env"' 'a complete env identity is reported as the "env" account'
assert_out_contains '"valid":true' 'the key validated'
assert_out_contains 'uku_live_…TAIL' 'the key is reported masked'
assert_out_not_contains "$TEST_API_KEY" 'auth status never prints the raw key'
assert_request 1 path /api/v3/members 'auth status validates against /members'

# ── auth print-header --dry-run keeps the mask ───────────────────────
reset_requests
uku auth print-header --dry-run
assert_status 0 'print-header --dry-run exits 0'
assert_out_not_contains "$TEST_API_KEY" '--dry-run masks the key'
assert_err_contains 'LIVE credential' 'it warns about what it prints'
assert_no_requests 'print-header talks to nobody'

# ── without --dry-run it deliberately prints the live key (documented) ──
reset_requests
uku auth print-header
assert_status 0 'print-header exits 0'
assert_out_contains "$TEST_API_KEY" 'print-header prints the live key by design'
assert_err_contains "don't paste it into a chat" 'and warns loudly on stderr'

finish
