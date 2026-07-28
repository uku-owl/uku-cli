#!/usr/bin/env bash
# accounts — one login, many companies. Which credential reaches the wire is
# the whole point: a write against the wrong company is unrecoverable.
#
# NOTE: profiles are written to disk by the harness rather than through
# `uku auth login`, because login ignores --base and UKU_BASE_URL and always
# validates against https://app.getuku.com. See KNOWN ISSUE #5 in tests/run.sh.
. "$(dirname "$0")/../lib/harness.sh"

MAIN_CO='aaaaaaaa-0000-0000-0000-000000000001'
SAND_CO='bbbbbbbb-0000-0000-0000-000000000002'
MAIN_KEY='uku_live_MAINKEY0123456789abcdefMAINTAIL'
SAND_KEY='uku_live_SANDKEY0123456789abcdefSANDTAIL'

setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/reject/api/v3/members",
      "response": {"status": 401, "body": {"error": {"code": "UNAUTHENTICATED"}}} },
    { "method": "GET", "path_prefix": "/api/v3/",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} }
  ]
}
JSON
start_server

# the profile path is what is under test — take the env identity away
clear_env_creds
write_profile main    "$MAIN_CO" "$MAIN_KEY"
write_profile sandbox "$SAND_CO" "$SAND_KEY"
set_active_profile main

# ── account list / current ───────────────────────────────────────────
uku account current
assert_status 0 'account current exits 0'
assert_out_contains 'main' 'it names the active account'
assert_no_requests 'account current is local'

reset_requests
uku account list
assert_status 0 'account list exits 0'
assert_true 'account list is JSON when not a TTY' sh -c "printf '%s' '$OUT' | jq -e '.active == \"main\"' >/dev/null"
assert_out_contains 'sandbox' 'both accounts are listed'
assert_out_contains "$MAIN_CO" 'with their company ids'
assert_no_requests 'account list is local'

# ── the active account's credentials are what reach the wire ─────────
reset_requests
uku clients list
assert_status 0 'a read on the active account exits 0'
assert_request 1 X-Uku-Company "$MAIN_CO" "the active account's company is sent"
assert_request 1 X-API-Key "$MAIN_KEY" "the active account's key is sent"

# ── --account targets ONE command without switching ──────────────────
reset_requests
uku --account sandbox clients list
assert_status 0 '--account exits 0'
assert_request 1 X-Uku-Company "$SAND_CO" '--account sends the named company'
assert_request 1 X-API-Key "$SAND_KEY" 'and the matching key — no cross-account bleed'

reset_requests
uku account current
assert_out_contains 'main' '--account did not change the active account'

# ── account use switches for good ────────────────────────────────────
reset_requests
uku account use sandbox
assert_status 0 'account use exits 0'
assert_err_contains 'Now using account' 'and says so'
assert_no_requests 'switching is local'

reset_requests
uku clients list
assert_request 1 X-Uku-Company "$SAND_CO" 'the switch took effect'

uku account use main >/dev/null 2>&1

# ── an unknown account is exit 2 and never reaches the network ───────
reset_requests
uku --account nope clients list
assert_status 2 'an unknown --account is an auth error'
assert_err_contains 'No such account' 'and names it'
assert_no_requests 'nothing sent'

reset_requests
uku account use nope
assert_status 2 'account use on an unknown account is exit 2'
assert_no_requests 'nothing sent'

# ── env credentials override the stored profile outright ─────────────
reset_requests
UKU_API_KEY='uku_live_ENVKEY01234567890abcdefENVTAIL' UKU_COMPANY='cccccccc-0000-0000-0000-000000000003' \
  uku clients list
assert_status 0 'a complete env identity works'
assert_request 1 X-Uku-Company 'cccccccc-0000-0000-0000-000000000003' 'env wins over the active profile'
assert_request 1 X-API-Key 'uku_live_ENVKEY01234567890abcdefENVTAIL' 'both halves come from the env'

reset_requests
UKU_API_KEY='x' UKU_COMPANY='y' uku auth status --json
assert_out_contains '"account":"env"' 'a complete env identity is named "env"'

# ── a PARTIAL env identity warns before welding onto a profile ───────
reset_requests
UKU_API_KEY='uku_live_ENVKEY01234567890abcdefENVTAIL' uku clients list
assert_status 0 'a half env identity still runs'
assert_err_contains 'mixing env credentials with stored account' 'but warns loudly'
assert_request 1 X-Uku-Company "$MAIN_CO" "the profile's company is used"
assert_request 1 X-API-Key 'uku_live_ENVKEY01234567890abcdefENVTAIL' 'with the env key welded on'

# ── --account resolves its base like every other path ────────────────
# profile base > UKU_BASE_URL > default, with --base winning over all three.
# The --account branch used to read the profile only.
reset_requests
uku --account sandbox clients list
assert_status 0 'the profile base is used under --account'
assert_request_count 1 'and it reached the fixture, i.e. the profile URL'

# a profile with no stored base falls back to UKU_BASE_URL (it used to fall
# straight through to https://app.getuku.com — the production API)
mkdir -p "$UKU_CONFIG_HOME/profiles"
{ printf 'UKU_COMPANY=%s\n' "$SAND_CO"; printf 'UKU_KEY=%s\n' "$SAND_KEY"; } \
  > "$UKU_CONFIG_HOME/profiles/nobase"
chmod 600 "$UKU_CONFIG_HOME/profiles/nobase"
reset_requests
uku --account nobase clients list
assert_status 0 'a base-less profile under --account exits 0'
assert_request_count 1 'and UKU_BASE_URL is where it went'
assert_request 1 X-API-Key "$SAND_KEY" 'carrying that profile s key'

# --base still beats both
reset_requests
uku --base 'http://127.0.0.1:1' --account sandbox clients list
assert_status 5 '--base wins over the profile base — a dead port is unreachable'
assert_no_requests 'so nothing reached the fixture'
rm -f "$UKU_CONFIG_HOME/profiles/nobase"

# ── logout removes the profile and hands the active flag on ──────────
reset_requests
uku --account sandbox auth logout
assert_status 0 'logout exits 0'
assert_err_contains 'Signed out of account' 'and says so'
assert_true 'the profile file is gone' test ! -f "$UKU_CONFIG_HOME/profiles/sandbox"
assert_true 'the other profile is untouched' test -f "$UKU_CONFIG_HOME/profiles/main"
assert_no_requests 'logout is local'

# Removing the LAST remaining profile is a success, and exits like one. It used
# to print "Removed account 'main'." and then exit 1 — the usage-error code —
# because _reassign_active's `list_profiles | head -n1` failed on an empty
# directory and `set -euo pipefail` aborted the script after the fact.
reset_requests
uku account remove main
assert_status 0 'removing the LAST account exits 0'
assert_err_contains "Removed account 'main'." 'and reports the removal'
assert_true 'the last profile is gone' test ! -f "$UKU_CONFIG_HOME/profiles/main"
assert_true 'the dangling active pointer is cleared' test ! -f "$UKU_CONFIG_HOME/active"

# the same for the other way out: logout on the last account
write_profile solo
set_active_profile solo
reset_requests
uku auth logout
assert_status 0 'logout on the last account exits 0'
assert_err_contains 'Signed out of account' 'and reports it'
assert_true 'and the profile is gone' test ! -f "$UKU_CONFIG_HOME/profiles/solo"

# and listing accounts when there are none is a normal, empty answer
reset_requests
uku account list
assert_status 0 'listing no accounts exits 0'
assert_no_requests 'and stays local'

# removing a NON-last account is exit 0 — the contrast that proves the cause
write_profile keeper
write_profile goner
set_active_profile goner
reset_requests
uku account remove goner
assert_status 0 'removing an account while others remain exits 0'
assert_err_contains "Active account → 'keeper'" 'and the active flag is handed on'
uku account remove keeper >/dev/null 2>&1

# with no profiles left and no env, a read is exit 2 and sends nothing
reset_requests
uku clients list
assert_status 2 'with nothing left, a read is an auth error'
assert_no_requests 'nothing sent'

# ── auth login refuses non-interactively without --company ───────────
reset_requests
UKU_API_KEY="$MAIN_KEY" uku auth login --account ci
assert_status 1 'a non-interactive login without --company is a usage error'
assert_err_contains 'needs --company' 'and says what is missing'
assert_no_requests 'nothing was sent'

# ── login validates against, and stores, the base it was told to use ──
# Was KNOWN ISSUE #5: the global pre-parse ate --base before cmd_auth saw it and
# login always talked to https://app.getuku.com — so pointing the CLI at staging
# sent the key to production. A hermetic login must reach the fixture and
# nothing else.
KEYFILE="$CASE_DIR/key.txt"
printf '%s' "$SAND_KEY" > "$KEYFILE"
SERVER_BASE="$UKU_BASE_URL"

reset_requests
uku_stdin "$KEYFILE" auth login --account envbase --company "$SAND_CO" --key-stdin
assert_status 0 'a login against UKU_BASE_URL exits 0'
assert_request_count 1 'exactly one request — the credential probe'
assert_request 1 path /api/v3/members 'it validated the key'
assert_request 1 X-API-Key "$SAND_KEY" 'with the key it was handed on stdin'
assert_request 1 X-Uku-Company "$SAND_CO" 'and the company it was given'
assert_equals "$(grep '^UKU_BASE=' "$UKU_CONFIG_HOME/profiles/envbase")" "UKU_BASE=$UKU_BASE_URL" \
  'and the profile stores the base it actually validated against'
assert_err_not_contains 'app.getuku.com' 'production is never named'

# --base wins over UKU_BASE_URL, whether it comes before or after the subcommand
reset_requests
UKU_BASE_URL='http://127.0.0.1:1' uku_stdin "$KEYFILE" --base "$SERVER_BASE" \
  auth login --account flagbase --company "$SAND_CO" --key-stdin
assert_status 0 'a global --base login exits 0'
assert_request_count 1 'the flag base is where the probe went'
assert_equals "$(grep '^UKU_BASE=' "$UKU_CONFIG_HOME/profiles/flagbase")" "UKU_BASE=$SERVER_BASE" \
  'and --base beats UKU_BASE_URL in what is stored'

reset_requests
UKU_BASE_URL='http://127.0.0.1:1' uku_stdin "$KEYFILE" \
  auth login --account subbase --company "$SAND_CO" --key-stdin --base "$SERVER_BASE"
assert_status 0 'a --base after the subcommand still works'
assert_request_count 1 'and it is the base that was contacted'

# and a login against a base that rejects the key saves nothing
reset_requests
uku_stdin "$KEYFILE" --base "$SERVER_BASE/reject" \
  auth login --account rejected --company "$SAND_CO" --key-stdin
assert_status 2 'rejected credentials are exit 2'
assert_true 'and nothing was written to disk' test ! -f "$UKU_CONFIG_HOME/profiles/rejected"

uku account remove envbase   >/dev/null 2>&1
uku account remove flagbase  >/dev/null 2>&1
uku account remove subbase   >/dev/null 2>&1

finish
