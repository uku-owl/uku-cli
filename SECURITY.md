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
  (`uku_live_…d5e2`). The CLI does not log request or response bodies. The one
  exception is `uku auth print-header`, which exists to print a live credential
  and warns on stderr every time it does.

  `--fields` used to be a way around that: its value was spliced into a `jq`
  program as text, so `--fields 'x // env.UKU_API_KEY'` printed the real key on
  a terminal. Field names are now required to be plain identifiers (letters,
  digits, underscore) and are passed to `jq` as data, not as program text —
  both, because either alone is one mistake away from the same hole.
- **An account name is a name, not a path.** `--account`, `account use`,
  `account remove` and `auth logout` all take a profile name matching
  `[[:alnum:]._-]`, excluding `.` and `..`. Before this,
  `uku account remove ../../../../victim/precious.txt` deleted the named file
  and reported success, and `--account ../../../victim/prof` read an arbitrary
  file as a profile — which meant an attacker who could write a file anywhere
  could choose the host your key was sent to. The `active` file is re-checked
  on read, so a profile poisoned by an older CLI cannot keep redirecting you.
- **TLS pinned.** HTTPS requests use `--proto '=https' --tlsv1.2`.
- **`http://` is for this machine only.** The base URL must be `https://`
  unless the host is this machine — `localhost`, `*.localhost`, `127.0.0.1`,
  `[::1]`. An `http://` base to any other host is **refused before anything is
  sent**, and so is a base with no scheme at all (`curl` would have guessed
  `http`). This applies wherever the base comes from: `--base`, `UKU_BASE_URL`,
  or a stored profile. Asserted in `tests/cases/base-trust.sh`, whose refusal
  assertions are "`curl` was never executed".

  Before this, `http://` was allowed anywhere with a code comment reading
  "allow http dev base" and no warning of any kind; a plaintext fixture server
  was measured receiving the full live `X-API-Key` header. The exemption is
  exactly the four loopback spellings above and nothing wider: `127.0.0.2`, a
  LAN address and a private hostname all count as remote. **The narrow part:** a
  loopback port that has been forwarded somewhere else (an SSH tunnel) is
  indistinguishable from a local server here, and is treated as local.
- **A non-default host announces itself.** When the base is neither
  `https://app.getuku.com` nor loopback, one line goes to stderr naming the
  host the credentials are about to go to — once per invocation, however the
  base was chosen, including a base that was stored in a profile weeks ago and
  is not mentioned on the command line. `--quiet` does **not** silence it: quiet
  drops progress chatter, and where your key went is not chatter. This is the
  one line a person supervising an agent has to be able to see.

  It is *not* a confirmation prompt and does not stop anything. It also stays
  silent for a loopback base, deliberately: a line on every command of a local
  development day is a line people learn to skip, which would cost us the one
  invocation that mattered.
- **Validated before it's saved.** `uku auth login` verifies the key against the
  API *before* writing anything to disk — bad credentials never land.
- **Temp files are swept on any exit**, including Ctrl-C, via a trap — the 0600
  key-config file never lingers in `$TMPDIR`. Every temp file of a run (the key
  config, the request body, response buffers) is created inside one private
  directory under `$TMPDIR`, and the EXIT/INT/TERM/HUP traps remove that
  directory. Asserted, not assumed: `tests/cases/no-residue.sh` runs the four
  failure paths — network error, `--dry-run`, Ctrl-C mid-request, a
  rate-limit-refused batch — and greps the filesystem afterwards.

  This claim was **false in v0.4.0 and every version before it**. The sweep kept
  its file list in a variable that every call site updated from inside a
  subshell, so the list stayed empty and the traps deleted nothing; the happy
  path was clean only because the request code deleted its own files
  explicitly. If you ran v0.4.0 or earlier, look in `$TMPDIR` (on macOS
  `/var/folders/**/T`, which is cleared only on reboot) for stray `tmp.*` files
  holding `header = "X-API-Key: …"`, and delete them.
- **A credential must be a single line.** `curl`'s `-K` config grammar is
  line-based, so a newline inside the API key or the company id would end the
  header directive and begin a new one — `url = http://elsewhere/` there makes
  curl perform a second transfer carrying the live key. The CLI refuses such a
  value before anything is sent and before anything is stored, so neither the
  environment, `--key-stdin` reading a file, nor a hand-edited profile can
  smuggle one through. Fixed after v0.4.0; v0.4.0 and earlier escaped `\` and `"`
  in a credential but not line breaks.

## The permission model — money has its own key

API keys are scoped **Read**, **Edit**, or **All**. Anything financial requires
the `All` scope explicitly; a Read or Edit key literally cannot touch money — the
API, not the CLI, enforces this. Hand an agent a Read or Edit key and it can help
run the firm without ever being able to move money it was never meant to touch.

## Deliberate writes

Writes (`POST`/`PATCH`/`DELETE`) are never accidental: a non-interactive write
requires an explicit `--yes`, and an interactive one prompts for confirmation.
`DELETE` restates the target and is labelled as permanent. Every non-GET is
recorded in a local audit log at `~/.config/uku/audit.log` (0600).

Be precise about what that log holds, because it is a file people share when
something goes wrong: one tab-separated line per write — timestamp, account
name, method, **the request path including its query string**, and the response
status. No request body, no response body, no key. The query string means a
name you searched for can appear in it (`POST /api/v3/tasks?q=Acme%20Ltd`), so
treat it as containing client names. It is not rotated and grows without
limit.

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

### The auto-update installs by itself — read this before you deploy the CLI

Auto-update is **on by default** and it does not merely notify. At most once a
day, on an ordinary command, `uku` fetches the release pointer and — if the
number moved — fetches the installer and **pipes it into `sh`**, with no prompt,
no TTY requirement and no confirmation in that moment. The new binary is renamed
into place, so the running command finishes on the old file and the change
applies from your next one. Turn it off with `UKU_NO_AUTO_UPDATE=1`; `uku update`
by hand keeps working either way.

This is a deliberate trade, not an oversight: a fix reaches every machine within
a day, and we would rather that than a long tail of old clients writing to a
firm's books. What you are accepting in exchange is stated plainly above — **a
compromise of this repository becomes a compromise of every client that runs the
CLI, automatically, within 24 hours.** The checksum chain covers the transport
and the moving-target problem; it is not a defence against a compromised source,
and signing is still not implemented. On a machine where that is not an
acceptable trade, set `UKU_NO_AUTO_UPDATE=1`.

**The two URLs it follows cannot be chosen by the environment.**
`UKU_INSTALL_URL` and `UKU_UPDATE_URL` are honoured **only** when `UKU_DEV=1` is
also set; otherwise the override is ignored, the built-in URL is used, and the
CLI says on stderr that it dropped it and why. They exist for the project's own
test suite. Without that lock, anything that can set an environment variable in
the process — a `.env`, a `direnv` file, a CI job definition, an agent's own
environment — chooses code that this CLI then runs unattended within a day.
Asserted in `tests/cases/update-trust.sh`.

## Reporting a vulnerability

Please email **security@getuku.com** with details and steps to reproduce. Do not
open a public issue for a security report. We'll acknowledge and work with you on
a fix and disclosure timeline.
