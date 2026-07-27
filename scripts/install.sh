#!/bin/sh
# install.sh — install the Uku CLI (`uku`).
#
#   curl -fsSL https://getuku.com/install-cli | sh
#
# Downloads a single self-contained script to a directory on your PATH, adds
# that directory to PATH, and — when run in a terminal — offers to sign you in.
# No compilation, no dependencies beyond `curl` (and `bash`, which `uku` uses).
#
# CHANNELS. `main` is where development happens; a git tag is a release.
#   release (default)  Reads main/VERSION as the pointer to the latest release,
#                      then installs the immutable tag v<version> and REQUIRES a
#                      matching bin/uku.sha256 published at that same tag.
#   pinned             UKU_VERSION=x.y.z — same rules, your chosen tag.
#   rolling (opt-in)   UKU_CHANNEL=main (or UKU_VERSION=main) — whatever is on
#                      main right now, with NO checksum verification at all.
#
# What the checksum does and does not prove: anchored to a tag it detects a
# swapped, truncated or corrupted download and stops main from moving under you.
# It is NOT authenticity — the artefact and its checksum come from the same repo,
# so anyone who could publish one could publish the other. See SECURITY.md.
#
# Options (via environment):
#   UKU_BIN_DIR       Where to install (default: ~/.local/bin, or ~/bin if on PATH)
#   UKU_VERSION       Pin a release tag (e.g. 0.2.0), or `main` for the rolling edge
#   UKU_CHANNEL       release (default) | main  — `main` is the unverified rolling edge
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
CHANNEL="${UKU_CHANNEL:-release}"
# `UKU_VERSION=main` is the obvious thing to type for "give me main"; accept it
# as an alias for the rolling channel rather than looking for a tag named vmain.
case "$VERSION" in main|edge) CHANNEL="main"; VERSION="" ;; esac
case "$CHANNEL" in
  release|main) : ;;
  *) printf '  UKU_CHANNEL must be `release` or `main` (got: %s)\n' "$CHANNEL" >&2; exit 1 ;;
esac

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

# ── resolve the channel → the exact ref we will install ───────────────
# REQUIRE_SUM=1 means: no matching checksum, no install. It is on for every
# path that resolves to a tag, because a tag is immutable — the checksum
# committed alongside it describes that exact file forever. It is off for the
# rolling channel, where a checksum would describe whichever commit main sat on
# when it was last written and would fail loudly for no security gain.
REQUIRE_SUM=1
if [ "$CHANNEL" = "main" ]; then
  REF="main"; REQUIRE_SUM=0
elif [ -n "$VERSION" ]; then
  case "$VERSION" in
    v*) err "UKU_VERSION takes the bare number (e.g. 0.2.0), not the tag name — the leading 'v' is added for you." ;;
    *[!0-9.]*) err "UKU_VERSION='$VERSION' is not a version number (expected x.y.z)." ;;
  esac
  REF="v$VERSION"
else
  # main/VERSION is the release pointer: "the newest tag we have published".
  # It is deliberately NOT "what is on main" — bin/uku on main may be ahead.
  step "Resolving the latest release…"
  VERSION="$(DL "$DL_BASE/main/VERSION" | tr -d '[:space:]')" \
    || err "could not read the release pointer at $DL_BASE/main/VERSION"
  [ -n "$VERSION" ] || err "the release pointer at $DL_BASE/main/VERSION is empty."
  case "$VERSION" in
    ''|*[!0-9.]*) err "the release pointer returned '$VERSION', which is not a version. Refusing to guess." ;;
  esac
  REF="v$VERSION"
fi
SRC="$DL_BASE/$REF/bin/uku"

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
if [ "$REF" = "main" ]; then step "Downloading uku from $(bold 'main')…"
else step "Downloading uku $(bold "v$VERSION") $(dim "(tag $REF)")…"; fi
DL "$SRC" > "$TMP" || err "download failed from $SRC"
# These two catch an error page or a truncated body — they are sanity checks on
# the shape of the download, not integrity checks. The checksum below is the
# only thing here that can tell you the bytes are the ones we published.
head -n 1 "$TMP" | grep -q '^#!' || err "downloaded file is not a script (an error page?). Aborting."
grep -q 'the Uku command-line client' "$TMP" || err "downloaded file doesn't look like uku. Aborting."

# ── verify checksum (integrity — this holds an API key) ───────────────
SHA_CMD=""
if command -v sha256sum >/dev/null 2>&1; then SHA_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SHA_CMD="shasum -a 256"; fi

if [ "$REQUIRE_SUM" = "0" ] && [ "${UKU_REQUIRE_CHECKSUM:-0}" = "1" ]; then
  err "UKU_REQUIRE_CHECKSUM=1 cannot be satisfied on the rolling channel — main publishes no per-commit checksum. Drop UKU_CHANNEL=main to install the latest verified release."
fi

if [ "$REQUIRE_SUM" = "1" ]; then
  [ -n "$SHA_CMD" ] || err "neither sha256sum nor shasum is available, so the download cannot be verified — refusing to install uku v$VERSION unverified. Install coreutils (or Perl's shasum), or opt into the unverified rolling channel with UKU_CHANNEL=main."
  DL "$SRC.sha256" > "$SUM" 2>/dev/null && [ -s "$SUM" ] \
    || err "no checksum published at $SRC.sha256 — refusing to install uku v$VERSION unverified. (An attacker who could swap the binary could also simply omit the checksum, so a missing one is treated as a failure, never as 'skip the check'.)"
  want="$(cut -d' ' -f1 < "$SUM" | tr -d '[:space:]')"
  got="$($SHA_CMD < "$TMP" | cut -d' ' -f1)"
  if [ "$want" != "$got" ]; then
    printf '\n'; err "$(red 'Checksum mismatch — do NOT run this file.')
    expected $want
    got      $got
  This is a failure worth reporting: security@getuku.com"
  fi
  info "Checksum verified  $(dim "sha256 $(printf '%s' "$got" | cut -c1-12)… · tag $REF")"
else
  # The rolling channel is unverified on purpose, and we say so rather than
  # implying otherwise. We do not even fetch a checksum here: any bin/uku.sha256
  # sitting on main belongs to the last release commit, so on a moved main it
  # would mismatch the current file and raise a security alarm that means
  # nothing. Verification lives at tags, where the pair is immutable.
  printf '\n'
  step "$(red '! UNVERIFIED INSTALL')  $(bold 'UKU_CHANNEL=main') $(dim '— installing whatever is on main right now.')"
  step "  $(dim 'No checksum is checked. main is the development branch: it can carry unreleased or half-finished work.')"
  step "  $(dim 'For the latest verified release, re-run without UKU_CHANNEL/UKU_VERSION.')"
  step "$(dim 'Source:') $(bold 'github.com/uku-owl/uku-cli') $(dim '(public, over HTTPS) — read it before you run it.')"
  printf '\n'
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
