#!/usr/bin/env bash
# tests/run.sh — the single command a developer or an agent runs.
#
#   tests/run.sh                 run every tests/cases/*.sh
#   tests/run.sh exit-codes      run one case (with or without the .sh)
#
# Cases run in parallel (see § concurrency below); output is buffered per case
# and printed in the order the cases were named, so the transcript is identical
# whatever the job count. Two knobs:
#
#   UKU_TEST_JOBS=1              serial, same code path — for a clean bisect
#   UKU_TEST_KEEP=1              keep each case's raw stdout/stderr on disk
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
run_all=0
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
  run_all=1
  for f in "$CASES_DIR"/*.sh; do [ -f "$f" ] && files="$files $f"; done
fi

total_ok=0
total_not_ok=0
failed_cases=""
started="$(date +%s)"

# ── concurrency ──────────────────────────────────────────────────────
# Safe because setup_case already gives every case its own temp dir, HOME,
# config home and ephemeral server port. UKU_TEST_JOBS=1 is serial, same path.
jobs_n="${UKU_TEST_JOBS:-}"
if [ -z "$jobs_n" ]; then
  jobs_n="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || printf 2)"
  [ "$jobs_n" -gt 8 ] 2>/dev/null && jobs_n=8   # past ~8 it stops helping
fi
case "$jobs_n" in ''|*[!0-9]*) jobs_n=2 ;; esac
[ "$jobs_n" -lt 1 ] && jobs_n=1

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/uku-run-XXXXXX")"
if [ "${UKU_TEST_KEEP:-0}" = "1" ]; then
  printf 'keeping per-case output in %s\n' "$RUN_DIR"
else
  trap 'rm -rf "$RUN_DIR"' EXIT
fi

# ── op coverage (Phase 3) ────────────────────────────────────────────
# Every request the CLI puts on the wire during the suite is appended here by
# tests/server.py, normalised to METHOD /api/v3/<path with ids as {id}>. After
# the cases finish, that OBSERVED set is compared against the `op` facts the
# CLI declares in its surface table.
#
# This is the executed half of the drift gate, and it is the half that matters:
# the declared list is hand-maintained, so on its own it is a third source of
# truth that can quietly omit an operation the CLI genuinely calls. Comparing
# it to what actually went over a socket is the same insurance check 3c in
# check-drift.sh buys by running every declared command against the real
# dispatcher, rather than trusting a parse.
#
# Only run for a FULL suite: a single-case run sees a fraction of the traffic
# and would report every other operation as unobserved.
#
# Each case gets its OWN oplog file, merged after the run. One shared file
# appended to by N concurrent fixture servers would work in practice — the
# lines are short and opened O_APPEND — but "in practice" is not a property
# worth resting a gate on when a per-case file costs nothing.
OPLOG_MERGED=""
[ "$run_all" = "1" ] && OPLOG_MERGED="$RUN_DIR/oplog-merged"

# ── launch ───────────────────────────────────────────────────────────
# Throttled by counting the rc.* files the finished cases leave behind, not by
# `jobs -r` or `kill -0`: a child that has exited but not been reaped is still
# a live process to `kill -0`, so it would over-count and stall the run. The rc
# file is written as the case's last act, which makes it an unambiguous
# "finished" marker.
_completed() {
  local n=0 rcf
  for rcf in "$RUN_DIR"/rc.*; do [ -f "$rcf" ] && n=$((n + 1)); done
  printf '%s' "$n"
}

# set -m is load-bearing: without job control, bash sets SIGINT to IGNORED in
# background commands, and SIG_IGN survives exec — so no-residue.sh's Ctrl-C
# test would signal a deaf CLI and pass nothing. Found the hard way.
set -m

# Indexed, not keyed by name, so `tests/run.sh smoke smoke` can't self-overwrite.
launched=0
for f in $files; do
  name="$(basename "$f" .sh)"
  launched=$((launched + 1))
  slot="$(printf '%03d-%s' "$launched" "$name")"
  while [ "$((launched - 1 - $(_completed)))" -ge "$jobs_n" ]; do sleep 0.05; done
  (
    [ -n "$OPLOG_MERGED" ] && export UKU_OPLOG="$RUN_DIR/oplog.$slot"
    bash "$f" > "$RUN_DIR/out.$slot" 2>&1
    printf '%s\n' "$?" > "$RUN_DIR/rc.$slot"
  ) &
done
wait

# ── collect, in the order the cases were named ───────────────────────
collected=0
idx=0
for f in $files; do
  name="$(basename "$f" .sh)"
  idx=$((idx + 1))
  slot="$(printf '%03d-%s' "$idx" "$name")"
  printf '\n\033[1m# %s\033[0m\n' "$name"

  # A case whose result never landed is a LOST case, and a parallel runner that
  # loses work while reporting green is strictly worse than a slow serial one.
  # Counted here and hard-failed below, not just noted.
  if [ ! -f "$RUN_DIR/rc.$slot" ]; then
    printf '# %s produced no result at all — the runner lost it\n' "$name"
    total_not_ok=$((total_not_ok + 1))
    failed_cases="$failed_cases $name"
    continue
  fi
  collected=$((collected + 1))

  out="$(cat "$RUN_DIR/out.$slot")"
  rc="$(tr -d '[:space:]' < "$RUN_DIR/rc.$slot")"
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

[ -n "$OPLOG_MERGED" ] && cat "$RUN_DIR"/oplog.* > "$OPLOG_MERGED" 2>/dev/null

elapsed=$(( $(date +%s) - started ))
printf '\n────────────────────────────────────────────────\n'
printf 'uku CLI test suite — %d passed, %d failed  (%d total, %ds, %d job(s))\n' \
  "$total_ok" "$total_not_ok" "$((total_ok + total_not_ok))" "$elapsed" "$jobs_n"

# count-in == count-out. Deliberately its own verdict, checked before the
# pass/fail totals are believed: if the runner launched more cases than it
# collected results for, then "0 failed" is a statement about the cases that
# happened to come back, and means nothing.
if [ "$collected" -ne "$launched" ]; then
  printf 'RUNNER FAULT — launched %d case(s), collected %d result(s).\n' "$launched" "$collected"
  printf 'A missing result is not a pass. Re-run with UKU_TEST_JOBS=1 UKU_TEST_KEEP=1.\n'
  printf '────────────────────────────────────────────────\n'
  exit 1
fi
if [ -n "$failed_cases" ]; then
  printf 'FAILED cases:%s\n' "$failed_cases"
  printf '────────────────────────────────────────────────\n'
  exit 1
fi
# ── op coverage verdict ──────────────────────────────────────────────
if [ -n "$OPLOG_MERGED" ] && [ -s "$OPLOG_MERGED" ]; then
  observed="$(LC_ALL=C sort -u "$OPLOG_MERGED")"
  declared="$("$TESTS_DIR/../bin/uku" --dump-surface | sed -n 's/^op //p' | LC_ALL=C sort -u)"
  undeclared="$(printf '%s\n' "$observed" | LC_ALL=C comm -23 - <(printf '%s\n' "$declared"))"
  if [ -n "$undeclared" ]; then
    printf '\n\033[31mOP DRIFT\033[0m — the CLI called operations it does not declare:\n'
    printf '%s\n' "$undeclared" | sed 's/^/    /'
    printf '  Every API operation this CLI uses must be an `op` fact, so that\n'
    printf '  scripts/check-api.sh can refuse to ship one production does not serve.\n'
    printf '  Add it to the surface table in bin/uku, then: scripts/check-surface.sh --update\n'
    printf '────────────────────────────────────────────────\n'
    exit 1
  fi
  printf 'op coverage: %d observed, all declared.\n' "$(printf '%s\n' "$observed" | grep -c .)"
fi

printf 'All green.\n'
printf '────────────────────────────────────────────────\n'
exit 0
