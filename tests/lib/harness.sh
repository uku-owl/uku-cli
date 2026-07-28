#!/usr/bin/env bash
# harness.sh — sourced by every tests/cases/*.sh file.
#
# Hermetic by construction:
#   * a fresh temp HOME and UKU_CONFIG_HOME per case, so no test can read or
#     write the developer's real credentials in ~/.config/uku;
#   * NO_COLOR=1 and UKU_NO_AUTO_UPDATE=1;
#   * a hard guard that refuses to run a single command unless UKU_BASE_URL
#     points at 127.0.0.1 — the tests must never touch the real API.
#
# bash 3.2 compatible: no associative arrays, no ${var^^}, no mapfile, no &>>.

# ── locations ────────────────────────────────────────────────────────
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
UKU_BIN="$REPO_ROOT/bin/uku"
SERVER_PY="$TESTS_DIR/server.py"
REQLOG_PY="$HARNESS_DIR/reqlog.py"

# The real system temp dir, captured before any case redirects TMPDIR into its
# own (soon-to-be-deleted) sandbox — otherwise the second setup_case in a file
# would try to mktemp inside the first case's removed directory.
HARNESS_TMPDIR="${TMPDIR:-/tmp}"

PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3}"
have_cmd() { command -v "$1" >/dev/null 2>&1; }
have_cmd "$PYTHON_BIN" || PYTHON_BIN="python3"

# ── the credentials every case uses (fake, long enough to exercise masking) ──
TEST_API_KEY='uku_live_TESTKEY0123456789abcdefSECRETTAIL'
TEST_COMPANY='11111111-2222-3333-4444-555555555555'

# ── TAP bookkeeping ──────────────────────────────────────────────────
TAP_N=0
TAP_FAILED=0
CASE_NAME="$(basename "${BASH_SOURCE[1]:-case}" .sh)"

_tap_ok()    { TAP_N=$((TAP_N + 1)); printf 'ok %d - %s\n' "$TAP_N" "$1"; }
_tap_fail()  {
  TAP_N=$((TAP_N + 1)); TAP_FAILED=$((TAP_FAILED + 1))
  printf 'not ok %d - %s\n' "$TAP_N" "$1"
  # sed, not a printf loop: a diagnostic line starting with "-" would be read
  # as a printf option under bash 3.2.
  printf '%s\n' "$2" | sed 's/^/  # /'
}

# _diag — dump the state a failing assertion needs, once, indented.
_diag() {
  printf 'exit status: %s\n' "${STATUS:-?}"
  printf '%s\n' '--- stdout ---'
  [ -f "${OUT_FILE:-}" ] && head -c 2000 "$OUT_FILE"
  printf '\n%s\n' '--- stderr ---'
  [ -f "${ERR_FILE:-}" ] && head -c 2000 "$ERR_FILE"
  printf '\n%s\n' "--- requests ($(request_count)) ---"
  "$PYTHON_BIN" "$REQLOG_PY" dump "$REQ_LOG" 2>/dev/null
}

# ── case lifecycle ───────────────────────────────────────────────────
CASE_DIR=""
SERVER_PID=""
REQ_LOG=""
SERVER_SCRIPT=""
REAL_CURL=""

# setup_case — fresh temp dirs + hermetic env. Call once at the top of a case.
setup_case() {
  CASE_DIR="$(mktemp -d "${HARNESS_TMPDIR%/}/uku-test-XXXXXX")"
  mkdir -p "$CASE_DIR/home" "$CASE_DIR/config" "$CASE_DIR/work"

  REAL_CURL="$(command -v curl)"

  export HOME="$CASE_DIR/home"
  export XDG_CONFIG_HOME="$CASE_DIR/home/.config"
  export UKU_CONFIG_HOME="$CASE_DIR/config"
  export NO_COLOR=1
  export UKU_NO_AUTO_UPDATE=1
  export TMPDIR="$CASE_DIR/work"
  # keep the CLI away from anything that resolves to the internet
  export UKU_INSTALL_URL="http://127.0.0.1:1/never"
  unset UKU_QUIET UKU_JSON UKU_DRY UKU_YES 2>/dev/null || true

  SERVER_SCRIPT="$CASE_DIR/script.json"
  REQ_LOG="$CASE_DIR/requests.jsonl"
  OUT_FILE="$CASE_DIR/stdout"
  ERR_FILE="$CASE_DIR/stderr"
  : > "$REQ_LOG"
  printf '{"routes":[]}\n' > "$SERVER_SCRIPT"
}

# server_script — read a JSON script from stdin. Call BEFORE start_server.
#   server_script <<'JSON'
#   { "routes": [ … ] }
#   JSON
server_script() { cat > "$SERVER_SCRIPT"; }

# start_server — boot the fixture on an ephemeral 127.0.0.1 port and export
# UKU_BASE_URL. Also points the update/release pointer at the fixture so no
# check can reach the network.
start_server() {
  local portfile="$CASE_DIR/port"
  : > "$portfile"
  "$PYTHON_BIN" "$SERVER_PY" --script "$SERVER_SCRIPT" --log "$REQ_LOG" > "$portfile" 2>"$CASE_DIR/server.err" &
  SERVER_PID=$!
  local i=0 port=""
  while [ "$i" -lt 200 ]; do
    port="$(head -n1 "$portfile" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$port" ] && break
    i=$((i + 1))
    sleep 0.05
  done
  if [ -z "$port" ]; then
    printf 'Bail out! fixture server did not start\n'
    cat "$CASE_DIR/server.err" >&2 2>/dev/null
    exit 1
  fi
  SERVER_PORT="$port"
  export UKU_BASE_URL="http://127.0.0.1:$port"
  export UKU_UPDATE_URL="http://127.0.0.1:$port/VERSION"
  # default identity: the env path (a complete key+company wins outright)
  export UKU_API_KEY="$TEST_API_KEY"
  export UKU_COMPANY="$TEST_COMPANY"
}

stop_server() {
  [ -n "$SERVER_PID" ] || return 0
  kill -TERM "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""
}

teardown_case() {
  stop_server
  [ -n "$CASE_DIR" ] && [ -d "$CASE_DIR" ] && rm -rf "$CASE_DIR"
  CASE_DIR=""
}

# finish — print the human summary and exit with the case's verdict.
finish() {
  teardown_case
  printf '1..%d\n' "$TAP_N"
  if [ "$TAP_FAILED" -gt 0 ]; then
    printf '# %s: %d/%d passed, %d FAILED\n' "$CASE_NAME" "$((TAP_N - TAP_FAILED))" "$TAP_N" "$TAP_FAILED"
    exit 1
  fi
  printf '# %s: %d/%d passed\n' "$CASE_NAME" "$TAP_N" "$TAP_N"
  exit 0
}

# ── credentials on disk (the profile path) ───────────────────────────
# Written directly rather than via `uku auth login`: login ignores --base and
# UKU_BASE_URL and always validates against https://app.getuku.com, so calling
# it in a test would hit the real API. See KNOWN ISSUE #5 in tests/run.sh.
write_profile() { # NAME [COMPANY] [KEY]
  local name="$1" company="${2:-$TEST_COMPANY}" key="${3:-$TEST_API_KEY}"
  mkdir -p "$UKU_CONFIG_HOME/profiles"
  { printf '# Uku CLI account "%s" — private (0600). Do not share.\n' "$name"
    printf 'UKU_BASE=%s\n' "$UKU_BASE_URL"
    printf 'UKU_COMPANY=%s\n' "$company"
    printf 'UKU_KEY=%s\n' "$key"
  } > "$UKU_CONFIG_HOME/profiles/$name"
  chmod 600 "$UKU_CONFIG_HOME/profiles/$name"
}
set_active_profile() { mkdir -p "$UKU_CONFIG_HOME"; printf '%s\n' "$1" > "$UKU_CONFIG_HOME/active"; }
clear_env_creds() { unset UKU_API_KEY UKU_COMPANY; }

# enable_curl_spy — put a curl shim first on PATH that records its full argv,
# so a test can prove the API key never appears on a command line (`ps`).
CURL_ARGV_LOG=""
enable_curl_spy() {
  CURL_ARGV_LOG="$CASE_DIR/curl-argv.log"
  : > "$CURL_ARGV_LOG"
  mkdir -p "$CASE_DIR/bin"
  { printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$*" >> %s\n' "$CURL_ARGV_LOG"
    printf 'exec %s "$@"\n' "$REAL_CURL"
  } > "$CASE_DIR/bin/curl"
  chmod +x "$CASE_DIR/bin/curl"
  export PATH="$CASE_DIR/bin:$PATH"
}

# ── the guard ────────────────────────────────────────────────────────
# Nothing runs unless the base URL is a loopback address. An unset or a
# non-loopback UKU_BASE_URL aborts the whole case, loudly.
_guard_base() {
  local base="${UKU_BASE_URL:-}"
  if [ -z "$base" ]; then
    printf 'Bail out! UKU_BASE_URL is unset — refusing to run (a test must never touch the real API)\n'
    exit 99
  fi
  case "$base" in
    http://127.0.0.1:*|http://127.0.0.1/*|http://127.0.0.1) : ;;
    *)
      printf 'Bail out! UKU_BASE_URL=%s is not 127.0.0.1 — refusing to run\n' "$base"
      exit 99 ;;
  esac
}

# ── running the CLI ──────────────────────────────────────────────────
# uku … — run bin/uku with the hermetic env; stdout/stderr/exit land in
# $OUT, $ERR, $STATUS. Never inherits a TTY (stdout is a file), which is what
# makes the "no --yes, no TTY" refusal testable.
uku() {
  _guard_base
  local extra_base=""
  # A --base on the command line is allowed only if it is also loopback.
  local a
  for a in "$@"; do
    case "$a" in
      http://127.0.0.1*|https://127.0.0.1*) : ;;
      http://*|https://*)
        printf 'Bail out! a test passed a non-loopback URL (%s)\n' "$a"; exit 99 ;;
    esac
  done
  : > "$OUT_FILE"; : > "$ERR_FILE"
  "$UKU_BIN" "$@" > "$OUT_FILE" 2> "$ERR_FILE" < /dev/null
  STATUS=$?
  OUT="$(cat "$OUT_FILE")"
  ERR="$(cat "$ERR_FILE")"
  return 0
}

# uku_stdin — same, but feeds stdin from the given file (for --data @- / --batch @-)
uku_stdin() {
  local infile="$1"; shift
  _guard_base
  : > "$OUT_FILE"; : > "$ERR_FILE"
  "$UKU_BIN" "$@" > "$OUT_FILE" 2> "$ERR_FILE" < "$infile"
  STATUS=$?
  OUT="$(cat "$OUT_FILE")"
  ERR="$(cat "$ERR_FILE")"
  return 0
}

# ── request-log helpers ──────────────────────────────────────────────
request_count() { "$PYTHON_BIN" "$REQLOG_PY" count "$REQ_LOG" 2>/dev/null || printf '0'; }
request_field() { "$PYTHON_BIN" "$REQLOG_PY" get "$REQ_LOG" "$1" "$2" 2>/dev/null; }
reset_requests() { : > "$REQ_LOG"; }

# ── assertions ───────────────────────────────────────────────────────
assert_status() { # N [name]
  local want="$1" name="${2:-exit status is $1}"
  if [ "${STATUS:-}" = "$want" ]; then _tap_ok "$name"
  else _tap_fail "$name" "expected exit status $want, got ${STATUS:-none}
$(_diag)"; fi
}

assert_out_contains() { # SUBSTRING [name]
  local want="$1" name="${2:-stdout contains \"$1\"}"
  case "$OUT" in
    *"$want"*) _tap_ok "$name" ;;
    *) _tap_fail "$name" "stdout does not contain: $want
$(_diag)" ;;
  esac
}

assert_out_not_contains() { # SUBSTRING [name]
  local want="$1" name="${2:-stdout does not contain \"$1\"}"
  case "$OUT" in
    *"$want"*) _tap_fail "$name" "stdout unexpectedly contains: $want
$(_diag)" ;;
    *) _tap_ok "$name" ;;
  esac
}

assert_err_contains() { # SUBSTRING [name]
  local want="$1" name="${2:-stderr contains \"$1\"}"
  case "$ERR" in
    *"$want"*) _tap_ok "$name" ;;
    *) _tap_fail "$name" "stderr does not contain: $want
$(_diag)" ;;
  esac
}

assert_err_not_contains() { # SUBSTRING [name]
  local want="$1" name="${2:-stderr does not contain \"$1\"}"
  case "$ERR" in
    *"$want"*) _tap_fail "$name" "stderr unexpectedly contains: $want
$(_diag)" ;;
    *) _tap_ok "$name" ;;
  esac
}

assert_err_empty() { # [name]
  local name="${1:-stderr is empty}"
  if [ -z "$ERR" ]; then _tap_ok "$name"
  else _tap_fail "$name" "stderr is not empty:
$ERR"; fi
}

assert_request_count() { # N [name]
  local want="$1" name="${2:-exactly $1 request(s) reached the server}"
  local got; got="$(request_count)"
  if [ "$got" = "$want" ]; then _tap_ok "$name"
  else _tap_fail "$name" "expected $want request(s), server saw $got
$(_diag)"; fi
}

assert_no_requests() { # [name]
  local name="${1:-nothing was sent}"
  local got; got="$(request_count)"
  if [ "$got" = "0" ]; then _tap_ok "$name"
  else _tap_fail "$name" "expected NO requests, server saw $got
$(_diag)"; fi
}

assert_request() { # N FIELD VALUE [name]
  local idx="$1" field="$2" want="$3" name="${4:-request #$1 $2 = $3}"
  local got; got="$(request_field "$idx" "$field")"
  if [ "$got" = "$want" ]; then _tap_ok "$name"
  else _tap_fail "$name" "request #$idx $field
  expected: $want
  actual:   $got
$(_diag)"; fi
}

assert_request_contains() { # N FIELD SUBSTRING [name]
  local idx="$1" field="$2" want="$3" name="${4:-request #$1 $2 contains $3}"
  local got; got="$(request_field "$idx" "$field")"
  case "$got" in
    *"$want"*) _tap_ok "$name" ;;
    *) _tap_fail "$name" "request #$idx $field
  expected to contain: $want
  actual:              $got
$(_diag)" ;;
  esac
}

assert_request_empty() { # N FIELD [name]
  local idx="$1" field="$2" name="${3:-request #$1 has no $2}"
  local got; got="$(request_field "$idx" "$field")"
  if [ -z "$got" ]; then _tap_ok "$name"
  else _tap_fail "$name" "request #$idx $field should be absent, got: $got
$(_diag)"; fi
}

assert_file_exists() { # PATH [name]
  local p="$1" name="${2:-file exists: $1}"
  if [ -e "$p" ]; then _tap_ok "$name"; else _tap_fail "$name" "missing file: $p"; fi
}

assert_equals() { # ACTUAL EXPECTED name
  local got="$1" want="$2" name="$3"
  if [ "$got" = "$want" ]; then _tap_ok "$name"
  else _tap_fail "$name" "expected: $want
  actual:   $got
$(_diag)"; fi
}

# assert_true CMD… — generic escape hatch; the name is the first argument.
assert_true() { # NAME CMD…
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then _tap_ok "$name"
  else _tap_fail "$name" "command failed: $*
$(_diag)"; fi
}

# note — a TAP comment (context, not a result).
note() { printf '# %s\n' "$1"; }
