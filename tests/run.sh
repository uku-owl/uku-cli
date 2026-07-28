#!/usr/bin/env bash
# tests/run.sh — the single command a developer or an agent runs.
#
#   tests/run.sh                 run every tests/cases/*.sh
#   tests/run.sh exit-codes      run one case (with or without the .sh)
#
# Exits non-zero if anything failed. bash 3.2 compatible.

# ─────────────────────────────────────────────────────────────────────
# KNOWN ISSUES in bin/uku that this suite PINS rather than fixes.
# Each one has a test whose name ends "— KNOWN ISSUE #n". The tests assert what
# the CLI does TODAY, so a refactor has to change each behaviour on purpose.
# bin/uku itself is not modified by anything in tests/.
#
#  #1  --batch --resume cannot resume a line that failed with an API error.
#      _ledger_state (bin/uku:965-975) inspects only `ok` and `send` rows, never
#      `fail`, so a definitively-rejected line (422/500/412) reads back as
#      UNKNOWN_OUTCOME and is REFUSED. The run's own summary tells the user to
#      --resume; doing so re-sends nothing and exits 3. `uku help batch` says
#      "--resume is safe and is the correct response to any interrupted batch".
#      → tests/cases/batch.sh §2b                                       [HIGH]
#
#  #2  --dry-run on a SINGLE write is refused without --yes (exit 4), because
#      confirm_write (bin/uku:589) runs before do_request's dry-run printer
#      (bin/uku:420). run_batch (bin/uku:1082) deliberately skips the confirm
#      under --dry-run, so a batch dry-run needs no --yes. Inconsistent.
#      → tests/cases/dry-run.sh, tests/cases/batch.sh §6                 [MED]
#
#  #3  A rate-limited or failing READ is sent THREE times by curl before the
#      CLI's own logic sees it: bin/uku:413 adds `--retry 2` to GET/HEAD, and
#      curl retries 408/429/5xx itself. Measured: GET→500 = 3 requests;
#      GET→429×3 then 200 = 4 requests; GET→429 then 200 = 2 requests (curl's
#      retry got the 200, the CLI never saw a 429). The documented "the CLI
#      already waits once for you" is preceded by two immediate retries.
#      → tests/cases/retry-429.sh §1, §4                                 [MED]
#
#  #4  --fields is parsed and then discarded whenever stdout is not a TTY
#      (bin/uku:480-484 falls back to render()). Since --json is the non-TTY
#      default, --fields is effectively TTY-only, and is accepted silently.
#      → tests/cases/output-modes.sh                                     [LOW]
#
#  #5  `uku auth login` ignores --base AND UKU_BASE_URL and always validates
#      against, and stores, https://app.getuku.com. The global pre-parse
#      (bin/uku:2025) eats --base before cmd_auth sees it — its own --base case
#      (bin/uku:646) is dead code — and login never calls load_creds
#      (bin/uku:672). Signing in against staging/self-hosted is impossible, and
#      `--base http://localhost:…` silently sends the key to production. This is
#      why the harness writes profile files directly instead of using login.
#      → tests/cases/accounts.sh (only login's pre-request refusal is tested)
#                                                                        [HIGH]
#
#  #6  `--account X` ignores UKU_BASE_URL. load_creds' --account branch
#      (bin/uku:123-130) reads UKU_BASE from the profile only; the env branch and
#      the active-profile branch both honour it. --base still wins over all three.
#      → tests/cases/accounts.sh                                         [LOW]
#
#  #7  Removing the LAST account succeeds but exits 1. _reassign_active
#      (bin/uku:178) runs `next="$(list_profiles | head -n1)"`; with an empty
#      profiles dir list_profiles (bin/uku:183) returns 1, and `set -euo
#      pipefail` aborts the script — after "✓ Removed account 'x'." was printed.
#      Same for `uku auth logout` on the last profile. Exit 1 means "usage error"
#      in this CLI's own contract.
#      → tests/cases/accounts.sh                                         [MED]
#
#  #8  `uku doctor` (text mode) prints its heading to stdout and every check
#      line to stderr (bin/uku:1523-1533), so `uku doctor > report.txt` captures
#      the heading alone. --json puts the whole report on stdout.
#      → tests/cases/doctor.sh §5                                        [LOW]
#
#  #9  A 428 on a COLLECTION POST is never healed: _etag_candidates
#      (bin/uku:347) only proposes path segments that look like an id, so
#      `POST /api/v3/tasks` yields no candidates and exits 3. Healing does work
#      for PATCH /contracts/{id} and for POST /contracts/{id}/rows (walking up to
#      the parent) — both verified. The README, `uku help` and the embedded agent
#      skill all promise the heal without this caveat.
#      → tests/cases/retry-428.sh §4, §5                            [LOW/docs]
# ─────────────────────────────────────────────────────────────────────

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CASES_DIR="$TESTS_DIR/cases"

if [ ! -x "$TESTS_DIR/../bin/uku" ]; then
  printf 'bin/uku is missing or not executable\n' >&2
  exit 2
fi

# refuse to run against anything but the fixture server
if [ -n "${UKU_BASE_URL:-}" ]; then
  case "$UKU_BASE_URL" in
    http://127.0.0.1*) : ;;
    *) printf 'refusing to run: UKU_BASE_URL=%s is not 127.0.0.1\n' "$UKU_BASE_URL" >&2; exit 99 ;;
  esac
fi

files=""
if [ "$#" -gt 0 ]; then
  for arg in "$@"; do
    f="$CASES_DIR/$arg"
    [ -f "$f" ] || f="$CASES_DIR/$arg.sh"
    if [ ! -f "$f" ]; then
      printf 'no such case: %s\n' "$arg" >&2
      printf 'available:\n' >&2
      for c in "$CASES_DIR"/*.sh; do printf '  %s\n' "$(basename "$c" .sh)" >&2; done
      exit 2
    fi
    files="$files $f"
  done
else
  for f in "$CASES_DIR"/*.sh; do [ -f "$f" ] && files="$files $f"; done
fi

total_ok=0
total_not_ok=0
failed_cases=""
started="$(date +%s)"

for f in $files; do
  name="$(basename "$f" .sh)"
  printf '\n\033[1m# %s\033[0m\n' "$name"
  out="$(bash "$f" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  n_ok="$(printf '%s\n' "$out" | grep -c '^ok ' || true)"
  n_bad="$(printf '%s\n' "$out" | grep -c '^not ok ' || true)"
  n_ok="$(printf '%s' "$n_ok" | tr -d '[:space:]')"
  n_bad="$(printf '%s' "$n_bad" | tr -d '[:space:]')"
  total_ok=$((total_ok + n_ok))
  total_not_ok=$((total_not_ok + n_bad))
  if [ "$rc" -ne 0 ] || [ "$n_bad" -gt 0 ]; then
    failed_cases="$failed_cases $name"
    if [ "$n_bad" -eq 0 ]; then
      # a case that died before finishing (bail out, syntax error, …)
      total_not_ok=$((total_not_ok + 1))
      printf '# %s exited %d without reporting a failure\n' "$name" "$rc"
    fi
  fi
done

elapsed=$(( $(date +%s) - started ))
printf '\n────────────────────────────────────────────────\n'
printf 'uku CLI test suite — %d passed, %d failed  (%d total, %ds)\n' \
  "$total_ok" "$total_not_ok" "$((total_ok + total_not_ok))" "$elapsed"
if [ -n "$failed_cases" ]; then
  printf 'FAILED cases:%s\n' "$failed_cases"
  printf '────────────────────────────────────────────────\n'
  exit 1
fi
printf 'All green.\n'
printf '────────────────────────────────────────────────\n'
exit 0
