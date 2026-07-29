#!/usr/bin/env bash
# traversal — S3/S7/S10a (2026-07-29 security audit). An account name (or a
# batch run-id) is a FILENAME the instant it reaches _profile_path /
# _ledger_file. `save_profile` validated names on WRITE; `account use`,
# `account remove`, `auth logout --account`, the global `--account` flag, and
# the `active` file's own content did NOT — proven exploit before this fix:
#
#   $ uku account remove ../../../../victim/precious.txt
#   ✓ Removed account '../../../../victim/precious.txt'.   # the file is GONE
#   $ uku --account ../../../../victim/prof clients list   # reads an
#     arbitrary file as a profile and sends a request carrying whatever
#     host/company/key it names
#
# This file is the cross-product this suite was missing: every kind of bad
# name × every command that turns a name into a path. Every cell must be a
# CLEAN usage error, delete NOTHING, and send NOTHING — asserting only the
# exit code would have passed on the OLD code too (it printed "✓ Removed …"
# and exited 0, a clean-LOOKING result). The assertion that actually pins the
# bug is that a real victim file, created once up front, still exists after
# every single one of these calls.
. "$(dirname "$0")/../lib/harness.sh"

setup_case
server_script <<'JSON'
{ "routes": [ { "method": "GET", "path_prefix": "/api/v3/",
  "response": {"status": 200, "body": {"data":[],"meta":{"total":0}}} } ] }
JSON
start_server

# A real file outside the profile directory. UKU_PROFILE_DIR resolves to
# "$UKU_CONFIG_HOME/profiles" == "$CASE_DIR/config/profiles" — two levels up
# from there is $CASE_DIR, so "../../victim/precious.txt" is exactly the shape
# of payload the audit used, scaled to this harness's directory depth.
VICTIM_FILE="$CASE_DIR/victim/precious.txt"
mkdir -p "$CASE_DIR/victim"
printf 'do not touch me\n' > "$VICTIM_FILE"

write_profile main
set_active_profile main
printf '{"title":"one"}\n' > "$CASE_DIR/lines.jsonl"

assert_victim_alive() { # LABEL
  assert_true "victim file survives: $1" test -f "$VICTIM_FILE"
  assert_true "profile 'main' survives: $1" test -f "$UKU_CONFIG_HOME/profiles/main"
  assert_true "active pointer unchanged: $1" sh -c "[ \"\$(cat '$UKU_CONFIG_HOME/active' 2>/dev/null)\" = main ]"
}

# Bad names that must be refused everywhere a name becomes a path. `''`
# (empty) is excluded from the --run-id row below: an empty --run-id is
# indistinguishable from "not passed" and the CLI correctly falls back to an
# auto-derived id there — that is documented, intended behaviour, not this
# bug class, so asserting failure for it would pin something untrue.
for name in .. . '../../victim/precious.txt' /etc/passwd a/b ''; do
  label="name='$name'"

  reset_requests
  uku account use "$name"
  assert_status 1 "account use $label is a usage error"
  assert_no_requests "account use $label sends nothing"
  assert_victim_alive "account use $label"

  reset_requests
  uku account remove "$name"
  assert_status 1 "account remove $label is a usage error"
  assert_no_requests "account remove $label sends nothing"
  assert_victim_alive "account remove $label"

  reset_requests
  uku auth logout --account "$name"
  assert_status 1 "auth logout --account $label is a usage error"
  assert_no_requests "auth logout --account $label sends nothing"
  assert_victim_alive "auth logout --account $label"

  reset_requests
  uku --account "$name" clients list
  assert_status 1 "--account $label clients list is a usage error"
  assert_no_requests "--account $label clients list sends nothing"
  assert_victim_alive "--account $label clients list"

  reset_requests
  uku batch show "$name"
  assert_status 1 "batch show $label is a usage error"
  assert_no_requests "batch show $label sends nothing"

  # --run-id only means anything alongside --batch; skip the empty case here
  # (see note above) — every other bad name must still refuse, unsent.
  if [ -n "$name" ]; then
    reset_requests
    uku tasks create --batch @"$CASE_DIR/lines.jsonl" --run-id "$name" --yes
    assert_status 1 "--run-id $label is a usage error"
    assert_no_requests "--run-id $label sends nothing"
  fi
done

# ── the active file itself can already be poisoned (S7) ──────────────
# Not a fresh argument this invocation — persisted state from an older CLI, a
# bug, or direct tampering. load_creds must not trust it blindly either.
reset_requests
printf '../../victim/precious.txt\n' > "$UKU_CONFIG_HOME/active"
uku account current
assert_status 0 'a poisoned active file does not crash account current'
assert_out_contains 'default' 'it falls back to the unnamed default'
assert_err_contains "stored active-account name" 'and says why, on stderr'
assert_true 'victim file survives: poisoned active file' test -f "$VICTIM_FILE"
assert_true "profile 'main' survives: poisoned active file" test -f "$UKU_CONFIG_HOME/profiles/main"

set_active_profile main

# ── the control: a normal name still works everywhere above ──────────
reset_requests
uku account use main
assert_status 0 'account use main (a normal name) still works'
assert_no_requests 'switching is local'

reset_requests
uku clients list
assert_status 0 'a normal read after switching back still works'
assert_request_count 1 'and it reached the fixture'

finish
