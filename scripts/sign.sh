#!/usr/bin/env bash
# sign.sh — sign the release artefacts, and print the public key to embed.
#
#   scripts/sign.sh --keygen [path]   create a signing key (do this ONCE)
#   scripts/sign.sh                   sign bin/uku.sha256 and scripts/install.sh
#   scripts/sign.sh --verify          verify what is on disk, using the embedded key
#
# WHAT THIS BUYS, AND WHAT IT DOES NOT
#
# The checksum in bin/uku.sha256 proves the download was not corrupted or swapped
# in transit. It is NOT authenticity: the artefact and its checksum come from the
# same repo, so anyone who can write to that repo can rewrite both. A signature
# made with a key that does NOT live in the repo is the only control in the whole
# chain that survives a repo compromise or a stolen CI token.
#
# It does not fix first-install trust-on-first-use: `curl … | sh` on a machine
# that has never seen uku is anchored by HTTPS and a pinned tag, not by a key the
# user already holds. What it does fix is every subsequent update, which is the
# path that runs unattended and the one C1 was actually about.
#
# RSA-4096 + SHA-256 through openssl, deliberately: openssl is on every macOS and
# Linux box already, and this CLI's whole premise is curl + bash. minisign and
# `gh attestation` are both better designs and both add a dependency that a
# customer would have to install before they could verify anything.
# LibreSSL 3.3 (macOS) has no Ed25519, which is why this is RSA.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

# Where the PRIVATE key lives. Never inside the repo — that is the entire point.
KEY_DEFAULT="${UKU_SIGN_KEY:-$HOME/.config/uku-release/signing-key.pem}"

green() { printf '\033[32m%s\033[0m' "$1"; }
red()   { printf '\033[31m%s\033[0m' "$1"; }
bold()  { printf '\033[1m%s\033[0m' "$1"; }
dim()   { printf '\033[2m%s\033[0m' "$1"; }
info()  { printf '  %s %s\n' "$(green '✓')" "$1"; }
err()   { printf '  %s %s\n' "$(red '✗ ERROR:')" "$1" >&2; exit 1; }

command -v openssl >/dev/null 2>&1 || err "openssl is required to sign or verify."

# The files that get signed. bin/uku.sha256 covers bin/uku transitively; the
# installer is signed in its own right because cmd_update pipes it into a shell,
# which is the actual remote-code path.
ARTEFACTS="bin/uku.sha256 scripts/install.sh"

case "${1:-}" in
  --keygen)
    KEY="${2:-$KEY_DEFAULT}"
    [ -e "$KEY" ] && err "$KEY already exists. Refusing to overwrite a signing key."
    case "$KEY" in
      "$ROOT"/*) err "refusing to write a private key inside the repo ($KEY). A key in the artefact repo protects nothing." ;;
    esac
    mkdir -p "$(dirname "$KEY")"
    ( umask 077; openssl genrsa -out "$KEY" 4096 2>/dev/null )
    chmod 600 "$KEY"
    info "private key → $(bold "$KEY") $(dim '(0600, never commit this)')"
    printf '\n  %s\n\n' "$(bold 'Paste this public key into BOTH bin/uku and scripts/install.sh')"
    printf '  %s\n\n' "$(dim 'as UKU_RELEASE_PUBKEY (it is public — committing it is the point):')"
    openssl rsa -in "$KEY" -pubout 2>/dev/null | sed 's/^/    /'
    printf '\n  %s\n' "$(dim 'Then back the private key up somewhere the repo cannot reach it.')"
    exit 0 ;;
  --verify)
    # Verify using the key EMBEDDED in bin/uku — i.e. exactly what a client uses.
    PUB="$(sed -n '/^UKU_RELEASE_PUBKEY=/,/^EOKEY$/p' bin/uku | sed '1d;$d')"
    [ -n "$PUB" ] || err "bin/uku has no UKU_RELEASE_PUBKEY — nothing to verify against. Run scripts/sign.sh --keygen first."
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    printf '%s\n' "$PUB" > "$TMP/pub.pem"
    rc=0
    for f in $ARTEFACTS; do
      [ -f "$f.sig" ] || { printf '  %s %s\n' "$(red '✗')" "$f — no signature"; rc=1; continue; }
      tr -d '\n' < "$f.sig" | openssl base64 -d -A -out "$TMP/s" 2>/dev/null || { printf '  %s %s\n' "$(red '✗')" "$f — signature is not base64"; rc=1; continue; }
      if openssl dgst -sha256 -verify "$TMP/pub.pem" -signature "$TMP/s" "$f" >/dev/null 2>&1; then
        info "$f"
      else
        printf '  %s %s\n' "$(red '✗')" "$f — SIGNATURE DOES NOT VERIFY"; rc=1
      fi
    done
    [ "$rc" = "0" ] || err "verification failed. Do not publish this."
    printf '\n  %s\n' "$(green 'All release artefacts verify against the key embedded in bin/uku.')"
    exit 0 ;;
  '') : ;;
  -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  *) err "unknown argument: $1" ;;
esac

# ── sign ──────────────────────────────────────────────────────────────
KEY="$KEY_DEFAULT"
[ -f "$KEY" ] || err "no signing key at $KEY.
    Create one:  scripts/sign.sh --keygen
    Or point at an existing one:  UKU_SIGN_KEY=/path/to/key.pem scripts/sign.sh"

for f in $ARTEFACTS; do
  [ -f "$f" ] || err "$f does not exist — run scripts/release.sh first (it writes bin/uku.sha256)."
done

for f in $ARTEFACTS; do
  openssl dgst -sha256 -sign "$KEY" -out "$f.sig.der" "$f" 2>/dev/null \
    || err "could not sign $f with $KEY."
  openssl base64 -in "$f.sig.der" -out "$f.sig"
  rm -f "$f.sig.der"
  info "$f.sig"
done

# Sign, then immediately verify with the EMBEDDED key. Signing with a key the
# clients do not carry produces artefacts that fail for every customer and pass
# every check here — so the check has to be the client's, not the signer's.
printf '\n'
exec "$0" --verify
