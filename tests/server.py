#!/usr/bin/env python3
"""Fixture HTTP server for the uku CLI test suite.

Python 3 standard library only. Binds 127.0.0.1 on an ephemeral port and prints
that port on stdout so a shell harness can capture it.

Usage:
    python3 tests/server.py --script script.json --log requests.jsonl

Script file (JSON):

    {
      "routes": [
        { "method": "POST",              # or "*" / omitted
          "path":   "/api/v3/tasks",     # exact match on the path (no query)
          # or "path_prefix": "/api/v3/" / "path_regex": "^/api/v3/tasks/[0-9]+$"
          "responses": [                 # a SEQUENCE: 1st request gets [0], …
            {"status": 428, "body": {"error": {"code": "PRECONDITION_REQUIRED"}}},
            {"status": 201, "body": {"data": {"id": 1}}}
          ]
        },
        { "method": "GET", "path": "/api/v3/contracts/41219",
          "response": {"status": 200, "body": {"data": {"id": 41219}},
                       "headers": {"ETag": "W/\\"v1\\""}} }
      ],
      "default": {"status": 200, "body": {"data": [], "meta": {"total": 0}}}
    }

  * "responses" is a list; the LAST entry repeats once the list is exhausted.
    "response" is sugar for a one-entry list.
  * A response body may be a JSON value (serialised) or a string (sent verbatim).
  * Header values support {{now+N}} / {{now-N}} / {{now}}, substituted with epoch
    seconds at send time — that is how Retry-After / X-RateLimit-Reset stay fast.

Every request is appended to the log file as one JSON object per line:
    {"method","path","query","headers":{...},"body"}
so tests can assert both what was sent and that nothing was sent at all.
"""

import argparse
import json
import os
import re
import signal
import sys
import threading
import time

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Headers that are recorded for every request. Lower-cased on the wire, but
# written to the log under these canonical names so assertions read naturally.
# An ALLOWLIST, which means a header the CLI genuinely sends is invisible to
# every assertion until it is named here — and an assertion comparing two
# absent headers passes. Add the header here first, then assert on it.
RECORDED_HEADERS = [
    "X-API-Key",
    "X-Uku-Company",
    "If-Match",
    "Idempotency-Key",
    "Content-Type",
    "User-Agent",
    "Accept",
    "Authorization",
]

TEMPLATE_RE = re.compile(r"\{\{\s*now\s*([+-]\s*\d+)?\s*\}\}")

STATE = {
    "script": {"routes": [], "default": None},
    "log": None,
    "counters": {},
    "lock": threading.Lock(),
}


def _expand(value):
    """Substitute {{now+N}} in a header value with epoch seconds."""
    if not isinstance(value, str):
        return str(value)

    def repl(m):
        delta = m.group(1)
        n = int(delta.replace(" ", "")) if delta else 0
        return str(int(time.time()) + n)

    return TEMPLATE_RE.sub(repl, value)


def _route_matches(route, method, path):
    want_method = route.get("method", "*")
    if want_method not in ("*", None) and want_method.upper() != method.upper():
        return False
    if "path" in route:
        return route["path"] == path
    if "path_prefix" in route:
        return path.startswith(route["path_prefix"])
    if "path_regex" in route:
        return re.search(route["path_regex"], path) is not None
    return True


def _pick_response(method, path):
    """Return the response dict for this request, advancing the sequence."""
    script = STATE["script"]
    with STATE["lock"]:
        for idx, route in enumerate(script.get("routes", [])):
            if not _route_matches(route, method, path):
                continue
            responses = route.get("responses")
            if responses is None:
                responses = [route.get("response", {})]
            if not responses:
                responses = [{}]
            key = "route-%d" % idx
            n = STATE["counters"].get(key, 0)
            STATE["counters"][key] = n + 1
            # The last entry repeats once the sequence is exhausted.
            return responses[n] if n < len(responses) else responses[-1]
    default = script.get("default")
    if default is None:
        default = {"status": 200, "body": {"data": [], "meta": {"total": 0, "offset": 0, "limit": 0}}}
    return default


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "uku-fixture/1"

    # keep the test output clean
    def log_message(self, fmt, *args):
        pass

    def _read_body(self):
        length = self.headers.get("Content-Length")
        if not length:
            return ""
        try:
            n = int(length)
        except ValueError:
            return ""
        if n <= 0:
            return ""
        raw = self.rfile.read(n)
        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError:
            return repr(raw)

    def _record(self, method, path, query, body):
        entry = {
            "method": method,
            "path": path,
            "query": query,
            "headers": {},
            "body": body,
        }
        for name in RECORDED_HEADERS:
            value = self.headers.get(name)
            if value is not None:
                entry["headers"][name] = value
        log = STATE["log"]
        if log:
            with STATE["lock"]:
                with open(log, "a", encoding="utf-8") as fh:
                    fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
                    fh.flush()
                    os.fsync(fh.fileno())

    def _handle(self, method):
        raw = self.path
        if "?" in raw:
            path, query = raw.split("?", 1)
        else:
            path, query = raw, ""
        body = self._read_body()
        self._record(method, path, query, body)

        spec = _pick_response(method, path)
        status = int(spec.get("status", 200))
        payload = spec.get("body", "")
        if isinstance(payload, (dict, list)):
            payload = json.dumps(payload)
        elif payload is None:
            payload = ""
        elif not isinstance(payload, str):
            payload = json.dumps(payload)
        data = payload.encode("utf-8")

        delay = spec.get("delay")
        if delay:
            time.sleep(float(delay))

        self.send_response(status)
        headers = spec.get("headers", {}) or {}
        sent_ct = False
        for name, value in headers.items():
            if name.lower() == "content-type":
                sent_ct = True
            self.send_header(name, _expand(value))
        if not sent_ct:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if method != "HEAD":
            self.wfile.write(data)

    def do_GET(self):
        self._handle("GET")

    def do_HEAD(self):
        self._handle("HEAD")

    def do_POST(self):
        self._handle("POST")

    def do_PUT(self):
        self._handle("PUT")

    def do_PATCH(self):
        self._handle("PATCH")

    def do_DELETE(self):
        self._handle("DELETE")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", required=True, help="JSON script file")
    ap.add_argument("--log", required=True, help="JSONL request log to append to")
    ap.add_argument("--port", type=int, default=0, help="0 = ephemeral (default)")
    args = ap.parse_args()

    with open(args.script, "r", encoding="utf-8") as fh:
        text = fh.read().strip()
    STATE["script"] = json.loads(text) if text else {"routes": []}
    STATE["log"] = args.log
    # make sure the log exists even when no request ever arrives
    open(args.log, "a", encoding="utf-8").close()

    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    httpd.daemon_threads = True
    port = httpd.server_address[1]
    sys.stdout.write("%d\n" % port)
    sys.stdout.flush()

    def stop(signum, frame):
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        httpd.serve_forever(poll_interval=0.05)
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
