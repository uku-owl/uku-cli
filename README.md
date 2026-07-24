# uku — the Uku command-line client

A thin, dependency-light wrapper over the [Uku public API v3](https://app.getuku.com/api/v3/docs).
It gives terminals, scripts, CI, and coding agents (Claude Code, Cursor, Codex) a
native way to operate a firm's Uku data — within the exact permissions of the API
key you hand it.

> **Status:** v0.1.0 — MVP. Read + the essential writes, plus an `api` escape
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

## Environment

| var | purpose |
|-----|---------|
| `UKU_API_KEY`, `UKU_COMPANY` | credentials (override the stored file — ideal for CI/agents) |
| `UKU_BASE_URL` | override the API base (default `https://app.getuku.com`) |
| `UKU_BIN_DIR` | install location (installer) |
| `UKU_CONFIG_HOME` | credentials directory (default `~/.config/uku`) |
| `NO_COLOR` | disable colored output |

## What's next

- Official **MCP server** (chat assistants operate Uku with no glue code) — coming.
- More first-class subcommands as the API grows. Until then, `uku api` reaches
  every one of the 80+ v3 endpoints.

Docs: <https://app.getuku.com/api/v3/docs> · <https://getuku.com/agents/>
