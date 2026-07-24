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

## Before you open a PR

```sh
bash -n bin/uku && sh -n scripts/install.sh     # syntax
shellcheck bin/uku scripts/install.sh           # if installed
./bin/uku doctor                                # self-check
```

Test any change against a **sandbox account** (`uku auth login --account sandbox`)
before a real one — never rehearse a write on production books.

## Style

- Short, greppable, self-documenting. Explicit lookup tables over clever parsing.
- One user-facing behaviour per change; keep the surface small.
- Error messages say what went wrong *and how to fix it* — no apologies, no
  vagueness.
