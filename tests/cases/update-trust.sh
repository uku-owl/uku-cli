#!/usr/bin/env bash
# update-trust — the two URLs the unattended update follows are dev-only
# (S6.1, audit 2026-07-29).
#
# What is NOT changing, and is deliberate: auto-update stays on by default and
# installs without asking, once a day, by piping the installer into `sh`. Reach
# is worth the residual risk and the checksum chain covers the transport.
#
# What is changing: `UKU_INSTALL_URL` and `UKU_UPDATE_URL` used to be plain
# environment overrides. Anything that can set a variable in this process — a
# .env, a direnv file, a CI job definition, an agent's own environment — could
# therefore choose a URL that gets fetched and run as root-of-your-shell code
# within a day, unattended. Since the fix they take effect only under UKU_DEV=1.
#
# Every run here puts a STUB curl in front — it records argv and exits without
# execing the real binary — so the case can read which URL the CLI chose
# without a single byte reaching the network. That is also why the assertions
# are on argv rather than on a response.
. "$(dirname "$0")/../lib/harness.sh"

setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} }
  ]
}
JSON
start_server

BUILTIN_INSTALL='https://getuku.com/install-cli'
BUILTIN_UPDATE='https://raw.githubusercontent.com/uku-owl/uku-cli/main/VERSION'
# harness.sh sets these two (and UKU_DEV=1, which is what makes them work)
FIXTURE_INSTALL="$UKU_INSTALL_URL"
FIXTURE_UPDATE="$UKU_UPDATE_URL"

STUB_LOG="$CASE_DIR/curl-argv.log"
mkdir -p "$CASE_DIR/stubbin"
{ printf '#!/bin/sh\n'
  printf 'printf "%%s\\n" "$*" >> %s\n' "$STUB_LOG"
  printf 'exit 1\n'
} > "$CASE_DIR/stubbin/curl"
chmod +x "$CASE_DIR/stubbin/curl"
export PATH="$CASE_DIR/stubbin:$PATH"
: > "$STUB_LOG"

assert_curl_saw() { # SUBSTRING name
  local want="$1" name="$2" log; log="$(cat "$STUB_LOG" 2>/dev/null)"
  case "$log" in
    *"$want"*) _tap_ok "$name" ;;
    *) _tap_fail "$name" "curl was never asked for: $want
--- curl argv ---
$log" ;;
  esac
}
assert_curl_never_saw() { # SUBSTRING name
  local want="$1" name="$2" log; log="$(cat "$STUB_LOG" 2>/dev/null)"
  case "$log" in
    *"$want"*) _tap_fail "$name" "curl WAS asked for: $want
--- curl argv ---
$log" ;;
    *) _tap_ok "$name" ;;
  esac
}

# ── 1 UKU_DEV=1: the override is honoured (this is what the suite relies on) ──
# If this ever goes red the rest of the suite is not hermetic any more — it
# would be reaching the real getuku.com instead of the fixture.
: > "$STUB_LOG"
uku update
assert_curl_saw "$FIXTURE_INSTALL" 'UKU_DEV=1 — UKU_INSTALL_URL is honoured'
assert_curl_never_saw "$BUILTIN_INSTALL" 'and the built-in installer URL is not used'
assert_err_not_contains 'ignoring UKU_INSTALL_URL' 'nothing is ignored under UKU_DEV=1'

# ── 2 without UKU_DEV: the override is dropped, and said so ──────────
: > "$STUB_LOG"
UKU_DEV='' uku update
assert_curl_saw "$BUILTIN_INSTALL" 'without UKU_DEV the built-in installer URL is used'
assert_curl_never_saw "$FIXTURE_INSTALL" 'and the environment override is NOT fetched'
assert_err_contains 'ignoring UKU_INSTALL_URL' 'the CLI says it dropped the override'
assert_err_contains 'UKU_DEV=1' 'and says how to mean it on purpose'
assert_err_contains 'piped into a shell' 'and why it is not a plain setting'

# ── 3 the release pointer is the same lock ───────────────────────────
# doctor is the one command that always asks the network for the pointer, so
# it is where UKU_UPDATE_URL is observable. The stub makes the probe fail,
# which doctor is documented to survive (offline-safe, T3) — the assertion is
# on which URL it asked for, not on the report.
: > "$STUB_LOG"
UKU_DEV='' uku doctor
assert_curl_saw "$BUILTIN_UPDATE" 'without UKU_DEV the built-in release pointer is used'
assert_curl_never_saw "$FIXTURE_UPDATE" 'and the environment override is NOT fetched'
assert_err_contains 'ignoring UKU_UPDATE_URL' 'and it says so'

: > "$STUB_LOG"
uku doctor
assert_curl_saw "$FIXTURE_UPDATE" 'UKU_DEV=1 — UKU_UPDATE_URL is honoured'
assert_curl_never_saw "$BUILTIN_UPDATE" 'and the built-in pointer is not used'

# ── 4 the unattended path — the one that matters ─────────────────────
# auto_update is the reason this lock exists: it runs on an ORDINARY command,
# without being asked, and hands what it fetches to `sh`. Turn it on (the
# harness keeps it off everywhere else), clear UKU_DEV, and check that the
# daily check goes to the built-in pointer and not to the environment's.
: > "$STUB_LOG"
rm -f "$UKU_CONFIG_HOME/last-update-check"
UKU_DEV='' UKU_NO_AUTO_UPDATE=0 uku clients list
assert_curl_saw "$BUILTIN_UPDATE" 'the once-a-day check on an ordinary command uses the built-in pointer'
assert_curl_never_saw "$FIXTURE_UPDATE" 'and never the environment override'
assert_err_contains 'ignoring UKU_UPDATE_URL' 'saying so before it runs'

# ── 5 setting it to the built-in value is not an "override" ──────────
# Someone pinning the documented URL explicitly should not be scolded for it.
: > "$STUB_LOG"
UKU_DEV='' UKU_INSTALL_URL="$BUILTIN_INSTALL" uku update
assert_err_not_contains 'ignoring UKU_INSTALL_URL' 'setting the built-in value changes nothing and warns about nothing'
assert_curl_saw "$BUILTIN_INSTALL" 'and the built-in URL is what runs'

finish
