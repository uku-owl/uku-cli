#!/usr/bin/env bash
# base-trust — where a live credential is allowed to travel (S5, audit
# 2026-07-29).
#
# Two measured facts this pins:
#   * `--base http://<host>` sent the real `X-API-Key` header to a plaintext
#     fixture server, in full, with nothing printed. The only thing the scheme
#     decided was whether `--proto '=https'` got added.
#   * `--base https://evil.example` sent the key to a host the user never
#     configured, silently — no prompt, no line, no trace.
#
# The assertions are therefore not about the response. They are "curl was never
# executed" (the refusal path) and "this exact sentence reached stderr" (the
# announcement path).
#
# WHY THIS CASE REACHES PAST uku(): the harness wrapper bails on any argv or
# base that is not 127.0.0.1, which is exactly what has to be exercised here.
# uku_offbox() below is the narrow exception, and it is safe by construction:
# every off-box run either dies before curl is reached (the refusal cases,
# proven by an empty spy log) or carries --dry-run, which returns before curl
# is invoked at all. No off-box host is ever contacted, so the suite's promise
# — a test never touches a real host — still holds.
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

# A stub curl, not the spy: it records argv and NEVER execs the real binary,
# so even a regression that got as far as calling curl cannot put a packet on
# the wire from this case.
STUB_LOG="$CASE_DIR/curl-argv.log"
: > "$STUB_LOG"
mkdir -p "$CASE_DIR/stubbin"
{ printf '#!/bin/sh\n'
  printf 'printf "%%s\\n" "$*" >> %s\n' "$STUB_LOG"
  printf 'exit 1\n'
} > "$CASE_DIR/stubbin/curl"
chmod +x "$CASE_DIR/stubbin/curl"
STUB_PATH="$CASE_DIR/stubbin:$PATH"

# uku_offbox BASE ARG… — the CLI with a deliberately non-loopback base and the
# stub curl in front. STATUS/OUT/ERR as usual.
uku_offbox() {
  local base="$1"; shift
  : > "$OUT_FILE"; : > "$ERR_FILE"
  PATH="$STUB_PATH" UKU_BASE_URL="$base" "$UKU_BIN" "$@" > "$OUT_FILE" 2> "$ERR_FILE" < /dev/null
  STATUS=$?
  OUT="$(cat "$OUT_FILE")"
  ERR="$(cat "$ERR_FILE")"
  return 0
}
# uku_profile_run ARG… — the CLI with NO base and NO credentials in the
# environment, so the stored profile is the only thing that can decide where
# the request goes. (UKU_BASE_URL beats a profile's own UKU_BASE, so leaving
# the harness's loopback value set would test the env path again.)
uku_profile_run() {
  : > "$OUT_FILE"; : > "$ERR_FILE"
  ( unset UKU_BASE_URL UKU_API_KEY UKU_COMPANY
    PATH="$STUB_PATH" exec "$UKU_BIN" "$@" ) > "$OUT_FILE" 2> "$ERR_FILE" < /dev/null
  STATUS=$?
  OUT="$(cat "$OUT_FILE")"
  ERR="$(cat "$ERR_FILE")"
  return 0
}
assert_stub_unused() { # [name]
  local name="${1:-curl was never executed}"
  if [ -s "$STUB_LOG" ]; then
    _tap_fail "$name" "curl WAS executed:
$(cat "$STUB_LOG")"
  else
    _tap_ok "$name"
  fi
}

# ── 0 control: the loopback fixture is unaffected, and says nothing ──
# The whole suite depends on http://127.0.0.1 continuing to work. It is also
# the case that must stay SILENT: a line printed on every command of a local
# dev day is a line people learn to skip.
uku clients list
assert_status 0 'an http:// loopback base still works'
assert_request_count 1 'and its request reaches the fixture'
assert_err_not_contains 'sending Uku credentials' 'a loopback base announces nothing'

# ── 1 http:// to a host that is not this machine — refused, nothing sent ──
reset_requests
: > "$STUB_LOG"
uku_offbox 'http://uku-cli-test.invalid' clients list
assert_status 1 'an http:// base on a remote host is refused (exit 1)'
assert_stub_unused 'curl never ran — zero requests left this process'
assert_no_requests 'and the fixture saw nothing either'
assert_err_contains 'cleartext' 'the refusal names the actual harm'
assert_err_contains 'uku-cli-test.invalid' 'and the host it refused'

# the --base flag is the same door as UKU_BASE_URL
: > "$STUB_LOG"
uku_offbox "$UKU_BASE_URL" clients list --base 'http://uku-cli-test.invalid'
assert_status 1 '--base http://<remote> is refused too'
assert_stub_unused 'curl never ran for the --base form'
assert_no_requests 'nothing reached the fixture'

# a write is refused at the same point, before the write doctrine starts
: > "$STUB_LOG"
uku_offbox 'http://uku-cli-test.invalid' tasks create --data '{"title":"x"}' --yes
assert_status 1 'a write over cleartext is refused'
assert_stub_unused 'and creates nothing, because curl never ran'

# --dry-run is refused as well: it writes the 0600 key config before it prints,
# so the guard has to come first (same reasoning as cred-injection.sh §5).
: > "$STUB_LOG"
uku_offbox 'http://uku-cli-test.invalid' clients list --dry-run
assert_status 1 '--dry-run over cleartext is refused, not previewed'
assert_out_not_contains 'would send' 'and prints no preview'

# ── 2 the loopback table, exactly as documented ──────────────────────
# These four spellings must all be accepted, and they are accepted for their
# NAME, not because they resolve — the stub curl means nothing is dialled.
for h in 'http://localhost:9' 'http://api.localhost:9' 'http://127.0.0.1:9' 'http://[::1]:9'; do
  : > "$STUB_LOG"
  uku_offbox "$h" clients list
  if [ "$STATUS" = "1" ] && [ "${ERR#*cleartext}" != "$ERR" ]; then
    _tap_fail "loopback base $h is accepted" "refused as cleartext: $ERR"
  else
    _tap_ok "loopback base $h is accepted"
  fi
done

# ── 3 no scheme at all → refused, not guessed ────────────────────────
# curl treats a bare host as http://, which is the same cleartext leak arrived
# at by accident rather than by flag.
: > "$STUB_LOG"
uku_offbox 'app.getuku.com' clients list
assert_status 1 'a base with no scheme is refused'
assert_stub_unused 'and nothing was dialled'
assert_err_contains 'must start with https://' 'saying what a base has to look like'

# ── 4 a userinfo prefix must not decorate the host ───────────────────
# https://app.getuku.com@evil.example/ is a request to evil.example, and the
# sentence a human reads is the whole point of the announcement: a line saying
# "sending credentials to app.getuku.com@evil.example" invites exactly the
# glance that stops at the familiar name. So the host reported is the host
# dialled, with the userinfo dropped.
: > "$STUB_LOG"
uku_offbox 'https://app.getuku.com@staging.uku-cli-test.invalid' clients list --dry-run
assert_err_contains 'to staging.uku-cli-test.invalid — not the default' \
  'the announcement names the REAL destination, not the userinfo'
# asserted on the announcement LINE alone: the --dry-run preview below it
# prints the URL verbatim, userinfo and all, which is right — that is what
# would be dialled.
said="$(printf '%s\n' "$ERR" | grep 'sending Uku credentials' || true)"
case "$said" in
  *"app.getuku.com@"*) _tap_fail 'the announcement never repeats the decoration back' "line was: $said" ;;
  *) _tap_ok 'the announcement never repeats the decoration back' ;;
esac
assert_stub_unused 'nothing dialled'

# the same over http is still refused, and refused by the real host
: > "$STUB_LOG"
uku_offbox 'http://app.getuku.com@uku-cli-test.invalid' clients list
assert_status 1 'a userinfo prefix does not make a remote host loopback'
assert_err_contains 'http://uku-cli-test.invalid' 'and the refusal names the real host'
assert_stub_unused 'nothing dialled'

# ── 5 https to a non-default host: allowed, but it announces ─────────
# --dry-run so that nothing is even attempted; the announcement must still
# come out, because it is printed before the request is built.
: > "$STUB_LOG"
uku_offbox 'https://staging.uku-cli-test.invalid' clients list --dry-run
assert_status 0 'an https base on another host is allowed'
assert_err_contains 'sending Uku credentials to staging.uku-cli-test.invalid' \
  'and it says, on stderr, where the credentials are going'
assert_err_contains 'not the default' 'contrasting it with the default host'
assert_stub_unused 'still nothing dialled under --dry-run'

# exactly one line for one invocation — not one per internal step
n="$(printf '%s\n' "$ERR" | grep -c 'sending Uku credentials' | tr -d ' ')"
assert_equals "$n" '1' 'the announcement is one line, not a repeated banner'

# ── 6 --quiet does not silence it ────────────────────────────────────
# --quiet exists to drop progress chatter. Where the key went is not chatter,
# and an agent running --quiet is exactly the case a supervising human needs
# this line for. (info() IS silenced by --quiet — that is the contrast.)
uku_offbox 'https://staging.uku-cli-test.invalid' clients list --dry-run --quiet
assert_err_contains 'sending Uku credentials to staging.uku-cli-test.invalid' \
  '--quiet does not silence the announcement'

# ── 7 a STORED profile announces every time, not just when it changes ──
# This is the S3/S7 attack primitive's end state: a base written into a profile
# is read by every later command, including ones with no flag at all. Silence
# must not be purchasable by persistence, so the rule is the same as for a
# flag — non-default and non-loopback says so, every invocation.
clear_env_creds
mkdir -p "$UKU_CONFIG_HOME/profiles"
{ printf 'UKU_BASE=%s\n' 'https://staging.uku-cli-test.invalid'
  printf 'UKU_COMPANY=%s\n' "$TEST_COMPANY"
  printf 'UKU_KEY=%s\n' "$TEST_API_KEY"
} > "$UKU_CONFIG_HOME/profiles/staging"
chmod 600 "$UKU_CONFIG_HOME/profiles/staging"
set_active_profile staging
: > "$STUB_LOG"
uku_profile_run clients list --dry-run
assert_status 0 'a stored non-default base is usable'
assert_err_contains 'sending Uku credentials to staging.uku-cli-test.invalid' \
  'and announces itself even though nothing on this command line named it'

# the same profile over http is refused just as flatly
{ printf 'UKU_BASE=%s\n' 'http://staging.uku-cli-test.invalid'
  printf 'UKU_COMPANY=%s\n' "$TEST_COMPANY"
  printf 'UKU_KEY=%s\n' "$TEST_API_KEY"
} > "$UKU_CONFIG_HOME/profiles/staging"
chmod 600 "$UKU_CONFIG_HOME/profiles/staging"
: > "$STUB_LOG"
uku_profile_run clients list
assert_status 1 'a stored http:// base on a remote host is refused'
assert_stub_unused 'curl never ran'
assert_no_requests 'nothing sent'

finish
