# Security

The Uku CLI holds an API key that can read — and, with the right scope, change —
an accounting firm's data. We take its security posture seriously.

## How the CLI protects your credentials

- **Stored 0600, parsed not sourced.** By default the credential lives in
  `~/.config/uku/profiles/<account>` with mode `0600`. The files are *parsed*
  (grep/sed), never `source`d as shell — a tampered profile is data, not code.
  That stays true whichever store is in use: with `UKU_KEYRING=1` the profile
  file holds only the base URL, the company id and a `UKU_KEY_STORE=keyring`
  marker, and it is still parsed, never sourced.
- **Optionally in the OS keyring — and here is exactly what that buys.** Set
  `UKU_KEYRING=1` and the next `uku auth login` stores the key in the OS
  credential store (macOS Keychain via `security`, Linux Secret Service via
  `secret-tool`) instead of the file. The key is then not in any file this CLI
  writes, so a backup, a synced dotfiles repo, or someone else's script reading
  `~/.config/uku/profiles/*` does not get it.

  It does **not** protect the key from you, or from anything running as you:
  `security find-generic-password -s uku-cli:<account> -a <account> -w` prints
  it, and so does `uku auth print-header`. Anyone claiming a keyring makes a
  CLI credential unreadable on its own machine is overselling it.

  It is **off by default**, on purpose. Existing installs must not silently
  move where their credential lives; and `security`/`secret-tool` can block on
  a locked store with nothing that can prompt (ssh, cron, a headless box),
  which would be a worse failure than the one this fixes. Every keyring call is
  therefore bounded by `UKU_KEYRING_TIMEOUT` (5s) and killed rather than waited
  on. A timeout while *reading* refuses the command and says the keyring is
  locked — it never quietly falls back to a file. A timeout while *storing*
  during `uku auth login` **does** fall back to the 0600 file, because the
  alternative is discarding a key you just typed and verified — and it says so
  on stderr, in those words, so nobody believes they are on the keyring when
  they are not.

  Migration is explicit: an existing file-stored key is never moved by an
  ordinary command, in either direction. `uku auth login` is the only thing
  that moves it. `uku auth logout` and `uku account remove` delete the key from
  **both** stores and exit 3, naming the exact `security delete-generic-password`
  command, if the keyring would not release it.
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
name, method, **the request path with any query string stripped**, and the
response status. No request body, no response body, no key, no query string —
a name you searched for (`?q=Acme%20Ltd`) is never written. The path's own
segments (a task or client id) still are, because a receipt has to say which
record changed. It rotates: once the file crosses ~5 MB or ~10k lines, it is
moved to `audit.log.1` (one prior generation, overwritten on the next
rollover) and a fresh `audit.log` starts — both files kept at 0600.

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

`uku update` goes through this same installer and therefore through the same
default channel: the newest released tag, checksum-verified.

### The update check tells you; it does not install

At most once a day, on an ordinary command, `uku` fetches the release pointer
and — if the number moved — prints a single line naming the new version and the
command that installs it. That is all it does. No script is fetched, nothing is
piped into a shell, and no binary changes until you run `uku update` yourself.
`UKU_NO_AUTO_UPDATE=1` silences the notice and skips the check.

**This is a change in behaviour, and the reasoning is worth stating plainly**,
because the previous behaviour was a documented, deliberate trade rather than an
oversight. Older versions had the same daily check go on to fetch the installer
and **pipe it into `sh`** — no prompt, no TTY needed. The argument for it was reach:
a fix lands on every machine within a day, rather than leaving a long tail of old
clients writing to a firm's books.

Three things outweighed that:

- **The payload URL resolved through our marketing site.** Whoever could deploy
  that site chose where the redirect landed, and so chose what every
  installation executed. A lower-trust deploy path was in the execution path of
  a tool that holds a live API key. It now points at an immutable tag on this
  repository, with no third party in between.
- **Every integrity control lived inside the artefact being fetched.** A checksum
  verified inside `install.sh` cannot tell you that `install.sh` is the right
  file. Controls inside the artefact cannot protect the *choice* of artefact.
- **The same path writes agent instructions.** It owns the step that installs
  `~/.claude/skills/uku/SKILL.md`, so a compromise would rewrite what our
  customers' coding agents read, not just what their terminals run.

The honest summary of the old behaviour was already in this file: *a compromise
of this repository becomes a compromise of every client that runs the CLI,
automatically, within 24 hours.* That sentence was true, and it is the reason the
default changed. Signing is still not implemented; until it is, the shortest
description of our position is that we are unwilling to run an unattended
execution channel we cannot authenticate.

Reach was the point of the old default, and it is not abandoned — the daily
check still runs, and you are still told. What changed is that a human decides.

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
