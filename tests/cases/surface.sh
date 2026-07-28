#!/usr/bin/env bash
# surface — the gate that keeps the prose honest.
#
# Everything here runs against a COPY of the repo in the case's temp dir, so a
# test can break the surface on purpose (delete a fact, invent a command, lie
# in the README) without touching the working tree. Each assertion proves the
# gate FAILS when it should — a checker that only ever passes is not a checker.
. "$(dirname "$0")/../lib/harness.sh"

SB=""
# mk_sandbox — a throwaway repo the gate can be run against and vandalised.
mk_sandbox() {
  SB="$CASE_DIR/repo"
  mkdir -p "$SB/bin" "$SB/scripts" "$CASE_DIR/gate-home"
  cp "$REPO_ROOT/bin/uku" "$SB/bin/uku"
  cp "$REPO_ROOT/scripts/check-surface.sh" "$REPO_ROOT/scripts/check-drift.sh" "$SB/scripts/"
  cp "$REPO_ROOT/.surface" "$REPO_ROOT/.surface-breaking" "$REPO_ROOT/.surface-internal" "$SB/"
  cp "$REPO_ROOT/README.md" "$SB/README.md"
  chmod +x "$SB/bin/uku" "$SB/scripts/check-surface.sh" "$SB/scripts/check-drift.sh"
}

# gate SCRIPT ARGS… — run one gate script against the sandbox.
gate() {
  local s="$1"; shift
  : > "$OUT_FILE"; : > "$ERR_FILE"
  ( cd "$SB" && HOME="$CASE_DIR/gate-home" UKU_NO_AUTO_UPDATE=1 NO_COLOR=1 \
      bash "scripts/$s" ${@+"$@"} ) > "$OUT_FILE" 2> "$ERR_FILE"
  STATUS=$?
  OUT="$(cat "$OUT_FILE")"; ERR="$(cat "$ERR_FILE")"
  return 0
}
dump() { "$SB/bin/uku" --dump-surface; }

# ── 1. --dump-surface is stable, sorted, and IS the committed .surface ─
setup_case
mk_sandbox
note '1 — the dump is deterministic and matches .surface'

dump > "$CASE_DIR/d1"
dump > "$CASE_DIR/d2"
assert_true 'two dumps in a row are byte-identical' \
  cmp -s "$CASE_DIR/d1" "$CASE_DIR/d2"
assert_true 'the dump is sorted and free of duplicates' \
  sh -c "LC_ALL=C sort -u '$CASE_DIR/d1' | cmp -s - '$CASE_DIR/d1'"
assert_true 'the dump is one fact per line, every line a known kind' \
  sh -c "! grep -vE '^(cmd|cmdalias|sub|subalias|flag|gflag|doc|arg|note) ' '$CASE_DIR/d1'"
assert_true 'the committed .surface is exactly what the CLI declares' \
  cmp -s "$CASE_DIR/d1" "$REPO_ROOT/.surface"
assert_true 'the dump needs no credentials, no network, no server' \
  sh -c "env -u UKU_BASE_URL -u UKU_API_KEY -u UKU_COMPANY '$SB/bin/uku' --dump-surface >/dev/null"

gate check-surface.sh
assert_status 0 'check-surface passes on an untouched tree'
assert_out_contains 'unchanged' 'and says so'
teardown_case

# ── 2. an ADDED fact fails, and --update is the only way in ──────────
setup_case
mk_sandbox
note '2 — new surface is cheap, but never accidental'

# drop a line from the committed file: the CLI now declares one fact more
grep -v '^flag projects --sort$' "$SB/.surface" > "$SB/.surface.new"
mv "$SB/.surface.new" "$SB/.surface"

gate check-surface.sh
assert_status 1 'an added fact fails the check'
assert_err_contains 'NEW SURFACE' 'the failure names the direction'
assert_err_contains 'flag projects --sort' 'and prints the exact fact'
assert_err_contains '--update' 'and how to accept it'

gate check-surface.sh --update
assert_status 0 '--update accepts the addition'
gate check-surface.sh
assert_status 0 'and the tree is clean afterwards'
teardown_case

# ── 3. a REMOVED fact fails unconditionally ──────────────────────────
setup_case
mk_sandbox
note '3 — removed surface is a compatibility break'

printf 'sub clients archive\n' >> "$SB/.surface"
LC_ALL=C sort -u "$SB/.surface" -o "$SB/.surface"

gate check-surface.sh
assert_status 1 'a fact that vanished from the CLI fails the check'
assert_err_contains 'REMOVED SURFACE' 'the failure names the direction'
assert_err_contains 'sub clients archive' 'and prints the exact fact'
assert_err_contains '.surface-breaking' 'and points at the acknowledgement file'

gate check-surface.sh --update
assert_status 1 '--update does NOT wave a removal through'
assert_err_contains 'REMOVED SURFACE' 'it fails for the same reason'
teardown_case

# ── 4. .surface-breaking acknowledges a removal — and only a real one ─
setup_case
mk_sandbox
note '4 — the acknowledgement is a changelog, not a permission slip'

printf 'sub clients archive\n' >> "$SB/.surface"
LC_ALL=C sort -u "$SB/.surface" -o "$SB/.surface"
printf '# 2026-07-28 archive was never released\nsub clients archive\n' >> "$SB/.surface-breaking"

gate check-surface.sh
assert_status 0 'an acknowledged removal passes'
assert_out_contains 'acknowledged' 'and is reported, not silent'

gate check-surface.sh --update
assert_status 0 '--update then rewrites .surface'
assert_true 'the removed fact is gone from .surface' \
  sh -c "! grep -qxF 'sub clients archive' '$SB/.surface'"
assert_true 'the acknowledgement stays as the record' \
  sh -c "grep -qxF 'sub clients archive' '$SB/.surface-breaking'"

# a STALE entry — one whose line still exists — must not pre-authorise anything
printf 'sub clients create\n' >> "$SB/.surface-breaking"
gate check-surface.sh
assert_status 1 'acknowledging a fact that still exists is itself an error'
assert_err_contains 'STALE ACKNOWLEDGEMENT' 'and says exactly that'
assert_err_contains 'sub clients create' 'naming the line'
teardown_case

# ── 5. drift: the docs must not promise fiction ──────────────────────
setup_case
mk_sandbox
note '5 — a doc that names something that does not exist fails the build'

gate check-drift.sh
assert_status 0 'the tree as committed is drift-free'

printf '\nRun `uku frobnicate list` to tidy up.\n' >> "$SB/README.md"
gate check-drift.sh
assert_status 1 'a README naming a command that does not exist fails'
assert_err_contains 'uku frobnicate' 'the failure quotes the promise'
assert_err_contains 'no such command' 'and says what is wrong with it'

cp "$REPO_ROOT/README.md" "$SB/README.md"
printf '\nUse `uku clients archive` when you are done.\n' >> "$SB/README.md"
gate check-drift.sh
assert_status 1 'a README naming a subcommand that does not exist fails'
assert_err_contains 'no `archive` subcommand' 'and names the subcommand'

cp "$REPO_ROOT/README.md" "$SB/README.md"
printf '\nPass `--force-it` to skip the confirm.\n' >> "$SB/README.md"
gate check-drift.sh
assert_status 1 'a README naming a flag that does not exist fails'
assert_err_contains '--force-it' 'and quotes the flag'
assert_err_contains 'no command accepts it' 'and says why it is wrong'
teardown_case

# ── 6. drift: the table must not lie by omission ─────────────────────
setup_case
mk_sandbox
note '6 — code the table does not know about, and table rows the code rejects'

# a command that exists in the code but not in the table
"$PYTHON_BIN" - "$SB/bin/uku" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("cmd_doctor() {", "cmd_frobnicate() { printf 'frob\\n'; }\ncmd_doctor() {", 1)
s = s.replace("  doctor)   cmd_doctor \"$@\" ;;", "  frobnicate) cmd_frobnicate \"$@\" ;;\n  doctor)   cmd_doctor \"$@\" ;;", 1)
open(p, "w").write(s)
PY
assert_true 'the sandbox CLI really did gain the command' \
  sh -c "'$SB/bin/uku' frobnicate | grep -q frob"
gate check-drift.sh
assert_status 1 'surface the code dispatches but the table omits fails'
assert_err_contains 'cmd_frobnicate()' 'the function is named'
assert_err_contains 'uku frobnicate' 'and so is the dispatcher label'

# the other direction: a table row nothing dispatches
mk_sandbox
"$PYTHON_BIN" - "$SB/bin/uku" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("version     |", "ghost       |              |                         |                |                                                         |                                                 | not wired to anything\nversion     |", 1)
open(p, "w").write(s)
PY
gate check-surface.sh --update
assert_status 0 'the new row is accepted into .surface'
gate check-drift.sh
assert_status 1 'a declared command the dispatcher rejects fails'
assert_err_contains 'unknown command' 'proved by EXECUTING it, not by parsing'
teardown_case

# ── 7. drift: nothing undiscoverable by accident ─────────────────────
setup_case
mk_sandbox
note '7 — surface nobody can find in uku --help'

"$PYTHON_BIN" - "$SB/bin/uku" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
# the RESOURCES line in usage() is the only place uku --help names products
s = re.sub(r'^  uku products list.*$', '  uku prods list', s, count=1, flags=re.M)
open(p, "w").write(s)
PY
gate check-drift.sh
assert_status 1 'a command missing from uku --help fails'
assert_err_contains 'nobody can discover it' 'and says why that matters'
assert_err_contains '.surface-internal' 'and offers the honest escape hatch'
teardown_case

finish
