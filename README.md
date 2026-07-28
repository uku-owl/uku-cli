# uku — the Uku command-line client

A thin, dependency-light wrapper over the [Uku public API v3](https://app.getuku.com/api/v3/docs).
It gives terminals, scripts, CI, and coding agents (Claude Code, Cursor, Codex) a
native way to operate a firm's Uku data — within the exact permissions of the API
key you hand it.

> **Status:** MVP. Read + the essential writes, plus an `api` escape
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

Singular and plural are the same command — `uku client get 41` is `uku clients get 41`.
The aliases are `client`, `task`, `invoice`, `member`, `product`, `project`, `contract`,
and they are one dispatch path, not a copy that can drift.

## Finding a record when you don't have its id

Nobody has ids in their head. Three ways in, and none of them guesses.

```sh
uku clients get "Acme Ltd"                # a name
uku clients get 41                        # an id — no lookup at all
uku clients get 'https://app.getuku.com/…/41'   # a URL you pasted from the browser
uku tasks list --client "Acme Ltd"        # the same, as a filter
uku search "acme"                         # when you're not sure what you're after
```

### A name

The CLI sends the same `--q` a list already takes, **to the endpoint the command
already names** — no new endpoint, no new parameter — and then matches what came
back: exact first (case-insensitive for ASCII), then a unique substring.

* **exactly one match** → it is used, and the record and its id are printed on
  stderr *before* anything else happens. You always see what was chosen.
* **several matches** → **refused**, with the candidates and their ids. This is the
  same doctrine as `--skip-existing`, for the same measured reason: in a firm
  dozens of records legitimately share a name, and a title that looked unique
  turned out to have 18 records. Guessing between them is the one thing a tool
  that writes invoices must never do.
* **no match** → refused, with whatever the query *did* bring back.
* **more records than the lookup could see** → **refused**. It reads at most 100 and
  compares that against the `meta.total` the API reports. One row out of a stated
  4000 is the first page, not a unique match — and a server that ignores `q`
  altogether lands exactly here rather than on the wrong record.

The argument is trimmed before anything looks at it; an empty or whitespace-only
reference names nothing and is refused, and one longer than 200 characters is
refused as a mistake rather than percent-encoded into a query string.

Resolving costs one request, and only when it has to: on a **read**, an argument
that already looks like an id goes straight through, and nothing is ever resolved
inside a `--batch` line. It needs `jq` (it compares a field exactly); without `jq`
it refuses rather than guess.

#### When the argument is both — `--by-id` / `--by-name`

`12345678`, `CAFE-1` and `DECADE` are id-shaped **and** perfectly good names; a
Nordic registry code is how a firm refers to a client every day. The two readings
are treated differently, on purpose:

* on a **read**, an id-shaped argument is taken as an id, with no request at all. If
  it was really a name, the worst case is a 404 and you try again.
* on a **write**, it is *also* looked up as a name — one extra GET, run *after* the
  `--yes` confirm so a refused write still sends nothing. If a record's name is that
  exact string, the write is **refused**: both readings are real, and picking one is
  how the wrong ledger gets written. Writes are rare and deliberate; a request is a
  fair price for not guessing on one.

```sh
uku clients patch 12345678 --by-id   --data @f.json --yes   # the record with that id
uku clients patch 12345678 --by-name --data @f.json --yes   # the record with that name
```

Without `jq` the collision cannot be checked, so an id-shaped write is refused until
`--by-id` says which was meant.

Which resources have a name to match is not a guess either — it is the field each
list command already declares: **clients** (`name`), **tasks** (`title`),
**members**, **products**, **projects** (`name`). An **invoice**, a **contract** and
a **time entry** have no name field, so there an id or a URL is the only way in.

### A URL you pasted

The host must match the base URL this account uses; a link from anywhere else is
refused and **nothing is sent**. The id is simply the last id-shaped segment — the
command already names the resource, so the CLI needs to know nothing about the web
app's routes (and deliberately encodes none of them).

### `--client <name|id>`

Resolves the name once, then sends `client_id=<id>` — the same query pair you would
type by hand. It is accepted only where the records carry a client_id (tasks, time,
invoices, contracts, projects); anywhere else it is a usage error rather than a
filter that silently does nothing. On a write or a batch it is refused: a batch line
carries its own fields, and resolving one into a body would be inventing data.

**And then it checks that the API actually did it.** That `client_id` is honoured as
a filter is the one fact in this feature that could not be verified from the repo —
so the CLI does not take it on trust. Every response is measured against the request:
if a returned row carries a `client_id` that differs from the one asked for, the
endpoint ignored the parameter, and the command **fails with exit 3** saying so
rather than handing back an unfiltered list that looks like an answer. Be exact
about what that proves: the API honoured `client_id` **for the id it was sent**. It
cannot prove that id is the client you named — that is what the resolution line on
stderr (`→ client 41 — Acme Ltd`) is for, and it is printed before the request goes
out precisely so you can check it. A row with no
`client_id` field, or a null one, proves nothing and never trips it. The comparison
needs `jq`, so `--client` refuses up front without it — the same rule name
resolution follows. The day that endpoint's behaviour changes, you are told.

### `uku search <query>`

**Not a server-side global search.** The API offers none this CLI can verify, and
inventing an endpoint is how a tool starts lying. `uku search` is the loop you would
otherwise write: the same `--q`, run once against each list endpoint that has a name
field — clients, tasks, members, products, projects. One request each, no
server-side join, no ranking across resources. `--limit` is per endpoint.

If an endpoint errors it is reported as **failed**, never folded into "0 results" —
"no such client" when nobody actually looked is the worst thing a search can say.
Exit 3 when any endpoint failed, 0 when they all answered.

```sh
uku search "acme" --limit 3
uku search "acme" --json | jq '.resources[] | select(.count > 0)'
```

## Creating many records — `--batch`

One JSON object per line, one confirm for the whole file, and a ledger that makes
the run restartable.

```sh
uku tasks create   --batch @tasks.jsonl --yes
uku clients create --batch @clients.jsonl --yes
uku api POST /api/v3/tasks --batch @tasks.jsonl --yes
cat tasks.jsonl | uku tasks create --batch @- --yes
```

Blank lines and `#` comments are skipped; a final line without a newline is fine.
A malformed line fails **by itself** and never aborts the run.

**stdout is JSONL — one result per input line**, so it pipes and greps. Everything
human (progress, the summary) goes to stderr.

```sh
uku tasks create --batch @tasks.jsonl --yes | jq -r 'select(.outcome=="failed")'
{"line":1,"outcome":"created","path":"/api/v3/tasks","id":"19639631","status":201,"code":null,"message":null}
{"line":2,"outcome":"skipped","path":"/api/v3/tasks","id":"19639632","status":null,"code":"LEDGER_HIT","message":"already created by run liveresume"}
{"line":3,"outcome":"failed","path":"/api/v3/tasks","id":null,"status":422,"code":"VALIDATION_ERROR","message":"…"}
```

### The ledger — why `--resume` can be trusted

Every created line is recorded as a **hash of its content** plus the id the server
returned, appended to `~/.config/uku/batches/<run-id>` the moment the create is
confirmed — one open-write-close per line, never buffered. Kill the run at any
point and the ledger is complete up to the last record that actually landed.

```sh
uku tasks create --batch @tasks.jsonl --yes       # interrupted at line 6 of 8
uku tasks create --batch @tasks.jsonl --resume --yes
```

Lines already created are skipped; the rest are created; **nothing is duplicated**.
The run-id is derived from the target plus a hash of the file, so `--resume` works
without your having remembered anything (`--run-id NAME` overrides it).

The ledger stores a **hash, never the line** — no client data is written to disk.

`uku batch list` · `uku batch show <run-id>` show what a previous run did.

**One line can be caught in flight**: the request left, the reply never came. That
line is recorded as *sent*, not created, and `--resume` **refuses to re-send it**
and says so — the CLI cannot know whether it landed, and guessing would duplicate a
record. Check that one, then `--retry-unknown` to send it. This is the same doctrine
the CLI already applies to a `429` or a `5xx` on a write.

### `--skip-existing --match-on <field>` — read this before you use it

It queries the API for a record whose field equals this line's value and skips the
line if it finds exactly one.

**It is fragile, and the fragility is not hypothetical.** In an accounting firm
dozens of records legitimately share a title — every client has a
"Käibedeklaratsioon". Run against a real firm's data while this was being built, a
title that looked unique in a 200-row sample turned out to have 18 records, and
"Enter Payroll" matched every row the query returned.

So when more than one record matches, the CLI **refuses that line**
(`AMBIGUOUS_MATCH`) and records why, rather than silently picking one.

> **The ledger, not `--match-on`, is the trustworthy path to idempotency.** Use
> `--match-on` only against a field that is genuinely unique in your firm, and only
> for records this CLI did not create.

### Batch write discipline

| | |
|---|---|
| `--yes` | confirms the batch **once** (line count, target, account) — not once per line. Without a TTY and without `--yes` the batch is refused (exit `4`). |
| a failed line | is recorded and the run **continues**. `--stop-on-error` halts instead. |
| `412` | fails that line and is **never** auto-retried. |
| `429` | never becomes a hot loop: the run paces itself through the same limiter as every other write (the write budget is 30/min). If the wait would exceed `UKU_RL_MAX_WAIT` it stops cleanly, tells you when the window resets, and leaves a resumable ledger. |
| `--dry-run` | validates every line, reports what *would* happen — including which lines the ledger would skip — and sends no write. |
| exit | `0` all good · `3` some line failed · `5` stopped on the rate limit · `4` refused. |

Full reference: `uku help batch`.

### Scoped keys — money has its own key

API keys are scoped **Read**, **Edit**, or **All**. Anything financial requires the
`All` scope explicitly, so a limited key literally cannot touch money — the API,
not this CLI, enforces it. Hand an agent a Read or Edit key and it can run the work
without ever being able to move money.

## Output & scripting

- `--json` prints the raw API JSON. It is the **default when stdout is not a TTY**,
  so pipes and agents get JSON automatically. It is the API's body, and `.data`
  means what the API says it means. **One flag changes that, and only that one:**
  `--fields` reduces each row in `.data` to the keys you named and re-serialises
  the result through `jq` (which also pretty-prints it). Ask for `--fields` and you
  are asking for a reshaped `.data`; leave it off and the body is the API's.
- `--agent` is the second channel — one envelope, for a program that wants the
  CLI's own reading of what just happened. See below. **A `--batch` run is the one
  exception**: it stays JSONL, one object per input line, under `--agent` too.
- With a TTY and `jq` installed, list commands print a compact table.

### `--agent` — one envelope, for a program

`--json` is the raw body and stays that way. When you want the CLI's summary and
its idea of what to do next, ask for `--agent` instead. The two are alternatives;
passing both is a usage error.

```sh
uku clients list --limit 2 --agent
```
```json
{"ok":true,
 "data":[{"id":41,"name":"Acme"},{"id":42,"name":"Byrd"}],
 "meta":{"total":2,"offset":0,"limit":2},
 "summary":"2 clients",
 "breadcrumbs":[{"cmd":"uku clients get 41","why":"that client in full"}]}
```

`data` and `meta` are spliced out of the API's own body, so `.data` means the same
thing it means under `--json` — the same caveat and no other: with `--fields`, rows
are projected and re-serialised through `jq` before they get here.

A failure is the same envelope, inverted, and **the exit code is unchanged**:

```sh
uku invoices create --data @march.json --yes --agent; echo "exit $?"
```
```json
{"ok":false,
 "error":"HTTP 403 — this key can't perform that action: financial actions need an All-scope key.",
 "code":"auth",
 "hint":"this needs an All-scope key — create one in Uku (Settings, API), then sign in again with: uku auth login"}
```
```
exit 2
```

`code` is the stable name of the exit status (`ok` `usage` `auth` `api` `confirm`
`network` `conflict`), so you can branch on either.

**A `--batch` run has no envelope, in either direction.** Its stdout stays JSONL —
one `{line, outcome, id, status, code, message}` object per input line — under
`--agent` as well, because one envelope cannot describe N independent outcomes.
That includes failure: a run with failed lines exits **3** and emits no
`{"ok":false}` object at all. Parse the lines.

**Breadcrumbs** are the commands you most plausibly want next, with the real ids
already filled in — the first row of a list, the id of the record you just
created. On a terminal they are a dim `Next:` footer; under `--agent` they are the
array above. `--no-hints`, `--quiet` and `--json` all suppress them. Every command
a breadcrumb can name is checked against the CLI's declared surface at build time,
so it can never point at something that does not exist. That is all the check
proves, and it is worth saying plainly: a breadcrumb can still be a **write** —
`uku clients get 41` offers `uku clients patch 41` as the next step. Read one
before you run it; the guarantee is that the command exists, not that you want it.

**Hints** do the same job for failures: a second line on stderr saying what to run
next, and the `hint` field above. Where no honest next step exists there is none.

### `uku --help --agent` — the CLI describing itself

```sh
uku --help --agent        # the whole tree
uku time --help --agent   # one command
```
```json
{"command":"time","aliases":[],"subcommands":["list","get","create"],
 "flags":["--limit","--data","--batch", "…"],
 "args":["get <id>"],
 "notes":["there is no `patch` subcommand here — use `uku api PATCH /api/v3/time-entries/<id>`",
          "`start` with no `end` is a RUNNING TIMER, not logged work — the CLI refuses duration-without-end before sending"]}
```

The `notes` are the agent-facing gotchas — mostly the negative kind, which is the
knowledge that stops an agent guessing. The root form adds `global_flags` and
`exit_codes`. This is how an agent discovers the CLI without a human pasting the
help text into its context.

### Exit codes

| code | meaning |
|------|---------|
| `0`  | success |
| `1`  | usage error / unknown command |
| `2`  | not authenticated / credentials rejected |
| `3`  | the API returned an error status (4xx/5xx) |
| `4`  | a deliberate write was refused (no `--yes`, no TTY) |
| `5`  | network error, or rate limited (HTTP 429); a `--batch` stopped on the rate limit |
| `6`  | conflict — someone else changed the record (HTTP 412). Re-read and re-apply. |

## Concurrency: version checks (If-Match / ETag)

Financial records — invoices, contracts and their rows, agreements, members,
monitors — are guarded so two people can't silently overwrite each other. A
guarded write must carry an `If-Match` header holding the `ETag` from the
resource's `GET`.

In most cases you do not have to manage this. If a write comes back **428**, the
CLI fetches the current ETag and re-sends the request **once**:

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

**Where the heal does not apply: a 428 on a collection `POST`.** Every candidate
is derived from an id in the path, so `POST /api/v3/tasks` — no id anywhere —
has no resource to read an ETag from. Such a 428 is reported straight through
(exit `3`) and you supply the version yourself with `--if-match '<etag>'`. The
heal covers the guarded writes that name a record: `PATCH /contracts/{id}`,
`POST /contracts/{id}/rows`, `DELETE …/{id}`, `POST /invoices/{id}/send`.

The ETag is the record's own `updated_at`, so adding or removing a contract row
does not change the parent contract's ETag, and neither does a no-op `PATCH`.

Assert a version yourself with `--if-match '<etag>'`. Then a 428 is **not**
healed — the value you chose is what the server rejected, and only you can fix it.

## Retry doctrine

The status code tells you whether the write happened. Treat them differently:

| Status | What happened | What to do |
|---|---|---|
| **428** `PRECONDITION_REQUIRED` | The write was refused for want of `If-Match`. **Nothing happened.** | Safe to re-send **once** with the ETag. The CLI does this for you when the path names a record; on a collection `POST` there is no ETag to fetch, so pass `--if-match` yourself. |
| **412** `STALE_WRITE` (exit `6`) | Someone else changed the record after you read it. **Nothing was written.** | **Stop.** Re-read, re-apply your change on top of the current values, write again. Never automatic — a blind retry overwrites their edit. |
| **429** rate limited (exit `5`) | For a write, the outcome is **unknown**. | **Never auto-retry a write.** `GET` to check whether it landed. The error says how many seconds until the window resets — wait, don't poll. |
| **5xx / timeout** | Outcome **unknown**. | Same as 429: `GET` first. |
| **409** domain conflict | The action isn't allowed right now (`*_LOCKED`, `TIMER_ALREADY_RUNNING`). | Re-sending the same request fails the same way. Change the request. |

**Reads are idempotent and may be retried** — once, and only when the connection
itself failed; an HTTP status is never a reason to re-send. A write is re-sent
automatically in exactly one case — a **428** on a path that names a record,
where the server refused it and nothing happened.
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
