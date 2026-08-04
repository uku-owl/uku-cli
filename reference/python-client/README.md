# Reference: Python client (NOT SHIPPED)

A second Uku CLI was written in Python on 2026-08-03, adversarially audited alongside `bin/uku`, and retired the same day — two CLIs is the worst state to be in. It is preserved here **as reference only**.

**Nothing in this directory ships, runs, or is tested in CI.** It exists because it solves four problems `bin/uku` currently has, and reading a working, tested implementation beats reconstructing one from a bug description.

Original home: `uku_service/uku_cli/` (deleted; recoverable from git history in that repo).

---

## What to read, and why

### 1. `src/oauth.py` — the one thing `bin/uku` has no version of

The security audit called this *"the best code in either repo."* `bin/uku` supports pasted API keys only, which means every user and every agent holds a **tenant-wide** credential that can carry `admin`/`financials`. This mints a **person-scoped** one.

Details that are load-bearing and easy to get wrong:

- **RFC 8414 §3.3 issuer validation.** The discovery document's `issuer` must match the origin that served it, and every advertised endpoint is re-checked on-origin.
- **`follow_redirects=False` on the well-known fetch.** This is the subtle one. Anchor the check to the *response* URL and follow redirects, and a 302 to production returns a document that legitimately names production — so the issuer check passes while every endpoint points away. Anchor to the URL the **user asked for**.
- Why it matters concretely: the Uku server builds discovery metadata from `[api_v3] app_base_url`, which defaults to `https://app.getuku.com` and is set in no dev ini. So `--base-url http://127.0.0.1:8885` against a local server sends the browser to **production's** consent page and POSTs the code to production. A CLI that trusts what a server tells it, unconditionally, is the vulnerability.
- PKCE S256, `secrets.compare_digest` on `state`, port-0 loopback bind before registration.

Note the server side needs no changes for this: `_valid_redirect_uri` already permits plain-http loopback.

**Honest caveat:** porting this to bash is genuinely hard — SHA-256 + base64url, a loopback HTTP listener, JSON parsing. See the Auth section of `../../CLAUDE.md`. Consider RFC 8628 **device flow** instead (what Basecamp's CLI prefers): a short code the user approves in a browser, no listener, works over SSH and headless.

### 2. `src/client.py` — idempotency, ETag, refresh-retry

Addresses bugs **C3** (no `Idempotency-Key` on any write) and **C6** (collapsed exit codes).

- **The key is minted once and reused across retries.** A fresh key per attempt defeats the entire purpose — that is precisely the bug the Uku MCP server shipped with until it was found by live testing.
- **The ETag is lifted from the response *header*, never rebuilt from the body.** `format_etag` emits `…+00:00` while the JSON body serialises `…Z`; reconstructing guarantees a 412. `tests/test_etag.py` proves the fixture discriminates *before* asserting behaviour — copy that pattern.
- Retry on **429 only**, honouring `Retry-After`, capped. Transport errors raise rather than retry.
- Single-use refresh-token claim under a lock, taken in the same critical section that marks it used — so the token cannot leave twice regardless of caller or thread count. Uku's server revokes the **entire token family** on refresh reuse, so a double-send is a hard logout.
- One refresh-and-retry on 401, never a loop.

### 3. `src/config.py` + `src/auth.py` — credential trust

`bin/uku` already refuses cleartext to non-loopback hosts and keeps keys out of `argv` via `curl -K` — both good, and better than this client's first cut. What is here that `bin/uku` lacks:

- **Cross-origin credential refusal.** A credential minted for origin X is never sent to origin Y. This client shipped a live exfiltration bug (`--base-url http://anywhere` sent the live bearer in cleartext, exit 0, no warning) because the fence existed for the refresh token and was never applied to the access token. Check every layer.
- **Loopback is deliberately announced-silent but still fenced** — announcing on every command of a local dev day trains people to skip the warning that matters. (`bin/uku` makes the same call; it is the right one.)
- **Keyring backends are allow-listed, not deny-listed.** An allowlist miss costs a `0600` file; a denylist miss costs the secret in cleartext on a box with `keyrings.alt` installed.
- Atomic credential writes (`mkstemp` + `fsync` + `os.replace`), directory created `0700` and repaired if looser.
- A read failure **refuses** rather than falling back — a stale file may hold a pre-rotation refresh token whose replay revokes the family.

### 4. `src/errors.py` — the exit-code taxonomy

Nine distinct codes where `bin/uku` collapses 401/403, 404/500, and rate-limit/network. Agents branch on `$?`; collapsed codes force prose parsing.

One non-obvious mapping worth keeping: **`400 MISSING_COMPANY` maps to *auth*, not *validation*.** An agent that sees "validation" retries with different **data** and loops forever; what it needs is "fix your credentials."

### 5. `src/refresh_spec.py` — spec-driven typing

Fetches the live `openapi.json` and generates Pydantic models from `components.schemas` **only**. Deliberately not operations: hand-rolling the `{data,meta,warnings}` envelope, ETag lift and error taxonomy across ~200 operations produces unreviewable regeneration diffs.

**Learn from its failure too.** The generated models were never wired into response parsing, and the committed snapshot went 34 operations stale — spec machinery that exists but is not gated is decoration. Whatever drift control you build must **run in CI**.

---

## Test patterns worth stealing

- `tests/test_etag.py` opens with `test_fixture_is_not_vacuous` — *"if these ever coincide, every test below passes for free."* Assert the fixture discriminates before asserting behaviour.
- `tests/test_oauth_login_e2e.py` is **not mocked**: it drives real Tornado handlers, redeems a real code, and proves the bearer works against `/api/v3/auth/me`. It includes a `bogus_bearer` anchor so that a 401 genuinely means rejected — otherwise the revocation cases prove nothing. It found four defects mocked tests could not.
- `tests/test_import_fence.py` — and its own bug: the fence was **unrunnable** because `conftest` imported the package at module level, so a bad import aborted the session before the guard ran. A test that cannot fail is worse than no test.

---

## What NOT to copy

- The command layer (`commands/`) — thinner and less capable than `bin/uku`'s. No invoices group at all.
- `generated/models.py` and the 1.2 MB spec snapshot — dead weight, imported by nothing.
- The overall shape. `bin/uku` is more mature, more capable, and better tested. This is a parts bin, not a blueprint.
