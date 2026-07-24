#!/bin/sh
# install.sh — install the Uku CLI (`uku`).
#
#   curl -fsSL https://getuku.com/install-cli | sh
#
# Downloads a single self-contained script to a directory on your PATH.
# No compilation, no dependencies beyond `curl` (and `bash`, which `uku` uses).
#
# Options (via environment):
#   UKU_BIN_DIR       Where to install (default: ~/.local/bin, or ~/bin if on PATH)
#   UKU_INSTALL_URL   Where to fetch the `uku` script from
#                     (default: https://getuku.com/uku)
set -eu

UKU_INSTALL_URL="${UKU_INSTALL_URL:-https://getuku.com/uku}"

# ── tiny output helpers (respect NO_COLOR + non-tty) ──────────────────
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  green() { printf '\033[32m%s\033[0m' "$1"; }
  bold()  { printf '\033[1m%s\033[0m' "$1"; }
  dim()   { printf '\033[2m%s\033[0m' "$1"; }
else
  green() { printf '%s' "$1"; }; bold() { printf '%s' "$1"; }; dim() { printf '%s' "$1"; }
fi
info()  { printf '  %s %s\n' "$(green '✓')" "$1"; }
step()  { printf '  %s %s\n' "$(bold '→')" "$1"; }
err()   { printf '  %s %s\n' "$(printf '\033[31m✗\033[0m')" "$1" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || err "curl is required but not found."

# ── choose an install dir that's on PATH ──────────────────────────────
on_path() { case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac; }
if [ -n "${UKU_BIN_DIR:-}" ]; then
  BIN_DIR="$UKU_BIN_DIR"
elif on_path "$HOME/.local/bin"; then
  BIN_DIR="$HOME/.local/bin"
elif on_path "$HOME/bin"; then
  BIN_DIR="$HOME/bin"
else
  BIN_DIR="$HOME/.local/bin"
fi
mkdir -p "$BIN_DIR"

TARGET="$BIN_DIR/uku"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

step "Downloading uku from $UKU_INSTALL_URL"
curl -fsSL "$UKU_INSTALL_URL" -o "$TMP" || err "download failed from $UKU_INSTALL_URL"

# sanity: must look like the uku script, not an HTML error page
head -n 1 "$TMP" | grep -q '^#!' || err "downloaded file is not a script (got an error page?). Aborting."
grep -q 'the Uku command-line client' "$TMP" || err "downloaded file doesn't look like uku. Aborting."

mv "$TMP" "$TARGET"
chmod +x "$TARGET"
trap - EXIT
info "Installed uku → $(bold "$TARGET")"

# ── PATH guidance ─────────────────────────────────────────────────────
if ! on_path "$BIN_DIR"; then
  printf '\n'
  step "$(bold "$BIN_DIR") is not on your PATH yet. Add it:"
  printf '      %s\n' "$(dim "echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc && source ~/.zshrc")"
fi

printf '\n'
info "Next: $(bold 'uku auth login')  — sign in with your company UUID + API key (Settings → API)."
step "Docs: https://app.getuku.com/api/v3/docs   ·   https://getuku.com/agents/"
