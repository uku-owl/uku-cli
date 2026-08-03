#!/usr/bin/env bash
# health — C8. `GET /api/v3/health` is unauthenticated on the server and
# answers 200 to bare curl, but this CLI refused to call it without a
# credential: need_auth checked that a key was PRESENT, never that it was
# needed. So "is the API up, or is it me?" — the first question anyone asks —
# could not be answered until after signing in.
#
# The two things pinned here are the two that were wrong:
#   1. it runs with NO credentials at all, and
#   2. it sends none either — an empty X-API-Key looks like a failed
#      credential rather than a deliberate anonymous call.
#
# Exit codes reuse the existing meanings rather than inventing any: 0 up,
# 3 the API answered but is unwell, 5 could not be reached at all.
. "$(dirname "$0")/../lib/harness.sh"

setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/health",
      "response": {"status": 200,
                   "body": {"status": "ok", "components": {"database": "up", "cache": "up"}}} }
  ]
}
JSON
start_server

note '1 — it works with no credentials, and sends none'
reset_requests
# forget_creds leaves the profile dir empty; the env vars are cleared for this
# one call, which is the state a brand-new install is actually in.
UKU_API_KEY='' UKU_COMPANY='' uku health --json
assert_status 0 'health exits 0 against a healthy API with no credentials'
assert_out_contains '"status": "ok"' 'and returns the body'
assert_request_count 1 'exactly one request'
assert_request 1 path /api/v3/health 'to the health endpoint'
assert_request_empty 1 X-API-Key 'THE POINT: no API key is sent — not even an empty one'
assert_request_empty 1 X-Uku-Company 'and no company header either'
assert_request_empty 1 Idempotency-Key 'a read carries no idempotency key'

note '2 — a credentialed user is not treated differently'
reset_requests
uku health --json
assert_status 0 'still exits 0 when signed in'
assert_request_empty 1 X-API-Key 'and STILL sends no key — the endpoint does not want one'

note '3 — the agent envelope'
reset_requests
uku health --agent
assert_status 0 'exits 0'
assert_true 'the envelope carries the health body as data' \
  sh -c "printf '%s' '$OUT' | jq -e '.data.status == \"ok\"' >/dev/null"
assert_true 'and names the base it asked, so an agent can tell WHICH api is up' \
  sh -c "printf '%s' '$OUT' | jq -e '.summary | test(\"127.0.0.1\")' >/dev/null"

teardown_case

# ── an API that answers but is unwell ────────────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/health",
      "response": {"status": 503,
                   "body": {"status": "degraded", "components": {"database": "down", "cache": "up"}}} }
  ]
}
JSON
start_server

note '4 — 503 is a different answer from "unreachable", and gets a different code'
reset_requests
UKU_API_KEY='' UKU_COMPANY='' uku health --json
assert_status 3 'an unwell API exits 3 (the API answered), not 5 (could not reach)'
assert_out_contains 'degraded' 'and the body still reaches the caller'
assert_request_count 1 'the request was made'

teardown_case

# ── an API that is not there at all ──────────────────────────────────
setup_case
start_server
note '5 — unreachable is exit 5, distinct from both of the above'
# Point at a port nothing listens on. Loopback, so the transport fence allows
# it; the connection simply fails.
UKU_API_KEY='' UKU_COMPANY='' uku --base http://127.0.0.1:1 health
assert_status 5 'unreachable exits 5'
assert_err_contains 'could not reach' 'and says so'

finish
