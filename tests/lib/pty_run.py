#!/usr/bin/env python3
"""Run a command with its STDOUT attached to a real pty, capturing what it
writes there to a file (stderr goes to a separate plain file, same as every
other harness runner). Used by tests/lib/harness.sh's uku_tty().

    pty_run.py OUTFILE ERRFILE -- CMD [ARGS...]

Why this exists: `uku()`/`uku_stdin()` in tests/lib/harness.sh deliberately
run bin/uku with stdout redirected to a plain file, because that is what
makes the "no --yes, no tty" refusal testable — and it is correct for every
one of this suite's other ~930 assertions. But bin/uku's `table()` has a
branch that exists ONLY when stdout is a real terminal (`[ -t 1 ]`), and that
branch was the one with the --fields → jq program-splice bug (S4, 2026-07-29
security audit): a plain-file-redirected test can never reach it. This is the
one place in the whole suite that pretends to be a terminal, and it exists
only because nothing else did.
"""

import os
import pty
import subprocess
import sys


def main():
    args = sys.argv[1:]
    if len(args) < 4 or args[2] != "--":
        sys.stderr.write(__doc__)
        return 2
    outfile, errfile = args[0], args[1]
    cmd = args[3:]
    if not cmd:
        sys.stderr.write(__doc__)
        return 2

    master_fd, slave_fd = pty.openpty()
    try:
        with open(errfile, "wb") as err_fh:
            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.DEVNULL,
                stdout=slave_fd,
                stderr=err_fh,
            )
        os.close(slave_fd)
        slave_fd = -1

        chunks = []
        while True:
            try:
                data = os.read(master_fd, 4096)
            except OSError:
                break
            if not data:
                break
            chunks.append(data)
        status = proc.wait()
    finally:
        if slave_fd != -1:
            os.close(slave_fd)
        os.close(master_fd)

    with open(outfile, "wb") as out_fh:
        out_fh.write(b"".join(chunks))
    return status


if __name__ == "__main__":
    sys.exit(main())
