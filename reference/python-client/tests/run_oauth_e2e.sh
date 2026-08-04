#!/usr/bin/env bash
# Run the REAL end-to-end OAuth login suite for `uku auth login`.
#
#   bash uku_cli/tests/run_oauth_e2e.sh                 # full run
#   bash uku_cli/tests/run_oauth_e2e.sh -k replay       # one case
#
# This is the server-side half of the suite. It cannot live in the pytest module:
# `uku_cli/tests/test_import_fence.py` forbids EVERY `.py` file under `uku_cli/` from
# importing `backend.*`, `sqlalchemy`, `redis` … — the CLI ships to customers and must
# run without the application venv. So all database / Redis work happens here, out of
# process, and reaches the suite as environment variables. (The fence walker only reads
# `.py` files, so a `.sh` with a heredoc is the sanctioned escape hatch — same shape as
# `backend/tests/integration_tests/run_mcp_e2e.sh`.)
#
# What it does, in order:
#   1. Activates venv + .env.native (POLARIS_ENVIRONMENT, PG/Redis host vars).
#   2. Refuses to run against anything that looks like production.
#   3. Verifies the `oauth_refresh_token` table exists — the refresh grant 500s without
#      it, and the migration is NEW (2026-08-03). Actionable message if missing.
#   4. Picks, in YOUR LOCAL DB, an API-plan-eligible company plus two people in it:
#      an ADMIN (MANAGE_ACCOUNT — drives the financials-granted case) and, if one
#      exists, a PLAIN member (no MANAGE_ACCOUNT — drives the financials-refused case).
#      Both must have a `user` row, because the consent page authenticates a person via
#      `self.UID` == `user.account_id`. Override with UKU_OAUTH_E2E_COMPANY_ID.
#   5. FORGES a logged-in session for each: writes `session:<sid>` into Redis DB 1 and
#      signs the `sid` cookie with `[app] cookie_secret`, exactly as `new_session_cookie`
#      would. This is the one step a human normally does by typing a password — there is
#      no other way to click "Allow" from a test. NOTHING ELSE IS STUBBED: the suite
#      talks to the real /oauth/register, /oauth/authorize, /oauth/token and /api/v3.
#   6. Clears the per-IP OAuth rate-limit buckets in Redis DB 8 (register is 20/hour and
#      a few runs exhaust it; the 429s then read as product failures).
#   7. Runs pytest, then ALWAYS cleans up (trap): retires every api_key the run minted,
#      deletes the oauth_client / oauth_authorization_code / oauth_refresh_token rows it
#      created, and drops the forged sessions.
#
# WRITES TO YOUR LOCAL DEV DB: oauth_client + oauth_authorization_code +
# oauth_refresh_token rows, and one `api_key` row per token minted. All are cleaned up
# on exit — api_keys are RETIRED (is_active=false, is_deleted=1), never hard-deleted,
# because `api_key_request_log` has an FK to them.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."   # -> uku_service/
ROOT="$PWD"

[ -f venv/bin/python ] || { echo "No venv at $ROOT/venv — run ./install_requirements.sh"; exit 1; }
# shellcheck disable=SC1091
[ -f .env.native ] && source .env.native
export POLARIS_ENVIRONMENT="${POLARIS_ENVIRONMENT:-$(whoami)}"
export PYTHONPATH="$ROOT"
# `[app] debug=True` in dev inis turns on Tornado's autoreload watcher; a .pyc written
# under backend/ mid-run re-execs the server and an in-flight request dies looking
# exactly like a product hang.
export PYTHONDONTWRITEBYTECODE=1

BASE="${UKU_OAUTH_E2E_BASE:-http://127.0.0.1:8885}"
V3_BASE="${UKU_OAUTH_E2E_V3_BASE:-http://127.0.0.1:8890/api/v3}"

case "$(printf '%s%s' "$BASE" "$V3_BASE" | tr '[:upper:]' '[:lower:]')" in
    *app.getuku*|*app.uku*|*prod.*|*production.*|*://live.*)
        echo "SAFETY STOP: OAuth e2e target looks like production ($BASE / $V3_BASE)."; exit 1 ;;
esac

RUN_ID="$(date +%s)-$$"

echo "== preparing OAuth e2e fixtures (POLARIS_ENVIRONMENT=$POLARIS_ENVIRONMENT) =="
ENV_LINES="$(venv/bin/python - <<'PY'
import json
import os
import sys
from uuid import uuid4

from sqlalchemy import text

from backend.modules.base_module import BaseModule

BaseModule.__init__()
db = BaseModule.db

import redis
from tornado.web import create_signed_value

from backend.dao.user_dao import UserDao
from backend.models.account import Account
from backend.modules.config import Config
from backend.modules.plan_gate_module import PlanGateModule
from backend.modules.rights_module import Rights, RightsModule
from backend.modules.session import RedisSessionStore

# --- preflight: the refresh-token table is brand new (migration 2026-08-03) ---------
if not db.execute(text("SELECT to_regclass('public.oauth_refresh_token')")).scalar():
    sys.exit(
        "Table `oauth_refresh_token` is missing, so EVERY /oauth/token exchange 500s "
        "(the handler seeds a refresh family on redemption). Apply the migration:\n"
        "    cd backend && POLARIS_ENVIRONMENT=$POLARIS_ENVIRONMENT ../venv/bin/alembic upgrade head"
    )

forced = os.environ.get("UKU_OAUTH_E2E_COMPANY_ID")
eligible = list(PlanGateModule.API_PLAN_BUNDLE_IDS)

# Candidate members of API-plan companies that have a `user` row. The consent page
# resolves the person as `self.UID` == `user.account_id`, so a member without a login
# row can never render it — filter them out here rather than debugging a blank page.
sql = (
    "SELECT am.company_id, am.person_id FROM account_member am "
    "JOIN account a ON a.id = am.company_id AND a.type = 'company' AND a.is_deleted = 0 "
    "JOIN account_plan ap ON ap.account_id = am.company_id AND ap.status = 'active' "
    "  AND ap.bundle_id = ANY(:bundles) AND CURRENT_DATE BETWEEN ap.date_from AND ap.date_until "
    'JOIN "user" u ON u.account_id = am.person_id AND u.is_deleted = 0 '
    "WHERE am.is_deleted = 0 AND am.status = 'active' "
    + ("AND am.company_id = :cid " if forced else "")
    + "ORDER BY am.company_id, am.person_id"
)
params = {"bundles": eligible}
if forced:
    params["cid"] = int(forced)
rows = db.execute(text(sql), params).fetchall()

by_company: dict[int, list[int]] = {}
for company_id, person_id in rows:
    by_company.setdefault(company_id, []).append(person_id)

admin = plain = None
for company_id, people in by_company.items():
    if not PlanGateModule.has_api_access(company_id):
        continue
    # The REAL predicate the consent page uses — never `role == 'owner'` as a proxy.
    admins = [p for p in people if RightsModule.check_rights(
        p, Account, company_id, required_right=Rights.MANAGE_ACCOUNT, raise_error=False)]
    if not admins:
        continue
    others = [p for p in people if p not in admins]
    admin = (company_id, admins[0])
    plain = (company_id, others[0]) if others else None
    if plain:
        break   # a company with BOTH tiers runs the whole suite; keep looking otherwise

if admin is None:
    sys.exit(
        "No usable company found. Need a company on an API-eligible plan "
        f"(bundle_id in {sorted(eligible)}) with an active member who holds "
        "MANAGE_ACCOUNT and has a `user` row. Set UKU_OAUTH_E2E_COMPANY_ID=<id> to "
        "force one, or create one with the recipe in CLAUDE/CLAUDE_TEST_SETUP.md."
    )

company_id = admin[0]
account = db.get(Account, company_id)

r_host = Config.get_service_host("redis")
r_port = Config.get_value_int("redis", "port") or 6379
r_pass = Config.get_value("redis", "password")
sessions = redis.Redis(host=r_host, port=r_port, db=1, password=r_pass)
store = RedisSessionStore(sessions)
secret = Config.get_value("app", "cookie_secret")


def forge(person_id: int) -> tuple[str, str]:
    """A logged-in session, byte-identical to what a real password login leaves behind.

    `last_seen` is deliberately absent: `check_session_timeout` short-circuits on a
    missing key, so the session cannot age out mid-run.

    `get_user_by_account_id`, NOT `fetch_user_by_id`: `self.UID` is `user.account_id`,
    and the two columns coincide only for the oldest rows.
    """
    user = UserDao.get_user_by_account_id(person_id)
    if user is None:
        sys.exit("person %s has no `user` row — cannot forge a login session" % person_id)
    sid = uuid4().hex
    store.set_session(sid, {
        "user": user,
        "pw_epoch": user.password_changed_at.isoformat() if user.password_changed_at else None,
    }, "data")
    return sid, create_signed_value(secret, "sid", sid).decode()


def offered_companies(person_id: int) -> list[int]:
    """Mirror of `OAuthAuthorizeHandler._api_enabled_companies` — EVERY account the
    person actively belongs to (including their own person-type account), filtered by
    the plan gate. Not a company-type-only query: the consent picker isn't either.
    """
    ids = [r[0] for r in db.execute(text(
        "SELECT a.id FROM account a "
        "JOIN account_member am ON am.company_id = a.id "
        "WHERE am.person_id = :pid AND am.status = 'active' AND am.is_deleted = 0 "
        "  AND a.is_deleted = 0"
    ), {"pid": person_id}).fetchall()]
    return [i for i in ids if PlanGateModule.has_api_access(i)]


def administers_any(person_id: int) -> bool:
    """Drives whether the consent page RENDERS the financials checkbox: the handler
    shows it to anyone holding MANAGE_ACCOUNT on ANY offered account, then re-checks
    the CHOSEN one on submit."""
    return any(RightsModule.check_rights(
        person_id, Account, cid, required_right=Rights.MANAGE_ACCOUNT, raise_error=False)
        for cid in offered_companies(person_id))


admin_sid, admin_cookie = forge(admin[1])
out = {
    "UKU_OAUTH_E2E_COMPANY_ID": company_id,
    "UKU_OAUTH_E2E_COMPANY_NAME": account.name or str(company_id),
    "UKU_OAUTH_E2E_COMPANY_UUID": account.public_uuid,
    "UKU_OAUTH_E2E_ADMIN_PERSON": admin[1],
    "UKU_OAUTH_E2E_ADMIN_COOKIE": admin_cookie,
    "UKU_OAUTH_E2E_SIDS": admin_sid,
}
if plain:
    plain_sid, plain_cookie = forge(plain[1])
    out["UKU_OAUTH_E2E_PLAIN_PERSON"] = plain[1]
    out["UKU_OAUTH_E2E_PLAIN_COOKIE"] = plain_cookie
    out["UKU_OAUTH_E2E_SIDS"] = f"{admin_sid},{plain_sid}"
    # Solo tenants own a person-type account and administer THAT, so a member with no
    # rights on the target company is still often "admin somewhere" — which is exactly
    # what decides whether the checkbox is drawn.
    out["UKU_OAUTH_E2E_PLAIN_ADMINISTERS_ANY"] = "1" if administers_any(plain[1]) else "0"
else:
    # Explicit, so the suite can name WHY it skipped instead of skipping silently.
    out["UKU_OAUTH_E2E_NO_PLAIN_REASON"] = (
        f"every active member of company {company_id} holds MANAGE_ACCOUNT, so there is "
        "no non-admin identity to test the financials refusal with"
    )

# Per-IP OAuth buckets (Redis DB 8): register is 20/hour, token 60/10min. A handful of
# runs exhausts them and the 429s look like product failures.
throttle = redis.Redis(host=r_host, port=r_port, db=8, password=r_pass)
for key in throttle.scan_iter("oauth:*"):
    throttle.delete(key)

print("UKU_OAUTH_E2E_TARGET=company %s (%s), admin person %s, plain person %s"
      % (company_id, account.name, admin[1], plain[1] if plain else "-"), file=sys.stderr)
for name, value in out.items():
    print("%s=%s" % (name, value))
PY
)"

# Config.load_configuration() prints banner lines to stdout, so take only the
# NAME=value lines we emitted ourselves.
while IFS= read -r line; do
    case "$line" in
        UKU_OAUTH_E2E_*=*) export "${line?}" ;;
    esac
done <<< "$ENV_LINES"

[ -n "${UKU_OAUTH_E2E_ADMIN_COOKIE:-}" ] || { echo "fixture setup produced nothing:"; echo "$ENV_LINES"; exit 1; }

export UKU_OAUTH_E2E_BASE="$BASE"
export UKU_OAUTH_E2E_V3_BASE="$V3_BASE"
export UKU_OAUTH_E2E_RUN_ID="$RUN_ID"
# Registration timestamp fence for cleanup: the CLI's own client_name is the hardcoded
# "Uku CLI", so rows created by the REAL login path cannot be tagged with the run id.
export UKU_OAUTH_E2E_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%S)"

cleanup() {
    echo "== cleaning up OAuth e2e artifacts =="
    venv/bin/python - <<'PY' || echo "(cleanup failed — see above)"
import os

from sqlalchemy import text

from backend.modules.base_module import BaseModule

BaseModule.__init__()
db = BaseModule.db

import redis

from backend.modules.config import Config

started = os.environ["UKU_OAUTH_E2E_STARTED_AT"]

# Every oauth_client this run created: loopback redirect URI, born after we started.
clients = [r[0] for r in db.execute(text(
    "SELECT client_id FROM oauth_client "
    "WHERE created_at >= :started AND redirect_uris::text LIKE '%127.0.0.1%'"
), {"started": started}).fetchall()]

if clients:
    # api_key rows are RETIRED, never deleted — api_key_request_log FKs to them.
    retired = db.execute(text(
        "UPDATE api_key SET is_active = false, is_deleted = 1 WHERE id IN ("
        "  SELECT api_key_id FROM oauth_authorization_code "
        "   WHERE client_id = ANY(:ids) AND api_key_id IS NOT NULL "
        "  UNION "
        "  SELECT api_key_id FROM oauth_refresh_token "
        "   WHERE client_id = ANY(:ids) AND api_key_id IS NOT NULL"
        ") AND is_deleted = 0"
    ), {"ids": clients}).rowcount
    db.execute(text("DELETE FROM oauth_refresh_token WHERE client_id = ANY(:ids)"), {"ids": clients})
    db.execute(text("DELETE FROM oauth_authorization_code WHERE client_id = ANY(:ids)"), {"ids": clients})
    db.execute(text("DELETE FROM oauth_client WHERE client_id = ANY(:ids)"), {"ids": clients})
    db.commit()
    print("removed %s oauth client(s), retired %s api_key row(s)" % (len(clients), retired))

# Belt and braces: any key the token endpoint named after a loopback redirect host and
# that the client sweep above somehow missed (e.g. a run killed before its rows landed).
swept = db.execute(text(
    "UPDATE api_key SET is_active = false, is_deleted = 1 "
    "WHERE name LIKE 'Claude (OAuth via 127.0.0.1:%' AND is_deleted = 0 AND created_at >= :started"
), {"started": started}).rowcount
db.commit()
if swept:
    print("swept %s stray loopback OAuth key(s)" % swept)

sessions = redis.Redis(
    host=Config.get_service_host("redis"),
    port=Config.get_value_int("redis", "port") or 6379,
    db=1, password=Config.get_value("redis", "password"),
)
for sid in filter(None, os.environ.get("UKU_OAUTH_E2E_SIDS", "").split(",")):
    sessions.delete("session:%s" % sid)
print("dropped forged session(s)")
PY
}
trap cleanup EXIT

echo "== running OAuth login end-to-end suite =="
venv/bin/python -m pytest uku_cli/tests/test_oauth_login_e2e.py -v -p no:cacheprovider "$@"
