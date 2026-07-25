#!/bin/sh
# install.sh — install the Uku CLI (`uku`).
#
#   curl -fsSL https://getuku.com/install-cli | sh
#
# Downloads a single self-contained script to a directory on your PATH, adds
# that directory to PATH, and — when run in a terminal — offers to sign you in.
# It does NOT verify a checksum: none is published for the rolling install, and
# one served from the same repo and commit as the file would prove transport,
# not authenticity. The anchor is HTTPS to a public, readable repo.
# No compilation, no dependencies beyond `curl` (and `bash`, which `uku` uses).
#
# Options (via environment):
#   UKU_BIN_DIR       Where to install (default: ~/.local/bin, or ~/bin if on PATH)
#   UKU_VERSION       Pin a git tag (e.g. 0.1.0). No tags are published yet,
#                     so this currently fails by design rather than silently
#                     installing something unpinned.
#   UKU_BASE_URL_DL   Raw repo base to fetch bin/uku from
#                     (default: https://raw.githubusercontent.com/uku-owl/uku-cli)
#   UKU_SKIP_SETUP    Set to 1 to skip the post-install sign-in + agent setup
#   UKU_SETUP_AGENT   claude | cursor | codex | all | none  (forwarded to `uku setup agents`)
#   NO_COLOR          Disable colored output
set -eu

# The repo is the single source of truth: the script you are reading and the
# binary it installs both come from raw.githubusercontent, so there is no
# second copy on the website to drift out of sync. getuku.com/install-cli is a
# vanity redirect to this same file — the published one-liner never changes
# even if this target does.
DL_BASE="${UKU_BASE_URL_DL:-https://raw.githubusercontent.com/uku-owl/uku-cli}"
VERSION="${UKU_VERSION:-}"
# A pinned version resolves to that git tag; unpinned follows main.
if [ -n "$VERSION" ]; then SRC="$DL_BASE/v$VERSION/bin/uku"; else SRC="$DL_BASE/main/bin/uku"; fi

# ── output helpers (respect NO_COLOR + non-tty) ───────────────────────
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  green() { printf '\033[32m%s\033[0m' "$1"; }; bold() { printf '\033[1m%s\033[0m' "$1"; }
  red()   { printf '\033[31m%s\033[0m' "$1"; }; dim()  { printf '\033[2m%s\033[0m' "$1"; }
else
  green() { printf '%s' "$1"; }; bold() { printf '%s' "$1"; }; red() { printf '%s' "$1"; }; dim() { printf '%s' "$1"; }
fi
info() { printf '  %s %s\n' "$(green '✓')" "$1"; }
step() { printf '  %s %s\n' "$(bold '→')" "$1"; }
err()  { printf '  %s %s\n' "$(red '✗ ERROR:')" "$1" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || err "curl is required but not found. Install curl and re-run."
DL() { curl -fsSL --retry 3 --connect-timeout 10 "$1"; }

printf '\n  %s\n  %s\n\n' "$(bold 'uku')" "$(dim 'operate your firm'\''s Uku from the terminal')"

# ── choose an install dir on PATH ─────────────────────────────────────
on_path() { case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac; }
if [ -n "${UKU_BIN_DIR:-}" ]; then BIN_DIR="$UKU_BIN_DIR"
elif on_path "$HOME/.local/bin"; then BIN_DIR="$HOME/.local/bin"
elif on_path "$HOME/bin"; then BIN_DIR="$HOME/bin"
else BIN_DIR="$HOME/.local/bin"; fi
mkdir -p "$BIN_DIR"
TARGET="$BIN_DIR/uku"

TMP="$(mktemp)"; SUM="$(mktemp)"
trap 'rm -f "$TMP" "$SUM"' EXIT

# ── download ──────────────────────────────────────────────────────────
step "Downloading uku${VERSION:+ v$VERSION}…"
DL "$SRC" > "$TMP" || err "download failed from $SRC"
head -n 1 "$TMP" | grep -q '^#!' || err "downloaded file is not a script (an error page?). Aborting."
grep -q 'the Uku command-line client' "$TMP" || err "downloaded file doesn't look like uku. Aborting."

# ── verify checksum (integrity — this holds an API key) ───────────────
SHA_CMD=""
if command -v sha256sum >/dev/null 2>&1; then SHA_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SHA_CMD="shasum -a 256"; fi
if DL "$SRC.sha256" > "$SUM" 2>/dev/null && [ -s "$SUM" ] && [ -n "$SHA_CMD" ]; then
  want="$(cut -d' ' -f1 < "$SUM" | tr -d '[:space:]')"
  got="$($SHA_CMD < "$TMP" | cut -d' ' -f1)"
  if [ "$want" != "$got" ]; then
    printf '\n'; err "$(red 'Checksum mismatch — do NOT run this file.')
    expected $want
    got      $got
  This is a failure worth reporting: security@getuku.com"
  fi
  info "Checksum verified  $(dim "sha256 $(printf '%s' "$got" | cut -c1-12)…")"
else
  # A missing checksum is a hard failure for a pinned version (an attacker can
  # simply omit it) and when the caller demands one; otherwise a loud warning.
  if [ -n "$VERSION" ]; then
    err "no checksum published for uku v$VERSION — refusing to install a pinned version unverified."
  elif [ "${UKU_REQUIRE_CHECKSUM:-0}" = "1" ]; then
    err "no checksum published and UKU_REQUIRE_CHECKSUM=1 — refusing to install unverified."
  fi
  # No checksum on the rolling install, and that is deliberate rather than an
  # oversight: a checksum served from the same repo and commit as the file it
  # describes verifies transport, not authenticity — anyone who could swap the
  # binary could swap the checksum with it. The real anchor here is TLS to
  # GitHub plus a public, auditable repo. A published checksum starts meaning
  # something at a tagged release, which is why a pinned version still refuses
  # to install without one.
  step "$(dim 'Source:') $(bold 'github.com/uku-owl/uku-cli') $(dim '(public, over HTTPS) — read it before you run it.')"
fi

# ── install ───────────────────────────────────────────────────────────
mv "$TMP" "$TARGET"; chmod +x "$TARGET"
trap 'rm -f "$SUM"' EXIT
info "Installed → $(bold "$TARGET")"

# ── PATH, handled (append to the right rc, idempotent; fish/nushell aware) ──
# UKU_SKIP_PATH=1 leaves the user's shell rc files untouched. Needed for
# sandboxed installs (CI, testing a throwaway UKU_BIN_DIR): appending a PATH
# line to a real ~/.zshrc for a temp directory is a side effect nobody asked
# for, and it outlives the temp dir.
if [ "${UKU_SKIP_PATH:-0}" = "1" ]; then
  step "Skipping PATH setup (UKU_SKIP_PATH=1). Add it yourself:  $(dim "export PATH=\"$BIN_DIR:\$PATH\"")"
elif ! on_path "$BIN_DIR"; then
  case "${SHELL:-}" in
    *fish)
      LINE="fish_add_path $BIN_DIR"; RC="$HOME/.config/fish/config.fish" ;;
    *nu)
      LINE="\$env.PATH = (\$env.PATH | prepend '$BIN_DIR')"; RC="$HOME/.config/nushell/config.nu" ;;
    *zsh)  LINE="export PATH=\"$BIN_DIR:\$PATH\""; RC="$HOME/.zshrc" ;;
    *bash) LINE="export PATH=\"$BIN_DIR:\$PATH\""; [ -f "$HOME/.bash_profile" ] && RC="$HOME/.bash_profile" || RC="$HOME/.bashrc" ;;
    *)     LINE="export PATH=\"$BIN_DIR:\$PATH\""; RC="$HOME/.profile" ;;
  esac
  if [ -n "$RC" ] && grep -qF "$BIN_DIR" "$RC" 2>/dev/null; then
    info "PATH already configured in $(dim "$RC") — restart your shell (or: $(dim "source $RC"))"
  elif [ -n "$RC" ] && mkdir -p "$(dirname "$RC")" 2>/dev/null && { [ -f "$RC" ] || : > "$RC"; }; then
    printf '\n# added by uku installer\n%s\n' "$LINE" >> "$RC"
    info "Added $(bold "$BIN_DIR") to PATH ($(dim "$RC")) — new terminals get it automatically"
    step "This shell: $(dim "source $RC")"
  else
    step "Add $(bold "$BIN_DIR") to your PATH:  $(dim "$LINE")"
  fi
fi

# ── shadow check — a shell function named `uku` would eclipse the binary ──
for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
  [ -f "$rc" ] || continue
  if grep -Eq '(^|[[:space:]])(function[[:space:]]+)?uku[[:space:]]*(\(\)|=)' "$rc" 2>/dev/null; then
    step "$(red "! a shell function/alias 'uku' in $rc will shadow this binary")"
    step "  $(dim "rename it, or call") $(bold 'command uku')"
    break
  fi
done

# ── verify + handoff ──────────────────────────────────────────────────
"$TARGET" --version >/dev/null 2>&1 && info "$("$TARGET" --version) ready" || err "installed but 'uku --version' failed (is bash available?)."

if [ "${UKU_SKIP_SETUP:-0}" = "1" ]; then
  printf '\n'; step "Next: $(bold 'uku auth login')  ·  $(bold 'uku setup agents')"
  exit 0
fi

if [ -r /dev/tty ] && [ -c /dev/tty ]; then
  printf '\n'
  printf '  %s ' "$(bold 'Sign in now? [Y/n]')"
  reply=""; read -r reply < /dev/tty || true
  case "$reply" in
    n|N|no|NO) printf '\n'; step "When ready: $(bold 'uku auth login')  ·  $(bold 'uku setup agents')" ;;
    *) "$TARGET" auth login < /dev/tty || true
       printf '\n'; "$TARGET" setup agents < /dev/tty || true ;;
  esac
else
  # non-interactive (CI / agent) — install the skill best-effort, print next steps
  UKU_SETUP_AGENT="${UKU_SETUP_AGENT:-auto}" "$TARGET" setup agents >/dev/null 2>&1 || true
  printf '\n'; step "Next: set $(dim 'UKU_API_KEY + UKU_COMPANY')  or run  $(bold 'uku auth login')"
fi

printf '\n  %s\n\n' "$(dim 'Docs: https://app.getuku.com/api/v3/docs · https://getuku.com/agents/')"
