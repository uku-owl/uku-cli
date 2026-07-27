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
`DELETE` restates the target and is labelled as permanent. Every non-GET is
recorded in a local, keyless audit log at `~/.config/uku/audit.log` (0600).

**Writes are re-sent automatically in exactly one case, and it is the case where
re-sending cannot do harm.** A `428 PRECONDITION_REQUIRED` means the server
refused the write for want of an `If-Match` header — *nothing happened*. The CLI
fetches the current `ETag` and sends the same request once more. Every other
failure is left to you, because in every other case the CLI cannot know whether
the write landed:

| Status | Automatic? | Why |
|---|---|---|
| **428** precondition required | **Re-sent once, automatically** | The server rejected it; nothing was written. Re-sending is safe by construction. |
| **412** stale write | Never | Someone else changed the record. A blind retry overwrites their edit. |
| **429** rate limited | Never for a write | The outcome is unknown. `GET` to check before resending. |
| **5xx / timeout** | Never for a write | Same: unknown outcome. |

If you supply `--if-match` yourself, even the 428 is not healed — the value you
chose is what the server rejected, and only you can resolve that. `GET`s, being
idempotent, may be retried automatically.

## The installer

`curl -fsSL https://getuku.com/install-cli | sh`

`main` is where development happens. A **git tag** is a release. The installer
has three channels, and they do not offer the same guarantees — here is exactly
what each one checks:

| Channel | How to get it | What is verified |
|---|---|---|
| **release** (default) | just run the one-liner | Reads `main/VERSION` — the pointer to the newest published release — then downloads `bin/uku` from the immutable tag `v<version>` and **requires** a matching `bin/uku.sha256` published at that same tag. A missing checksum, an unavailable `sha256sum`/`shasum`, or a mismatch all **abort the install**. |
| **pinned** | `UKU_VERSION=0.2.0 …` | Identical rules against the tag you named. |
| **rolling** (opt-in) | `UKU_CHANNEL=main …` | **Nothing.** You get whatever is on `main` at that moment, unreleased work included, with no checksum checked at all. The installer says so, loudly, every time. |

**What the checksum does prove.** Anchored to a tag, it detects a download that
was swapped, truncated or corrupted in transit, and it stops `main` from moving
underneath an install: the bytes you get are the bytes we committed at that tag,
and neither the file nor the checksum can be edited afterwards without moving
the tag.

**What it does not prove: authenticity.** The artefact and its checksum are
published from the same repository. Anyone able to compromise that repository
could publish both, and the check would pass. This scheme raises the bar against
tampering *in transit* and against a moving target; it is not a defence against a
compromised source. The next step is **signing** — a minisign or cosign signature
over the release artefact, verified against a key that does not live in the repo.
**That is not implemented today.** Until it is, please do not read the checksum
as more than it is.

Two other checks run on the download — that it starts with `#!` and mentions
"the Uku command-line client". Those catch an HTML error page or a truncated
body. They are sanity checks on the shape of the file, not integrity
verification; anything deliberately malicious would pass them.

The script is small and readable — review it before running if you prefer:
`curl -fsSL https://getuku.com/install-cli` (without `| sh`).

`uku update`, and the once-a-day auto-update, both go through this same
installer and therefore through the same default channel: the newest released
tag, checksum-verified.

## Reporting a vulnerability

Please email **security@getuku.com** with details and steps to reproduce. Do not
open a public issue for a security report. We'll acknowledge and work with you on
a fix and disclosure timeline.
