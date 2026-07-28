# Contributing

Thanks for helping improve the Uku CLI.

## What it is

A single, dependency-light POSIX-friendly **bash** script (`bin/uku`) over the
Uku public API v3, plus a POSIX **sh** installer (`scripts/install.sh`). No build
step, no compilation — the script *is* the tool.

## Ground rules

- **Bash 3.2 compatible.** macOS still ships bash 3.2; no associative arrays, no
  `mapfile`/`readarray`, guard array expansions (`"${arr[@]+"${arr[@]}"}"`).
- **`set -euo pipefail` throughout.** Watch the foot-guns: a function must not end
  on a failing test (add `return 0`); never set a needed global inside `$( … )`
  (a subshell swallows it — see the `do_request`/`REPLY_*` pattern).
- **No invented API.** Endpoints, fields, scopes and limits must mirror the live
  API (`https://app.getuku.com/api/v3/openapi.json`). If unsure, link the spec.
- **Safety is not optional.** Keys never on argv or in logs; writes stay
  deliberate; money stays behind the All scope. Don't weaken these.
- **`jq` is optional.** Pretty tables use it when present; `--json` (the default
  off a TTY) must always work without it.
- **Portable output.** Respect `NO_COLOR`; degrade gracefully when `column`/`jq`
  are missing.

## Before you push — `bin/ci` is mandatory

```sh
bin/ci      # syntax · bash 3.2 · surface · drift · tests. Non-zero on any failure.
```

Run it before every push and before opening a PR. It is the whole gate, and it
is the same command a human and an agent run. Optional extras: `shellcheck
bin/uku scripts/*.sh`, `./bin/uku doctor`.

### The surface gate (why `bin/ci` fails on a doc change)

The agent-facing contract is prose — `README.md`, `uku --help`, and the skill
`uku setup agents` installs — and prose drifts from code silently. So the
command surface is **declared** in one table in `bin/uku` (`_surface_table`),
`uku --dump-surface` prints it one fact per line, and that output is committed
as `.surface`.

- **New surface** → `scripts/check-surface.sh --update`, and commit `.surface`
  with the change. Cheap, but never accidental: the diff is the review.
- **Removed surface** → paste the exact `.surface` line into
  `.surface-breaking` under a dated comment, then `--update`. That file is the
  changelog of everything we have taken away, and an entry only counts while
  the line is genuinely gone.
- **Docs may not promise fiction, and the table may not hide surface.**
  `scripts/check-drift.sh` checks both directions, including by *executing*
  every declared command against the real dispatcher. Deliberately hidden
  surface goes in `.surface-internal` with a reason.

Adding a command means: the `case` label, the `cmd_*` function, a row in the
table, `--update`, and a line in `usage()` — the gate names whichever you
forgot.

Test any change against a **sandbox account** (`uku auth login --account sandbox`)
before a real one — never rehearse a write on production books.

## Releasing

`main` is the development channel; a **git tag** is a release. Users install the
tag, not `main`, and the installer refuses a tag whose `bin/uku.sha256` is
missing or does not match.

```sh
scripts/release.sh 0.3.0 --dry-run   # show the plan and the checksum that would ship
scripts/release.sh 0.3.0             # bump both files, write the checksum, commit, tag
git push origin v0.3.0               # TAG FIRST — see below
git push origin main
```

Three things follow from that, and they bite if you forget them:

- **`VERSION` is the release pointer, not a copy of `UKU_VERSION`.** `VERSION`
  means "the newest tag we have published"; `UKU_VERSION` in `bin/uku` means
  "what this file is". Between releases the file legitimately runs **ahead** —
  bumping `UKU_VERSION` on `main` does not ship anything. `uku doctor` enforces
  the rule that actually matters: `UKU_VERSION` must never be *behind* `VERSION`,
  or every client chases a number it can never reach and re-installs daily.
- **Tag before branch.** The installer reads `main/VERSION` and then fetches the
  matching tag. Push the branch first and, until the tag lands, every install
  and auto-update resolves the new number and gets a 404.
- **`bin/uku.sha256` on `main` is a release artefact and goes stale there.** It
  describes `bin/uku` as of the last release commit, so once `main` moves on it
  no longer matches the `main` copy. That is expected and harmless: it is only
  ever read from a tag. The rolling channel (`UKU_CHANNEL=main`) deliberately
  does not fetch it, so a stale file cannot raise a false alarm. Never hand-edit
  it — `scripts/release.sh` owns that file.

Signing (minisign/cosign) is the next step and is **not** implemented; do not
describe the checksum as authenticity anywhere in the docs. See `SECURITY.md`.

## Style

- Short, greppable, self-documenting. Explicit lookup tables over clever parsing.
- One user-facing behaviour per change; keep the surface small.
- Error messages say what went wrong *and how to fix it* — no apologies, no
  vagueness.
