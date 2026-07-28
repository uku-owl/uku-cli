#!/usr/bin/env bash
# check-surface.sh — the committed surface must match the declared one.
#
#   scripts/check-surface.sh            check (exit 1 on any difference)
#   scripts/check-surface.sh --update   accept ADDITIONS and rewrite .surface
#
# The rule is asymmetric on purpose:
#   * a NEW fact is cheap but never accidental — it lands only when a human or
#     an agent runs --update, so the diff of .surface is the review of the
#     surface we just promised to keep.
#   * a VANISHED fact is a compatibility break. It fails unconditionally until
#     the exact line is written into .surface-breaking, which is therefore the
#     changelog of everything we have ever taken away.
#   * a .surface-breaking entry only counts while the line is genuinely gone.
#     Listing a line that still exists would pre-authorise its removal, so that
#     is itself an error — the acknowledgement has to be written at the moment
#     of the break, not before it.
#
# bash 3.2 compatible; needs nothing but bash + coreutils.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UKU="$ROOT/bin/uku"
SURFACE="$ROOT/.surface"
BREAKING="$ROOT/.surface-breaking"

UPDATE=0
case "${1:-}" in
  ""|--check) : ;;
  -u|--update) UPDATE=1 ;;
  *) printf 'usage: %s [--update]\n' "$0" >&2; exit 2 ;;
esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/uku-surface-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

"$UKU" --dump-surface > "$TMP/new" || { printf 'uku --dump-surface failed\n' >&2; exit 2; }

if [ ! -f "$SURFACE" ]; then
  if [ "$UPDATE" = "1" ]; then
    cp "$TMP/new" "$SURFACE"
    printf 'surface: created %s (%s facts)\n' ".surface" "$(wc -l < "$SURFACE" | tr -d ' ')"
    exit 0
  fi
  printf 'surface: .surface is missing. Create it: scripts/check-surface.sh --update\n' >&2
  exit 1
fi

LC_ALL=C sort -u "$SURFACE" > "$TMP/old"
# .surface-breaking: one removed surface line per row; # comments and blanks ignored.
: > "$TMP/breaking"
[ -f "$BREAKING" ] && grep -v '^[[:space:]]*#' "$BREAKING" 2>/dev/null | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u > "$TMP/breaking" || true

LC_ALL=C comm -13 "$TMP/old" "$TMP/new" > "$TMP/added"
LC_ALL=C comm -23 "$TMP/old" "$TMP/new" > "$TMP/removed"
# an acknowledgement is stale when the line it excuses is still in the surface
LC_ALL=C comm -12 "$TMP/breaking" "$TMP/new" > "$TMP/stale"
# a removal is acknowledged when .surface-breaking names it
LC_ALL=C comm -12 "$TMP/breaking" "$TMP/removed" > "$TMP/ack"
LC_ALL=C comm -23 "$TMP/removed" "$TMP/breaking" > "$TMP/unack"

n_added="$(wc -l < "$TMP/added" | tr -d ' ')"
n_unack="$(wc -l < "$TMP/unack" | tr -d ' ')"
n_ack="$(wc -l < "$TMP/ack" | tr -d ' ')"
n_stale="$(wc -l < "$TMP/stale" | tr -d ' ')"
fail=0

if [ "$n_stale" != "0" ]; then
  printf '\n  STALE ACKNOWLEDGEMENT — %s line(s) in .surface-breaking still exist:\n' "$n_stale" >&2
  sed 's/^/    + /' "$TMP/stale" >&2
  printf '  .surface-breaking records what has ALREADY been removed. A line that\n' >&2
  printf '  still exists would pre-authorise its own removal.\n' >&2
  printf '  Fix: delete those rows from .surface-breaking.\n' >&2
  fail=1
fi

if [ "$n_unack" != "0" ]; then
  printf '\n  REMOVED SURFACE — %s fact(s) the CLI no longer has:\n' "$n_unack" >&2
  sed 's/^/    - /' "$TMP/unack" >&2
  printf '  Every one of these is a compatibility break for someone scripting uku.\n' >&2
  printf '  Fix: put it back in the table in bin/uku, or — if the break is\n' >&2
  printf '  deliberate — append the exact line(s) to .surface-breaking with a\n' >&2
  printf '  dated # comment saying why, then re-run with --update.\n' >&2
  fail=1
fi

if [ "$n_added" != "0" ] && [ "$UPDATE" != "1" ]; then
  printf '\n  NEW SURFACE — %s fact(s) not in .surface:\n' "$n_added" >&2
  sed 's/^/    + /' "$TMP/added" >&2
  printf '  New surface is cheap, but never accidental.\n' >&2
  printf '  Fix: scripts/check-surface.sh --update, then commit .surface with the change.\n' >&2
  fail=1
fi

[ "$fail" = "0" ] || exit 1

if [ "$UPDATE" = "1" ]; then
  cp "$TMP/new" "$SURFACE"
  printf 'surface: updated .surface (+%s, -%s acknowledged, %s facts total)\n' \
    "$n_added" "$n_ack" "$(wc -l < "$SURFACE" | tr -d ' ')"
  exit 0
fi

printf 'surface: %s facts, unchanged.\n' "$(wc -l < "$TMP/new" | tr -d ' ')"
[ "$n_ack" = "0" ] || printf 'surface: %s removal(s) acknowledged in .surface-breaking.\n' "$n_ack"
exit 0
