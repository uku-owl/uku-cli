#!/usr/bin/env bash
# agent — being DRIVEN: what a failure tells you to do next, and what a program
# gets back when it asks for an envelope instead of a body.
#
# Three contracts are pinned here and each one has a way of being broken that a
# green suite would otherwise hide:
#
#   1. every error carries a remedy, on stderr, and the command it names is one
#      the CLI actually has (proved by RUNNING it, not by reading it);
#   2. --agent wraps the response — and `.data` inside the envelope is the same
#      bytes `--json` returns, because the moment those diverge every agent
#      already parsing `.data` is quietly reading something else;
#   3. --json is untouched. It is documented as the raw API body; a test that
#      only checked --agent would let a key creep into --json unnoticed.
. "$(dirname "$0")/../lib/harness.sh"

# jq is not on the box in §5 (the no-jq pass), so JSON assertions go through
# python, which the harness already depends on.
jqx() { # FILTER  → the value, from $OUT
  printf '%s' "$OUT" | "$PYTHON_BIN" -c '
import json, sys
doc = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    if part == "": continue
    if part.isdigit() or (part[0] == "-" and part[1:].isdigit()): doc = doc[int(part)]
    else: doc = doc[part]
print("" if doc is None else (json.dumps(doc) if isinstance(doc, (dict, list)) else doc))
' "$1" 2>/dev/null
}
is_json() { printf '%s' "$OUT" | "$PYTHON_BIN" -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; }

# ── 1. hints: an error says what to do next ──────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200,
                   "body": {"data":[{"id":41,"name":"Acme"},{"id":42,"name":"Byrd"}],
                            "meta":{"total":2,"offset":0,"limit":50}}} },
    { "method": "GET", "path": "/api/v3/clients/41",
      "response": {"status": 200, "body": {"data": {"id": 41, "name": "Acme"}}} },
    { "method": "GET", "path": "/api/v3/members",
      "response": {"status": 200, "body": {"data":[{"id":1}],"meta":{"total":1}}} },
    { "method": "POST", "path": "/api/v3/invoices",
      "response": {"status": 403, "body": {"error": {"code": "SCOPE_FORBIDDEN", "message": "needs an All key"}}} },
    { "method": "PATCH", "path": "/api/v3/tasks/99",
      "response": {"status": 412, "body": {"error": {"code": "STALE_WRITE"}}} },
    { "method": "POST", "path": "/api/v3/tasks",
      "response": {"status": 201, "body": {"data": {"id": 7, "title": "Prepare Q1"}}} }
  ]
}
JSON
start_server
note '1 — every failure with a next step names it, on stderr'

uku clients get
assert_status 1 'a missing argument is a usage error'
assert_err_contains '→ run: uku help clients' 'and the remedy is the card for that command'
assert_out_not_contains 'run:' 'a hint never touches stdout — that is the machine channel'

# The point of the whole exercise: the command it just told us to run exists.
reset_requests
uku help clients
assert_status 0 'and that command really is one the CLI has'

reset_requests
clear_env_creds
uku clients list
assert_status 2 'no credentials is exit 2'
assert_err_contains '→ run: uku auth login' 'and the remedy is to sign in'
export UKU_API_KEY="$TEST_API_KEY" UKU_COMPANY="$TEST_COMPANY"

reset_requests
uku tasks create --data '{"title":"x"}'
assert_status 4 'a write with no --yes and no TTY is refused'
assert_err_contains "→ run: uku tasks create --data '{\"title\":\"x\"}' --yes" \
  'and the remedy is the line you just ran, with --yes on the end'

reset_requests
uku tasks create --yes
assert_status 1 'a create with no body is a usage error'
assert_err_contains '→ run: uku help tasks' 'and the remedy is where the required fields are written down'

reset_requests
uku invoices create --data '{"client_id":1}' --yes
assert_status 2 'a 403 on money is exit 2'
assert_err_contains 'All-scope key' 'the remedy names the key that would work'
assert_err_contains '→ ' 'and it is rendered as a remedy line'

reset_requests
# --by-id: `tasks patch <id>` now PROBES an id-shaped argument for a task
# whose TITLE is that string (tests/cases/ref-safety.sh §1). That probe is a GET
# on the list endpoint, which this fixture deliberately answers 401/500 — so the
# flag says "this really is an id" and keeps the test about the code under test.
uku tasks patch 99 --by-id --data '{"title":"x"}' --yes
assert_status 6 'a 412 is exit 6'
assert_err_contains '→ run: uku tasks get 99' 'and the remedy names the exact record to re-read'

reset_requests
uku frobnicate
assert_status 1 'an unknown command is a usage error'
assert_err_contains '→ run: uku help' 'and the remedy is the command list'

# where nothing honest can be suggested, nothing is
reset_requests
uku tasks create --data '@/nope/missing.json' --yes
assert_status 1 'a missing data file is a usage error'
assert_err_not_contains '→ run:' 'and it invents no remedy, because none exists'
teardown_case

# ── 2. --agent: the success envelope ─────────────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200,
                   "body": {"data":[{"id":41,"name":"Acme"},{"id":42,"name":"Byrd"}],
                            "meta":{"total":2,"offset":0,"limit":50}}} },
    { "method": "GET", "path": "/api/v3/clients/41",
      "response": {"status": 200, "body": {"data": {"id": 41, "name": "Acme"}}} },
    { "method": "GET", "path": "/api/v3/members",
      "response": {"status": 200, "body": {"data":[{"id":1}],"meta":{"total":1}}} },
    { "method": "POST", "path": "/api/v3/tasks",
      "response": {"status": 201, "body": {"data": {"id": 7, "title": "Prepare Q1"}}} }
  ]
}
JSON
start_server
note '2 — {ok,data,meta,summary,breadcrumbs}'

uku clients list --agent
assert_status 0 '--agent on a list exits 0'
assert_true 'the envelope is one JSON object' is_json
assert_equals "$(jqx ok)" 'True' 'ok is true'
assert_equals "$(jqx summary)" '2 clients' 'the summary counts what came back'
assert_equals "$(jqx data.0.name)" 'Acme' '.data is the array the API returned'
assert_equals "$(jqx meta.total)" '2' '.meta is the envelope the API returned'
assert_equals "$(jqx breadcrumbs.0.cmd)" 'uku clients get 41' \
  'the breadcrumb carries the real id of the first row'
assert_true 'the breadcrumb names a command the CLI has' \
  sh -c "'$UKU_BIN' --dump-surface | grep -qx 'sub clients get'"

# .data must be the API's bytes, not ours — otherwise every agent already
# parsing --json's .data is silently reading a re-serialised copy.
reset_requests
uku clients list --agent
AGENT_DATA="$(jqx data)"
uku clients list --json
JSON_DATA="$(printf '%s' "$OUT" | "$PYTHON_BIN" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["data"]))')"
assert_equals "$AGENT_DATA" "$JSON_DATA" '--agent .data parses to what --json returns'
# and BYTES, not just meaning: the server's own spacing has to survive intact,
# which it only can if the value was spliced out rather than re-serialised.
reset_requests
uku clients list --agent
assert_out_contains '"data":[{"id": 41, "name": "Acme"}, {"id": 42, "name": "Byrd"}]' \
  'and byte for byte — the value is spliced out of the response, never rebuilt'
assert_out_contains '"meta":{"total": 2, "offset": 0, "limit": 50}' 'the same for .meta'

reset_requests
uku clients get 41 --agent
assert_status 0 '--agent on a get exits 0'
assert_equals "$(jqx summary)" 'client 41' 'the summary names the record'
assert_equals "$(jqx data.name)" 'Acme' '.data is the object, not an array'
assert_equals "$(jqx meta)" '' 'a response with no meta carries null, not a guess'
assert_equals "$(jqx breadcrumbs.0.cmd)" 'uku clients patch 41' 'the next step is to change it'

reset_requests
uku tasks create --data '{"title":"Prepare Q1"}' --yes --agent
assert_status 0 '--agent on a create exits 0'
assert_equals "$(jqx summary)" 'task 7 created' 'the summary names what was created'
assert_equals "$(jqx breadcrumbs.0.cmd)" 'uku tasks get 7' 'and the breadcrumb carries the NEW id'

# suppression
reset_requests
uku clients list --agent --no-hints
assert_status 0 '--no-hints still succeeds'
assert_equals "$(jqx breadcrumbs)" '[]' '--no-hints empties the breadcrumbs'
assert_equals "$(jqx summary)" '2 clients' 'but the summary is not a hint and stays'

reset_requests
uku clients list --agent --quiet
assert_equals "$(jqx breadcrumbs)" '[]' '--quiet empties them too'

reset_requests
uku doctor --agent
assert_true 'doctor --agent is one JSON object' is_json
assert_equals "$(jqx ok)" 'True' 'a doctor with no failing check is ok'
assert_true 'and the checks are carried as data' \
  sh -c "printf '%s' '$OUT' | '$PYTHON_BIN' -c 'import json,sys; d=json.load(sys.stdin); assert d[\"data\"][\"checks\"]'"

reset_requests
uku account current --agent
assert_status 0 'a local command answers in the same envelope'
assert_equals "$(jqx data.active)" 'default' 'and carries its answer as data'
assert_equals "$(jqx summary)" "active account 'default'" 'with a summary a human can read'

reset_requests
uku auth status --agent
assert_status 0 'auth status --agent exits 0'
assert_equals "$(jqx data.account)" 'env' 'it carries the account'
assert_out_not_contains "$TEST_API_KEY" 'and never the key itself'
teardown_case

# ── 3. --agent: the failure envelope ─────────────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/members",
      "response": {"status": 200, "body": {"data":[{"id":1}],"meta":{"total":1}}} },
    { "method": "POST", "path": "/api/v3/invoices",
      "response": {"status": 403, "body": {"error": {"code": "SCOPE_FORBIDDEN", "message": "needs an All key"}}} },
    { "method": "PATCH", "path": "/api/v3/tasks/99",
      "response": {"status": 412, "body": {"error": {"code": "STALE_WRITE"}}} },
    { "method": "GET", "path": "/api/v3/tasks",
      "response": {"status": 500, "body": {"error": {"code": "BOOM"}}} }
  ]
}
JSON
start_server
note '3 — {ok:false,error,code,hint} — same exit codes as ever'

uku frobnicate --agent
assert_status 1 'an unknown command is still exit 1 under --agent'
assert_true 'the failure is one JSON object' is_json
assert_equals "$(jqx ok)" 'False' 'ok is false'
assert_equals "$(jqx code)" 'usage' 'the code names the exit status'
assert_equals "$(jqx hint)" 'uku help' 'and the hint is in the envelope, not only on stderr'

reset_requests
uku invoices create --data '{"client_id":1}' --yes --agent
assert_status 2 'a 403 is still exit 2'
assert_equals "$(jqx code)" 'auth' 'code auth'
assert_out_contains 'All-scope key' 'the hint says which key would work'

reset_requests
uku tasks patch 99 --by-id --data '{"x":1}' --yes --agent
assert_status 6 'a 412 is still exit 6'
assert_equals "$(jqx code)" 'conflict' 'code conflict'
assert_equals "$(jqx hint)" 'uku tasks get 99' 'and the hint is the record to re-read'

reset_requests
uku tasks patch 99 --data '{"x":1}' --agent
assert_status 4 'a refused write is still exit 4'
assert_equals "$(jqx code)" 'confirm' 'code confirm'

reset_requests
uku tasks list --agent
assert_status 3 'a 500 is still exit 3'
assert_equals "$(jqx code)" 'api' 'code api'

reset_requests
clear_env_creds
uku clients list --agent
assert_status 2 'no credentials is exit 2 under --agent too'
assert_equals "$(jqx hint)" 'uku auth login' 'and the hint is to sign in'
export UKU_API_KEY="$TEST_API_KEY" UKU_COMPANY="$TEST_COMPANY"
teardown_case

# ── 4. --json is not touched ─────────────────────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data":[{"id":41,"name":"Acme"}],"meta":{"total":1}}} },
    { "method": "GET", "path": "/api/v3/members",
      "response": {"status": 200, "body": {"data":[{"id":1}],"meta":{"total":1}}} }
  ]
}
JSON
start_server
note '4 — the documented raw body gains nothing and loses nothing'

uku clients list --json
assert_equals "$OUT" '{"data": [{"id": 41, "name": "Acme"}], "meta": {"total": 1}}' \
  '--json is still the response body, byte for byte'
assert_out_not_contains '"ok"' 'no envelope key crept into --json'
assert_out_not_contains 'breadcrumbs' 'and no breadcrumbs either'

reset_requests
uku clients list
assert_out_not_contains 'breadcrumbs' 'a plain pipe (the --json default) has none either'
assert_err_empty 'and nothing is offered on stderr when nobody is watching'

reset_requests
uku clients list --json --agent
assert_status 1 'asking for both output contracts at once is a usage error'
assert_out_contains 'alternatives' 'and it says why — in the envelope that was asked for'
assert_no_requests 'nothing was sent'
teardown_case

# ── 5. no jq on the box ──────────────────────────────────────────────
setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path": "/api/v3/clients",
      "response": {"status": 200, "body": {"data":[{"id":41,"name":"Acme"}],"meta":{"total":1,"offset":0}}} },
    { "method": "GET", "path": "/api/v3/members",
      "response": {"status": 200, "body": {"data":[{"id":1}],"meta":{"total":1}}} },
    { "method": "GET", "path": "/api/v3/tasks",
      "response": {"status": 401, "body": {"error": {"code": "UNAUTHENTICATED"}}} }
  ]
}
JSON
start_server
hide_cmd jq
note '5 — the envelope is built in bash; jq is optional everywhere else too'

uku clients list --agent
assert_status 0 '--agent works without jq'
assert_true 'and still emits one JSON object' is_json
assert_equals "$(jqx ok)" 'True' 'ok is true'
assert_equals "$(jqx summary)" '1 client' 'the count is right (one row, singular)'
assert_equals "$(jqx data.0.name)" 'Acme' '.data survived the pure-bash splice'
assert_equals "$(jqx meta.total)" '1' 'and so did .meta'
assert_equals "$(jqx breadcrumbs.0.cmd)" 'uku clients get 41' 'the id was found without jq'

reset_requests
uku tasks list --agent
assert_status 2 'a 401 without jq is still exit 2'
assert_true 'and the failure is still one JSON object' is_json
assert_equals "$(jqx code)" 'auth' 'code auth'
teardown_case

# ── 6. --help --agent: the CLI describes itself ──────────────────────
setup_case
start_server
note '6 — discovery without pasting the help text into a context window'

uku --help --agent
assert_status 0 'uku --help --agent exits 0'
assert_true 'the whole tree is valid JSON' is_json
assert_equals "$(jqx cli)" 'uku' 'it names itself'
n_described="$(printf '%s' "$OUT" | "$PYTHON_BIN" -c 'import json,sys; print(len(json.load(sys.stdin)["commands"]))')"
n_surface="$("$UKU_BIN" --dump-surface | grep -c '^cmd ' | tr -d '[:space:]')"
assert_equals "$n_described" "$n_surface" 'it describes every command in the surface, no more and no less'
assert_out_contains '"exit_codes"' 'the exit codes are part of the description'
assert_out_contains '--agent' 'and so is --agent itself'
assert_no_requests 'describing itself needs no network'

reset_requests
uku time --help --agent
assert_status 0 'a leaf command exits 0'
assert_true 'and is valid JSON' is_json
assert_equals "$(jqx command)" 'time' 'it names the command'
assert_out_contains 'NO `uku time patch`' 'the notes carry the gotcha an agent would otherwise guess wrong'
assert_equals "$(jqx subcommands.0)" 'list' 'the subcommands come from the table'

reset_requests
uku accounts --help --agent
assert_equals "$(jqx command)" 'account' 'an alias describes the command it names'

reset_requests
uku frobnicate --help --agent
assert_status 1 'describing a command that does not exist is a usage error'
assert_equals "$(jqx code)" 'usage' 'reported in the same failure envelope'
teardown_case

finish
