#!/bin/sh
# release.sh — cut a release of the Uku CLI.
#
#   scripts/release.sh 0.3.0            cut it
#   scripts/release.sh 0.3.0 --dry-run  show exactly what would happen, change nothing
#
# A release is a git tag, and a tag is immutable. That is the whole point: the
# checksum we publish has to live in the commit the tag points at, or it would
# describe a file that can still change. So this script writes the version into
# both places, computes the checksum of the final file, commits all three, and
# tags that commit.
#
# It never pushes. Releasing and publishing are separate decisions, and the
# second one is a human's. The push commands are printed at the end.
#
# Options:
#   --dry-run          Print the plan; touch nothing (no edits, no commit, no tag)
#   --branch <name>    Branch this release must be cut from (default: main)
set -eu

usage() {
  cat <<'EOF'
usage: scripts/release.sh <version> [--dry-run] [--branch <name>]

  <version>        x.y.z — digits and dots only (auto_update ignores anything else)
  --dry-run        show the plan, change nothing
  --branch <name>  the branch this release must be cut from (default: main)

Writes <version> into bin/uku (UKU_VERSION) and VERSION, writes bin/uku.sha256,
commits the three, and creates the annotated tag v<version>. Never pushes.
EOF
}

VERSION=""; DRY=0; WANT_BRANCH="main"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    --branch) shift; [ $# -gt 0 ] || { usage >&2; exit 1; }; WANT_BRANCH="$1" ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'unknown flag: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
    *) [ -z "$VERSION" ] || { printf 'one version at a time (got %s and %s)\n' "$VERSION" "$1" >&2; exit 1; }; VERSION="$1" ;;
  esac
  shift
done

# ── output helpers ────────────────────────────────────────────────────
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  green() { printf '\033[32m%s\033[0m' "$1"; }; bold() { printf '\033[1m%s\033[0m' "$1"; }
  red()   { printf '\033[31m%s\033[0m' "$1"; }; dim()  { printf '\033[2m%s\033[0m' "$1"; }
else
  green() { printf '%s' "$1"; }; bold() { printf '%s' "$1"; }; red() { printf '%s' "$1"; }; dim() { printf '%s' "$1"; }
fi
info() { printf '  %s %s\n' "$(green '✓')" "$1"; }
step() { printf '  %s %s\n' "$(bold '→')" "$1"; }
err()  { printf '  %s %s\n' "$(red '✗ ERROR:')" "$1" >&2; exit 1; }

[ -n "$VERSION" ] || { usage >&2; exit 1; }
case "$VERSION" in
  v*) err "pass the bare number (0.3.0), not the tag name — the 'v' is added for you." ;;
  *[!0-9.]*) err "'$VERSION' is not a version number. auto_update ignores anything that is not digits and dots, so a client would never see this release." ;;
  *.*.*) : ;;
  *) err "'$VERSION' is not x.y.z." ;;
esac

# ── run from the repo root, whatever directory you invoked from ───────
command -v git >/dev/null 2>&1 || err "git is required."
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || err "not inside a git repository."
cd "$ROOT"
[ -f bin/uku ] && [ -f VERSION ] || err "this does not look like the uku-cli repo (no bin/uku + VERSION at $ROOT)."

printf '\n  %s\n  %s\n\n' "$(bold "uku release v$VERSION")" "$(dim "$ROOT")"
[ "$DRY" = "1" ] && step "$(bold 'DRY RUN') $(dim '— nothing will be written, committed or tagged.')"

# ── refuse to release from the wrong place ────────────────────────────
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'HEAD')"
[ "$BRANCH" = "$WANT_BRANCH" ] || err "on branch '$BRANCH', but a release must be cut from '$WANT_BRANCH'.
    Switch branch, or state the release branch deliberately:  scripts/release.sh $VERSION --branch $BRANCH"
info "on branch $(bold "$BRANCH")"

# A dirty tree means the tag would not describe what you tested, and the
# checksum would be computed over a file nobody else has.
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  printf '\n'; git status --short; printf '\n'
  err "working tree is not clean. Commit or stash first — a tag must describe exactly what is in the repo."
fi
info "working tree clean"

git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null 2>&1 \
  && err "tag v$VERSION already exists. Tags are immutable on purpose — pick the next number."
info "tag v$VERSION is free"

# ── never go backwards ────────────────────────────────────────────────
CUR="$(tr -d '[:space:]' < VERSION)"
# _ver_ge A B — true when dotted-numeric A is >= B (POSIX sh, no arrays).
_ver_ge() {
  a="$1"; b="$2"
  while [ -n "$a$b" ]; do
    x="${a%%.*}"; y="${b%%.*}"
    case "$x" in ''|*[!0-9]*) x=0 ;; esac
    case "$y" in ''|*[!0-9]*) y=0 ;; esac
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
    case "$a" in *.*) a="${a#*.}" ;; *) a="" ;; esac
    case "$b" in *.*) b="${b#*.}" ;; *) b="" ;; esac
  done
  return 0
}
_ver_ge "$VERSION" "$CUR" \
  || err "v$VERSION is older than the current release pointer ($CUR). Clients only ever move forward, so a lower number would reach nobody."
info "$(dim "release pointer $CUR → ") $(bold "$VERSION")"

# ── the checksum tool is not optional here ────────────────────────────
if command -v sha256sum >/dev/null 2>&1; then SHA_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SHA_CMD="shasum -a 256"
else err "neither sha256sum nor shasum found — a release without a checksum cannot be installed by the default channel."; fi

# ── the one line in bin/uku that carries the version ──────────────────
grep -q '^UKU_VERSION="[0-9.]*"$' bin/uku \
  || err "cannot find the UKU_VERSION line in bin/uku (expected: UKU_VERSION=\"x.y.z\" at the start of a line). Fix bin/uku or this script — do not release blind."
BINV="$(sed -n 's/^UKU_VERSION="\([0-9.]*\)"$/\1/p' bin/uku)"

step "bin/uku      UKU_VERSION $(dim "$BINV") → $(bold "$VERSION")"
step "VERSION      $(dim "$CUR") → $(bold "$VERSION")"
step "bin/uku.sha256   sha256 of the released bin/uku, as '<hash>  bin/uku'"
step "commit + annotated tag $(bold "v$VERSION")"

if [ "$DRY" = "1" ]; then
  printf '\n'
  # Show the real checksum the release would carry, computed on a copy, so a
  # dry run answers "what would ship" without writing anything.
  TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
  sed "s/^UKU_VERSION=\"[0-9.]*\"$/UKU_VERSION=\"$VERSION\"/" bin/uku > "$TMP"
  info "would publish sha256 $(bold "$($SHA_CMD < "$TMP" | cut -d' ' -f1)")  bin/uku"
  printf '\n'
  info "$(bold 'Dry run complete — nothing was changed.')"
  printf '\n'
  exit 0
fi

# ── write ─────────────────────────────────────────────────────────────
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
sed "s/^UKU_VERSION=\"[0-9.]*\"$/UKU_VERSION=\"$VERSION\"/" bin/uku > "$TMP"
cat "$TMP" > bin/uku          # keep the original inode + mode (0755)
rm -f "$TMP"; trap - EXIT
printf '%s\n' "$VERSION" > VERSION

# Order matters: the checksum must describe the FINAL bin/uku, version line
# included. Written in the `<hash>  <path>` form the installer's
# `cut -d' ' -f1` already parses (and `shasum -c` accepts).
HASH="$($SHA_CMD < bin/uku | cut -d' ' -f1)"
printf '%s  bin/uku\n' "$HASH" > bin/uku.sha256

if command -v bash >/dev/null 2>&1; then
  bash -n bin/uku || err "bin/uku does not parse after the version edit — nothing has been committed. Inspect the diff."
fi
[ "$(sed -n 's/^UKU_VERSION="\([0-9.]*\)"$/\1/p' bin/uku)" = "$VERSION" ] \
  || err "the UKU_VERSION edit did not take — nothing has been committed."

info "bin/uku, VERSION → $VERSION"
info "bin/uku.sha256 → $(dim "$HASH")"

# ── commit + tag ──────────────────────────────────────────────────────
git add bin/uku VERSION bin/uku.sha256
git commit -q -m "release: v$VERSION

bin/uku and VERSION both say $VERSION, and bin/uku.sha256 describes this exact
file. The tag makes the three immutable, which is what lets the installer treat
the checksum as meaningful."
info "committed $(dim "$(git rev-parse --short HEAD)")"

git tag -a "v$VERSION" -m "uku v$VERSION"
info "tagged $(bold "v$VERSION")"

# ── hand back to the human ────────────────────────────────────────────
cat <<EOF

  $(bold 'Nothing has been pushed.') Publish it yourself, tag first:

    git push origin v$VERSION
    git push origin $BRANCH

  That order is not cosmetic. The installer reads main/VERSION and then fetches
  the matching tag. Push the branch first and, for the seconds or minutes until
  the tag lands, every install and every auto-update resolves $VERSION and gets
  a 404. Push the tag first and the pointer only moves once the artefact exists.

  Verify once it is up:
    curl -fsS https://raw.githubusercontent.com/uku-owl/uku-cli/v$VERSION/bin/uku.sha256
    curl -fsSL https://getuku.com/install-cli | sh

EOF
