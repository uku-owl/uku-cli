# uku — the Uku command-line client

A thin, dependency-light wrapper over the [Uku public API v3](https://app.getuku.com/api/v3/docs).
It gives terminals, scripts, CI, and coding agents (Claude Code, Cursor, Codex) a
native way to operate a firm's Uku data — within the exact permissions of the API
key you hand it.

> **Status:** v0.2.0 — MVP. Read + the essential writes, plus an `api` escape
> hatch to every endpoint. Built on the real API v3 (no invented endpoints).

## Install

```sh
curl -fsSL https://getuku.com/install-cli | sh
```

Installs a single self-contained script to a directory on your `PATH`
(`~/.local/bin` by default). The only runtime requirements are `curl` and `bash`;
[`jq`](https://jqlang.github.io/jq/) is used for pretty tables when present, but is
never required (`--json` always gives you raw JSON).

To install somewhere specific: `UKU_BIN_DIR=~/bin curl -fsSL https://getuku.com/install-cli | sh`

### Releases and channels

`main` is the development branch. A **git tag** is a release, and a tag cannot
change after it is published — which is what makes the checksum beside it worth
checking.

```sh
# default — the newest release, from its tag, checksum required
curl -fsSL https://getuku.com/install-cli | sh

# a specific release — same rules, your tag
UKU_VERSION=0.2.0 curl -fsSL https://getuku.com/install-cli | sh

# the rolling edge — whatever is on main right now, NOT verified
UKU_CHANNEL=main curl -fsSL https://getuku.com/install-cli | sh
```

The default and pinned paths **refuse to install** if the checksum published at
that tag is missing or does not match. The rolling channel checks nothing and
says so on every run — it exists for trying unreleased work, not for daily use.

A checksum anchored to a tag catches a swapped or truncated download and stops
`main` moving under you. It is **not** authenticity: the file and its checksum
come from the same repo. Signing is the next step and is not implemented —
[`SECURITY.md`](SECURITY.md) spells out exactly where the line is.

`uku update` and the once-a-day auto-update follow the release channel: they
notice a bump in `VERSION` and install the tag behind it, verified.

On a terminal the installer offers to sign you in and connect your coding agents
right away. Or run it yourself:

## Sign in

```sh
uku auth login      # prompts for your Company UUID + API key (Uku → Settings → API)
uku auth status     # confirms the key works, shows the account (key is masked)
uku auth logout
```

Credentials are stored per account at `~/.config/uku/profiles/<name>`, mode `0600`;
the key is never printed. In CI or an agent sandbox, skip `login` and pass
credentials as environment variables (they override the stored account):

```sh
export UKU_COMPANY="…company-uuid…"
export UKU_API_KEY="uku_live_…"
# or non-interactively persist an account:
printf '%s' "$KEY" | uku auth login --account ci --company <uuid> --key-stdin
```

## Accounts — one login, many companies

Uku lets one person hold several companies. Keep a **sandbox** beside your main
firm: rehearse a change (price edits, invoices) on the sandbox, then run the same
command against the real account.

```sh
uku auth login --account sandbox     # sign a second company in
uku account list                     # ● marks the active account
uku account use main                 # switch the active account
uku --account sandbox invoices list  # run one command against a specific account
```

## Connect your coding agents

```sh
uku setup agents    # installs a skill for Claude Code / Cursor + an AGENTS.md block
```

This teaches your agents the `uku` contract once — the commands, the JSON/exit-code
model, and above all the safety rules — so every future session knows the tool.

## Use it

```sh
uku clients list --q "acme" --limit 5
uku clients get <client_id>
uku tasks list --limit 10
uku time list
uku invoices list --status draft

# Writes are deliberate. Interactive → confirm; non-interactive → needs --yes.
uku invoices create --data @march.json --yes

# Escape hatch: any endpoint in the API, any method.
uku api GET  /api/v3/members --query limit=5
uku api POST /api/v3/tasks --data @task.json --yes
```

### Scoped keys — money has its own key

API keys are scoped **Read**, **Edit**, or **All**. Anything financial requires the
`All` scope explicitly, so a limited key literally cannot touch money — the API,
not this CLI, enforces it. Hand an agent a Read or Edit key and it can run the work
without ever being able to move money.

## Output & scripting

- `--json` prints the raw API JSON. It is the **default when stdout is not a TTY**,
  so pipes and agents get JSON automatically.
- With a TTY and `jq` installed, list commands print a compact table.

### Exit codes

| code | meaning |
|------|---------|
| `0`  | success |
| `1`  | usage error / unknown command |
| `2`  | not authenticated / credentials rejected |
| `3`  | the API returned an error status (4xx/5xx) |
| `4`  | a deliberate write was refused (no `--yes`, no TTY) |
| `5`  | network error, or rate limited (HTTP 429) |
| `6`  | conflict — someone else changed the record (HTTP 412). Re-read and re-apply. |

## Concurrency: version checks (If-Match / ETag)

Financial records — invoices, contracts and their rows, agreements, members,
monitors — are guarded so two people can't silently overwrite each other. A
guarded write must carry an `If-Match` header holding the `ETag` from the
resource's `GET`.

You do not have to manage this. If a write comes back **428**, the CLI fetches
the current ETag and re-sends the request **once**:

```sh
uku api POST /api/v3/contracts/41219/rows --data @row.json --yes
# 428 → re-sent once with If-Match from /api/v3/contracts/41219
```

Which resource's ETag applies depends on the write, so the CLI tries the most
specific `GET`able path first and walks up rather than following a hardcoded
table. Measured against the live API:

| Write | ETag the server accepts |
|---|---|
| `POST /contracts/{id}/rows` | the **parent**, `GET /contracts/{id}` — the collection `GET /contracts/{id}/rows` carries no ETag at all |
| `DELETE /contracts/{id}/rows/{row_id}` | the **row's own**, `GET /contracts/{id}/rows/{row_id}` |
| `POST /invoices/{id}/send`, `/mark-paid` | `GET /invoices/{id}` (the trailing verb is stripped) |

The ETag is the record's own `updated_at`, so adding or removing a contract row
does not change the parent contract's ETag, and neither does a no-op `PATCH`.

Assert a version yourself with `--if-match '<etag>'`. Then a 428 is **not**
healed — the value you chose is what the server rejected, and only you can fix it.

## Retry doctrine

The status code tells you whether the write happened. Treat them differently:

| Status | What happened | What to do |
|---|---|---|
| **428** `PRECONDITION_REQUIRED` | The write was refused for want of `If-Match`. **Nothing happened.** | Safe to re-send **once** with the ETag. The CLI does this for you. |
| **412** `STALE_WRITE` (exit `6`) | Someone else changed the record after you read it. **Nothing was written.** | **Stop.** Re-read, re-apply your change on top of the current values, write again. Never automatic — a blind retry overwrites their edit. |
| **429** rate limited (exit `5`) | For a write, the outcome is **unknown**. | **Never auto-retry a write.** `GET` to check whether it landed. The error says how many seconds until the window resets — wait, don't poll. |
| **5xx / timeout** | Outcome **unknown**. | Same as 429: `GET` first. |
| **409** domain conflict | The action isn't allowed right now (`*_LOCKED`, `TIMER_ALREADY_RUNNING`). | Re-sending the same request fails the same way. Change the request. |

**Reads are idempotent and may be retried.** A write is re-sent automatically in
exactly one case — a **428**, where the server refused it and nothing happened.
No other failed write is ever retried for you, because in no other case can the
CLI know whether it landed.

## Rate limits

Every response carries `X-RateLimit-Limit / Remaining / Reset / Tier`; reads and
writes are metered in separate buckets. The CLI reads them — there is no
hardcoded local budget — and remembers the latest per account under
`~/.config/uku` (mode `0600`). Before a write, if the last response said the
write budget was spent and the window hasn't turned over, it waits for `Reset`
rather than spending a 429 it could never safely retry. It waits at most
`UKU_RL_MAX_WAIT` seconds (default `60`) and refuses rather than hanging.

## Time entries — the one payload shape to avoid

Uku reads a time entry with a `start` and **no `end`** as a *running timer*. So
sending `duration` without `end` starts a timer instead of logging the work, and
fails with `409 TIMER_ALREADY_RUNNING` if one is already running. The CLI
refuses that payload **before** sending it. To log finished work, send `start`
and `end`. Send `start` alone only when you really do mean to start a timer.

## Dropping to curl

When `uku api` can't express something, get the auth headers instead of digging
them out of the profile file:

```sh
curl -K <(uku auth print-header) https://app.getuku.com/api/v3/health   # curl config form
eval "$(uku auth print-header --shell)"                                 # UKU_COMPANY + UKU_API_KEY
uku auth print-header --format plain                                    # "X-API-Key: …" lines
```

This prints a **live credential** on stdout — it warns you on stderr. Add
`--dry-run` to see the shape with the key masked.

## Environment

| var | purpose |
|-----|---------|
| `UKU_API_KEY`, `UKU_COMPANY` | credentials (override the stored file — ideal for CI/agents) |
| `UKU_BASE_URL` | override the API base (default `https://app.getuku.com`) |
| `UKU_BIN_DIR` | install location (installer) |
| `UKU_VERSION` | installer: pin a release tag (`0.2.0`), or `main` for the unverified rolling edge |
| `UKU_CHANNEL` | installer: `release` (default) or `main` (rolling, unverified) |
| `UKU_REQUIRE_CHECKSUM` | installer: `1` insists on a verified install; it is already the default, and it is refused outright on `UKU_CHANNEL=main` rather than silently ignored |
| `UKU_SKIP_PATH` | set to `1` so the installer leaves your shell rc files alone (sandboxed / CI installs) |
| `UKU_CONFIG_HOME` | credentials directory (default `~/.config/uku`) |
| `UKU_RL_MAX_WAIT` | longest the CLI will wait for a rate-limit window to reset (default `60`s; beyond it, it refuses instead of blocking) |
| `NO_COLOR` | disable colored output |

## Troubleshooting

```sh
uku doctor    # checks PATH, shadowing, curl/jq/bash, config perms, key validity, skill
```

**`uku` runs something else?** A shell function or alias named `uku` in your
`~/.zshrc` (or `~/.bashrc`) shadows the binary — shell functions win over `PATH`.
Rename the function, or call the CLI explicitly as `command uku`. `uku doctor`
and the installer both detect and warn about this.

## Documentation

- `uku --help` — the command surface · `uku help <command>` — a focused card
- `uku api --describe [resource]` — the API v3 endpoint map + required fields
- [`SECURITY.md`](SECURITY.md) — how credentials are protected + the scope model
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — development ground rules (bash 3.2, safety)
- API reference: <https://app.getuku.com/api/v3/docs> · agent guide: <https://getuku.com/agents/>

## What's next

- Official **MCP server** (chat assistants operate Uku with no glue code) — coming.
- More first-class subcommands as the API grows. Until then, `uku api` reaches
  every one of the 80+ v3 endpoints.

Docs: <https://app.getuku.com/api/v3/docs> · <https://getuku.com/agents/>
