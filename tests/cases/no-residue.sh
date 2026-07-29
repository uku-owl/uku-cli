#!/usr/bin/env bash
# no-residue — the dimension the other 929 tests do not have.
#
# Every other case in this suite asks "what request went out". None of them
# looks at the FILESYSTEM afterwards, which is why the temp-file sweep could be
# a complete no-op for the whole life of this CLI without a single test going
# red. It was: _mktemp appended to UKU_TMPFILES from inside `$(…)`, a subshell,
# so the parent's list stayed empty and the EXIT/INT/TERM/HUP traps deleted
# nothing. Measured 2026-07-29 — a network error left the 0600 curl config
# holding `header = "X-API-Key: uku_live_…"`, and --dry-run left that PLUS the
# request body with the client's data in it. macOS only clears /var/folders on
# reboot.
#
# So this case asserts on residue, not on requests: after every non-happy exit
# path, $TMPDIR must be empty and no file under $TMPDIR, $HOME or the config
# home may contain the key or the body.
#
# One thing to know about $TMPDIR here: macOS's mktemp IGNORES it (a bare
# `mktemp` writes to /var/folders no matter what), so the CLI names an explicit
# template under "${TMPDIR:-/tmp}". Without that, this case would be scanning a
# directory the leak never reached and would pass on broken code. Verified by
# deleting the rm -rf from _cleanup and watching every assertion below go red.
. "$(dirname "$0")/../lib/harness.sh"

# ── residue assertions ───────────────────────────────────────────────
# $TMPDIR is this case's alone — the harness keeps its own scratch (the request
# log, the captured stdout/stderr, the server script) in $CASE_DIR, one level
# up — so "empty" is the honest bar, not an approximation of one.
assert_tmpdir_empty() { # [name]
  local name="${1:-\$TMPDIR is empty}" left
  left="$(ls -A "$TMPDIR" 2>/dev/null)"
  if [ -z "$left" ]; then _tap_ok "$name"
  else _tap_fail "$name" "files left behind in $TMPDIR:
$(ls -la "$TMPDIR" 2>/dev/null)
$(grep -rl . "$TMPDIR" 2>/dev/null | while IFS= read -r f; do printf -- '--- %s\n' "$f"; head -c 400 "$f"; printf '\n'; done)"; fi
}

# assert_no_file_contains NEEDLE NAME — nowhere the CLI can write may hold it.
#
# $HARNESS_TMPDIR — the SYSTEM temp dir — is in the list, and it is the whole
# reason this case can fail at all. macOS's mktemp ignores $TMPDIR when it is
# given no template: the leaking version of this CLI called a bare `mktemp`,
# so its key config landed in /var/folders, a directory this case does not
# own and would never have looked in. Written without this line, every
# assertion below passed against the broken binary. Only files created since
# the case started are considered, so a neighbouring process's temp file
# cannot turn this red — and a needle is a unique test string besides.
assert_no_file_contains() { # NEEDLE NAME
  local needle="$1" name="$2" hits d newf
  hits=""
  for d in "$TMPDIR" "$HOME" "$UKU_CONFIG_HOME"; do
    [ -d "$d" ] || continue
    hits="$hits$(grep -rl -F -- "$needle" "$d" 2>/dev/null || true)"$'\n'
  done
  newf="$(find "$HARNESS_TMPDIR" -maxdepth 1 -type f -newer "$CASE_DIR/.epoch" 2>/dev/null || true)"
  if [ -n "$newf" ]; then
    hits="$hits$(printf '%s\n' "$newf" | tr '\n' '\0' | xargs -0 grep -l -F -- "$needle" 2>/dev/null || true)"$'\n'
  fi
  hits="$(printf '%s' "$hits" | grep -v '^$' || true)"
  if [ -z "$hits" ]; then _tap_ok "$name"
  else _tap_fail "$name" "these files contain it:
$hits"; fi
}

setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET",  "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "GET",  "path": "/api/v3/tasks",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} },
    { "method": "POST", "path": "/api/v3/tasks",
      "response": {"status": 201, "body": {"data": {"id": 1}}} },
    { "method": "GET",  "path": "/slow",
      "response": {"status": 200, "delay": 3, "body": {"data": []}} }
  ]
}
JSON
start_server

# the mtime every "was this file created during this case" question is asked
# against (see assert_no_file_contains)
touch "$CASE_DIR/.epoch"

PII='Kliendi Nimi OU reg 12345678'

# ── 0 the happy path is the control ──────────────────────────────────
uku clients list
assert_status 0 'a successful read exits 0'
assert_tmpdir_empty 'a successful read leaves nothing behind'
assert_no_file_contains "$TEST_API_KEY" 'and the key is on no file anywhere'

# ── 1 network error ──────────────────────────────────────────────────
# Port 1 on loopback: nothing listens, curl exits 7, the CLI dies with EX_NET
# and never reaches its explicit _rmtmp. This is where the live key used to be
# left behind in a 0600 file — the single worst instance of the bug.
uku --base http://127.0.0.1:1 clients list
assert_status 5 'an unreachable base exits 5'
assert_err_contains 'network error' 'and says so'
assert_tmpdir_empty 'a network error leaves nothing behind'
assert_no_file_contains "$TEST_API_KEY" 'the key config file is gone, not orphaned'

# ── 2 --dry-run ──────────────────────────────────────────────────────
# The command an agent runs before every write. It exits from the MIDDLE of
# do_request, after the -K config and the body file are both written — so it
# used to leave the key AND the client's data on disk, every single time.
uku tasks create --data "{\"title\":\"$PII\"}" --yes --dry-run
assert_status 0 '--dry-run exits 0'
assert_tmpdir_empty '--dry-run leaves nothing behind'
assert_no_file_contains "$TEST_API_KEY" 'no key config survives a dry run'
assert_no_file_contains "$PII" 'and neither does the request body'

# ── 3 SIGINT in the middle of a request ──────────────────────────────
# Ctrl-C is the path SECURITY.md names by name, so it is simulated faithfully:
# a real Ctrl-C goes to the whole foreground PROCESS GROUP, hitting curl as
# well as the shell. Signalling the shell alone proves nothing — bash defers a
# trapped signal until the running command returns and then, if that command
# did not itself die of it, drops it: the run finishes with exit 0 and the trap
# never fires. Measured while writing this case. Hence python: it is the only
# thing on the box that can put the CLI in its own session and killpg it.
: > "$OUT_FILE"; : > "$ERR_FILE"
STATUS="$("$PYTHON_BIN" - "$UKU_BIN" "$OUT_FILE" "$ERR_FILE" <<'PY'
import os, signal, subprocess, sys, time
binp, outp, errp = sys.argv[1], sys.argv[2], sys.argv[3]
with open(outp, "w") as o, open(errp, "w") as e:
    p = subprocess.Popen([binp, "api", "GET", "/slow"], stdout=o, stderr=e,
                         stdin=subprocess.DEVNULL, start_new_session=True)
    time.sleep(1.0)
    os.killpg(os.getpgid(p.pid), signal.SIGINT)
    rc = p.wait()
print(128 - rc if rc < 0 else rc)
PY
)"
OUT="$(cat "$OUT_FILE")"; ERR="$(cat "$ERR_FILE")"
assert_status 130 'Ctrl-C mid-request really stops (128+SIGINT), it is not swallowed'
assert_tmpdir_empty 'and it sweeps its temp files on the way out'
assert_no_file_contains "$TEST_API_KEY" 'the key is not left in $TMPDIR by an interrupt'

# ── 4 the rate-limit refusal ─────────────────────────────────────────
# A batch whose write budget is already spent stops before line 1 — but the
# batch input file, 0600 and holding every client row of the run, was
# materialised before the loop started (it has to be: @- must be drained
# first). It stayed there. The single-write _pace_write refusal named in the
# audit is NOT a leak by comparison — it happens above the first _mktemp in
# do_request — so the batch is the case worth pinning.
reset_requests
printf '{"title":"%s"}\n' "$PII" > "$CASE_DIR/lines.jsonl"
printf 'limit=10\nremaining=0\nreset=%s\ntier=write\n' "$(( $(date +%s) + 9999 ))" \
  > "$UKU_CONFIG_HOME/ratelimit-env-write"
uku tasks create --batch @"$CASE_DIR/lines.jsonl" --yes
assert_status 5 'a spent write budget refuses rather than blocks'
assert_err_contains 'write rate limit spent' 'and says why'
assert_no_requests 'nothing was sent'
assert_tmpdir_empty 'the refusal leaves no batch input behind'
assert_no_file_contains "$TEST_API_KEY" 'no key config either'
rm -f "$UKU_CONFIG_HOME/ratelimit-env-write"

# ── 5 an API error status ────────────────────────────────────────────
# A 4xx is an ordinary reply, so do_request does reach _rmtmp — this is the one
# failure path that was always clean. Pinned so it stays that way.
reset_requests
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 403, "body": {"error": {"message": "nope"}}} }
  ]
}
JSON
stop_server
start_server
uku clients list
assert_status 2 'a 403 exits 2 (auth), the one failure path that was always clean'
assert_tmpdir_empty 'and leaves nothing behind'
assert_no_file_contains "$TEST_API_KEY" 'no key on disk after an API error'

finish
