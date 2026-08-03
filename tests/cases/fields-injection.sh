#!/usr/bin/env bash
# fields-injection — S4 (2026-07-29 security audit). `table()`'s TTY path
# built a jq program by string concatenation: `.$f` where `$f` came straight
# from `--fields`. jq cannot spawn processes, but it CAN read `env` — so on a
# real terminal, `uku clients list --fields 'zzz // env.UKU_API_KEY'` printed
# the live API key. `--json`/`--agent` were never vulnerable (`_project_fields`
# already passed the field list through jq's `--arg`), which is exactly why
# every other case in this suite — none of which ever runs against a real
# tty — missed this: the vulnerable branch is the one branch nothing else
# exercises. This file uses uku_tty() (tests/lib/harness.sh) for that reason.
#
# Two independent layers are pinned here, matching the fix:
#   1. --fields is validated against a plain-identifier allowlist BEFORE any
#      command runs (_check_fields_arg at the flag's parse site) — a payload
#      is refused outright, as a usage error, with nothing sent.
#   2. table()'s jq invocation passes field names as jq POSITIONAL STRING
#      ARGUMENTS (--args), never spliced into the program text — so even a
#      name that were somehow not caught by (1) could not become code.
. "$(dirname "$0")/../lib/harness.sh"

setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200,
                   "body": {"data":[{"id":1,"name":"Acme"},{"id":2,"name":"Nordic"}],
                             "meta":{"total":2,"offset":0,"limit":50}}} }
  ]
}
JSON
start_server
# TEST_API_KEY (tests/lib/harness.sh) is exported as UKU_API_KEY by
# start_server — the very secret an `env.UKU_API_KEY` payload goes after.

# ── 1 — the control: a normal --fields still renders a table on a real tty ──
uku_tty clients list --fields id,name
assert_status 0 'a plain --fields id,name still works on a real tty'
assert_out_contains 'ID' 'the header is rendered'
assert_out_contains 'NAME' 'both requested columns are rendered'
assert_out_contains 'Acme' 'and real row data is there'
assert_out_contains 'Nordic' 'for both rows'

# ── 2 — env-read payload: must be refused before rendering, and the key
#         must never appear even if it somehow weren't ────────────────────
reset_requests
uku_tty clients list --fields 'zzz // env.UKU_API_KEY'
assert_status 1 "'zzz // env.UKU_API_KEY' is a usage error, not a table"
assert_out_not_contains "$TEST_API_KEY" 'the live API key never reaches stdout'
assert_err_contains '--fields wants plain field names' 'and the refusal names the actual rule'
assert_no_requests 'refused before any request was sent'

# ── 3 — a payload shaped to close the array and open a second filter ──────
reset_requests
uku_tty clients list --fields 'x),(env.HOME'
assert_status 1 "'x),(env.HOME' is a usage error"
assert_out_not_contains "$HOME" '$HOME is never printed either'
assert_err_contains '--fields wants plain field names' 'refused for the same reason'
assert_no_requests 'nothing sent'

# ── 4 — the identical payloads are refused in the --json/--agent path too,
#         even though _project_fields' --arg passing was never exploitable
#         itself — the allowlist is checked once, for every consumer ──────
reset_requests
uku clients list --fields 'zzz // env.UKU_API_KEY' --json
assert_status 1 'the same payload is refused under --json'
assert_out_not_contains "$TEST_API_KEY" 'and the key is not printed there either'
assert_no_requests 'nothing sent'

reset_requests
uku clients list --fields 'zzz // env.UKU_API_KEY' --agent
assert_status 1 'and refused under --agent'
assert_out_not_contains "$TEST_API_KEY" 'no leak in the agent envelope either'

# ── 5 — C10: the comma split must not expand globs ───────────────────────
# The allowlist above is reached by splitting on commas with `set --` on an
# UNQUOTED expansion, which is subject to pathname expansion as well as word
# splitting. So the value the allowlist inspected was not always the value the
# user passed: in a directory containing files named `id` and `name`,
# `--fields '*'` was replaced by those filenames BEFORE _valid_field ran, every
# name passed, and the request went out with its columns chosen by whatever
# happened to be in the working directory.
#
# Non-vacuity first (Lesson 2): with no bait files, `*` stays literal and is
# refused for unrelated reasons, so both assertions below would pass against
# the unfixed code for free.
note '5 — the comma split must not expand globs'
mkdir -p "$CASE_DIR/globbait"
( cd "$CASE_DIR/globbait" && touch id name )
assert_true 'the bait directory really does contain glob-able field names' \
  sh -c "[ -f '$CASE_DIR/globbait/id' ] && [ -f '$CASE_DIR/globbait/name' ]"

# cd in the CURRENT shell, never in a ( subshell ): uku() records the run into
# $OUT/$ERR/$STATUS, and a subshell discards all three, leaving the assertions
# below reading the PREVIOUS test's values — passing without ever running this
# one. That mistake was made here first and caught by this very comment.
_glob_cwd="$PWD"
cd "$CASE_DIR/globbait"

reset_requests
uku clients list --fields '*'
assert_status 1 "'*' is a usage error, not the cwd's filenames"
assert_err_contains "got '*'" 'the CLI reports the literal value the user passed'
assert_no_requests 'and nothing is sent — columns are never chosen by the filesystem'

reset_requests
uku clients list --fields 'id,?ame'
assert_status 1 "'?' does not expand either"
assert_err_contains "got '?ame'" 'and that value is reported literally too'
assert_no_requests 'still nothing sent'

cd "$_glob_cwd"

finish
