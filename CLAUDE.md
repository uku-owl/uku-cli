# CLAUDE.md — uku-cli

The public command-line client for Uku, over public API v3.

## Story

**Pain:** Uku has three ways in — REST, MCP, and this CLI — and they drift. The CLI's own `--help` currently tells users the API has no search endpoint. It does. A task completed through this CLI silently skips automations, client-portal sync and notifications, because it uses a write path the API deprecated. Neither failure is visible from inside this repo, because everything here checks the CLI against *itself*.

**What it does:** gives terminals, CI, and AI agents native access to a firm's Uku data, inside the exact permissions of the credential handed to it.

**Outcome wanted:** the fastest, least surprising way for an agent or a developer to operate Uku — provably in step with the API, and safe enough to hand a customer.

## Status & ownership

**CTO-owned as of 2026-08-03.** v0.6.0, bash + curl, `jq` optional.

> ### ⚠ THE NEXT PIECE OF WORK IS A **GO REWRITE** — decided 2026-08-04
>
> The language question is **settled**. Do not start new feature work in bash.
> Read [`refactoring-cli.md`](refactoring-cli.md) **§ 0 — START HERE** before
> anything else; it carries the execution notes, everything still outstanding,
> and a pasteable prompt for the API team about OAuth device flow.
>
> **State:** branch `sec/phase0-install-chain`, pushed 2026-08-04, 28 commits.
> `main` is untouched at `f04f500` (v0.6.0). **Phases 0–5 shipped.** 1,480
> assertions, 424 surface facts.
>
> **CI on that branch is RED on purpose.** The first remote run (Linux, bash 5,
> GNU coreutils) was 1443/37. One failure was a real bug and is fixed; the other
> 36 are macOS assumptions in the test harness (`stat -f`, a literal `bash 3.2`,
> macOS `security` vs Linux `secret-tool`). They were left for the Go session to
> fix **once**, since the tests port through the subprocess boundary.
>
> **Why Go, in one line:** the whole remaining roadmap — OAuth, signed
> cross-platform distribution, Windows — is where bash is weakest, and every one
> of the eight bugs found on 2026-08-04 was a bash bug, not a logic bug. The full
> argument with measurements is `refactoring-cli.md` § 11.1.

**Nothing releases until it is right.** There is no deadline pressure on this repo. Prefer the correct fix over the quick one, and say so when you defer something.

## PRIME DIRECTIVE — don't break existing usage

Existing command syntax, flags, output shapes and exit-code *meanings* are a contract. Someone has scripted them. Revise and rewrite internals freely; **change the surface only when it is broken**, and when you must, say so loudly in `.surface-breaking` and the changelog.

If a rewrite happens, the new implementation must pass the *existing* behavioural tests. That suite is this repo's best asset — treat it as the specification.

---

## THE MOST IMPORTANT SECTION — how to know what the API actually does

**Never take an API fact from prose. Not from this file, not from `README.md`, not from `--help`, not from a help-centre page, not from `llms-full.txt`.** Prose drifts and then lies with confidence. The phantom-search bug below is exactly that failure.

There are two different machine-generated truths, and you need both:

| Question | Command | Can it be wrong? |
|---|---|---|
| What is **released** (live in production)? | `curl -s https://app.getuku.com/api/v3/openapi.json` | **No.** FastAPI generates it from the live router table at request time. |
| What is **built** (merged, maybe not deployed)? | `uku_service/CLAUDE/api/openapi.json` | Only by being stale — regenerate from a running dev server. |
| What can a *user* do, semantically? | `curl -s https://app.getuku.com/api/v3/capabilities` — **⚠ 404 in production as of 2026-08-03; built, not yet released.** Until it deploys, read it from a local/staging server. | No — built from the same enforcement tables the API uses. Unauthenticated by design. |
| Narrative, conventions, gotchas | `/api/v3/llms-full.txt`, `uku_service/CLAUDE/api/CLAUDE_API_V3.md` | **Yes.** Useful for intent; never authoritative for surface. |

**Built ≠ released, and the gap is real.** On 2026-08-03 production served **182 operations** while the repo had **217**. A CLI implemented against the repo would ship commands that 404 for every customer. Any drift tooling must distinguish the two and refuse to ship ahead of production.

The `/capabilities` caveat above is that same trap, caught in this very file within minutes of writing it — the author asserted an endpoint existed because it existed in the repo, then measured production and found a 404. **Assume this file is stale about the API. Re-measure.** That is the whole point of the table: the commands are durable, the facts around them are not.

Backend repo: `../uku_service`. Ask it directly rather than guessing.

---

## Bug ledger

> ### ⚠ STATUS AS OF 2026-08-04 — most of this is FIXED. Read this box first.
>
> The ledger below is preserved as written on 2026-08-03, because *why* each bug
> existed is worth keeping. **It does not describe the current code.** Work is on
> branch `sec/phase0-install-chain` (unpushed; `main` is still v0.6.0).
>
> | | Status |
> |---|---|
> | C1 unattended auto-update | ✅ fixed — notifies, installs nothing; install URL pinned to a tag off the marketing site |
> | C2 deprecated completion path | ⏳ **blocked** — `/complete` and `/reopen` are built but 404 in production |
> | C3 no `Idempotency-Key` | ✅ fixed — **but not for the reason the entry below gives; see the correction** |
> | C4 `--help` lies about `/search` | ⏳ **blocked** — `/search` 404s in production. **And the entry below is wrong; see the correction** |
> | C5 `warnings[]` dropped | ✅ fixed |
> | C6 collapsed exit codes | ⏳ **needs a CTO ruling** — it is a deliberate surface break |
> | C7 unannounced loopback cleartext | ❌ **deliberately NOT fixed** — implemented, measured, reverted |
> | C8 credentials for endpoints needing none | ◐ half — `uku health` ships; `uku capabilities` 404s in production |
> | C9 `..` path traversal | ✅ fixed — **worst vector was `--by-id`, not `uku api`** |
> | C10 unquoted `--fields` split | ✅ fixed |
> | C11 unprompted agent setup | ✅ fixed |
> | C12 agent help larger than human | ✅ fixed — 1.44× → 0.69× |
> | C13 hand-maintained `--describe` | ⏳ **blocked** — needs `/capabilities`, which 404s in production |
> | C14 curl stderr leak | ✅ fixed |
>
> **Three entries below are WRONG and would produce a wrong implementation.**
> Each is corrected in place, marked `⚠ CORRECTION`. The full reasoning, with
> measurements, is in [`refactoring-cli.md`](refactoring-cli.md) § 1.
>
> **Also fixed, and not in this ledger:** the API-anchored drift gate that would
> have caught C4 in the first place (`scripts/check-api.sh`, 27 `op` facts, a
> daily job), CI that actually gates, shellcheck, and HTTP 400/409 test coverage.

Severity-ordered. `✅ verified` = reproduced first-hand; otherwise reported by audit and worth re-confirming before you act.

### Critical — blocks any customer release

**C1 — Unsigned auto-update pipes a remote URL into `sh`, unattended, daily.**
`bin/uku` `auto_update()` is opt-out (`UKU_NO_AUTO_UPDATE`), runs on nearly every invocation, and on a version bump calls `cmd_update` → `curl -fsSL "$UKU_INSTALL_URL" | sh`. ✅ verified: both endpoints live (`raw.githubusercontent.com/.../VERSION` → 200, `getuku.com/install-cli` → 308).

Two things make this worse than it looks:
- **The payload URL resolves through Vercel.** `getuku.com/install-cli` → 308 (`server: Vercel`) → `raw.githubusercontent.com/.../scripts/install.sh`. Whoever controls the marketing site controls where `-L` lands. The marketing site is a lower-trust deploy path than the app, and is currently in the RCE path for every installation.
- **Every integrity control lives *inside* `install.sh`.** Controls inside the artifact cannot protect the *choice* of artifact. `install.sh` says so itself: *"It is NOT authenticity — the artefact and its checksum come from the same repo."*

Persistence multiplier: the update path also owns `_setup_claude`, which writes `~/.claude/skills/uku/SKILL.md` — so a compromise rewrites what customers' coding agents read.

**Fix, in order:** (1) invert the default to opt-in or notify-only — one line, removes the standing channel today; (2) point `UKU_INSTALL_URL_DEFAULT` at a GitHub release asset so Vercel leaves the chain; (3) sign releases (minisign / GitHub artifact attestations) with a key that does not live in the artifact repo, verified in both `install.sh` and `cmd_update`; (4) branch protection + required review, so one stolen token is not sufficient.

This is a *product decision* honestly disclosed in `SECURITY.md`, not an oversight. Unattended updates have real value for agent installs. Decide deliberately — but the current shape cannot ship to accounting firms.

### High — customer-visible correctness

**C2 — Task completion uses the deprecated write path.** ✅ verified: zero occurrences of `/complete` or `/reopen` in `bin/uku`. `tasks patch --data '{"status":"finished"}'` skips `finished_at`, client-portal auto-finish, `finished`-trigger automations, activity records and notifications. The API ships `POST /tasks/{id}/complete` and `/reopen` for exactly this. A firm completing tasks via CLI is silently losing automation e-mails.

**C3 — No `Idempotency-Key` on any write, ever.** ✅ verified: no occurrence in `bin/uku`. The API's middleware covers ~20 top-level creators plus action sub-paths (`invoices/{id}/mark-paid|mark-unpaid|send`, `tasks/{id}/complete|reopen`, `tasks/bulk-action`, `workflow-templates/{id}/apply|push`, `clients/{id}/documents-folder`, `members/{id}/agreements`). The CLI reasoned correctly *from* this gap — it refuses to retry a 429'd write because the request may or may not have landed — but the constraint is self-imposed. Send a key, stable across retries, and safe write retries become available.

> **⚠ CORRECTION (2026-08-04).** The last sentence is wrong twice over. (a) A key minted per process protects only the CLI's internal 428 re-send — the one path that repeats a write. Two runs of a command are two processes, two keys and two writes, correctly so. Cross-invocation safety has to be *asked for*, which is why `--idempotency-key` now exists. (b) Write auto-retry is still **off**, and deliberately: retrying is only safe on a path the middleware covers, and coverage is absent from the OpenAPI spec, so it cannot be drift-checked. Hand-copying the covered-path list into the CLI is the exact 'client asserts facts about the server' failure this repo has been bitten by twice. An API-side ticket to declare coverage in the spec is the fix.

**C4 — `--help` asserts a falsehood about the API.** ✅ verified, `bin/uku:3068`: *"Not a server-side search: the API has none."* `GET /api/v3/search` exists (cross-entity: invoices, contacts, suppliers, contracts, tasks, notes). The CLI instead fans out 5 requests, misses four of those entity types, and burns 5× the rate-limit budget.

> **⚠ CORRECTION (2026-08-04).** This reads as *replace the fan-out with `/search`*, and doing that would lose data. Measured from `uku_service/backend/api_v3/routers/search.py:20`: `/search` covers **invoice, contact, supplier, contract, task, note**; the CLI's fan-out covers **clients, tasks, members, products, projects**. The overlap is **`tasks` alone**. Swapping would silently drop clients — which is what someone searching "Acme" almost always means. The fix is a **union**, not a substitution. Also: `/search` 404s in production today, so this is Phase 4 work regardless. Note `bin/uku:3413` hedges — *"none this CLI can verify"* — which is the more honest phrasing and points straight at the missing capability: **it had no way to check.** That is what § Drift control fixes.

### Medium

**C5 — the API's `warnings[]` array is dropped.** ✅ verified: never read. `TIME_ENTRY_OVERLAP`, `MONITOR_OVERLAP` and deprecation notices never reach the user on a TTY.
**C6 — exit codes collapse distinct failures** — 401/403 → 2, 404/500 → 3, rate-limit/network → 5. Agents branch on `$?`; these need separating.
**C7 — loopback cleartext is allowed *and* unannounced.** `--base http://127.0.0.1:PORT` ships the live production key to any local process with no stderr line. The non-loopback refusal is excellent; this is the one gap in it.
**C8 — credentials demanded for endpoints that need none.** `/health`, `/capabilities`, `/openapi.json` all return 200 to bare curl; the CLI refuses with rc=2. The gate checks credential *presence*, not validity. You cannot check whether the API is up, or discover capabilities, before signing in — and `capabilities` is precisely what an agent wants *first*. Add `uku health` and `uku capabilities` subcommands.

### Low

**C9** — `..` in an `api` path escapes the `/api/v3` prefix (`uku api GET /../../oauth/token` reached `/oauth/token` with the credential attached). Note: enforce at the request layer, not just the `api` command — curated commands interpolate paths too.

> **⚠ SHARPENED (2026-08-04).** The closing note was right and understated. The *worst* vector was not `uku api` at all: `_resolve_ref` took the argument **verbatim** when `--by-id` was passed and interpolated it into `/api/v3/clients/$id`, so `uku clients get '../../oauth/token' --by-id` was the same escape through a curated command. A guard in `cmd_api` alone would have missed it. Fixed at the `do_request` chokepoint, which covers all 17 call sites and any added later.
**C10** — unquoted `local IFS=','; set -- $raw` → pathname expansion on `--fields`.
**C11** — non-interactive install runs `setup agents`, appending to `./AGENTS.md` in the cwd and writing `~/.claude/skills/` unprompted.
**C12** — `--help --agent` (14 KB) is *larger* than human `--help` (9.8 KB). Backwards; the machine variant is the one that should be lean.
**C13** — `api --describe` is a hand-maintained ~12-resource map. Stale, and doesn't know `/search`, `/capabilities`, `/teams`, `/workflow-templates`, `/reports/*`, `/mcp-usage` exist. Replace with live `/api/v3/capabilities`.
**C14** — curl's raw stderr leaks twice on an unreachable host, alongside the CLI's own clean message.

### Capability gaps vs the current API

No OAuth (see § Auth). No cursor-pagination follow (`meta.next_cursor` is passed through but never followed). No `/search`, `/capabilities`, `/teams`, `/workflow-templates`, `/reports/*`, `/mcp-usage`.

### Process

No CI — `bin/ci` is "run before you push", i.e. discipline, not a gate. The test suite **never scripts an HTTP 400** and covers 422 once, yet 400 is what the API returns for the commonest misconfiguration (`MISSING_COMPANY`). No shellcheck. `LICENSE` is MIT here while the sibling Python client declared Proprietary — settle it.

---

## Auth — the one architectural gap

The CLI supports pasted API keys only. The API implements **OAuth 2.1 + PKCE** (`uku_service/backend/handlers/oauth_handlers.py`), including dynamic client registration and — importantly — `_valid_redirect_uri` already permits plain-http **loopback**, so a CLI browser flow needs no server change.

Why it matters: a pasted *integration* key is **tenant-wide** and can carry `admin`/`financials`. An OAuth-minted key is **person-scoped**, `read`+`write`, with `financials` only if the consenting user holds Manage Account and ticks a box. Today every CLI user and every agent holds the most powerful credential the platform issues.

**Be honest about the cost in bash:** PKCE S256 needs SHA-256 + base64url, the flow needs a loopback HTTP listener, and the token exchange needs JSON parsing — in a tool whose selling point is bash + curl with `jq` optional. Shelling out to `python3` is pragmatic but dents the zero-dependency claim. This is the single strongest argument for a rewrite; weigh it honestly rather than forcing it.

### Answered by the API team, 2026-08-04 — read `refactoring-cli.md` § 0 and § 9 before writing auth code

Four things that change the design, all re-measured here:

- **Discovery lives on the APP host, not api-v3.** `/.well-known/oauth-authorization-server` is 200 on `:8885`/`:8886` and 404 on `:8890`, because `oauth_handlers.py` registers via `tornroutes`, not FastAPI. An earlier note in this repo called it a 404 — that was a wrong-host probe, now corrected.
- **Device flow does not exist.** A few days of API work, no blocking objection. Build the Go auth layer grant-agnostic so it is one branch later, not a rewrite.
- **Device flow will be allow-listed to first-party `client_id`s**, because it removes the redirect host that the consent page's anti-phishing story depends on. So this CLI pins a `client_id` and never calls `/oauth/register`. That is not a drift violation — a `client_id` is a fact about the *client*, and endpoints still come from `.well-known`.
- **Production 403s both `.well-known` documents** (`infra/.../block-scanners.conf:45` whitelists only acme-challenge; staging has the fix). OAuth cannot work in production until that is backported. Not this repo's to fix.

Also: `scopes_supported` is `["read","write"]` — `financials` cannot be *requested* but can still be *granted* via the consent checkbox, and re-checked at every refresh. Read the granted scope from the token response, never from what was asked.

**The drift gate is blind here.** `check-api.sh` reads `/api/v3/openapi.json`, which structurally cannot contain Tornado-served OAuth routes — so an `op` fact for one fails forever, and `.api-pending` deadlocks `release.sh`. Resolve before declaring any OAuth operation (`refactoring-cli.md` § 6.2.1).

Also note the API now issues **refresh tokens** (24h access, 90d rotating refresh, with reuse detection that revokes the whole family). If you implement OAuth: persist the rotated pair atomically, never send a refresh token twice, and refuse to use a credential against an origin other than the one it was minted for.

---

## Drift control — the highest-leverage work in this repo

`.surface` (359 facts) + `check-surface.sh` + `check-drift.sh` are genuinely well-engineered. `check-surface.sh` is an asymmetric backward-compatibility ratchet: additions need a deliberate `--update`, removals fail until acknowledged in `.surface-breaking`. `check-drift.sh` cross-checks README, the generated skill, `--help`, the dispatcher's case labels and the remedy table — and check 3 *executes* every declared command against the real dispatcher rather than trusting a parse.

**But not one of those 359 facts references the Uku API.** The gate checks the CLI against itself. That is precisely why `--help` can assert the API has no search endpoint and stay green.

> **✅ DONE (2026-08-04).** Built as described, and the prediction below held — `check-surface.sh` needed no changes at all, because its emitter was already fact-kind-agnostic. There are now 27 `op METHOD /path` facts, plus `scripts/check-api.sh` gating them against a committed snapshot of the 182 operations production serves, plus an executed check in `tests/run.sh` comparing declared ops to what the suite actually puts on the wire. CI runs the gate on every push and PR; a second workflow re-fetches the live spec daily. Verified by injecting `op GET /api/v3/search` — which exists in the repo and 404s in production — and watching it fail.

**The fix is cheap because the machinery exists.** Add an API-derived fact type — `op GET /api/v3/tasks` — generated from the published spec. The existing ratchet then gives API-coverage drift control for free: a new operation shows up as NEW SURFACE, a removed one fails until acknowledged. No new tooling, no code generator, no unreviewable diffs.

Make it distinguish **released** from **built** (see above) so the CLI can never ship a command production doesn't serve. Run it in CI on every PR *and* on a daily schedule, so API-side changes surface within a day rather than at the next release.

---

## Lessons learned — earned, not theoretical

**On testing**
1. **Test the test.** Every guard here was proven by re-injecting the bug and confirming red. Four mutations were injected into this repo's suite; all four were caught. That is why it is trustworthy.
2. **Write non-vacuity guards.** A fixture whose two values coincide makes every test below it pass for free. Assert the fixture discriminates *before* asserting behaviour.
3. **A test that cannot fail is worse than no test** — it retires the question. One CLI's import fence never ran because `conftest` aborted first; a `--if-match auto` bug hid behind a fixture that answered GET on any path.
4. **Live tests find what mocks cannot.** Mocked suites missed: idempotency being unreachable, credentials crossing origins, a CLI pointing at production, timezone anchoring. All were caught the moment something real was on the other end.
5. **Assert on side-effect absence.** `traversal.sh` is this repo's best case: it checks the victim file still exists, not that a message was printed. Exit-code-only assertions passed against the *old, broken* code.

**On agents as users**
6. **Context is the agent's currency.** `--help` at 9.8 KB is paid on every session. For comparison: this repo's skill file ~18 KB; Uku's MCP `tools/list` ~22.7 K tokens; Basecamp's CLI covers 155 endpoints in ~11–12 K. Lean help is a feature.
7. **Round trips cost inferences, not milliseconds.** One tool call ≈ one model turn ≈ seconds. A CLI's structural advantage over MCP is that an agent can chain `uku a && uku b && uku c` in a *single* round trip. Design for batching.
8. **Exit codes are the agent's control flow.** Collapsing 401 and 403 forces prose parsing. Map `MISSING_COMPANY` to *auth*, not *validation* — an agent seeing "validation" retries with different data and loops forever.
9. **Teach discovery, don't enumerate.** Basecamp's skill covers 155 endpoints via decision trees, a quick-reference table, and "walk the tree: start at `--agent --help`". Constraints live in a `notes` field in the introspectable help rather than inlined.

**On security**
10. **A credential minted for one origin must never be sent to another.** Found independently in *both* Uku CLIs. Check every layer — one had the fence on its refresh token but not its access token.
11. **Validate discovery metadata against the origin that served it** (RFC 8414 §3.3), and do **not** follow redirects while doing so — a 302 to production returns a document that legitimately names production, so the check passes while every endpoint points away.
12. **Keep secrets out of argv.** `curl -K` config files, as done here, is the right call — argv is world-readable via `ps`.
13. **Allowlist, don't denylist, for credential stores.** An allowlist miss costs a fallback file; a denylist miss costs the secret in cleartext.

**On drift**
14. **A client's own docs must never assert facts about the server.** Point at the generated spec. Every hand-maintained resource list eventually lies.
15. **Documentation that isn't executed is decoration.** The only reason this repo's docs match its code is that `check-drift.sh` runs them. Extend that property to the API.

---

## What "better" looks like

Reference implementation worth studying: **`basecamp/basecamp-cli`** — same audience shape, ships **no MCP server**, CLI + skill + native Claude Code / Codex plugins. Go, so it distributes signed cross-platform binaries via Homebrew, Scoop, deb/rpm/apk, AUR and Nix rather than `curl | sh` alone. OAuth 2.1 preferring **device flow** (approve a short code in a browser) over an auth-code redirect — better for a CLI, since it works over SSH, headless, and when the browser is on a different machine. Named profiles, keyring storage, JSON envelope with breadcrumbs, `doctor`.

Note this repo already converged independently on breadcrumbs, `doctor`, profiles, output polymorphism and an agent-skill installer. The gaps are distribution, device-flow auth, and API-anchored drift control.

---

## Open decisions — resolve before large work

1. **~~Stay bash, or rewrite?~~ RESOLVED 2026-08-04 — rewrite in Go.** Kept below
   for the reasoning, which is what stops it being re-opened. The claim that a
   rewrite could not reuse the suite turned out to be **false**: 301 of ~324 CLI
   invocations exec the binary as a subprocess against a language-agnostic
   fixture, so a Go binary at `bin/uku` inherits all 1,480 assertions unchanged.
   Original framing: Bash's cost is concentrated in OAuth (above), Windows (`bin/uku` targets bash 3.2; "Windows", "WSL", "PowerShell" appear nowhere), and static analysis. Its value is 51 commits of hard-won API archaeology, 1306 wire-level assertions, and an adversarial security audit it passed clean. **The audience is AI agents and developers**, so Windows matters less than it would for end-customers — but a rewrite would also buy signed cross-platform binaries. Decide explicitly, with the PRIME DIRECTIVE in force either way.
2. **Auto-update policy** — opt-in, notify-only, or signed-and-on (§ C1).
3. **Licence** — MIT stands, but reconcile it with the platform's position.

---

## Definition of done

- [x] C1 resolved; nothing pipes an unverified remote artifact into a shell
- [ ] C2–C4 fixed: **C3 done**; C2 and C4 blocked — both 404 in production
- [x] `check-drift.sh` anchored to the API spec, distinguishing released from built, running in CI
- [x] CI exists and gates every PR
- [x] Test suite covers HTTP 400 and 422 *(and 409, which idempotency made load-bearing)*
- [x] `--help`/skill restructured for progressive disclosure; machine variant smaller than the human one
- [x] Existing command surface unchanged, or every deviation recorded in `.surface-breaking`
- [ ] Auth decision made and implemented — **needs the bash-vs-rewrite call first**
- [ ] SOC 2: repo added to asset inventory, subprocessor list, access-control matrix (same gap exists for `infra` and `mailbox` — close together; **add getuku-astro deploy access**, which is now a production trust root)

**Decided 2026-08-04:** C6 (take the break — done), C7 (implemented, measured,
reverted), auto-update (notify-only — done), **bash-vs-rewrite (Go)**.

**Still open, needing a person rather than code:** provision the signing key
(`scripts/sign.sh --keygen` — the machinery is built and tamper-tested but ships
inert until a key is pasted in), branch protection on `main`, the licence, and
the SOC 2 inventory rows. Full list: [`refactoring-cli.md`](refactoring-cli.md)
§ 0.1.

## Release context — you are ahead of production

A large batch of API v3 / MCP work is **committed but not deployed** (branch `staging` in `../uku_service`, 2026-08-03). Production is running the *older* surface. That means:

- Several endpoints this repo should eventually use — `/capabilities`, `/mcp-usage`, sparse `fields=`, `If-None-Match`, widened cursor support — **exist in the repo and 404 in production.** Build against them only once they ship.
- Nothing here is on a deadline. The plan is a single coordinated release of API + MCP + CLI (+ help and marketing content, handled separately) once everything is right.
- The whole platform is in **development and staging testing**, iterating aggressively. Test against staging or a local server, not production.

## Reference

- **`reference/python-client/` — working implementations of four things this CLI lacks.** A second CLI was written in Python, audited alongside this one, and retired the same day (two CLIs is the worst state). Preserved as a parts bin, not a blueprint: OAuth 2.1 + PKCE with RFC 8414 issuer validation (C-auth), idempotency keys stable across retries (C3), a 9-code exit taxonomy (C6), and cross-origin credential refusal. Read its README first — it says what to take and what to ignore.
- Backend, API v3 and MCP: `../uku_service` — start at `CLAUDE/api/CLAUDE_API_V3.md`
- Platform-wide conventions and the three-surface propagation rule: `../CLAUDE.md`
- OAuth server: `../uku_service/backend/handlers/oauth_handlers.py`
- Idempotency contract: `../uku_service/backend/api_v3/middleware/idempotency.py`
- ETag/optimistic locking: `../uku_service/backend/api_v3/services/_optimistic_lock.py`
