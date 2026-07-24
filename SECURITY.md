# Security

The Uku CLI holds an API key that can read — and, with the right scope, change —
an accounting firm's data. We take its security posture seriously.

## How the CLI protects your credentials

- **Stored 0600, parsed not sourced.** Credentials live in
  `~/.config/uku/profiles/<account>` with mode `0600`. The files are *parsed*
  (grep/sed), never `source`d as shell — a tampered profile is data, not code.
- **Never on the process list.** Auth headers (`X-API-Key`, `X-Uku-Company`) are
  passed to `curl` via a 0600 config file (`-K`), not on the command line, so the
  key can't be read from `ps` on a multi-user host. Request bodies are handled the
  same way, so client PII isn't on the process list either.
- **Never printed.** `uku auth status` and every message mask the key
  (`uku_live_…d5e2`). The CLI does not log request or response bodies.
- **TLS pinned.** HTTPS requests use `--proto '=https' --tlsv1.2`.
- **Validated before it's saved.** `uku auth login` verifies the key against the
  API *before* writing anything to disk — bad credentials never land.
- **Temp files are swept on any exit**, including Ctrl-C, via a trap — the 0600
  key-config file never lingers in `$TMPDIR`.

## The permission model — money has its own key

API keys are scoped **Read**, **Edit**, or **All**. Anything financial requires
the `All` scope explicitly; a Read or Edit key literally cannot touch money — the
API, not the CLI, enforces this. Hand an agent a Read or Edit key and it can help
run the firm without ever being able to move money it was never meant to touch.

## Deliberate writes

Writes (`POST`/`PATCH`/`DELETE`) are never accidental: a non-interactive write
requires an explicit `--yes`, and an interactive one prompts for confirmation.
`DELETE` restates the target and is labelled as permanent. GET requests may be
retried automatically; **writes are never retried**. Every non-GET is recorded in
a local, keyless audit log at `~/.config/uku/audit.log` (0600).

## The installer

`curl -fsSL https://getuku.com/install-cli | sh` downloads a single script,
verifies it against a published SHA-256 (a pinned version refuses to install
without a matching checksum), and installs it to a directory on your `PATH`. The
script is small and readable — review it before running if you prefer:
`curl -fsSL https://getuku.com/install-cli` (without `| sh`).

## Reporting a vulnerability

Please email **security@getuku.com** with details and steps to reproduce. Do not
open a public issue for a security report. We'll acknowledge and work with you on
a fix and disclosure timeline.
