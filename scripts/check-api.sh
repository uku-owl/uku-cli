#!/usr/bin/env bash
# check-api.sh — the CLI against the API, instead of against itself.
#
#   scripts/check-api.sh            offline: gate the declared ops (CI, PRs)
#   scripts/check-api.sh --live     also fetch production and report drift
#   scripts/check-api.sh --update   refresh .api-released from production
#
# WHY THIS EXISTS
#
# .surface has ~390 facts and check-surface.sh ratchets every one of them, but
# not one of them used to reference the Uku API. The gate checked the CLI
# against itself. That is exactly how `uku --help` could assert "the API has no
# search endpoint" and stay green while GET /api/v3/search existed.
#
# TWO SOURCES OF TRUTH, AND THE GAP BETWEEN THEM IS THE POINT
#
#   released   what production serves      app.getuku.com/api/v3/openapi.json
#   built      what the backend repo has   uku_service/CLAUDE/api/openapi.json
#
# On 2026-08-03 production served 182 operations and the repo had 217. A CLI
# built against the repo ships commands that 404 for every customer. So the
# gate is against RELEASED, always, and being ahead of it is a failure.
#
# CHECK 1 — the ship gate (offline, runs on every PR)
#   Every `op` fact the CLI declares must exist in .api-released, UNLESS it is
#   acknowledged in .api-pending. Pending ops are built-but-not-deployed: the
#   endpoint exists in ../uku_service and is verifiable against a local server,
#   but production still 404s it. They are allowed in the tree so the work can
#   be written and tested; scripts/release.sh REFUSES while any remain, so they
#   cannot reach a customer. Emptying .api-pending is part of shipping the API
#   release, not an afterthought.
#
# CHECK 2 — coverage drift (needs the network, runs daily)
#   Production vs .api-released. New operations are reported so the CLI can
#   grow into them; disappeared ones fail, because something the CLI may call
#   has gone.
#
# The split keeps PRs deterministic — no network, no flakes — while still
# surfacing an API-side change within a day rather than at the next release.
#
# ⚠ THE SNAPSHOT IS ONLY AS GOOD AS THE JOB THAT REFRESHES IT. The retired
# Python client built this same machinery and its snapshot went 34 operations
# stale, because nothing ran it (reference/python-client/README.md:58). If the
# daily job is not running, this file is a souvenir. Prefer --live in CI over a
# snapshot nobody refreshes.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || { printf 'cannot cd to %s\n' "$ROOT" >&2; exit 1; }

UKU="${UKU_BIN:-$ROOT/bin/uku}"
SNAPSHOT="$ROOT/.api-released"
PENDING="$ROOT/.api-pending"
SPEC_URL="${UKU_SPEC_URL:-https://app.getuku.com/api/v3/openapi.json}"
LIVE=0; UPDATE=0
for a in "$@"; do
  case "$a" in
    --live) LIVE=1 ;;
    --update) UPDATE=1; LIVE=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$a" >&2; exit 2 ;;
  esac
done

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
bold()  { printf '\033[1m%s\033[0m' "$1"; }
dim()   { printf '\033[2m%s\033[0m' "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0

# ── the operations the CLI declares ───────────────────────────────────
# Read by EXECUTING the CLI, like check-surface.sh does, not by parsing it.
"$UKU" --dump-surface | sed -n 's/^op //p' | LC_ALL=C sort -u > "$TMP/declared"
n_declared="$(grep -c . < "$TMP/declared" || true)"
[ "$n_declared" -gt 0 ] || { printf '  %s the CLI declares no op facts at all — has _surface_ops been removed?\n' "$(red '✗')"; exit 1; }

# ── fetch production, if asked ────────────────────────────────────────
# Parameter NAMES are normalised away on both sides: the spec writes
# /tasks/{task_id} and the CLI declares /tasks/{id}, and the name is not part
# of an operation's identity here. Verified on the 2026-08-03 spec that this
# collapses no two distinct operations into one — if it ever does, the count
# printed below drops and that is the signal.
if [ "$LIVE" = "1" ]; then
  printf '  %s %s\n' "$(dim '→')" "fetching $SPEC_URL"
  if ! curl -fsSL --max-time 30 "$SPEC_URL" > "$TMP/spec.json"; then
    printf '  %s could not fetch the released spec — refusing to guess.\n' "$(red '✗')"
    exit 1
  fi
  python3 - "$TMP/spec.json" "$TMP/live" <<'PY' || { printf '  %s could not parse the spec\n' "$(red '✗')"; exit 1; }
import json, re, sys
spec = json.load(open(sys.argv[1]))
verbs = ("get", "post", "put", "patch", "delete", "head")
raw = [(m.upper(), p) for p, v in spec["paths"].items() for m in v if m.lower() in verbs]
ops = sorted({f"{m} {re.sub(r'{[^}]+}', '{id}', p)}" for m, p in raw})
open(sys.argv[2], "w").write("\n".join(ops) + "\n")
print(f"  {len(raw)} operations in production, {len(ops)} after normalising ids")
PY
fi

if [ "$UPDATE" = "1" ]; then
  cp "$TMP/live" "$SNAPSHOT"
  printf '  %s wrote %s (%s operations)\n' "$(green '✓')" ".api-released" "$(grep -c . < "$SNAPSHOT")"
  exit 0
fi

[ -f "$SNAPSHOT" ] || { printf '  %s no %s — run: scripts/check-api.sh --update\n' "$(red '✗')" ".api-released"; exit 1; }
LC_ALL=C sort -u "$SNAPSHOT" > "$TMP/released"
: > "$TMP/pending"
[ -f "$PENDING" ] && grep -v '^[[:space:]]*\(#\|$\)' "$PENDING" | LC_ALL=C sort -u > "$TMP/pending"

# ── CHECK 1 — the ship gate ───────────────────────────────────────────
printf '\n%s\n' "$(bold 'api: every operation the CLI calls is served in production')"
LC_ALL=C comm -23 "$TMP/declared" "$TMP/released" > "$TMP/ahead_all"
LC_ALL=C comm -23 "$TMP/ahead_all" "$TMP/pending" > "$TMP/ahead"
n_ahead="$(grep -c . < "$TMP/ahead" || true)"
n_pending="$(grep -c . < "$TMP/pending" || true)"

# A pending entry only counts while the operation is genuinely absent from
# production. Listing one that HAS shipped is an error, not a harmless
# leftover: it would pre-authorise a future op nobody reviewed. Same rule
# .surface-breaking has.
LC_ALL=C comm -12 "$TMP/pending" "$TMP/released" > "$TMP/stale"
n_stale="$(grep -c . < "$TMP/stale" || true)"
if [ "$n_stale" -gt 0 ]; then
  printf '  %s %s pending operation(s) that production now SERVES:\n' "$(red '✗')" "$n_stale"
  sed 's/^/      /' < "$TMP/stale"
  printf '  They have shipped. Remove them from .api-pending.\n'
  fail=1
fi
if [ "$n_ahead" -gt 0 ]; then
  printf '  %s %s operation(s) the CLI declares but production does NOT serve:\n' "$(red '✗')" "$n_ahead"
  sed 's/^/      /' < "$TMP/ahead"
  printf '  These 404 for every customer. Built is not released: the endpoint may\n'
  printf '  well exist in ../uku_service and still not be deployed. Wait for the\n'
  printf '  API release, or drop the command.\n'
  fail=1
else
  printf '  %s all %s declared operations are live\n' "$(green '✓')" "$((n_declared - n_pending))"
fi
if [ "$n_pending" -gt 0 ]; then
  printf '  %s %s operation(s) acknowledged in .api-pending — built, NOT released:\n' "$(dim '→')" "$n_pending"
  sed 's/^/      /' < "$TMP/pending"
  printf '  Not a failure here, but scripts/release.sh refuses while any remain.\n'
fi

# ── CHECK 2 — coverage drift, only with a live fetch ──────────────────
if [ "$LIVE" = "1" ]; then
  printf '\n%s\n' "$(bold 'api: the snapshot still matches production')"
  LC_ALL=C sort -u "$TMP/live" > "$TMP/livesorted"
  LC_ALL=C comm -13 "$TMP/released" "$TMP/livesorted" > "$TMP/added"
  LC_ALL=C comm -23 "$TMP/released" "$TMP/livesorted" > "$TMP/gone"
  n_added="$(grep -c . < "$TMP/added" || true)"
  n_gone="$(grep -c . < "$TMP/gone" || true)"

  if [ "$n_gone" -gt 0 ]; then
    printf '  %s %s operation(s) have DISAPPEARED from production:\n' "$(red '✗')" "$n_gone"
    sed 's/^/      /' < "$TMP/gone"
    printf '  If the CLI calls one of these, it is broken for every customer right now.\n'
    fail=1
  fi
  if [ "$n_added" -gt 0 ]; then
    printf '  %s %s new operation(s) in production the snapshot does not have:\n' "$(dim '→')" "$n_added"
    sed 's/^/      /' < "$TMP/added" | head -30
    [ "$n_added" -gt 30 ] && printf '      … and %s more\n' "$((n_added - 30))"
    printf '  Not a failure — the API is allowed to grow. Refresh with:\n'
    printf '    scripts/check-api.sh --update\n'
  fi
  [ "$n_gone" = "0" ] && [ "$n_added" = "0" ] && printf '  %s snapshot matches production exactly\n' "$(green '✓')"

  # Informational: what the CLI could reach and does not. This is the coverage
  # question the handover cares about, and it is deliberately NOT a failure —
  # a CLI is allowed to be smaller than its API.
  n_uncovered="$(LC_ALL=C comm -13 "$TMP/declared" "$TMP/livesorted" | grep -c . || true)"
  printf '  %s %s live operations this CLI does not call\n' "$(dim '·')" "$n_uncovered"
fi

printf '\n'
if [ "$fail" != "0" ]; then
  printf '%s\n' "$(red 'api: FAILED')"
  exit 1
fi
printf '%s\n' "$(green 'api: clean.')"
exit 0
