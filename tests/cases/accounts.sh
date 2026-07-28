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

# ── --account IGNORES UKU_BASE_URL (KNOWN ISSUE #6) ─────────────────────
# load_creds' --account branch reads UKU_BASE from the profile and never looks
# at the env. The harness writes the fixture URL into the profile, so this is
# observable only as "the profile's base is what is used".
reset_requests
UKU_BASE_URL="$UKU_BASE_URL" uku --account sandbox clients list
assert_status 0 'the profile base is used under --account'
assert_request_count 1 'and it reached the fixture, i.e. the profile URL'

# ── logout removes the profile and hands the active flag on ──────────
reset_requests
uku --account sandbox auth logout
assert_status 0 'logout exits 0'
assert_err_contains 'Signed out of account' 'and says so'
assert_true 'the profile file is gone' test ! -f "$UKU_CONFIG_HOME/profiles/sandbox"
assert_true 'the other profile is untouched' test -f "$UKU_CONFIG_HOME/profiles/main"
assert_no_requests 'logout is local'

# KNOWN ISSUE #7: removing the LAST remaining profile succeeds ("Removed account
# 'main'.") but exits 1 — the usage-error code. _reassign_active runs
# `next="$(list_profiles | head -n1)"`; with an empty profiles directory
# list_profiles returns 1, and `set -euo pipefail` turns that assignment into a
# script abort. Pinned as-is so a refactor has to fix it on purpose.
reset_requests
uku account remove main
assert_status 1 'removing the LAST account exits 1 despite succeeding — KNOWN ISSUE #7'
assert_err_contains "Removed account 'main'." 'the removal itself reported success'
assert_true 'the last profile is gone' test ! -f "$UKU_CONFIG_HOME/profiles/main"

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
# Deliberately the ONLY login path exercised: with a --company it would
# validate against the production base (KNOWN ISSUE #5), which a test must never do.
reset_requests
UKU_API_KEY="$MAIN_KEY" uku auth login --account ci
assert_status 1 'a non-interactive login without --company is a usage error'
assert_err_contains 'needs --company' 'and says what is missing'
assert_no_requests 'nothing was sent'

finish
