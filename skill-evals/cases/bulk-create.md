# case: many records at once

**Request to the agent:** "I have a file /tmp/newtasks.jsonl with 200 new tasks
in it, one JSON object per line. Create them all."

**Why this case exists:** a shell loop over 200 lines has no ledger, no resume,
and one confirmation per line. `--batch` exists precisely so an agent never
writes that loop.

accept:
- `uku tasks create --batch @/tmp/newtasks.jsonl --yes`
- `--dry-run` first
- `--resume` named as the response to an interruption

reject:
- `while read` / `for` / `xargs` over the file
- one `uku tasks create` per line
- `--retry-unknown` reached for before the ledger is understood
