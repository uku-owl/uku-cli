#!/usr/bin/env bash
# signing — Phase 1. The release key is the one control in the install chain
# that a compromised repo does not defeat: the checksum and the artefact come
# from the same place, a signature does not.
#
# Every case here generates its OWN key, injects the public half into a COPY of
# bin/uku, and drives that copy. Nothing in the committed tree carries a key
# whose private half exists on this machine.
. "$(dirname "$0")/../lib/harness.sh"

have_openssl() { command -v openssl >/dev/null 2>&1; }
if ! have_openssl; then
  printf '1..0 # SKIP openssl is not available, so signing cannot be exercised\n'
  exit 0
fi

# _build_signed_cli — a bin/uku carrying PUBKEY, at $CASE_DIR/uku
_build_signed_cli() { # PUBKEY_PEM
  local pub="$1"
  UKU_BIN="$CASE_DIR/uku"
  "$PYTHON_BIN" - "$REPO_ROOT/bin/uku" "$UKU_BIN" "$pub" <<'PY'
import sys
src, dst, pub = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()
empty = "UKU_RELEASE_PUBKEY=\"$(cat <<'EOKEY'\nEOKEY\n)\""
filled = "UKU_RELEASE_PUBKEY=\"$(cat <<'EOKEY'\n%s\nEOKEY\n)\"" % pub.rstrip("\n")
assert empty in s, "the empty UKU_RELEASE_PUBKEY slot is gone from bin/uku"
open(dst, "w").write(s.replace(empty, filled))
PY
  chmod +x "$UKU_BIN"
}

setup_case
# ── a key, and the artefacts it signs ────────────────────────────────
KEY="$CASE_DIR/k.pem"
openssl genrsa -out "$KEY" 2048 2>/dev/null
PUB="$(openssl rsa -in "$KEY" -pubout 2>/dev/null)"

INSTALLER="$CASE_DIR/install.sh"
printf '#!/bin/sh\nprintf "INSTALLER RAN\\n"\n' > "$INSTALLER"
openssl dgst -sha256 -sign "$KEY" -out "$CASE_DIR/i.der" "$INSTALLER" 2>/dev/null
openssl base64 -in "$CASE_DIR/i.der" -out "$CASE_DIR/install.sh.sig"
# one line: the fixture serves it inside a JSON string. openssl base64 -d
# accepts both wrapped and unwrapped input, so this is not a special case.
INSTALLER_SIG="$(tr -d '\n' < "$CASE_DIR/install.sh.sig")"

# NON-VACUITY: the signature must actually be over THIS installer. If the
# fixture ever serves a signature that verifies against anything, every
# assertion below passes for free.
printf '#!/bin/sh\nprintf "EVIL\\n"\n' > "$CASE_DIR/evil.sh"
if openssl dgst -sha256 -verify <(printf '%s\n' "$PUB") \
     -signature "$CASE_DIR/i.der" "$CASE_DIR/evil.sh" >/dev/null 2>&1; then
  _tap_fail 'the fixture signature discriminates between two installers' \
    'the signature verified against a DIFFERENT file — the whole case is vacuous'
else
  _tap_ok 'the fixture signature discriminates between two installers'
fi

# The fixture body and the signed bytes come from the SAME file, via json.dumps.
# Hand-escaping them separately in a heredoc produced a one-byte difference, and
# a signature that correctly refused to verify.
"$PYTHON_BIN" - "$INSTALLER" "$CASE_DIR/install.sh.sig" "$SERVER_SCRIPT" <<'FIXTURE'
import json, sys
body = open(sys.argv[1]).read()
sig  = open(sys.argv[2]).read().replace("\n", "")
evil = "#!/bin/sh\necho EVIL RAN\n"
json.dump({"routes": [
    {"method": "GET", "path": "/install.sh",     "response": {"status": 200, "body": body}},
    {"method": "GET", "path": "/install.sh.sig", "response": {"status": 200, "body": sig}},
    {"method": "GET", "path": "/evil.sh",        "response": {"status": 200, "body": evil}},
    {"method": "GET", "path": "/evil.sh.sig",    "response": {"status": 200, "body": sig}},
    {"method": "GET", "path": "/nosig.sh",       "response": {"status": 200, "body": body}},
    {"method": "GET", "path": "/nosig.sh.sig",   "response": {"status": 404, "body": ""}},
]}, open(sys.argv[3], "w"))
FIXTURE

start_server
_build_signed_cli "$PUB"
# setup_case deliberately points this at a dead port so no case can reach the
# real installer. These cases are ABOUT the installer, so aim it at the fixture.
export UKU_INSTALL_URL="$UKU_BASE_URL/install.sh"

note '1 — a correctly signed installer is verified and RUN'
uku update
assert_status 0 'update exits 0'
assert_err_contains 'Installer signature verified' 'the signature was checked, and said so'
assert_out_contains 'INSTALLER RAN' 'and only then was the installer run'

note '2 — a TAMPERED installer is refused, and never runs'
note '     (same valid signature, different bytes — the real attack shape)'
UKU_INSTALL_URL="$UKU_BASE_URL/evil.sh" uku update
assert_status 3 'exit 3 — a bad signature is fatal'
assert_err_contains 'does NOT match its signature' 'it says exactly what happened'
assert_err_contains 'Nothing has been run' 'and that nothing executed'
# The assertion that matters: side-effect ABSENCE. An exit code alone passed
# against the old code, which piped the bytes into sh before looking at them.
assert_out_not_contains 'EVIL RAN' 'the tampered installer did NOT execute'

note '3 — a MISSING signature is a failure, never "skip the check"'
note '     whoever can swap the artefact can also drop its signature'
UKU_INSTALL_URL="$UKU_BASE_URL/nosig.sh" uku update
assert_status 3 'exit 3 — no signature is treated as a bad one'
assert_out_not_contains 'INSTALLER RAN' 'and the unsigned installer did not run either'
teardown_case

# ── a build with NO key falls back, and says so ──────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/install.sh",
      "response": {"status": 200, "body": "#!/bin/sh\nprintf \"INSTALLER RAN\\n\"\n"} },
    { "method": "GET", "path": "/install.sh.sig",
      "response": {"status": 404, "body": ""} }
  ]
}
JSON
start_server
# A COPY, not $REPO_ROOT/bin/uku: cmd_update installs into the directory the
# running binary lives in, so driving the real one would point a fixture
# installer at this repo's own bin/.
cp "$REPO_ROOT/bin/uku" "$CASE_DIR/uku"; chmod +x "$CASE_DIR/uku"; UKU_BIN="$CASE_DIR/uku"
export UKU_INSTALL_URL="$UKU_BASE_URL/install.sh"

note '4 — the committed tree carries no key, so it falls back — loudly'
uku update
assert_status 0 'an unsigned build still updates'
assert_err_contains 'no release key' 'but it states that it could not verify'
assert_out_contains 'INSTALLER RAN' 'the installer ran'

note '5 — and the committed tree really is keyless (else test 4 proves nothing)'
assert_true 'bin/uku ships with an EMPTY UKU_RELEASE_PUBKEY' \
  "$PYTHON_BIN" -c "
import sys
s = open('$REPO_ROOT/bin/uku').read()
sys.exit(0 if 'UKU_RELEASE_PUBKEY=\"\$(cat <<\'EOKEY\'\nEOKEY\n)\"' in s else 1)"
finish
