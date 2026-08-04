# refactoring-cli.md — the implementation plan

**Status:** written 2026-08-03. **Phases 0, 1, 2, 3, 4 and 5 shipped** on branch
`sec/phase0-install-chain` (**pushed** 2026-08-04; `main` untouched at `f04f500`,
v0.6.0). **Phase 6 — the auth work — is DECIDED and NOT started: the answer is a
Go rewrite.** Start it in a fresh session; see § 0 below.

---

## 0. START HERE — next session

**The next piece of work is the Go rewrite.** The decision was taken 2026-08-04
with the full argument and measurements in § 11.1. It is not provisional: the
remaining roadmap (OAuth, signed cross-platform distribution, Windows) is exactly
where bash is weakest, and every one of the eight bugs found on 2026-08-04 was a
bash bug rather than a logic bug.

### What the rewrite inherits, and what it must honour

| | |
|---|---|
| **The specification** | `tests/` — **1,480 assertions**. 301 of ~324 CLI invocations `exec` the binary as a subprocess against a language-agnostic Python fixture, so a Go binary dropped at `bin/uku` is held to all of them **unchanged**. |
| **The contract** | `.surface` — **424 facts**, including 31 `op` facts and the 10 `exit N name` codes. `scripts/check-surface.sh` ratchets it; `.surface-breaking` is the only way to deviate. |
| **The ship gate** | `.api-released` (182 production operations) + `.api-pending` (4 built-but-undeployed). `scripts/release.sh` refuses while `.api-pending` is non-empty — verified. |
| **PRIME DIRECTIVE** | The new binary passes the existing suite, or it does not ship. |

**The one test that will NOT port as-is:** `tests/cases/update-trust.sh` greps
`bin/uku` for `UKU_INSTALL_URL_DEFAULT` / `UKU_UPDATE_URL_DEFAULT` as literal
source text (lines 37, 51). A compiled binary must expose those another way —
`-ldflags` plus a hidden subcommand, or `uku --dump-surface`-style output.
`tests/cases/signing.sh` similarly rewrites the `UKU_RELEASE_PUBKEY` heredoc in a
copy of `bin/uku`; same treatment.

### Do this early in the rewrite session

**Fix the test-portability debt once, properly** — do NOT do it in bash first.
The first remote CI run (2026-08-04, GitHub Actions, ubuntu-latest, bash 5, GNU
coreutils) was **1443 passed / 37 failed**. The suite had only ever run on macOS
with bash 3.2 and BSD tools. One failure was a real CLI bug and is fixed
(`aca123f`, `UKU_BASE` unbound under `set -u`). The other 36 are harness
assumptions:

- `tests/cases/audit-log.sh` (2) — `stat -f` is "file format" on macOS and
  "filesystem status" on Linux; the assertion received a disk-usage dump.
- `tests/cases/doctor.sh` (1) — asserts the output contains the literal
  `bash 3.2`.
- `tests/cases/keyring.sh` (~33) — the stubs assume macOS `security`; Linux
  resolves `secret-tool`.

These were deliberately left red rather than fixed in bash, because the Go
session inherits the same tests through the subprocess boundary and the work
should be done once. **CI on this branch is red on purpose. That is an accurate
signal, not a broken build.**

### The API team's OAuth answers — ASKED AND ANSWERED 2026-08-04

The device-flow question was put to an agent in `uku_service` and came back
answered. Each answer is kept next to its question, because an answer without
its question reads as an unsourced assertion — the exact failure this repo
guards against. **Every claim below was then re-measured here**; the one that
was wrong was mine.

**a. Does device flow exist?** No. Genuinely absent — zero matches for
`device_code`, `device_authorization` or the grant URN across all six repos. The
metadata is truthful: `authorization_code` + `refresh_token` are the only
grants.

**d. Is `.well-known` public, and where?** Public, unauthenticated,
`Cache-Control: public, max-age=300`. **My 404 was a wrong-host artifact** — the
document is served by the main Tornado app, never by api-v3, because
`oauth_handlers.py` registers via `tornroutes` on the app rather than as a
FastAPI route. Re-measured here 2026-08-04:

```
https://127.0.0.1:8886/.well-known/oauth-authorization-server   200
http://127.0.0.1:8885/.well-known/oauth-authorization-server    200
http://127.0.0.1:8890/.well-known/oauth-authorization-server    404   <- my probe
```

Paths: `/.well-known/oauth-authorization-server` (RFC 8414),
`/.well-known/oauth-protected-resource` (RFC 9728), and an `/mcp`-suffixed
variant of each for SDKs that probe by path insertion — all four served 200
locally. **Fetch discovery from the app base URL, not the api-v3 origin.**

**b. Effort if added.** ~80% of the parts exist — `_mint_access_key`,
`_issue_refresh_token`, `_effective_scopes`, `_token_response`, `_hash_code`,
the consent shell with its company picker and financials checkbox, the Redis
per-IP limiter, and `oauth_authorization_code` as a table template. Genuinely
new: a device-code table, the `user_code` entry page, the polling branch with
`authorization_pending`/`slow_down`/`expired_token`/`access_denied`, and
brute-force limits on a ~20-bit `user_code` (needs both a per-code attempt cap
and a global one). A few days, mostly consent page and abuse limits rather than
protocol.

**c. Objection — and it changes the CLI's design.** No blocking objection, but
one that propagates: the consent page's whole trust story is *"trust the address
above, not the name"*, because `client_name` is attacker-controlled free text
from an unauthenticated `/oauth/register`. Device flow deletes that anchor — no
redirect host means the page has nothing verifiable to say about who is asking,
while training users to type codes from elsewhere into it. That is RFC 8628 §5.4
remote phishing with the mitigation removed.

Their recommendation, which this plan adopts: **device flow only for
allow-listed first-party `client_id`s, never for dynamically-registered
clients**, and `financials` barred over device flow entirely. Consequences for
this CLI are in § 9.

**Security premise confirmed, and worth leading the rewrite with.** OAuth tokens
are real `api_key` rows: `kind='personal'`, person-scoped, `auth_type='oauth2'`,
revocable in Settings → API Keys. They can **never** carry `admin` —
`_granted_scopes` whitelists by exact canonical string and fails closed to
`["read","write"]`, deliberately, because `/oauth/register` is unauthenticated
and a pre-consent row can hold attacker-chosen scope text. `financials` only via
the consent checkbox, gated on `MANAGE_ACCOUNT`, and **re-authorized at every
mint including every refresh**, downgrading silently if the right was dropped.
Against a pasted integration key that is tenant-wide, can carry `admin`, and
never expires.

### Production 403s OAuth discovery — a release gate, not a design input

Found by the API team while answering the above, and re-measured here
2026-08-04:

```
https://app.getuku.com/.well-known/oauth-authorization-server       403
https://app.getuku.com/.well-known/oauth-protected-resource         403
https://app.getuku.com/.well-known/acme-challenge/x                 302  <- the regex is what fires
https://staging.getuku.com/.well-known/oauth-authorization-server   200
```

Cause is `infra/configs/nginx/includes/block-scanners.conf:45` — a dotfile
blocker whose only whitelist is acme-challenge:

```nginx
location ~ /\.(?!well-known/acme-challenge) { return 403; }
```

Staging already carries the fix at
`staging_infra/configs/nginx/includes/block-scanners.conf:52` —
`(acme-challenge|oauth-)` — so this is a proven backport, not a design decision.
Its comment records both the provenance (found 2026-07-23 testing the
claude.ai/Claude Desktop OAuth connector) and the nginx gotcha that makes it
necessary: **regex locations match in config order, not by specificity**, so the
dotfile blocker 403s these paths before any OAuth location is reached, no matter
what that location's own settings say.

**Scope the backport carefully — it is one line, not two.** Staging also has an
access-gate bypass at `staging_infra/configs/nginx/uku.conf:405` and `:843`, but
that is **staging-specific**: it exists to get past staging's basic-auth gate.
Verified 2026-08-04 that `infra/configs/nginx/uku.conf` contains no `auth_basic`
and no oauth/well-known location at all, so prod has no gate to bypass. Copying
that block into prod would be cargo-culting.

**OAuth is blocked twice over in production, and the two are independent.** The
edge 403s discovery *and* the OAuth handler is committed but not deployed. The
measurement above is taken at the edge, so it says nothing about the second —
fixing nginx alone will not make OAuth work. Treat deployment as a separate
question.

**It blocks nothing this repo is about to build** — staging serves discovery.
`infra/` is production-only and access-restricted; do not touch it from here.
Recorded in § 0.1 for whoever owns it.

**Nothing currently measures this.** "OAuth discovery is reachable in
production" is a shippability precondition of the same kind as `.api-pending`,
and it lives outside the drift gate's reach for the reason in § 6.2.1.

---

---

## 0.1 Everything still outstanding

**Needs a person, not code:**

| Item | Who / what |
|---|---|
| **Signing key** | `scripts/sign.sh --keygen`, then paste the public half into `bin/uku` **and** `scripts/install.sh`. The machinery is built and tamper-tested; it ships **inert** (`UKU_RELEASE_PUBKEY` empty) until this is done. Private key must not live in this repo — `--keygen` refuses to write it there. |
| **Branch protection** | Required review on `uku-owl/uku-cli` `main`, so one stolen token is not sufficient (§ 4.4). Needs GitHub admin. |
| **Licence** | MIT here vs the retired Python client's Proprietary. Still unresolved. |
| **SOC 2** | `uku-cli` is in scope but absent from the asset inventory, subprocessor list and access-control matrix — same gap as `infra` and `mailbox`, plus `getuku-astro` deploy access, now a production trust root. Close together. |
| **Local dev API key** | `api_key` id **184**, company 4, named "uku-cli-local-dev (delete me)", scopes read/write/admin/financials. Minted 2026-08-04 to verify Phase 4 against `127.0.0.1:8890`. Delete when done. |
| **`reference/`** | Untracked in the working tree. Commit or remove. |
| **nginx 403 on OAuth discovery** | Backport staging's `(acme-challenge\|oauth-)` whitelist to `infra/configs/nginx/includes/block-scanners.conf:45`. **That one line only** — staging's `uku.conf:405/843` bypass is staging-gate-specific and prod has no gate. Necessary but not sufficient: the OAuth handler is also committed-not-deployed. `infra/` is access-restricted — not ours to touch. Detail + measurements in § 0. |

**Needs the API:**

- **Device flow** (RFC 8628) does not exist. A few days of work, no blocking
  objection, ~80% of the parts already present (§ 0b). Not on the critical path
  if the Go auth layer is built grant-agnostic (§ 9.0).
- **A trust column on `OAuthClient`**, or a config allow-list, so device flow can
  be restricted to first-party `client_id`s. This is the phishing mitigation
  that makes device flow safe at all (§ 0c), and it is what lets this CLI pin a
  `client_id`.
- **A decision on `financials` over device flow.** If barred, invoice and billing
  commands are unavailable on that path — a capability regression against pasted
  keys (§ 9.1).

**Needs the API deploy:**

- `.api-pending` holds four operations — `POST /tasks/{id}/complete`,
  `POST /tasks/{id}/reopen`, `GET /search`, `GET /capabilities`. All verified
  against a local server; all 404 in production. **Emptying this file is part of
  shipping the API release, not an afterthought** — `release.sh` refuses until it
  is empty.
- Re-run `scripts/check-api.sh --live` and `--update` after the deploy.

**Needs a push or a release:**

- **GitHub Releases** (§ 4.1) — `gh release create` with `bin/uku`,
  `bin/uku.sha256`, `scripts/install.sh` and their `.sig` files. Measured
  2026-08-03: `gh api repos/uku-owl/uku-cli/releases` is empty.
- **Migrate both install URLs** (§ 4.2) to `releases/latest/download/`, and
  repoint the `getuku.com/install-cli` redirect in lockstep. Until then the
  release ritual in `release.sh` still prints a `curl … | shasum` check against
  the marketing URL — deliberate, and it must move with the URLs.

**Filed against `uku_service` (2026-08-04), track to closure:**

- **UKU-849** — `/tasks/{id}/reopen`'s docstring wrongly calls the `new` case a
  no-op. The CODE IS CORRECT and must not change: `status = 'new'` marks a
  recurring occurrence as untouched and therefore destroyable by the
  re-provisioning teardown, so any interaction must move it. Predicate:
  `virtual_task_module.py:796`. **Confirmed by the API team 2026-08-04 and now
  recorded in `uku_service/CLAUDE.md`**, so the semantics survive outside the
  ticket. The docstring fix itself is still open.
- **UKU-850** — `/capabilities` reports `read: false` for `teams` and
  `workflow-templates`, which are readable; `/mcp-usage` and `/reports/*` are
  absent entirely. Until fixed, **no client may treat `/capabilities` as a route
  index** — the CLI deliberately does not.

**Decisions already taken, recorded so they are not re-litigated:**

- **C6** — exit codes split (403→7, 400/422→8, 429→9, `MISSING_COMPANY`→2).
  Approved by the CTO 2026-08-04 as a deliberate surface break; in
  `.surface-breaking`.
- **C7** — loopback cleartext warning: implemented, measured, **reverted**. See
  § 5.5.
- **Auto-update** — notify-only, never installs by itself (Phase 0).
- **Bash vs Go** — **Go** (§ 11.1).

---

**Companion to:** `CLAUDE.md` (the handover + bug ledger). Where this file and the
ledger disagree, **this file wins** — every claim below was measured, and § 1
lists the ledger claims that measurement corrected.

**Where this file and the CODE disagree, the code wins** — three things in here
were tried, measured and reversed or corrected during implementation (C3's
rationale in § 5.1, C5's emit point in § 5.2, C7 entirely in § 5.5). Each is
marked in place rather than quietly rewritten, because *why* an approach was
abandoned is the part that stops it being re-attempted.

**Two rules in force for every phase:**

1. **PRIME DIRECTIVE.** Command syntax, flags, output shapes and exit-code
   *meanings* are a contract. Internals are free. Every surface deviation goes in
   `.surface-breaking` with a dated rationale, and gets called out in the
   changelog.
2. **Never ship ahead of production.** A command that 404s for every customer is
   worse than a missing command. Phase 3 exists to make this mechanical rather
   than remembered.

---

## 1. What measurement changed

Read this before touching anything. Five ledger claims were wrong or incomplete,
and two of them would have produced a wrong implementation.

### 1.1 `/search` is not a drop-in replacement — this inverts C4

Measured from `uku_service/backend/api_v3/routers/search.py:20`:

| | entity types |
|---|---|
| `GET /api/v3/search` | invoice, contact, supplier, contract, task, note |
| `uku search` fan-out (`bin/uku:1731`) | clients, tasks, members, products, projects |
| **overlap** | **`tasks` only** |

The ledger says the CLI "misses four of those entity types and burns 5× the
rate-limit budget", which reads as *replace the fan-out with `/search`*. Doing
that would silently drop **clients, members, products and projects** — including
clients, which is what a user searching "Acme" almost always means.

**The correct fix is a union, not a substitution:** call `/search` *and* keep the
four list endpoints it does not serve. Still 5 requests, but 10 entity types
instead of 5. See § 6.2.

### 1.2 The falsehood is in the test suite, not just `--help`

`tests/cases/search.sh:3-5` states as its rationale: *"there is no server-side
global search to lean on."* The handover calls the suite "this repo's best
asset — treat it as the specification." So the spec itself asserts the
falsehood. Fixing C4 is a deliberate spec amendment, not a patch.

### 1.3 C2, C4, C8-capabilities and C13 all target endpoints that 404 in production

Measured 2026-08-03: production serves **182** operations, the repo has **217**,
and **0** operations are released-but-not-built (so the repo spec is not stale).

| Target | Released? |
|---|---|
| `GET /api/v3/health` | ✅ released |
| `GET /api/v3/search` | ❌ built only |
| `POST /api/v3/tasks/{id}/complete`, `/reopen` | ❌ built only |
| `GET /api/v3/capabilities` | ❌ built only |
| `/teams`, `/workflow-templates`, `/reports/*`, `/mcp-usage` | ❌ built only |
| `POST /api/v3/tasks/bulk-action` | ❌ built only |
| `invoices/{id}/mark-paid`, `/send` | ✅ released |
| `invoices/{id}/mark-unpaid` | ❌ built only |
| `/clients/{id}/documents-folder`, `/members/{id}/agreements` | ✅ released |

Full lists: `scratchpad/released-ops.txt`, `scratchpad/built-ops.txt`.

This is the plan's organizing principle. **Phases are ordered by release-safety,
not by severity** — see § 2.

### 1.4 `warnings[]` is already live; `Idempotency-Key` is not spec-visible at all

- `warnings` appears on **76 response schemas in the released spec**. C5 is
  ship-now safe.
- `Idempotency-Key` appears **0× in the released spec, 4× in the built one**.
  That is docstring drift, *not* proof the middleware is off in production — it
  is middleware, so FastAPI would not document it as a route parameter either
  way. **This matters: idempotency coverage is invisible to the OpenAPI spec and
  therefore cannot be drift-checked.** See § 5.1, which is the honest
  consequence.
- A fourth warning code exists that the ledger does not list: `AGREEMENT_OVERLAP`
  (`uku_service/backend/api_v3/services/agreement_service.py:227,305`).

### 1.5 C12 confirmed, C13's premise strengthened, C9's real vector is elsewhere

- **C12 holds.** Measured: human `--help` 9,767 B (~2.4 K tok), `--help --agent`
  14,045 B (~3.5 K tok) — **1.44×**. The machine variant is the larger one.
- **C9's worst vector is not `cmd_api`.** `_resolve_ref` at `bin/uku:1835` assigns
  `UKU_REF_ID="$arg"` **completely unvalidated** when `--by-id` is passed, then
  interpolates it into `/api/v3/clients/$id` (`bin/uku:2944`). `_looks_like_id`
  (`bin/uku:788`) only runs on the auto-detect path. So a curated command with
  `--by-id` is a traversal vector, and guarding `cmd_api` alone would miss it.
- **`do_request()` (`bin/uku:911-1027`) is a genuine single chokepoint** — all 17
  call sites funnel through it. Idempotency keys, the traversal guard and
  `warnings` extraction all belong there or immediately downstream, not in the
  four write callers.

### 1.6 `getuku.com/uku` is not unused — grep said yes, history said no

Searching current files for `getuku.com/uku` returns nothing outside
`vercel.json`, which reads as "dead route, delete it". **That is wrong.** Until
commit `15933bd` (2026-07-25) `scripts/install.sh` carried
`DL_BASE="${UKU_BASE_URL_DL:-https://getuku.com}"` and `SRC="$DL_BASE/uku"` — the
route was the live binary download path for every installation. Old installers
vendored into Dockerfiles and CI jobs still call it.

Kept here as a method note as much as a fact: **a grep over the working tree
cannot establish that a published URL is unused.** Anything already distributed
has consumers that no current file mentions. Check `git log -S` before removing a
route. § 3.1 sequences this as repoint-now, delete-after-measuring.

---

## 2. Phase order and why

```
Phase 0  Kill the unattended RCE channel          ships now, independent
Phase 1  Release integrity (signing, releases)     ships now
Phase 2  Client-side correctness + safety          ships now
Phase 3  API-anchored drift gate + CI              ships now  ← must precede 4
Phase 4  API-gated capability work                 BLOCKED on API deploy
Phase 5  Progressive disclosure (help/skill)       after 4 (surface settles)
Phase 6  Auth — OAuth decision                     independent, largest
```

**Phase 3 before Phase 4 is the load-bearing ordering.** Phase 4 adds commands
against endpoints that 404 today. Build the gate that refuses to ship ahead of
production *before* building the thing it must catch — otherwise the gate is
written by the same person, at the same time, under the same assumption, and
tests nothing.

Phases 0–3 are independent of the `uku_service` release train and can land in any
order among themselves. Phase 4 waits.

---

## 3. Phase 0 — kill the unattended RCE channel

**Goal:** nothing pipes an unverified remote artifact into a shell unattended.
**Blocks:** any customer release. **Effort:** hours.

**Step zero — baseline.** Run `bin/ci` and confirm green before touching anything,
so every later failure is attributable. Measured 2026-08-03 on `main` at `f04f500`:

```
CI PASSED — syntax · bash 3.2 · surface · drift · tests
uku CLI test suite — 1306 passed, 0 failed  (1306 total, 374s)
```

Budget ~6 minutes for the suite. Note `bin/ci` runs all five stages without
short-circuiting (`bin/ci:26-96`), so one failure does not mask the rest.

### 3.1 getuku-astro — ✅ SHIPPED 2026-08-03, with one deviation

**Measured live after the deploy:**

| Route | Live result | vs. plan |
|---|---|---|
| `/install-cli` | → `…/v0.6.0/scripts/install.sh`, 200, sha256 `60cacc51…` | ✅ exactly as specified, bytes unchanged |
| `/uku` | **404 — deleted** | ⚠ deleted rather than repointed |
| `/uku.sha256` | 404 — not added | moot; see below |
| `/uku-partner-program/` | 200 | ✅ untouched |

**On the deviation.** The plan said repoint, keep it alive, measure, then remove.
What shipped is the removal. The failure mode is milder than the caution assumed:
a vendored pre-`15933bd` installer now gets a hard `download failed from
https://getuku.com/uku` naming the URL, rather than a silent wrong install. It
also closes the vector completely, including the silently-unverified-binary
problem — nothing installs at all, so `/uku.sha256` no longer has a purpose.

**One thing still to check, and it is retroactive:** Vercel request counts for
`/uku` over the preceding 30 days. Zero → this is finished and strictly better
than the plan. Non-zero → restore as a repoint to `v0.6.0/bin/uku`, because those
are real machines that just lost their install path.

**What this does NOT change:** the installed base still carries the old
`UKU_INSTALL_URL_DEFAULT` and the old opt-out auto-update, so it keeps resolving
through Vercel until each machine updates once. That hop now lands on immutable,
verified bytes — which was the whole point of doing this side first.

### 3.1.1 Original brief (kept for the record)

`UKU_INSTALL_URL_DEFAULT="https://getuku.com/install-cli"` (`bin/uku:4357`) is
baked into every `bin/uku` already on a customer's machine. Editing that line
changes *future* installs and reaches nobody who already has the CLI. **The
marketing-site change is the only control that reaches the installed base.**

In `getuku-astro/vercel.json` `redirects` (lines 55-59):

1. Repoint `/install-cli` **and** `/install-cli/` from
   `raw.githubusercontent.com/uku-owl/uku-cli/main/scripts/install.sh` to the
   same path under tag **`v0.6.0`**. Both rows matter: Astro normalises to the
   trailing slash before Vercel evaluates redirects, so the live chain is
   `/install-cli` →308→ `/install-cli/` →307→ raw (measured).
2. **Repoint** `/uku` and `/uku/` to the `v0.6.0` tag's `bin/uku` — **do not delete
   yet.** This route serves the raw binary with *zero* integrity checking: it
   bypasses `install.sh` entirely, so it bypasses the tag pin, `REQUIRE_SUM=1`,
   the checksum and even the shape checks. It is the worse of the two vectors.

   **Why repoint rather than delete — verified, and it corrects an earlier
   reading.** No *current* file publishes `getuku.com/uku`, which initially looked
   like "unused, safe to remove". Git history says otherwise: until commit
   `15933bd` (2026-07-25) `scripts/install.sh` had
   `DL_BASE="${UKU_BASE_URL_DL:-https://getuku.com}"` and
   `SRC="$DL_BASE/uku"` — **`getuku.com/uku` was the real binary fetch path for
   every installer** before that date. Anyone who vendored an old `install.sh`
   into a Dockerfile or CI job still calls it.

   Note the *pinned* variant (`$DL_BASE/uku/v$VERSION`) has no `vercel.json` row
   and is **already broken**, so only unpinned old installers remain live.

3. **Add a `/uku.sha256` row** → `raw.../uku-cli/v0.6.0/bin/uku.sha256` (verified
   200 at that tag). This is a strict security improvement, and the reason is
   worth stating exactly.

   The pre-`15933bd` installer fetched `$SRC.sha256` — i.e. `getuku.com/uku.sha256`
   — but verified it **best-effort, not required**: `if DL "$SRC.sha256" > "$SUM"
   && [ -s "$SUM" ] && [ -n "$SHA_CMD" ]; then` (`install.sh:63` at commit
   `3537378`). Today no `vercel.json` row serves that path, so the fetch 404s, the
   `if` falls through, and **old installers silently install an unverified binary
   right now.** Adding the row converts that path from silently-unverified to
   verified, for free. (Current installers are unaffected — `REQUIRE_SUM=1` makes
   a missing checksum a hard error, `install.sh:129`.)

   Note old *pinned* installers (`$DL_BASE/uku/v$VERSION` → `getuku.com/uku/v0.5.0`)
   have no row, 404 on the binary itself, and are already hard-broken. Only the
   unpinned path is live.

   **Sequence:** repoint `/uku` + add `/uku.sha256` now (immutable bytes *and*
   restored verification for old installers) → check Vercel analytics for `/uku`
   traffic over 30 days → remove both once it is zero. Do not confuse with
   `/uku-partner-program`, a real page.

**Zero-risk proof:** as of 2026-08-03 the tag, `main`, and the working copy of
`install.sh` all hash to `60cacc5149292bfd383a019d5269508853a5e4135493589565f6e67bd52d6e36`.
Users get identical bytes before and after.

**Low coupling, contrary to first appearance:** `install.sh` resolves the newest
release itself from `main/VERSION` (`scripts/install.sh:86`, measured → `0.6.0`).
Pinning the *installer* does not freeze what gets *installed*. New CLI releases
flow through with no marketing deploy. A deploy is needed only when `install.sh`
itself changes — which is rare, and is exactly the gate wanted.

4. **Extend the redirect guard to cover `vercel.json`.** getuku-astro already has
   `.github/workflows/redirects-test.yml` → `scripts/test-trailing-slash.mjs`
   (also wired into `.githooks/pre-push`). **It never reads `vercel.json`** — it
   validates only `astro.config.mjs`'s `redirects:` object and the built
   `.vercel/output/config.json`. So the two most security-sensitive redirects in
   the repo have *zero* automated coverage.

   This is not hypothetical: commit `511de259` records `/install-cli` **404ing in
   production** because Vercel's own `trailingSlash: true` 308'd the bare path
   before the redirect rule matched. It was "found by testing the live deploy
   rather than the build" — i.e. by hand. Add a liveness + destination assertion
   for both routes, which is also the cheapest possible guard against a future
   silent repoint.

**A latent drift bug worth fixing while in there:** the published one-liner exists
as **five independent, unlinked copies** — `src/data/prompts.ts:35` (the intended
single source), `src/pages/agents.astro:227`, `src/pages/et/ai-agentidele/index.astro:228`,
`public/llms-full.txt:154`, and `src/data/blog/en/accounting-practice-data-audit/index.mdx:154,305`.
On `agents.astro` the **visible `<code>` text is hardcoded while the copy button
uses `data-copy={INSTALL}` from `prompts.ts`** — what a user reads and what they
paste are two different sources on the same element. Out of scope for the urgent
deploy; worth a follow-up.

A ready-to-hand prompt for whoever owns getuku-astro is in § 10.

### 3.2 uku-cli

| Site | Change |
|---|---|
| `bin/uku:4385-4411` `auto_update()` | Invert to **notify-only** (or opt-in). Today it is opt-out via `UKU_NO_AUTO_UPDATE`, stamps `$UKU_CONFIG_HOME/last-update-check` daily, and on a version bump calls `cmd_update`. Notify-only keeps the value (agents learn they are stale) and removes the standing unattended-execution channel. |
| `bin/uku:4357` `UKU_INSTALL_URL_DEFAULT` | Point at GitHub directly, **at the tag**: `https://raw.githubusercontent.com/uku-owl/uku-cli/v0.6.0/scripts/install.sh`. Removes Vercel from the chain for every future install. **Not `main`** — see the warning below. |
| `bin/uku:3352-3365` `cmd_update()` | The `curl -fsSL "$url" \| sh` at **3364**. Pin to a tag/release asset; do not leave it resolving a mutable ref. |
| `bin/uku:3249-3252` | The `doctor` line that advertises auto-update behaviour must match the new default. |

> ### ⚠ Two adjacent constants, opposite requirements — read before editing either
>
> `bin/uku:4356` and `bin/uku:4357` sit on consecutive lines and must be treated
> in **opposite** ways. Getting this backwards is the most likely way to break
> Phase 0 while believing it is done.
>
> **`UKU_INSTALL_URL_DEFAULT` (4357) — PIN IT.** This is the payload that gets
> executed. Pinning to `main` would leave the CLI's own update path *less* pinned
> than the redirect it just replaced — and this is the path that actually matters,
> since `auto_update` and `uku update` both use it. Name the tag explicitly.
>
> **`UKU_UPDATE_URL_DEFAULT` (4356) — LEAVE IT MUTABLE.** It is
> `raw.../uku-cli/main/VERSION`, the *release pointer* — "the newest tag we have
> published". It is mutable **by design**. Pin it to a tag and update detection is
> permanently dead: the CLI would forever compare its own version against itself
> and never see a new release. `scripts/install.sh:86` has the identical
> dependency and the same rule.
>
> **Make the pin bump automatic.** `release.sh:141-144` already does an in-place
> `sed` on `bin/uku` to rewrite `UKU_VERSION`. Extend that same pass to rewrite the
> tag inside `UKU_INSTALL_URL_DEFAULT`, so the pin can never be forgotten at
> release time. A forgotten pin means every new install runs the *previous*
> release's installer — which works, silently, until the day it doesn't.

**Surface impact:** changing the auto-update default is a behaviour change users
may have scripted around. Record in `.surface-breaking`. `--dump-surface` facts
for `gflag`/`note` around update behaviour will move — regenerate with
`scripts/check-surface.sh --update` and review the diff.

**Test that will move with it:** `tests/cases/update-trust.sh` pins the current
behaviour hard — it asserts the exact stderr strings `ignoring UKU_INSTALL_URL`,
`UKU_DEV=1` and `piped into a shell` (lines 74-83, 94), and relies on
`UKU_DEV=1` honouring the override so the fixture server can be used at all. That
`piped into a shell` assertion becomes false the moment `cmd_update` stops piping.
Update it deliberately — this test is the record of an earlier fix to the same
class of bug (its header, lines 9-13, documents that these env vars used to be
plain overrides and were fenced behind `UKU_DEV` precisely because they get piped
into a shell unattended). Do not weaken it; re-point it at the new behaviour.

### 3.3 Be honest about what Phase 0 does not do

Two things must be stated in the changelog rather than implied away:

- **The redirect does not become trustworthy.** Whoever can deploy getuku-astro
  still controls the destination. Mutability moves from "anyone who can push to
  `uku-cli` main" to "anyone who can deploy the marketing site" — narrower and
  more deliberate, not eliminated. **getuku-astro production deploy access is
  therefore a production trust root** and belongs in the same SOC 2
  access-control item as `uku-cli` / `infra` / `mailbox`.
- **The installed base traverses Vercel once more.** Existing machines carry the
  old default *and* the old opt-out auto-update. They escape only after updating
  once — and updating is the action that goes through Vercel. There is no way
  around that ordering. Phase 0 makes that final hop land on immutable bytes,
  which is the best move available.

### 3.4 Done when

- [ ] `curl -sSL https://getuku.com/install-cli | shasum -a 256` = `60cacc51…`
- [ ] `bin/ci` green before and after (baseline: 1306 passed, 0 failed)
- [ ] `https://getuku.com/uku` resolves to the `v0.6.0` tag, not `main`
- [ ] `https://getuku.com/uku.sha256` returns the checksum (new row)
- [ ] A real end-to-end install prints "Checksum verified"
- [ ] `UKU_INSTALL_URL_DEFAULT` pinned to a tag; `UKU_UPDATE_URL_DEFAULT` left on
      `main/VERSION` — verify `uku doctor` still detects a newer release
- [ ] `https://getuku.com/uku-partner-program/` still 200
- [ ] The redirect guard reads `vercel.json` and fails if either route moves
- [ ] No code path reaches `| sh` without an explicit user action — including
      `release.sh:189`, the release ritual's own final step
- [ ] `.surface-breaking` records the auto-update default change
- [ ] `tests/cases/update-trust.sh` re-pointed at the new behaviour, not weakened
- [ ] A calendar item exists to check `/uku` traffic in 30 days and remove it

---

## 4. Phase 1 — release integrity

**Goal:** close C1's integrity half, which is orthogonal to Vercel and survives
Phase 0. **Effort:** ~1 day.

The verifier is currently the unverified component: `install.sh` performs the
checksum check, and `install.sh` is itself fetched from a mutable ref. Phase 0
pins it for the redirect path; `cmd_update` still needs its own pin.

### 4.1 Publish actual releases

`scripts/release.sh` today writes `bin/uku` (version line, in place, preserving
inode/mode), `VERSION`, and `bin/uku.sha256` (`release.sh:150-151`, computed
*after* the version edit so it describes the released bytes), commits, and
creates an annotated tag. **It deliberately never pushes** (`release.sh:13-14`:
publishing is a human decision) and **never creates a GitHub Release** — measured,
`gh api repos/uku-owl/uku-cli/releases` returns empty.

Add, after the human confirms the push (`release.sh:179-180`):

```
gh release create "v$VERSION" bin/uku bin/uku.sha256 scripts/install.sh \
  --title "v$VERSION" --generate-notes
```

Keep the "publishing is a separate human decision" invariant — make it an
explicit step, not an automatic side effect of tagging.

**`release.sh` already ends with a smoke test that must move with the URLs**
(`release.sh:187-189`): it prints
`curl -fsS .../v$VERSION/bin/uku.sha256` and `curl -fsSL https://getuku.com/install-cli | sh`
for the human to run. The second line pipes the marketing URL into a shell as the
*documented final step of every release* — repoint it in lockstep with
`UKU_INSTALL_URL_DEFAULT`, or Phase 0's fix is undone by the release ritual
itself. The surrounding note about pushing the **tag before the branch** (so the
release pointer never resolves to a nonexistent artefact) is correct and should
survive unchanged.

### 4.2 Then migrate both URLs

Once releases exist, `UKU_INSTALL_URL_DEFAULT` and the getuku-astro redirect both
move to `releases/latest/download/install.sh` — mutable only by publishing a
release (a gated action), no staleness, and **no per-release marketing deploy**.

### 4.3 Sign

minisign or GitHub artifact attestations, key **not** in the artifact repo,
verified in **both** `install.sh` and `cmd_update`. This is the only control in
the whole chain that is not defeated by a compromised repo or a compromised
marketing deploy. Everything before it is defence in depth.

### 4.4 Branch protection

Required review on `uku-owl/uku-cli` main, so one stolen token is not sufficient.

### 4.5 Done when

- [ ] `gh release list` shows releases with `install.sh` + `bin/uku` + `.sha256`
- [ ] Both install URLs resolve to a release asset, not a branch
- [ ] A tampered artifact fails signature verification in `install.sh` **and** in
      `cmd_update` — prove it by tampering, per Lesson 1 (test the test)
- [ ] Branch protection on, verified by attempting a direct push

---

## 5. Phase 2 — client-side correctness and safety

**Goal:** everything fixable without waiting for the API deploy.
**Effort:** ~2-3 days. All items here are release-safe today.

> ### ✅ SHIPPED 2026-08-03 — except § 5.3, which needs a ruling
>
> | | Status |
> |---|---|
> | § 5.1 C3 idempotency | ✅ done — **and the rationale below was wrong; corrected in place** |
> | § 5.2 C5 warnings | ✅ done — **emitted from `check_status`, not `render()`; see why** |
> | § 5.3 C6 exit codes | ⏳ **the only Phase 2 item outstanding.** Needs a CTO ruling |
> | § 5.4 C9 traversal | ✅ done |
> | § 5.5 C10, C11, C14 | ✅ done. **C7 implemented, measured, and REVERTED** |
> | § 5.6 `uku health` | ✅ done |
> | § 5.7 test gaps | ✅ done — 400 and 409 covered, shellcheck gating in `bin/ci` |
>
> `bin/ci` green at 1397 passed / 0 failed, from a 1306 baseline. Every guard
> was proven by re-injecting its bug; the mutation counts are in each commit.

### 5.1 C3 — Idempotency-Key (and an honest limit on what it buys)

**Where:** `do_request()` header block, `bin/uku:932-937`, gated on method the
same way `_pace_write` already is at `bin/uku:925`. Not in the four write callers
(`write_resource:2453`, `run_batch:2841`, `cmd_invoices create:2984`,
`cmd_api:3097`) — they must not each invent a key.

**Contract, measured from `uku_service/backend/api_v3/middleware/idempotency.py`:**

- Header `Idempotency-Key`, any non-empty string, **max 200 chars** (over → 400).
- Redis key is scoped `idem:{sha256(api_key)}:{path}:{key}` — same key on two
  different paths never cross-replays.
- Replay of an identical key + identical body → **the original response verbatim**,
  plus `Idempotency-Replayed: true`. Route not re-invoked.
- Same key, **different** body → **409 `IDEMPOTENCY_KEY_REUSED`**.
- Concurrent in-flight duplicate → **409 `IDEMPOTENCY_CONFLICT`**.
- Stored 2xx responses retained **24h**; non-2xx never stored.
- **Uncovered path, or Redis down → the header is ignored, not an error** (fail-open).

**The key must be stable across retries** — generated once per logical operation,
not per attempt. It must survive the 428 auto-heal resend (`_heal_428`,
`bin/uku:807-829`), which currently re-sends the write. Bash 3.2, no
dependencies: read from `/dev/urandom` via `od`/`hexdump`.

**This exact mistake has already shipped once on this platform.** Per
`reference/python-client/README.md:32`, a fresh key per attempt "is precisely the
bug the Uku MCP server shipped with until it was found by live testing." A
per-attempt key defeats the entire mechanism while looking correct in review and
passing any mocked test. Assert key *stability* across a retry, not merely key
presence — and note that only a live or fixture-server test can catch it, which
is another instance of Lesson 4.

**Working implementation to read first:** `reference/python-client/src/client.py`
(mint-once, reuse-across-retries, plus the ETag-from-header rule below).

**The honest limit — do not skip this.** The ledger implies keys unlock write
retries. They do not, not safely:

- Retrying a write is only safe if the path is **covered** by the middleware.
- Coverage is **not in the OpenAPI spec** (§ 1.4), so it cannot be drift-checked.
- Hand-maintaining a copy of the covered-path list in the CLI is precisely the
  "client's own docs asserting facts about the server" failure this repo has been
  bitten by twice.

**Therefore ship the conservative version now:** send the key on every non-GET/HEAD
request, keep the existing refusal to auto-retry writes. Auto-retry stays off.

> **⚠ CORRECTION — the sentence that used to be here was wrong, and it is the
> one that would send someone re-implementing this the same wrong way.**
>
> It claimed the gain was that "when a user or agent re-runs a write after an
> ambiguous failure, the second call replays instead of double-creating."
> **It does not.** A key minted per process protects exactly one thing: the 428
> re-send in `_heal_428`, the only path in this CLI that repeats a write. Two
> runs of `uku tasks create` are two processes, two keys, and two tasks — which
> is *correct*, because those really are two requests to create something.
>
> Cross-invocation safety cannot be inferred and has to be asked for. That is
> what the new **`--idempotency-key`** flag is: an agent retrying a write it is
> unsure about passes the key it used the first time and gets the original
> response back. Deriving the key from the request instead would make two
> deliberate identical creates collide and silently return the first one.
>
> Shipped: key minted in `do_request`, `_heal_428` sets `_UKU_IDEM_REUSE` so the
> re-send carries the first attempt's key, and the flag is validated at its parse
> site (newline → header forgery in the `curl -K` config; >200 chars → the API's
> own 400). Pinned by `tests/cases/retry-428.sh` §C3 and `write-safety.sh` §C3.

**And file the API-side ticket** so option (b) never becomes necessary: ask
`uku_service` to declare idempotency coverage in the OpenAPI spec (e.g. an
`x-idempotent: true` extension per operation). Then Phase 3's gate can verify it,
and safe write-retry becomes available without a hand-maintained list. This is a
three-surface propagation item — MCP has the same blind spot.

**Related drift found:** `uku_service/backend/api_v3/routers/docs.py:446-455` still
tells callers the header is honoured only on `POST /invoices, /contracts,
/agreements, /time-entries`. The middleware actually covers ~30 paths and
patterns. Report upstream.

**Tests:** the suite currently exercises **no 409 at all**. With C3 that becomes a
gap with teeth — `IDEMPOTENCY_KEY_REUSED` and `IDEMPOTENCY_CONFLICT` both need
cases, plus a replay case asserting the CLI does not treat `Idempotency-Replayed`
as an error.

### 5.2 C5 — surface `warnings[]`

**Where — and the obvious answer is wrong.** This went into `render()` first,
which looked right and was not: `table()`'s TTY branch renders columns and
returns **without ever calling `render()`**, so the one caller who most needs to
be told — a person reading a table — was the only one who never was.

**Shipped from `check_status()`'s 2xx branch**, which is on the path of every
response and is therefore the only place it can be done once. `_agent_ok()`
additionally carries them inside the envelope so an agent has one document
rather than two channels to reconcile. UKU_SOFT probes (the ETag fetch behind a
428, the search fan-out) stay silent — a warning about a request the user never
made is noise.

Known codes: `TIME_ENTRY_OVERLAP`, `MONITOR_OVERLAP`, `AGREEMENT_OVERLAP`, plus
deprecation notices. Shape: `{code, message}`, sometimes with `details`.

On a TTY: print to stderr, do not pollute stdout. In `--agent`: add a `warnings`
key to the envelope (additive, so not a break, but regenerate `.surface`).

### 5.3 C6 — separate the exit codes

Current mapping, measured in `check_status()` (`bin/uku:1174-1264`) plus
`do_request:994`:

| HTTP | code | name |
|---|---|---|
| 2xx | 0 | ok |
| 401 | 2 | auth |
| 403 | 2 | auth |
| 409 | 3 | api |
| 412 | 6 | conflict |
| 428 | 3 | api |
| 429 | 5 | network |
| 5xx | 3 | api |
| 400 / 404 / 422 | 3 | api |
| transport failure | 5 | network |

**This is the highest-risk item in the plan for the PRIME DIRECTIVE** — exit-code
*meanings* are explicitly named as contract, and agents branch on `$?`. Every
change here is a surface break.

Two specific defects worth the break:
- 401 and 403 collapse, forcing prose parsing to tell "bad credential" from
  "insufficient scope".
- `MISSING_COMPANY` is **HTTP 400** (verified,
  `uku_service/backend/api_v3/dependencies.py:186`, test at
  `test_auth_and_scopes.py:44`) and therefore lands on code 3 = "api/validation".
  An agent reading "validation" retries with different data and loops forever.
  It is an auth-configuration failure.

**There is a worked taxonomy to start from**, not a blank page:
`reference/python-client/src/errors.py` implements nine distinct codes over the
same API, and independently arrived at the `MISSING_COMPANY` → *auth* mapping for
the same reason (`reference/python-client/README.md:48-52`). Read it before
designing a new one; converging on the sibling client's taxonomy also stops the
two from disagreeing about what a given failure means.

**Recommendation:** batch **all** exit-code changes into a single release with a
minor-version bump, every one recorded in `.surface-breaking` with its rationale,
and `_exit_name()` (`bin/uku:1584-1589`) plus the hardcoded map in `_help_agent`
(`bin/uku:3587`) plus the `usage()` table (`bin/uku:4115-4270`) updated in
lockstep. **Do not** add a compatibility flag — permanent complexity for an
audience that reads changelogs.

**Open question for the CTO:** is separating 401/403 worth a documented break at
all, given someone has scripted `[ $? -eq 2 ]`? My read: yes, once, batched — but
it is your call, and it should be made deliberately rather than absorbed as an
implementation detail.

**⚠ There is a GREEN TEST TO FLIP when this lands.** `tests/cases/exit-codes.sh`
now covers 400 and asserts, by name:

```
assert_status 3 'MISSING_COMPANY is exit 3 today — see refactoring-cli.md 5.3'
```

That pins **today's wrong behaviour on purpose**, so the change is visible as a
deliberate edit rather than discovered as a mysterious failure. Whoever
implements C6 flips that assertion to `2` in the same commit. The same file also
covers a validation 400 and a 409 `IDEMPOTENCY_KEY_REUSED`; only the
`MISSING_COMPANY` one is expected to move.

### 5.4 C9 — path traversal, at the request layer

**Two vectors, one guard.**

- `_resolve_ref` (`bin/uku:1835`): `--by-id` sets `UKU_REF_ID="$arg"` with **no
  validation**, and it is interpolated into `/api/v3/clients/$id` (`bin/uku:2944`),
  `/api/v3/tasks/$id` (`bin/uku:2953`), etc. `_looks_like_id` (`bin/uku:788`) runs
  only on the auto-detect path.
- `cmd_api` (`bin/uku:3078-3109`): raw path from argv, only a leading-slash
  normalisation at `bin/uku:3087`.

**Guard in `do_request()`, immediately after `bin/uku:913`** (`url="$UKU_BASE$path"`)
— before any credential file or body is written. Reject any path containing a
`..` segment, and require the path to start `/api/v3/` unless an explicit
override is in play. One place, catches both.

Also re-validate ids extracted from pasted URLs (`_url_last_id`, `bin/uku:1746-1778`),
which today are not passed through `_looks_like_id` either.

**Test per Lesson 5 — assert on side-effect absence.** `tests/cases/traversal.sh`
is already the model: it checks the victim file still exists rather than that a
message was printed. Extend it to the `--by-id` vector.

### 5.5 C7, C10, C11, C14 — the small ones

| ID | Site | Fix |
|---|---|---|
| C7 | `_announce_base` | ❌ **IMPLEMENTED, MEASURED, REVERTED — see below.** |
| C10 | `bin/uku:1061` and `bin/uku:1084` | `local IFS=','; set -- $raw` — unquoted, so pathname expansion applies to `--fields`. Quote, or `set -f` around it. Two sites, same bug. |
| C11 | `scripts/install.sh:215` | The non-interactive branch runs `setup agents` unprompted, which writes `~/.claude/skills/uku/SKILL.md` (`_setup_claude`, `bin/uku:4032-4042`) and appends to `./AGENTS.md` in the cwd. Make the non-interactive path require explicit `UKU_SETUP_AGENT`, defaulting to none. |
| C14 | `bin/uku:979` | `curl` runs with `-sS` and unsuppressed stderr, so on an unreachable host curl's raw error prints alongside the CLI's own clean message at `bin/uku:994`. Capture curl stderr to a file; emit it only under `--verbose`. Note `auto_update` (`bin/uku:4401`) and the doctor probe (`bin/uku:3206`) already do `2>/dev/null` — this is inconsistency, not oversight. |

#### C7 — why it was reverted, and what would change the answer

The ledger calls silent cleartext-to-loopback the one gap in the transport
fence. It was implemented and measured, and three independent sources said no:

- **It can only ever fire on local development.** Non-loopback cleartext is
  already refused outright in `_check_base_transport`, so there is no other
  situation left for it to warn about. It is not a warning about a risky
  moment; it is a line on every command of an ordinary dev day.
- **Four existing assertions broke, and they are contract** — *"a successful
  read writes nothing to stderr"*, *"nothing is offered on stderr when nobody is
  watching"*, *"nothing about the missing jq leaks into a clean read"*.
- **`reference/python-client/README.md:43` reached the same conclusion
  independently:** announcing on every command trains people to skip the warning
  that matters, and *"`bin/uku` makes the same call; it is the right one"*.

There is also no low-noise version available: every Uku key is `uku_live_`,
there is no test-key tier, so the CLI cannot warn only when a *production*
credential is at stake.

**What would change the answer:** a key tier that marks non-production keys, or
a persisted once-per-base acknowledgement rather than once-per-invocation. The
reasoning is recorded in `_announce_base` itself so it is not re-litigated from
scratch. **The CTO can overturn this** — it is a two-line change plus four test
updates.

### 5.6 `uku health` — the one C8 item that ships now

`GET /api/v3/health` is **released** and needs no credential. `need_auth()`
(`bin/uku:563-570`) currently gates most commands; `doctor` already demonstrates
the credential-free pattern (`bin/uku:3195-3352`, probes with `UKU_SOFT=1`).

Add `uku health` bypassing `need_auth`, dispatched alongside the existing
credential-free routes (`help`, `version`, `completions`, `setup` — `bin/uku:4426-4454`).
`uku capabilities` waits for Phase 4.

### 5.7 Test-suite gaps to close in this phase

Measured coverage: 400 **absent** (the only match is `head -c 400`, a byte count),
409 **absent**. Both 412 and 428 are heavily covered.

Concrete 400 cases, taken from handlers rather than invented:
- `/search` with `q` under 2 chars after trim → 400
- `/search` `category=note` without `client_id` → 400
- missing `X-Uku-Company` → 400 `MISSING_COMPANY`

409 cases arrive with C3 (§ 5.1).

**✅ Done.** shellcheck is stage 3 of `bin/ci`, gating at severity **warning**,
where the repo is clean. It earned its place on the first run: two genuinely
dead variables and a `cd` without a failure guard in `bin/ci` itself.

Scope is split deliberately — shipped code gated with nothing excluded; test
cases exclude exactly `SC2034` and `SC1112`, both false positives against this
harness, with the reasons in `bin/ci`. Notes stay ungated (`SC2015`, `SC2012`
are deliberate idioms). **Missing shellcheck reports SKIPPED, not passed** — a
stage cannot gate what it cannot run, so Phase 3's CI must install it.

HTTP coverage is now 200 201 400 401 403 404 409 412 422 428 429 500 503.

---

## 6. Phase 3 — the API-anchored drift gate

**Goal:** make "never ship ahead of production" mechanical.
**Effort:** ~1-2 days. **Must precede Phase 4.**

> ### ✅ SHIPPED 2026-08-04
>
> Three parts, each checking something the others cannot:
>
> | | |
> |---|---|
> | **27 `op` facts** in the surface table | Ratcheted by the existing `check-surface.sh` with no changes to it — the emitter was already fact-kind-agnostic, as § 6.1 predicted |
> | **`scripts/check-api.sh`** + `.api-released` (182 ops) | The ship gate. Offline on PRs, `--live` for drift |
> | **`tests/run.sh` op coverage** | Every operation observed on the wire must be declared. Currently *20 observed, all declared* |
>
> `bin/ci` is now **seven** stages and runs in GitHub Actions on every push and
> PR; a second workflow fetches the live spec daily.
>
> **Two things measurement changed:**
>
> - **Parameter names had to be normalised on both sides.** The spec writes
>   `/tasks/{task_id}`, the CLI declares `/tasks/{id}`. Without this the gate
>   reported **14 false "ahead of production" failures on its first run** and
>   would have blocked everything. Verified no two distinct operations collapse:
>   182 raw → 182 normalised, zero collisions.
> - **Path normalisation is by position, not shape.** Shape-matching has to guess
>   whether a segment "looks like" an id, and it guessed wrong on `a..b` — the
>   C9 control asserting dots inside a segment are *not* a traversal.
>
> Proven by mutation: declaring `GET /api/v3/search` (built, 404s in production)
> fails the ship gate naming it; an operation vanishing from production fails the
> drift check.

### 6.1 What the existing machinery actually supports

Better than the handover assumed, with one real constraint it missed.

- `check-surface.sh` is **fact-source-agnostic**. It runs `uku --dump-surface`
  (`check-surface.sh:37`) and diffs the *output* with `comm` — it does not parse
  `bin/uku`. A new fact kind needs **zero changes** to it. The ratchet
  (unacknowledged removals always fail, even under `--update`, enforced at
  `check-surface.sh:77-85` and again at `95-102`) applies automatically.
- The emit point is `_surface_emit()` (`bin/uku:3457-3495`); `_dump_surface()`
  (`bin/uku:3498`) just sorts whatever it produces.
- **The constraint:** `bin/uku` ships as a single checksum-verified file with no
  sidecar. A spec cannot be read from disk at runtime. Any API-derived fact must
  be **transcribed into the script** and committed.
- **`tests/cases/surface.sh:46` asserts a closed set of fact kinds** —
  `^(cmd|cmdalias|sub|subalias|flag|gflag|doc|arg|note) `. Adding a kind fails
  this until the regex is widened. Easy to miss.

### 6.2 Design — declare what the CLI *uses*, not the whole API

**Do not transcribe all 182 released operations into `bin/uku`.** The file is
already 258 KB, agent context cost is a stated design value (Lesson 6), and
`--dump-surface` would balloon. Instead:

**Inside `bin/uku`:** `op METHOD /path` facts for **only the operations the CLI
actually calls** (~25-40 lines). Emitted from `_surface_emit()` (`bin/uku:3457`).
Ratcheted by the existing `check-surface.sh` for free.

**Outside `bin/uku`:** a new `scripts/check-api.sh` plus a committed
`.api-released` snapshot of production's operation list. Two checks:

1. **Ship gate (the important one).** Every `op` fact must exist in
   `.api-released`. If the CLI declares an operation production does not serve,
   fail. This is what makes shipping ahead of production impossible.
2. **Coverage drift.** Diff live production against `.api-released`. New
   operations appear as NEW SURFACE; removed ones fail until acknowledged —
   the same asymmetric ratchet, applied to the API.

**CI split that keeps PRs deterministic:** PR runs read `.api-released` offline —
no network, no flakiness. A **daily scheduled job** fetches production, refreshes
the snapshot, and opens a PR when production has moved. API-side changes surface
within a day instead of at the next release.

> **⚠ A committed spec snapshot has already gone stale in this repo's own
> history — do not repeat it.** The retired Python client built exactly this
> machinery (`reference/python-client/src/refresh_spec.py`) and its verdict is
> recorded in `reference/python-client/README.md:58`: the generated models "were
> never wired into response parsing, and the committed snapshot went **34
> operations stale** — spec machinery that exists but is not gated is
> decoration."
>
> That is the failure mode of the design above, stated by the last person who
> built it here. The daily refresh job is not a nice-to-have that can slip to a
> later phase; **it is the thing that makes `.api-released` a fact rather than a
> souvenir.** If the schedule cannot be stood up, do not ship the snapshot —
> have `check-api.sh` fetch live and accept the flakiness instead, because a
> stale snapshot that reports "clean" is worse than no gate at all.

### 6.2.1 The hole this design has, and how to close it

As described so far, the `op` table is **a third hand-maintained source of truth**,
alongside the dispatcher and the surface table. Nothing ties it to the paths
`do_request()` actually receives. Curated commands interpolate their paths
(`bin/uku:2944`, `bin/uku:2953`) and `cmd_api` takes raw argv, so the table can
silently omit an operation the CLI genuinely calls — and the gate stays green
while the CLI hits an unreleased endpoint. **That gates the declaration, not the
behaviour**, which is the same failure mode § 6.4 describes for the
dispatcher/surface-table split, and the same one the handover's Lesson 3 warns
about: a test that cannot fail retires the question.

`check-drift.sh` already solved this class of problem twice and both remedies
apply:

- **Static analogue of checks 3a/3b** (`check-drift.sh:116-137`): extract every
  literal `/api/v3/…` string in `bin/uku` plus every `_res_path` target
  (`bin/uku:1706-1718`), and require each to be covered by an `op` fact. Cheap,
  offline, catches omissions.
- **Executed analogue of check 3c** (`check-drift.sh:139-163`, which runs every
  declared command against the real dispatcher rather than trusting a parse): the
  test suite already records **every request byte the CLI sends** to the fixture
  server (`tests/server.py:146-164`, read back via `tests/lib/reqlog.py`). Add a
  suite-wide assertion that every distinct `(method, path)` observed across the
  whole run is covered by an `op` fact. That anchors the table to **observed
  behaviour**, not to a parse — and it is nearly free, because the requests are
  already being logged.

Neither is optional if Phase 3 is to be worth building. Verify feasibility of the
static half before committing to it; the executed half is the stronger of the two
and should ship regardless.

**A third hole, found 2026-08-04 and NOT closed: the gate cannot see the OAuth
surface at all.** `SPEC_URL` is `app.getuku.com/api/v3/openapi.json`
(`check-api.sh:54`) — FastAPI-generated from the api-v3 router table. But
`/oauth/authorize`, `/oauth/token`, `/oauth/register` and every `.well-known`
document are served by the **Tornado app**, not api-v3 (measured: 200 on `:8885`,
404 on `:8890`). They can never appear in that spec, so:

- an `op` fact for an OAuth endpoint fails check 1 **permanently** — production
  does serve it, the spec just cannot say so; and
- parking it in `.api-pending` silences check 1 but **deadlocks
  `scripts/release.sh`**, which refuses while any entry remains. Permanently
  pending is not a state the design has.

So Phase 6 lands exactly where the gate is blind, and the obvious escape hatch
makes it worse. Do not declare OAuth endpoints as `op` facts until this is
resolved. Options, cheapest first: a second fact kind checked against the app
origin rather than the spec; a `.well-known`-derived source of truth (it is
public and machine-generated, which is the property that made `op` facts work);
or accept the blind spot and cover OAuth by executed tests only, recording it
here as a known gap. **Decide in the Go session, before writing the auth code.**

### 6.3 Files that change

| File | Change |
|---|---|
| `bin/uku:3398` (`_surface_table` neighbourhood) | New declared table of operations the CLI calls |
| `bin/uku:3457` (`_surface_emit`) | Emit `op %s %s` per declared operation |
| `tests/cases/surface.sh:46` | Widen the fact-kind whitelist to include `op` |
| `.surface` | Regenerate via `scripts/check-surface.sh --update`; review the diff |
| `scripts/check-api.sh` | New |
| `.api-released` | New, committed snapshot |
| `bin/ci` | New stage |
| `.github/workflows/` | New — none exists today |

`check-drift.sh` needs **no change**: its discoverability check (check 4) loops
only `cmd`, `gflag` and `doc` facts (`check-drift.sh:171-196`), so `op` facts
impose no `--help` obligation and need no `.surface-internal` entries.

**Deliberate decision:** `_help_agent_cmd`/`_help_agent` (`bin/uku:3548-3589`)
enumerate fact kinds explicitly rather than passing them through, so `op` facts
will be omitted from the agent JSON unless wired in. **Recommendation: leave them
out** — the ratchet enforces existence regardless, and C12 says the agent
envelope needs to get smaller, not larger.

### 6.4 CI must exist at all

`bin/ci` is currently "run before you push" — discipline, not a gate. It does run
five stages in order (syntax → bash-3.2 scan → check-surface → check-drift →
tests), accumulates failures without short-circuiting, and exits non-zero
correctly (`bin/ci:26-96`). It just is not wired to anything.

There is **no `.github/workflows/`**. Add one that runs `bin/ci` on every PR, plus
the daily `check-api.sh` schedule.

**Also fix the drift-in-the-drift-checker:** `check-drift.sh:14-24` documents four
checks; the file implements five (check 5, breadcrumbs → surface, at
`check-drift.sh:198-256`, is undocumented).

### 6.5 Done when

- [ ] `scripts/check-api.sh` fails when an `op` fact is not in production — prove
      by injecting a fake op (Lesson 1)
- [ ] A new production operation shows as NEW SURFACE within 24h
- [ ] `bin/ci` runs on every PR and blocks merge
- [ ] `tests/cases/surface.sh` passes with the widened kind set

---

## 7. Phase 4 — API-gated capability work

**BLOCKED** until the `uku_service` `staging` branch reaches production. Nothing
here may merge to a releasable state before then; the Phase 3 gate enforces it.

Implement and test against a **local or staging** server, per the platform rule
that everything is in development/staging testing.

### 7.1 C2 — real completion

Add `uku tasks complete <ref>` and `uku tasks reopen <ref>` to `cmd_tasks`
(`bin/uku:2948-2956`), the surface table row (`bin/uku:3405`), and the help card
generation (`bin/uku:3633-3651`).

Measured from `uku_service/backend/api_v3/routers/tasks.py:210-263`: **no request
body**, response is `SingleResponse[TaskOut]`. `/complete` sets `finished_at`,
resets the "my later" tag, auto-finishes the client-portal side, arms
`finished`-trigger automations, and writes an activity + notifications. It returns
**400** on completion-validation failure (required custom fields, blocking
dependencies, incomplete checklist, required time entry/topic) and **422** if the
task has no active client. `/reopen` moves to `in_progress`, clears `finished_at`,
writes a `task_in_progress` activity — and has a documented gap: **it does not
reset the client-portal `finished` flag** a prior completion set.

The handler's own docstring confirms C2 first-hand: a bare status write "skips all
of the above and is deprecated for completion."

**Open question:** should `uku tasks patch --data '{"status":"finished"}'` now warn,
or refuse? Refusing is a surface break under the PRIME DIRECTIVE. **Recommendation:
warn** — stderr on a TTY, a `warnings` entry in the agent envelope (which C5 has
already built by then) — and do not refuse. Flag for the CTO.

### 7.2 C4 — search as a union

Per § 1.1. Call `GET /search` **and** retain the four list endpoints it does not
cover (clients, members, products, projects); dedupe `tasks`, which both return.
`UKU_SEARCH_RESOURCES` is at `bin/uku:1731`; the fan-out loop at `bin/uku:3019-3055`.

`/search` parameters: `q` (min 2 chars trimmed), `category` (`all|invoice|contact|
supplier|contract|task|note`), `client_id` (**required** when `category=note`),
`limit` (1-20, per category, default 5). Response is a flat `SingleResponse` with
all six keys always present — **no pagination, no cursor**. Invoices are withheld
(empty list, not an error) for keys without `financials` scope.

Then delete the falsehood at `bin/uku:3068` and rewrite the rationale at
`tests/cases/search.sh:3-5`. The output gains resource keys → **surface change,
record it**.

### 7.3 C8 / C13 — capabilities replaces the hand-maintained map

Add `uku capabilities` (credential-free, like `uku health`). Replace
`_api_describe_all` (`bin/uku:3121-3142`, a ~20-line hand-maintained heredoc
filtered by `grep -iA1` at `bin/uku:3116`) with live `/api/v3/capabilities`.

`GET /api/v3/capabilities?surface=rest|mcp` is unauthenticated by design and built
from the same enforcement tables the routes use, so REST and MCP cannot drift.
It returns `entities` (per-resource read/create/update/delete booleans plus
`<verb>_unavailable_because` reasons), `curated_tools`, `not_available`, and a
`how_to_use` block. It is derived from enforcement, not hand-authored — which is
exactly what C13 needs.

**Unverified, check on release:** whether `/teams`, `/workflow-templates`,
`/reports/*` and `/mcp-usage` appear as first-class `entities` or only as raw
routes. This was read from the builder, not from a running server.

### 7.4 New capability coverage

`/teams`, `/workflow-templates` (+ `/apply`, `/push`), `/reports/kpi-summary`,
`/reports/time-summary`, `/mcp-usage`, `POST /tasks/bulk-action`,
`invoices/{id}/mark-unpaid`, and cursor-pagination follow (`meta.next_cursor` is
passed through today but never followed). Scope these individually once released
— they are additions, so `check-surface.sh --update` covers them.

---

## 8. Phase 5 — progressive disclosure

> ### ✅ SHIPPED 2026-08-04
>
> `uku --help --agent` **14,621 → 7,217 bytes; 1.44× the human help → 0.69×.**
> 7,622 of the removed bytes were per-command notes describing twenty commands
> the agent was not about to run. Nothing was deleted — the top level became an
> index carrying a `more` field, and `uku <cmd> --help --agent` still returns one
> command's full card with its notes.
>
> **The skill was measured and deliberately left alone** at ~4.6 K tokens. The
> Basecamp reference spends ~11–12 K covering 155 endpoints; ours is under half
> that, and its content is the safety contract, retry doctrine and naming rules.
> Cutting it would optimise the wrong number and remove the guidance that stops
> an agent doing damage. It *did* contain two claims this change falsified —
> corrected, along with a stale endpoint count and the missing `uku health`.
>
> **Guarded, because nothing else could see it.** Putting the notes back changes
> no `.surface` fact, so `check-surface` passes and the regression ships silently.
> `tests/cases/agent.sh` now asserts the size relationship directly; verified by
> re-injecting it, which returns the ratio to 1.46.

### The original plan


C12, measured: human `--help` 9,767 B, `--help --agent` 14,045 B (1.44×), skill
blob 18,337 B (`bin/uku:3847-4024`). The machine variant must become the lean one.

Follow Lesson 9 — teach discovery rather than enumerating. Basecamp covers 155
endpoints in ~11-12 K tokens via decision trees, a quick-reference table, and
"walk the tree." Constraints belong in an introspectable `notes` field, not inlined.

Do this **after** Phase 4 so the surface has stopped moving. Every change here is
`--help` output, which `check-drift.sh` check 4 already gates against `.surface`.

---

## 9. Phase 6 — the auth decision

Still the single largest open question, but **substantially narrowed by the API
team's answers of 2026-08-04 (§ 0)**. A pasted integration key is **tenant-wide**
and can carry `admin`/`financials`; an OAuth-minted key is **person-scoped**,
cannot carry `admin` under any circumstances, and re-authorizes `financials` at
every mint. Today every CLI user and every agent holds the most powerful
credential the platform issues. That premise is confirmed against the code, not
inferred — lead the rewrite with it.

### 9.0 What the answers settled, and what they cost

**Device flow does not exist.** It is a few days of API work, with no blocking
objection, but it is not there today and the CLI cannot wait on it.

**Recommended shape: build flow-agnostic, keep the grant pluggable.** Everything
expensive is shared between the two flows — token storage, rotation with
reuse-safety, the origin fence, RFC 8414 discovery with
`follow_redirects=False`, scope handling, the error taxonomy. Only the grant
branch differs. Build that layer in Go now with `authorization_code` + PKCE as
the first grant; adding `device_code` later is one branch, not a rewrite.
Nothing is wasted either way and the rewrite does not stall on an API
dependency.

**Discovery comes from the app origin, not api-v3.** Fetch
`/.well-known/oauth-authorization-server` from the app base URL. `:8890` will
404 forever — that is not a bug to work around, it is the wrong host.

**The `client_id` must be pinned, and that is not a drift violation.** Device
flow is to be allow-listed to first-party `client_id`s only (§ 0c), so this CLI
ships a fixed `client_id` and never calls `/oauth/register`. It reads as a
violation of *"never assert facts about the server"* and is not: a `client_id`
is a fact about the **client**, and a client's own identity cannot drift without
the client being reissued. Endpoints still come from `.well-known`. Only the
identity is pinned, and pinning it is what lets the consent page name "Uku CLI"
with authority instead of echoing attacker-controlled free text.

Note this needs a **server-side change** — `OAuthClient` has `client_id`,
`client_name` and `redirect_uris` and no trust column — so it is an API
dependency, tracked in § 0.1.

### 9.1 Scope handling — read what was granted, never what was asked

`scopes_supported` is `["read","write"]`; `financials` is deliberately omitted so
connectors cannot request it, yet it can still arrive via the consent checkbox.
So the CLI **cannot request `financials` and may nonetheless receive it**. Two
consequences:

- Read the granted scope from the **token response**, never from what was
  requested. It can also be *downgraded* at any refresh if the user lost
  `MANAGE_ACCOUNT`.
- When a financials command runs without the scope, fail pointing at the consent
  checkbox — not a generic 403. An agent that sees "forbidden" retries; one that
  is told "re-authorize and tick Financials" acts.

**A product call, not a footnote:** if `financials` is barred over device flow
(§ 0c), then invoice and billing commands are **unavailable on that path
entirely**. That is a capability regression against pasted keys, and it needs a
decision rather than a default.

### 9.2 Distinguish a 403 from a redirect on the discovery fetch

Production 403s `.well-known` today (§ 0). Collapsing that into "discovery
failed" throws away the one signal that separates *your edge is misconfigured*
from *your base URL is wrong* — and given § 0, the first is the likelier cause
right now. Keep them distinct in the error path.

### 9.3 Carried over, still true

The server side of the browser flow is ready — `_valid_redirect_uri` permits
plain-http loopback, so it needs no server change. The bash cost that motivated
the Go decision was concentrated exactly here: PKCE S256 needs SHA-256 +
base64url, the flow needs a loopback listener, the exchange needs JSON parsing.

The API issues refresh tokens (24h access, 90d rotating refresh, reuse detection
revoking the whole family). Persist the rotated pair atomically, never send a
refresh token twice, and refuse to use a credential against an origin other than
the one it was minted for (Lesson 10 — found in *both* Uku CLIs, and one had the
fence on its refresh token but not its access token).

Device flow remains the better end state for this audience — it works over SSH,
headless, and when the browser is on another machine — per the Basecamp
reference. It is now a question of when the API ships it, not whether to design
around it.

**Read `reference/python-client/src/oauth.py` before writing a line of this.** The
audit called it "the best code in either repo", and it encodes one Uku-specific
trap that is not obvious from the RFCs:

> The Uku server builds its discovery metadata from `[api_v3] app_base_url`,
> which **defaults to `https://app.getuku.com` and is set in no dev ini**. So
> `--base http://127.0.0.1:8885` against a local server sends the browser to
> **production's** consent page and POSTs the code to production.

**Reproduced first-hand 2026-08-04**, so this is no longer a borrowed claim —
the local dev app really does serve `"issuer": "https://app.getuku.com"` and
production endpoints, while `https://staging.getuku.com` correctly serves its
own. The API team confirms `issuer` comes from `ApiV3Config.get_app_base_url()`
and deliberately never from the `Host` header, which is what makes it stable to
pin against — and, on an unconfigured dev box, exactly this trap. Expect strict
RFC 8414 validation to **refuse a local server** until that ini value is set;
that is the check working, not a bug to loosen.

The defence is RFC 8414 §3.3 issuer validation with **`follow_redirects=False`**
on the well-known fetch, anchored to the URL *the user asked for* rather than the
response URL — because a 302 to production returns a document that legitimately
names production, so the issuer check passes while every endpoint points away.
This is Lesson 11 with a concrete local reproduction.

Also from that client, and cheap to get wrong: the ETag must be lifted from the
response **header**, never rebuilt from the body (`format_etag` emits `…+00:00`
while the JSON body serialises `…Z`, so reconstruction guarantees a 412), and the
single-use refresh token must be claimed under a lock *in the same critical
section that marks it used* — Uku's server revokes the whole token family on
reuse, so a double-send is a hard logout for the user.

**This phase is the strongest argument for the rewrite decision.** Resolve
§ 11.1 before starting it, not during.

---

## 10. Hand-off prompt — getuku-astro (Phase 0, § 3.1)

Ready to paste to whoever owns the marketing site. Self-contained; needs no
uku-cli knowledge. Kept verbatim in this plan so the two stay in sync.

> **Repo:** getuku-astro. **File:** `vercel.json` only. Deploy to production.
>
> **Why:** `https://getuku.com/install-cli` is the published one-liner for our CLI
> (`curl -fsSL https://getuku.com/install-cli | sh`). It currently redirects to the
> **main branch** of the CLI repo — mutable, so anyone who can push to main instantly
> changes the script every installer pipes into `sh`. A second route, `/uku`, serves
> the raw CLI binary with **no integrity checking at all**, bypassing the installer's
> checksum verification.
>
> **Change 1** — in the `redirects` array, repoint **both** `/install-cli` and
> `/install-cli/` from `.../uku-cli/main/scripts/install.sh` to
> `.../uku-cli/v0.6.0/scripts/install.sh`. Both rows matter: Astro normalises to the
> trailing slash before Vercel evaluates redirects, so the request takes two hops and
> changing one leaves the old path live.
>
> **Change 2** — repoint the `/uku` and `/uku/` rows from `.../main/bin/uku` to
> `.../v0.6.0/bin/uku`. **Do not delete them.** This route serves the raw CLI binary with
> no integrity checking at all, so it must stop tracking a mutable branch — but until
> 2026-07-25 it was the *actual* download path used by our installer, so old installers
> vendored into Dockerfiles or CI jobs may still call it. We will check traffic and remove
> it later. Do not confuse it with `/uku-partner-program`, which is a real page and must stay.
>
> **Change 3** — **add** two new rows, `/uku.sha256` and `/uku.sha256/`, pointing to
> `https://raw.githubusercontent.com/uku-owl/uku-cli/v0.6.0/bin/uku.sha256` (returns 200).
> Our older installer fetched this checksum file next to the binary, but no redirect serves
> it, so the fetch 404s and those installers silently skip verification and install anyway.
> Adding the row restores integrity checking for them. This is an addition, not a change —
> nothing today can break from it.
>
> **Change 4** — extend the redirect guard to cover `vercel.json`. Today
> `.github/workflows/redirects-test.yml` → `scripts/test-trailing-slash.mjs` validates only
> `astro.config.mjs` redirects and the built `.vercel/output/config.json`; it never reads
> `vercel.json`, so these four routes have no automated coverage at all. Add an assertion
> that `/install-cli` and `/uku` resolve, with a 200, to the destinations above. This is not
> hypothetical — commit `511de259` records `/install-cli` 404ing in production because
> Vercel's `trailingSlash: true` 308'd the bare path before the redirect rule matched, and it
> was caught by hand, not by CI.
>
> **This is byte-identical today** — the tag and main both hash to
> `60cacc5149292bfd383a019d5269508853a5e4135493589565f6e67bd52d6e36`. Users get exactly
> the same bytes; nothing about the install experience changes.
>
> **Do not "helpfully" fix these:**
> - It does **not** freeze anyone on CLI v0.6.0. The installer resolves the newest
>   release at runtime from a pointer on main. We are pinning the *installer*, not what
>   it installs. New CLI releases keep reaching users with no website deploy.
> - Do **not** change the published one-liner anywhere it appears (`src/data/prompts.ts`,
>   `src/pages/agents.astro`, `src/pages/et/ai-agentidele/index.astro`). The vanity URL is
>   permanent.
> - Do **not** move these into `astro.config.mjs`, and do not touch any other redirect.
>
> **Verify after deploying to production**, and paste all four outputs into the PR:
> ```
> curl -sS -o /dev/null -L -w '%{url_effective} %{http_code}\n' https://getuku.com/install-cli
> #   expect: https://raw.githubusercontent.com/uku-owl/uku-cli/v0.6.0/scripts/install.sh 200
> curl -sS -L https://getuku.com/install-cli | shasum -a 256
> #   expect: 60cacc5149292bfd383a019d5269508853a5e4135493589565f6e67bd52d6e36
> curl -sS -o /dev/null -L -w '%{url_effective} %{http_code}\n' https://getuku.com/uku
> #   expect: https://raw.githubusercontent.com/uku-owl/uku-cli/v0.6.0/bin/uku 200
> curl -sS -L https://getuku.com/uku.sha256
> #   expect: a line ending in "  bin/uku"
> curl -sS -o /dev/null -w '%{http_code}\n' -L https://getuku.com/uku-partner-program/  # expect 200
> ```
>
> **End-to-end check that matters most** — this is what a real user runs:
> ```
> curl -sS -L https://getuku.com/install-cli | UKU_BIN_DIR=/tmp/ukutest UKU_SKIP_SETUP=1 sh
> /tmp/ukutest/uku --version    # expect 0.6.0
> ```
> It must print "Checksum verified". If it does not, stop.
> If the hash in check 2 differs, **stop** and tell the CTO before announcing the deploy.
>
> **Access note:** until further notice, whoever can deploy getuku-astro controls what
> every CLI installation downloads and executes. Treat production deploy access to this
> repo at the same level as production application access.

---

## 11. Open decisions — resolve before the phase that needs them

### 11.1 Bash, or rewrite in Go? — DECIDED 2026-08-04: **Go**

**Resolved.** The CTO approved the rewrite on 2026-08-04. What follows is the
argument that produced the decision, kept because the reasoning is what stops it
being re-opened on a bad day. Execution notes are in § 0.

#### The claim that turned out to be wrong

The old text here said the suite "is portable in spirit but not in code — a
rewrite must pass the existing behavioural tests, which are bash harness +
Python fixture server. That is a real port, not a copy." **Measured, that is
false.** The harness drives the CLI as a **subprocess** — 301 `uku …`
invocations, 18 `uku_stdin`, 5 `uku_tty`, all of which exec `$UKU_BIN` and
assert on stdout/stderr/exit status and on what reached the fixture server. The
fixture is a language-agnostic HTTP server.

**A Go binary dropped at `bin/uku` would be held to all 1,410 assertions
unchanged.** One case needs a different technique: `update-trust.sh` greps
`bin/uku` for `UKU_INSTALL_URL_DEFAULT` / `UKU_UPDATE_URL_DEFAULT` as literal
source text (`tests/cases/update-trust.sh:37,51`), which a compiled binary would
have to expose some other way. Three cases use `--dump-surface`, but that is a
published command, not an internal.

This inverts the strongest argument for staying: the 51 commits of API
archaeology are **not** locked in the bash. They are in the tests, the `.surface`
table (403 facts) and `.api-released`, all of which survive a rewrite intact.
The PRIME DIRECTIVE is enforceable against a Go binary on day one.

#### What Go actually buys

1. **OAuth, which is the real blocker.** Measured against the running local
   server: `grant_types_supported: ["authorization_code", "refresh_token"]`
   (`oauth_handlers.py:183`) and **no device-authorization endpoint** — the
   `.well-known` document 404s. So the "device flow avoids the loopback
   listener" escape hatch does **not** exist today. A CLI login needs PKCE S256
   (SHA-256 + base64url), a **loopback HTTP listener**, JSON token parsing, and
   atomic persistence of a rotating refresh pair with reuse detection. In bash
   that is `python3` for three of the four, which contradicts the whole
   "curl + bash, jq optional" premise. In Go it is standard library.
2. **Distribution — the unfixed half of C1.** Phase 0 stopped the CLI installing
   things by itself, but `curl | sh` is still the only channel. Go gives signed,
   attested release binaries via Homebrew, Scoop, deb/rpm/apk, AUR and Nix, and
   makes signing natural rather than bolted on. This is the single biggest
   security improvement still available.
3. **A whole bug class stops existing.** `curl -K` config files exist only
   because argv is world-readable; they are why the key reaches the filesystem
   at all, and `tests/cases/no-residue.sh` exists solely to police the cleanup.
   In Go the credential goes in a header on an in-process request and never
   touches disk. C9 (`..` traversal), C10 (unquoted `--fields` glob) and the
   `IFS` hazards are likewise not expressible.
4. **Static analysis.** shellcheck at severity `warning` versus a type system
   plus `go vet` / `staticcheck`.
5. **Concurrency.** The search fan-out is 5 sequential curls. Go does them at
   once — a real latency win on the surface agents use most.
6. **jq stops being a branch.** Every "without jq it warns instead" path
   disappears, along with the matrix of tests covering them.
7. **Windows.** Currently absent from the repo entirely.

#### What it costs

1. **Auditability, which is a genuine product claim.** "It is one bash file, read
   it yourself" is worth something for a public CLI holding an accounting firm's
   tenant-wide key. A binary is opaque; the answer is reproducible builds plus
   signing, which is *more* trustworthy for most users but not for the ones who
   currently read the script.
2. **Release machinery.** Cross-compile matrix, signing key custody (already an
   open decision), macOS notarisation/Gatekeeper, a Homebrew tap to maintain.
3. **Two implementations, or a freeze.** Whichever way, there is a window where
   the bash is frozen. Two CLIs is the state this project has already been in
   once and correctly called "the worst state" (`reference/python-client/`).
4. **Scale.** 4,894 lines, 192 functions, ~30 commands. Weeks, not days.
5. **Drift the tests do not cover.** 1,410 assertions and 403 surface facts is a
   lot, not everything.
6. **bash 3.2 discipline is real and maintained** — no associative arrays, no
   `mapfile`, hand-written `_ver_gt` and `_urlencode`. That care should carry
   over rather than be discarded as legacy.

#### Recommendation — sequence it, do not choose between them

**Finish Phase 4 in bash first, then rewrite in Go.** Reasons:

- Phase 4 is now **unblocked** (the API runs locally on `:8890`, 218 operations,
  all four endpoints live). It is small: two task commands, a search union, and
  `capabilities`. Doing it in bash costs days, not weeks.
- Rewriting while the surface is still moving means porting a moving target and
  paying for every change twice. After Phase 4 the surface is stable, and
  `.surface` + the suite become a **frozen, executable specification** — which is
  the best possible starting condition for a rewrite, and one this repo is almost
  unique in having.
- The rewrite then delivers Phase 6 (OAuth) and Phase 1 (signed distribution)
  together, which is where Go earns its cost. Doing OAuth in bash first would be
  work thrown away.

**A third option worth pricing before committing:** ask the API to add
**device flow** (`urn:ietf:params:oauth:grant-type:device_code`). It is modest
server-side work, and it removes the loopback listener — the single hardest part
of OAuth in bash — while also being the better UX over SSH and in headless
agent environments. If that lands, "stay bash" becomes materially more viable
and the decision should be re-taken.

**Phases 0-3 were worth doing under either answer** — security, gates and
correctness, not architecture. They are done, and they carry over.

### 11.2 Auto-update — opt-in, notify-only, or signed-and-on? (Phase 0)

Recommendation: **notify-only now**, revisit signed-and-on after Phase 1. Agent
installs genuinely benefit from staying current; the objection is unattended
execution, not currency.

### 11.3 Exit-code break — worth it? (Phase 2, § 5.3)

Recommendation: yes, once, batched, documented. CTO's call.

### 11.4 Deprecated-completion path — warn or refuse? (Phase 4, § 7.1)

Recommendation: warn, do not refuse.

### 11.5 Licence

MIT here, Proprietary on the sibling Python client. Settle it. Independent of
every phase.

---

## 12. Cross-cutting, do not let these fall off

- **SOC 2.** `uku-cli` is in scope but absent from the asset inventory,
  subprocessor list and access-control matrix — the same gap as `infra` and
  `mailbox`. Close all three together, and **add getuku-astro deploy access** to
  the matrix (§ 3.3).
- **Three-surface propagation.** Every fix here is checked against MCP and API v3.
  Two already identified: the idempotency spec-declaration request (§ 5.1) and the
  stale `routers/docs.py:446-455` idempotency prose. MCP shares the CLI's
  idempotency blind spot.
- **The suite is the specification.** Two spec amendments are queued —
  `tests/cases/search.sh:3-5` (§ 1.2) and the exit-code contract (§ 5.3). Both
  need `.surface-breaking` entries.
- **Test the test** (Lesson 1). Every guard added by this plan gets proven by
  re-injecting the bug and confirming red. This is why the existing suite is
  trustworthy; do not let the new work be the exception.

---

## 13. Definition of done

- [x] C1 resolved; nothing pipes an unverified remote artifact into a shell
- [ ] C2-C4 fixed: **C3 done**; C2 and C4 blocked on the API deploy (Phase 4)
- [x] `check-api.sh` anchored to the API spec, distinguishing released from built,
      running in CI and on a daily schedule
- [x] CI exists and gates every PR
- [x] Test suite covers HTTP 400 and 409 (422 already covered; 412 and 428 heavily)
- [x] shellcheck in `bin/ci`
- [x] `--help`/skill restructured; machine variant smaller than the human one
- [x] Existing command surface unchanged, or every deviation in `.surface-breaking`
- [ ] Auth decision made and implemented (Phase 6 — needs the bash-vs-rewrite call)
- [ ] SOC 2: `uku-cli`, `infra`, `mailbox` + getuku-astro deploy access recorded

**Also done, beyond the original list:** C5, C7 (decided *not* to do, with
reasons), C9, C10, C11, C14, and `uku health`. **Outstanding and needing a
ruling rather than an implementation:** C6 (§ 5.3).

---

## 14. Appendix A — Phase 4 wire contract, measured 2026-08-04

Read from router source + the **built** `uku_service/CLAUDE/api/openapi.json`, not
from prose. None of these four endpoints is live: production still serves 182
operations and 404s on all of them (re-measured 2026-08-04). This appendix exists
so Phase 4 is transcription rather than research on the day it deploys — **nothing
here has been implemented, and no `op` fact was added.**

### A.0 Six findings that would have produced a wrong implementation

1. **The spec's per-endpoint error lists are decoration.** `main.py:362-384`
   attaches one shared `COMMON_RESPONSES` (`schemas/_common_responses.py:20-70`)
   to *every* router, so `GET /capabilities` — dependency-free, unauthenticated —
   is documented as returning 401/403/404/409/412/428, none of which its handler
   (`capabilities.py:54-61`) can emit. **Generate error handling from the routers,
   not from `responses{}`.**
2. **Two unrelated 422s, and the spec documents the dead one.** The spec's
   `HTTPValidationError` never occurs: `main.py:305` converts every
   `RequestValidationError` into a **400 `VALIDATION_ERROR`**
   (`exceptions.py:55-92`). The *live* 422 on complete/reopen is
   `ApiError(code="VALIDATION_ERROR", status_code=422)`
   (`task_service.py:1472-1476`, `1595-1599`) with the `ErrorResponse` shape.
3. **`VALIDATION_ERROR` is the code at both 400 and 422.** The status is the only
   discriminator — directly relevant to C6's taxonomy (§ 5.3).
4. **`/reopen` on a task in status `new` — the DOCSTRING is the bug, not the code.**
   Reproduced first-hand against the local server on 2026-08-04: task 19609710
   went `new` → `in_progress` on `POST /reopen`, HTTP 200 (restored afterwards).
   The docstring (`task_service.py:1564-1565`) calls that case a no-op; the guard
   at `task_service.py:1589` tests `status == STATUS_IN_PROGRESS` only, and
   `STATUS_NEW != STATUS_IN_PROGRESS` (`constants.py:1038-1039`).
   **Per the product owner, the behaviour is correct and must not change:** a
   task stays `new` only until something interacts with it — a checklist item, a
   revision, a timer (even one whose time is later deleted) all move it to
   `in_progress`. Reopen is an interaction. So the guard must NOT be widened;
   the docstring must be corrected and the side effects listed. The parity
   suite's factory only ever seeds `in_progress`, so the branch is untested
   either way. **→ filed against `uku_service`.**
   *A CLI must therefore not treat `reopen` as safe to issue speculatively.*

   **Why the transition exists, from the product owner:** recurring tasks
   generate instances and the cleanup destroys older ones — but only ones
   nobody has touched. `status = 'new'` is the marker for "untouched, therefore
   disposable"; any real interaction moves it to `in_progress` and takes it out
   of the cleanup's reach. The status is a **data-safety marker, not a progress
   indicator**. Widening the guard would leave an interacted-with task marked
   disposable and let the cleanup destroy a user's work.

5. **`/capabilities` is not a route index.** `GET /mcp-usage` (`mcp_usage.py:24`)
   appears nowhere in it; `reports/*` only inside `curated_tools`
   (`server.py:2291`), never as an entity. Its own text concedes the OpenAPI doc
   is "wider in places" (`server.py:2216-2223`). **C13 cannot be built on
   `/capabilities` alone** — it would silently drop real routes.
6. **⚠ `entities` reports `read: false` for readable resources.** The build loop
   (`server.py:2343-2393`) hardcodes all four verbs false for anything in the
   exclusion tables. `workflow-templates` sits only in the *write* exclusion
   (`server.py:1886-1889`) yet renders fully false, as does `teams`
   (`server.py:1576-1577`) — both have working REST routes. A CLI branching on
   `entities[x].read` would conclude the resource does not exist.
   **→ file against `uku_service`.**

### A.1 `POST /tasks/{task_id}/complete` and `/reopen`

Path param is **`{task_id}`**, not `{id}` (`tasks.py:213`, `247`). No body, no
query params. Response `SingleResponse[TaskOut]` (`tasks.py:214`, `248`);
`warnings` is present but never populated on these two — only `patch_task` emits
them (`tasks.py:208`). Scope `write:tasks` (`tasks.py:239`, `267`) plus
`require_active_subscription` and the Elite plan gate.

Both are **idempotency-covered**: `^/api/v3/tasks/\d+/(?:complete|reopen)$`
(`idempotency.py:104`). The Redis key includes the concrete path
(`idempotency.py:221`), so complete and reopen never replay each other despite
both having an empty body.

Errors: 400 `VALIDATION_ERROR` (completion rules — custom fields, blocking
dependencies, checklist, required time entry/topic; `_bo_bridge.py:61-68`),
404 `NOT_FOUND`, 422 `VALIDATION_ERROR` (no active client), 403
`FORBIDDEN`/`SUBSCRIPTION_READ_ONLY`/`PLAN_UPGRADE_REQUIRED`, 409 idempotency.
**412/428 are unreachable** — neither handler calls `require_if_match`.
Reopen has no completion-style 400.

Side effects confirming C2 — `complete` sets `finished_at`, resets the "my later"
tag, arms `finished`-trigger automations (`task_service.py:1491`), writes a
`task_finished` activity tagged `source=api`, notifies assignees, auto-finishes
the client-portal side when `is_cp`, and — when `auto_fill_task_duration` is on
and the task has an estimation but no tracked time — **inserts a real TimeEntry**
(`task_service.py:1436-1439`). Already-finished is a genuine no-op 200.

**Asymmetries `reopen` does not undo:** the "my later" tag, and `cp_status` /
`cp_finished_at` — a reopened task stays finished on the client portal
(`task_service.py:1567-1569`). It also sends **no** notification, which the
docstring does not mention.

### A.2 `GET /search`

`q` (required; **≥2 chars after strip**, else 400 — `search_service.py:180-186`),
`category` (default `all`; `all|invoice|contact|supplier|contract|task|note`,
`search_service.py:50` — **the spec carries no enum for it**), `client_id`
(**required when `category=note`**, `search_service.py:198-204`), `limit`
(`ge=1,le=20`, default 5, **per category**).

Response `SingleResponse[SearchResults]` with **exactly six always-present keys**
— `invoices, contacts, suppliers, contracts, tasks, notes`, each defaulting to
`[]`, never absent (`schemas/search.py:77-85`). **No pagination, no cursor.**
Without `financials` the `invoices` bucket is withheld whole, not partially
(`search_service.py:212-217`). No `require_scope` call at all — any valid key.

This confirms § 1.1: the overlap with the CLI's fan-out is **tasks alone**, so the
union stands and substitution would drop clients.

### A.3 `GET /capabilities`

**Unauthenticated by design** — zero `Depends()` (`capabilities.py:54-60`), and
the built spec carries no `security` key on the operation, unlike every other
route. Still rate-limited, via the per-IP floor bucket (`rate_limit.py:82-108`),
so a pre-login `uku capabilities` works.

**Envelope differs from everything else:** a bare
`JSONResponse({"data": ...})` with no `response_model` (`capabilities.py:61`) —
**no `warnings` key, ever.** Keys of `data`: `how_to_use`, `company_timezone`,
`entities`, `curated_tools`, `not_available`. `surface=rest|mcp`; the `mcp`
rendering is pinned byte-for-byte by a backend test.

### A.4 Worth a CLI follow-up once released

`GET/POST/PATCH/DELETE /teams` · `/workflow-templates` + `/apply`, `/push`,
`/tasks` · `GET /reports/time-summary`, `/reports/kpi-summary` ·
`GET /mcp-usage` · `POST /tasks/bulk-action` ·
`POST /invoices/{invoice_id}/mark-unpaid` (idempotency-covered alongside
`mark-paid` and `send`).
