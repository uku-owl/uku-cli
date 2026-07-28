#!/usr/bin/env bash
# tests/run.sh — the single command a developer or an agent runs.
#
#   tests/run.sh                 run every tests/cases/*.sh
#   tests/run.sh exit-codes      run one case (with or without the .sh)
#
# Exits non-zero if anything failed. bash 3.2 compatible.

# ─────────────────────────────────────────────────────────────────────
# The nine issues this suite once PINNED are now FIXED in bin/uku, and each
# test asserts the corrected behaviour instead. Kept as a map of what changed
# and where the guard against a regression lives.
#
#  #1  --batch --resume can resume a line the server REFUSED. _ledger_state
#      reads `fail` rows carrying an HTTP status as FAILED — a reply arrived and
#      it was not a success, so nothing was created and plain --resume re-sends
#      it, which is what the run's own summary tells the user to do. Only a
#      `send` with no observed outcome is UNKNOWN and stays behind
#      --retry-unknown; a `fail` row carrying a WORD (UNKNOWN_OUTCOME,
#      GUARD_REFUSED) is a local refusal and decides nothing. A v0.3.0 ledger
#      with no fail row still reads send-without-ok as UNKNOWN.
#      → tests/cases/batch.sh §2b (re-send) and §3 (still-unknown, back-compat)
#
#  #2  --dry-run needs no --yes on a single write: confirm_write returns early
#      under UKU_DRY, matching run_batch. A dry run sends nothing, so there is
#      nothing to confirm; a real write without --yes is still exit 4.
#      → tests/cases/dry-run.sh, tests/cases/write-safety.sh
#
#  #3  curl's `--retry` is gone. An HTTP status is never re-sent automatically,
#      so a rate-limited read reaches the CLI's own "wait for X-RateLimit-Reset,
#      retry once" path on the FIRST 429. Reads keep a transport-only retry:
#      once, on curl exit 6/7/28/35/52/56 (never connected / never completed),
#      and never for a write.
#      → tests/cases/retry-429.sh §1, §1b, §4, §5
#
#  #4  --fields works in JSON too — each row in .data is reduced to the named
#      keys, in the order named, envelope untouched. Missing keys come back
#      null so every row keeps one shape. Without jq it warns rather than
#      silently ignoring the flag.
#      → tests/cases/output-modes.sh
#
#  #5  `uku auth login` honours the base it is told to use: explicit --base
#      (before or after the subcommand) > UKU_BASE_URL > the default. It used to
#      validate against, and store, production regardless — a credential
#      disclosure for anyone pointing the CLI at staging.
#      → tests/cases/accounts.sh (a full hermetic login against the fixture)
#
#  #6  `--account X` resolves its base like every other path: profile base >
#      UKU_BASE_URL > default, with --base winning over all three.
#      → tests/cases/accounts.sh
#
#  #7  Removing (or logging out of) the LAST account exits 0. list_profiles
#      always succeeds — "no accounts" is an answer, not a failure — so
#      _reassign_active no longer trips `set -euo pipefail` after reporting
#      success.
#      → tests/cases/accounts.sh
#
#  #8  `uku doctor` (text mode) writes the WHOLE report to stdout, so
#      `uku doctor > report.txt` captures it. --json was already whole.
#      → tests/cases/doctor.sh §5
#
#  #9  A 428 on a COLLECTION POST still cannot be healed — correctly: every
#      candidate comes from an id in the path, and `POST /api/v3/tasks` has
#      none. The code is unchanged; the README, `uku help` and the embedded
#      agent skill now state the caveat instead of promising the heal.
#      → tests/cases/retry-428.sh §4, §5
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
