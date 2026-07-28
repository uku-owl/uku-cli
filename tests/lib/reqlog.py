#!/usr/bin/env python3
"""Query the fixture server's JSONL request log. Used by tests/lib/harness.sh.

    reqlog.py count           <log>
    reqlog.py get             <log> <index-1-based> <field>
    reqlog.py dump            <log>

<field> is one of: method, path, query, body, or a header name (anything
containing a '-', e.g. X-API-Key, If-Match). A missing field prints nothing.
"""

import json
import sys


def load(path):
    out = []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    out.append(json.loads(line))
    except FileNotFoundError:
        pass
    return out


def field(entry, name):
    if name in ("method", "path", "query", "body"):
        return entry.get(name, "")
    headers = entry.get("headers", {})
    for key, value in headers.items():
        if key.lower() == name.lower():
            return value
    return ""


def main():
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    cmd, path = sys.argv[1], sys.argv[2]
    entries = load(path)
    if cmd == "count":
        print(len(entries))
        return 0
    if cmd == "dump":
        for i, entry in enumerate(entries, 1):
            print("  #%d %s %s%s" % (
                i, entry.get("method"), entry.get("path"),
                ("?" + entry["query"]) if entry.get("query") else ""))
            for key in sorted(entry.get("headers", {})):
                print("       %s: %s" % (key, entry["headers"][key]))
            if entry.get("body"):
                print("       body: %s" % entry["body"])
        return 0
    if cmd == "get":
        idx = int(sys.argv[3])
        name = sys.argv[4]
        if idx < 1 or idx > len(entries):
            sys.stderr.write("no request #%d (log has %d)\n" % (idx, len(entries)))
            return 1
        sys.stdout.write(field(entries[idx - 1], name))
        sys.stdout.write("\n")
        return 0
    sys.stderr.write("unknown command: %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main())
