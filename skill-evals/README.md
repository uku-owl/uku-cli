# skill-evals — does an agent actually follow SKILL.md?

The drift gate proves every command and flag named in the skill *exists*. It
cannot prove the skill *teaches* anything: a document can be entirely accurate
and still lead an agent to guess.

So the skill is evaluated the only way that answers that question — give a model
the skill and nothing else, hand it a real bookkeeper's request, and grade the
commands it chose.

## How to run it

There is no automated runner, and that is a deliberate limit, not an oversight.
Basecamp's equivalent calls a hosted model API on every CI run; this project does
not spend on an API key for a check that runs a handful of times a release. So
the harness is built and the run is manual:

    scripts/skill-eval-setup.sh          # generates SKILL.md as a user receives it,
                                         # plus a mock `uku` that records argv and writes nothing

Then, in a Claude Code session, hand a subagent one case file from `cases/`,
pointing it at the generated skill and the mock's `bin/` on PATH. Grade the
recorded commands against the case's `accept` / `reject` lines yourself.

**This is not part of `bin/ci`.** Nothing here gates a release. Treat a finding
the way you would a bug report — with a test, if the finding turns out to be
about the CLI rather than the prose.

## What the first run found (2026-07-28, skill v0.4.0)

Held up:
- an ambiguous client name ("Acme", where both "Acme Ltd" and "Acme Holdings"
  exist) made the agent stop and ask rather than pick one
- 200 records went to `--batch`, not a shell loop
- `--dry-run` was reached for before the batch write

Gaps, all now fixed in the skill:
- **the agent invented `uku invoices mark-paid`** — a *money* write. No such
  subcommand exists; the real CLI would have refused with a usage error, so the
  safety net held, but the skill had led it there. The API has the operation as
  a POST, and the skill now says so explicitly, next to the same warning that
  already existed for `invoices patch`.

Re-run of `cases/money-write.md` after the fix, same model, same mock: no guess
at all. The agent ran `account current` before touching anything, read the
invoice, quoted the skill line that named `uku api POST
/api/v3/invoices/88/mark-paid`, and then stopped on its own — invoice 88 is a
*draft*, and a client cannot pay an invoice they were never sent. That last part
is the model's domain reasoning, not the skill's; worth knowing which is which.

The measurable change is the point: before, a money write was invented; after,
it was read. That is what this harness is for.

Known, not fixed here:
- the skill does not warn that a shell function or alias named `uku` will shadow
  the CLI. `uku doctor` detects it, but you cannot reach `doctor` to be told.
