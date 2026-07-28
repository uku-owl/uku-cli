#!/usr/bin/env bash
# query-encoding — the bash-3.2 signed-char regression.
#
# `printf '%d' "'ä"` yields a NEGATIVE number under bash 3.2, so an unguarded
# encoder rendered the UTF-8 continuation byte as %FFFFFFFFFFFFFFE4 and every
# non-ASCII filter silently matched nothing. _urlencode masks with & 0xFF. This
# case asserts the exact query string the server receives.
. "$(dirname "$0")/../lib/harness.sh"

setup_case
server_script <<'JSON'
{
  "routes": [
    { "method": "GET", "path_prefix": "/api/v3/",
      "response": {"status": 200, "body": {"data": [], "meta": {"total": 0}}} }
  ]
}
JSON
start_server

# ── Estonian: the case that was actually broken in production ────────
uku clients list --q 'Käibedeklaratsioon'
assert_status 0 'a non-ASCII filter succeeds'
assert_request 1 query 'q=K%C3%A4ibedeklaratsioon' 'ä is percent-encoded as UTF-8 (%C3%A4), not as a signed byte'
if printf '%s' "$(request_field 1 query)" | grep -q 'FFFFFFFF'; then
  _tap_fail 'no sign-extended byte in the query' 'the signed-char bug is back'
else
  _tap_ok 'no sign-extended byte in the query'
fi

# ── every Estonian/Nordic letter, plus an em-dash (3-byte UTF-8) ─────
reset_requests
uku clients list --q 'öäüõšž—'
assert_request 1 query 'q=%C3%B6%C3%A4%C3%BC%C3%B5%C5%A1%C5%BE%E2%80%94' \
  'two- and three-byte UTF-8 sequences are byte-correct'

# ── unreserved characters pass through, everything else is encoded ───
reset_requests
uku clients list --q 'aZ0.~_-'
assert_request 1 query 'q=aZ0.~_-' 'RFC-3986 unreserved characters are left alone'

reset_requests
uku clients list --q 'a b&c=d/e?f#g+h%i'
assert_request 1 query 'q=a%20b%26c%3Dd%2Fe%3Ff%23g%2Bh%25i' \
  'separators that would break the query string are encoded'

# ── several filters keep their order and each value is encoded ───────
reset_requests
uku clients list --q 'ä' --status 'open items' --limit 5
assert_request 1 query 'q=%C3%A4&status=open%20items&limit=5' 'each value is encoded independently'

# ── uku api --query takes a raw k=v pair, and the VALUE is encoded ───
reset_requests
uku api GET /api/v3/tasks --query 'title=Küsimus & vastus'
assert_request 1 query 'title=K%C3%BCsimus%20%26%20vastus' 'the ampersand in a value cannot inject a second parameter'
assert_request 1 path /api/v3/tasks 'the path is untouched'

# ── an empty value is still sent ─────────────────────────────────────
reset_requests
uku clients list --q ''
assert_request 1 query 'q=' 'an empty filter value produces an empty parameter'

finish
