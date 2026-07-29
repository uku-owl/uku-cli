#!/usr/bin/env bash
# keyring — the opt-in OS credential store (S8, audit 2026-07-29).
#
# The rule this whole file is built around: NOTHING HERE MAY TOUCH THE REAL
# LOGIN KEYCHAIN. `security` and `secret-tool` are stubbed in front of the real
# binaries on PATH — the same mechanism update-trust.sh uses for curl — and the
# stub keeps its "keychain" in a directory inside CASE_DIR. Every section
# re-asserts that `security` still resolves inside CASE_DIR before it runs a
# single command, because a stub that silently fell off PATH would not fail the
# assertions: it would quietly write a live-looking key into the developer's
# Keychain and pass.
#
# The stub also reproduces the one thing that was MEASURED on the real binary
# and is easy to get wrong: `security add-generic-password … -w` (no argument)
# reads the password from stdin and asks for it TWICE. Fed a single line it
# takes EOF as the second answer, stores an EMPTY password, and still exits 0.
# That is why _keyring_set feeds the value twice and then reads it back, and
# §7 here proves the read-back catches it.
#
# What is asserted, in order: a store/lookup/delete round trip · the key never
# reaching the profile file · logout clearing BOTH stores · no backend at all ·
# a backend that fails · a backend that hangs (on read AND on store) · a
# tampered value coming back out · the migration rule · what doctor reports.
. "$(dirname "$0")/../lib/harness.sh"

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

KR_KEY='uku_live_KEYRING0123456789abcdefKRTAIL'
KR_CO='cccccccc-0000-0000-0000-000000000003'
KEYFILE="$CASE_DIR/key.txt"
printf '%s' "$KR_KEY" > "$KEYFILE"

# ── the stub keychain ────────────────────────────────────────────────
STUB_DIR="$CASE_DIR/stubbin"
STUB_LOG="$CASE_DIR/keyring-argv.log"
STUB_STORE="$CASE_DIR/keyring-items"
mkdir -p "$STUB_DIR" "$STUB_STORE"
: > "$STUB_LOG"

# One stub body, two names. $UKU_TEST_KR_MODE picks the behaviour at RUN time,
# so a section changes it with a variable instead of rewriting the file:
#   ok        a working store
#   fail      every call exits 1 (a refusing / broken backend)
#   hang      every call sleeps far past UKU_KEYRING_TIMEOUT
#   hangread  only the lookup hangs (a locked keychain on an ordinary command)
#   halfwrite the measured `security` bug: stores an EMPTY value, exits 0
_write_stub() { # PATH-OF-STUB
  cat > "$1" <<STUB
#!/bin/sh
# fake credential-store binary (tests only) — never talks to a real keychain
LOG="$STUB_LOG"
STORE="$STUB_STORE"
MODE="\${UKU_TEST_KR_MODE:-ok}"
printf '%s\n' "\$0 \$*" >> "\$LOG"
case "\$MODE" in
  hang) sleep 10; exit 0 ;;
esac
svc=""; acct=""; op="\$1"; shift
while [ \$# -gt 0 ]; do
  case "\$1" in
    -s|service) svc="\$2"; shift 2 ;;
    -a|account) acct="\$2"; shift 2 ;;
    --label=*)  shift ;;
    -D)         shift 2 ;;
    *)          shift ;;
  esac
done
# secret-tool's op names map onto the same three actions
case "\$op" in
  store)  op="add-generic-password" ;;
  lookup) op="find-generic-password" ;;
  clear)  op="delete-generic-password" ;;
esac
item="\$STORE/\$(printf '%s' "\$svc-\$acct" | tr -c '[:alnum:]._-' '_')"
case "\$MODE" in
  fail) exit 1 ;;
esac
case "\$op" in
  add-generic-password)
    if [ "\$MODE" = "halfwrite" ]; then : > "\$item"; exit 0; fi
    # the real \`security\` asks twice; secret-tool once, with no trailing
    # newline. Accept both — and note \`read\` returns non-zero on a final line
    # with no newline while still assigning it, so the status is discarded
    # rather than used to clear the value.
    one=""; two=""
    IFS= read -r one || :
    [ -n "\$one" ] || exit 1
    IFS= read -r two || :
    [ -n "\$two" ] || two="\$one"
    if [ "\$one" != "\$two" ]; then : > "\$item"; exit 0; fi
    printf '%s' "\$one" > "\$item"
    exit 0 ;;
  find-generic-password)
    if [ "\$MODE" = "hangread" ]; then sleep 10; exit 0; fi
    [ -f "\$item" ] || exit 44
    cat "\$item"; printf '\n'
    exit 0 ;;
  delete-generic-password)
    [ -f "\$item" ] || exit 44
    rm -f "\$item"; exit 0 ;;
esac
exit 2
STUB
  chmod +x "$1"
}
_write_stub "$STUB_DIR/security"
export PATH="$STUB_DIR:$PATH"
STUB_PATH="$PATH"

# ── the guard ────────────────────────────────────────────────────────
# Re-run before every section. A stub that fell off PATH is not a failed
# assertion, it is a live write to the developer's login keychain.
guard_stub() { # LABEL
  local resolved; resolved="$(command -v security 2>/dev/null || true)"
  case "$resolved" in
    "$STUB_DIR"/*) : ;;
    *) printf 'Bail out! `security` resolves to %s, not the stub — refusing to run (%s)\n' "${resolved:-nothing}" "$1"
       exit 99 ;;
  esac
}
stub_log() { cat "$STUB_LOG" 2>/dev/null; }
assert_stub_saw() { # SUBSTRING name
  local want="$1" name="$2" log; log="$(stub_log)"
  case "$log" in
    *"$want"*) _tap_ok "$name" ;;
    *) _tap_fail "$name" "the keyring stub was never asked: $want
--- stub argv ---
$log" ;;
  esac
}
assert_stub_never_saw() { # SUBSTRING name
  local want="$1" name="$2" log; log="$(stub_log)"
  case "$log" in
    *"$want"*) _tap_fail "$name" "the keyring stub WAS asked: $want
--- stub argv ---
$log" ;;
    *) _tap_ok "$name" ;;
  esac
}
# assert_no_key_on_disk — the point of the feature, checked the blunt way:
# grep every file under the config dir and the fake HOME for the key itself.
assert_no_key_on_disk() { # name
  local name="$1" hits
  hits="$(grep -rl "$KR_KEY" "$UKU_CONFIG_HOME" "$HOME" 2>/dev/null | grep -v "^$STUB_STORE" || true)"
  if [ -z "$hits" ]; then _tap_ok "$name"
  else _tap_fail "$name" "the key appears in:
$hits"; fi
}
elapsed_since() { printf '%s' "$(( $(date +%s) - $1 ))"; }
assert_faster_than() { # SECONDS ELAPSED name
  local limit="$1" got="$2" name="$3"
  if [ "$got" -le "$limit" ]; then _tap_ok "$name"
  else _tap_fail "$name" "took ${got}s, expected at most ${limit}s — the call was not bounded"; fi
}

clear_env_creds
export UKU_KEYRING_TIMEOUT=1

# ── 1 store · lookup · delete, through the CLI ───────────────────────
guard_stub 'round trip'
: > "$STUB_LOG"
reset_requests
UKU_KEYRING=1 uku_stdin "$KEYFILE" auth login --account kr --company "$KR_CO" --key-stdin
assert_status 0 'a login with UKU_KEYRING=1 exits 0'
assert_request_count 1 'the key was still validated against the API first'
assert_stub_saw 'add-generic-password' 'and then handed to the OS keyring'
assert_stub_saw '-s uku-cli:kr -a kr' 'under a service namespaced to the account'
assert_err_contains 'stored in the OS keyring' 'and the CLI says where it went'

assert_true 'the profile file exists' test -f "$UKU_CONFIG_HOME/profiles/kr"
assert_equals "$(grep -c '^UKU_KEY=' "$UKU_CONFIG_HOME/profiles/kr" | tr -d ' ')" "0" \
  'and carries no UKU_KEY line at all'
assert_equals "$(grep '^UKU_KEY_STORE=' "$UKU_CONFIG_HOME/profiles/kr")" "UKU_KEY_STORE=keyring" \
  'it records WHERE the key is, so a read knows where to look'
assert_equals "$(grep '^UKU_COMPANY=' "$UKU_CONFIG_HOME/profiles/kr")" "UKU_COMPANY=$KR_CO" \
  'the company id — not a secret — stays in the file'
assert_no_key_on_disk 'the key itself is in no file the CLI wrote'

# the lookup half: an ordinary command reads it back and sends it
: > "$STUB_LOG"
reset_requests
uku clients list
assert_status 0 'an ordinary command on a keyring account exits 0'
assert_stub_saw 'find-generic-password' 'it asked the keyring for the key'
assert_request 1 X-API-Key "$KR_KEY" 'and the key that reached the wire is the stored one'

# reading follows the PROFILE, not the environment: the variable says where a
# NEW key would go, never where an existing one is.
: > "$STUB_LOG"
reset_requests
UKU_KEYRING=0 uku clients list
assert_status 0 'UKU_KEYRING=0 does not sign a keyring account out'
assert_request 1 X-API-Key "$KR_KEY" 'the key is still read from the keyring'

# ── 2 doctor names the store ─────────────────────────────────────────
guard_stub 'doctor'
uku doctor
assert_out_contains 'credential store: the OS keyring' 'doctor reports which store is in use'
assert_out_contains 'uku-cli:kr' 'naming the exact service, so nobody has to guess'

# ── 3 logout clears BOTH stores ──────────────────────────────────────
# The worst outcome this feature can produce is a "signed out" that leaves a
# live key in the Keychain.
guard_stub 'logout'
: > "$STUB_LOG"
uku auth logout --account kr
assert_status 0 'logout exits 0'
assert_stub_saw 'delete-generic-password' 'it asked the keyring to release the key'
assert_true 'the profile file is gone' test ! -f "$UKU_CONFIG_HOME/profiles/kr"
assert_equals "$(ls "$STUB_STORE" | wc -l | tr -d ' ')" "0" 'and the keyring holds nothing for it either'
assert_err_contains 'Removed the key from the OS keyring' 'and it says so out loud'

# a file-stored account is swept too — someone who tried the keyring, turned it
# off, and logged out must not leave the old secret behind.
guard_stub 'logout sweeps a file account too'
: > "$STUB_LOG"
write_profile filed "$KR_CO" "$KR_KEY"
uku auth logout --account filed
assert_status 0 'logging out of a file-stored account exits 0'
assert_stub_saw 'delete-generic-password' 'the keyring is swept even then'

# ── 4 the keyring refuses to release it → the command says so, loudly ─
guard_stub 'delete failure'
: > "$STUB_LOG"
reset_requests
UKU_KEYRING=1 uku_stdin "$KEYFILE" auth login --account stuck --company "$KR_CO" --key-stdin
assert_status 0 'a second keyring account is stored'
UKU_TEST_KR_MODE=fail uku auth logout --account stuck
assert_status 3 'a logout that cannot clear the keyring is NOT reported as success'
assert_err_contains 'did NOT release the key' 'it says what is still out there'
assert_err_contains 'security delete-generic-password' 'and the exact command to finish the job'
assert_true 'the profile file went anyway — the file half did work' \
  test ! -f "$UKU_CONFIG_HOME/profiles/stuck"
rm -f "$STUB_STORE"/* 2>/dev/null || true

# ── 5 account remove is the same contract ────────────────────────────
guard_stub 'account remove'
: > "$STUB_LOG"
UKU_KEYRING=1 uku_stdin "$KEYFILE" auth login --account gone --company "$KR_CO" --key-stdin
: > "$STUB_LOG"
uku account remove gone
assert_status 0 'account remove exits 0'
assert_stub_saw 'delete-generic-password' 'and removes the secret from the keyring too'
assert_equals "$(ls "$STUB_STORE" | wc -l | tr -d ' ')" "0" 'nothing is left behind'

# ── 6 a backend that returns non-zero ────────────────────────────────
# Falling back is allowed. Falling back QUIETLY is not: the user would believe
# the key is in the keyring while it is in a file.
guard_stub 'store fails'
: > "$STUB_LOG"
reset_requests
UKU_TEST_KR_MODE=fail UKU_KEYRING=1 uku_stdin "$KEYFILE" \
  auth login --account failed --company "$KR_CO" --key-stdin
assert_status 0 'a login whose keyring refuses still signs you in'
assert_err_contains 'FALLING BACK to the 0600 file' 'and says the fallback happened in those words'
assert_err_contains 'not in the keyring' 'leaving no room to think otherwise'
assert_equals "$(grep -c '^UKU_KEY=' "$UKU_CONFIG_HOME/profiles/failed" | tr -d ' ')" "1" \
  'the key is in the file, where the message said it is'
reset_requests
uku --account failed clients list
assert_status 0 'and the account works'
assert_request 1 X-API-Key "$KR_KEY" 'with the key that was validated'

# ── 7 a backend that lies: stored, exit 0, empty value ───────────────
# Measured on the real `security`: a short stdin makes it store an empty
# password and exit 0. The read-back in _keyring_set is what catches it.
guard_stub 'halfwrite'
: > "$STUB_LOG"
UKU_TEST_KR_MODE=halfwrite UKU_KEYRING=1 uku_stdin "$KEYFILE" \
  auth login --account half --company "$KR_CO" --key-stdin
assert_status 0 'a login against a lying backend still signs you in'
assert_err_contains 'FALLING BACK to the 0600 file' 'the read-back caught the empty value'
assert_equals "$(grep -c '^UKU_KEY=' "$UKU_CONFIG_HOME/profiles/half" | tr -d ' ')" "1" \
  'and the key is in the file rather than nowhere'

# ── 8 a backend that hangs — on the store path ───────────────────────
# A locked keychain with no GUI and no tty is where basecamp got stuck. The
# call must be killed, not waited on, and the credential must not be lost.
guard_stub 'hang on store'
: > "$STUB_LOG"
started="$(date +%s)"
UKU_TEST_KR_MODE=hang UKU_KEYRING=1 uku_stdin "$KEYFILE" \
  auth login --account hung --company "$KR_CO" --key-stdin
took="$(elapsed_since "$started")"
assert_status 0 'a hanging keyring does not hang the login'
assert_faster_than 6 "$took" "and it came back in ${took}s, not the stub's 10"
assert_err_contains 'did not answer within 1s' 'it names the timeout'
assert_err_contains 'FALLING BACK to the 0600 file' 'and refuses to pretend the keyring took it'
assert_equals "$(grep -c '^UKU_KEY=' "$UKU_CONFIG_HOME/profiles/hung" | tr -d ' ')" "1" \
  'the key you just typed is not lost'

# ── 9 a backend that hangs — on the READ path ────────────────────────
# Here a fallback would be a lie (there is no file key to fall back to), so a
# timeout is a REFUSAL: exit 2, nothing sent, and a message about a locked
# keychain rather than "not signed in", which would send the user to re-type a
# key that is perfectly fine.
guard_stub 'hang on read'
: > "$STUB_LOG"
UKU_KEYRING=1 uku_stdin "$KEYFILE" auth login --account locked --company "$KR_CO" --key-stdin
uku account use locked >/dev/null 2>&1
: > "$STUB_LOG"
reset_requests
started="$(date +%s)"
UKU_TEST_KR_MODE=hangread uku clients list
took="$(elapsed_since "$started")"
assert_status 2 'a locked keyring is an auth error, not a hang'
assert_faster_than 6 "$took" "and it refused in ${took}s"
assert_no_requests 'nothing was sent'
assert_err_contains 'did not answer within 1s' 'the message is about the keyring'
assert_err_contains 'locked keychain' 'and names the real cause'
assert_err_not_contains 'Not signed in' 'it never tells the user to re-type a key that is fine'

# ── 10 the secret is gone from the keyring behind our back ───────────
guard_stub 'secret vanished'
: > "$STUB_LOG"
reset_requests
rm -f "$STUB_STORE"/* 2>/dev/null || true
uku clients list
assert_status 2 'a profile pointing at a secret that is not there is exit 2'
assert_no_requests 'and nothing is sent'
assert_err_contains 'removed outside this CLI' 'the message says what actually happened'

# ── 11 a tampered value coming OUT of the keyring ────────────────────
# Wave 1 checked credentials on the way IN. A keyring is a store, not a
# validator: `security` will hold a value with a newline in it, and that value
# would inject a second directive into curl's -K config.
guard_stub 'CR/LF out of the keyring'
: > "$STUB_LOG"
reset_requests
printf 'uku_live_EVIL\nurl = http://127.0.0.1:1/exfil' > "$STUB_STORE/uku-cli_locked-locked"
uku clients list
assert_status 1 'a key with a line break in it is refused'
assert_no_requests 'and NOTHING is sent — not one request, let alone two'
assert_err_contains 'must be a single line' 'with the same reason as every other credential path'
rm -f "$STUB_STORE"/* 2>/dev/null || true

# ── 12 migration: an ordinary command never moves a key ──────────────
# The decision, stated: UKU_KEYRING=1 says where a NEW key goes. A `uku tasks
# list` that rewrote your credential store because a variable was set in some
# shell profile would be a surprise; one run WITHOUT the variable moving it
# back into a file would be worse.
guard_stub 'migration'
# The fallback sections above deliberately left file-stored profiles holding
# the key; drop them so the blunt "the key is in NO file" grep below means what
# it says instead of being narrowed to one path.
rm -f "$UKU_CONFIG_HOME/profiles/failed" "$UKU_CONFIG_HOME/profiles/half" "$UKU_CONFIG_HOME/profiles/hung"
clear_env_creds
write_profile legacy "$KR_CO" "$KR_KEY"
set_active_profile legacy
: > "$STUB_LOG"
reset_requests
UKU_KEYRING=1 uku clients list
assert_status 0 'a file-stored account keeps working with UKU_KEYRING=1 set'
assert_request 1 X-API-Key "$KR_KEY" 'reading the key straight out of the file'
assert_equals "$(stub_log)" "" 'and the keyring was not called at all — nothing moved'
assert_equals "$(grep -c '^UKU_KEY=' "$UKU_CONFIG_HOME/profiles/legacy" | tr -d ' ')" "1" \
  'the profile is untouched'

# doctor is where that state is visible, because it is the one command whose
# job is to say what is actually going on.
UKU_KEYRING=1 uku doctor
assert_out_contains 'UKU_KEYRING=1 is set, but an existing key is never moved' \
  'doctor points out the gap between the setting and the reality'

# …and `uku auth login` is what migrates it.
: > "$STUB_LOG"
reset_requests
UKU_KEYRING=1 uku_stdin "$KEYFILE" auth login --account legacy --company "$KR_CO" --key-stdin
assert_status 0 'a re-login with UKU_KEYRING=1 exits 0'
assert_stub_saw 'add-generic-password' 'and moves the key into the keyring'
assert_equals "$(grep -c '^UKU_KEY=' "$UKU_CONFIG_HOME/profiles/legacy" | tr -d ' ')" "0" \
  'the UKU_KEY line is gone from the file'
assert_no_key_on_disk 'the migrated key is in no file'

# and back the other way: a login WITHOUT the variable must not leave the old
# secret sitting in the keyring holding a live key.
: > "$STUB_LOG"
reset_requests
uku_stdin "$KEYFILE" auth login --account legacy --company "$KR_CO" --key-stdin
assert_status 0 'a login without UKU_KEYRING exits 0'
assert_stub_saw 'delete-generic-password' 'and clears the secret it is no longer using'
assert_equals "$(grep -c '^UKU_KEY=' "$UKU_CONFIG_HOME/profiles/legacy" | tr -d ' ')" "1" \
  'the key is back in the file'

# ── 13 no backend on this machine at all ─────────────────────────────
guard_stub 'before hiding it'
: > "$STUB_LOG"
reset_requests
hide_cmd security          # takes the stub with it; there is no secret-tool here either
UKU_KEYRING=1 uku_stdin "$KEYFILE" auth login --account nokr --company "$KR_CO" --key-stdin
assert_status 0 'with no keyring on the box, login still works'
assert_err_contains 'neither' 'and says the tools are missing'
assert_err_contains 'plain text' 'and does not dress the file up as something else'
assert_equals "$(grep -c '^UKU_KEY=' "$UKU_CONFIG_HOME/profiles/nokr" | tr -d ' ')" "1" \
  'the key went to the 0600 file'

# a profile that SAYS keyring on a machine with no keyring is a refusal, not a
# silent "not signed in"
mkdir -p "$UKU_CONFIG_HOME/profiles"
{ printf 'UKU_BASE=%s\n' "$UKU_BASE_URL"
  printf 'UKU_COMPANY=%s\n' "$KR_CO"
  printf 'UKU_KEY_STORE=keyring\n'
} > "$UKU_CONFIG_HOME/profiles/orphan"
chmod 600 "$UKU_CONFIG_HOME/profiles/orphan"
reset_requests
uku --account orphan clients list
assert_status 2 'a keyring profile with no keyring tool is exit 2'
assert_no_requests 'and sends nothing'
assert_err_contains 'secret-tool' 'naming what is missing'
export PATH="$STUB_PATH"

# ── 14 the Linux backend ─────────────────────────────────────────────
# Same three operations through `secret-tool`, chosen only when `security` is
# not there. NOTE: the secret-tool argument forms are written to its documented
# interface — the stub encodes that documentation, and this asserts we call it
# the way we say we do. It has NOT been run against real libsecret; this repo
# has no Linux machine. Said plainly here rather than implied by a green test.
guard_stub 'before the secret-tool section'
_write_stub "$CASE_DIR/stubbin/secret-tool"
hide_cmd security     # leaves the secret-tool stub reachable
: > "$STUB_LOG"
reset_requests
UKU_KEYRING=1 uku_stdin "$KEYFILE" auth login --account lin --company "$KR_CO" --key-stdin
assert_status 0 'a login on a secret-tool box exits 0'
assert_stub_saw 'store --label=Uku CLI (lin) service uku-cli:lin account lin' \
  'secret-tool is called with the documented store form'
assert_equals "$(grep -c '^UKU_KEY=' "$UKU_CONFIG_HOME/profiles/lin" | tr -d ' ')" "0" \
  'and the key is not in the profile file'
: > "$STUB_LOG"
reset_requests
uku --account lin clients list
assert_status 0 'reading it back works'
assert_stub_saw 'lookup service uku-cli:lin account lin' 'through secret-tool lookup'
assert_request 1 X-API-Key "$KR_KEY" 'and the right key reaches the wire'
: > "$STUB_LOG"
uku account remove lin
assert_stub_saw 'clear service uku-cli:lin account lin' 'and secret-tool clear removes it'
export PATH="$STUB_PATH"

finish
