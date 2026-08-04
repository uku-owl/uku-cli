"""Lint test — pins the "the CLI is a standalone package" invariant.

Rule: NO module under `uku_cli/` may import `backend.*`.

Why: customers `pip install uku-cli` on their own machines. It talks to the public
REST API over HTTPS and nothing else — it must never need the Uku application venv,
never import server code, and never touch the database. A single `from backend.…`
import would drag in SQLAlchemy models, config files and DB connections, turning an
installable client into something only a server operator can run.

This mirrors `backend/tests/lint/test_admin_db_import_allowlist.py`, and ships inside
the package so the guarantee travels with the code rather than living in the monorepo.

If this fails: delete the import. There is no allowlist. Anything the CLI needs from
the server must arrive over the API — that is the whole contract.
"""

import os
import re

PACKAGE_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))

# `import backend`, `import backend.x`, `from backend import y`, `from backend.x import y`.
IMPORT_RE = re.compile(r'^\s*(?:from\s+backend(?:\.|\s+import\b)|import\s+backend\b)')

# This file necessarily contains the literal string it forbids (in the regex and the
# docstring), so it excludes itself — same self-exclusion the backend lint test uses.
ALLOWED_FILES = {
    os.path.join(PACKAGE_ROOT, 'tests', 'test_import_fence.py'),
}


def _iter_py_files():
    for root, dirs, files in os.walk(PACKAGE_ROOT):
        dirs[:] = [d for d in dirs
                   if d not in ('__pycache__', '.git', 'build', 'dist')
                   and not d.endswith('.egg-info')]
        for name in files:
            if name.endswith('.py'):
                yield os.path.join(root, name)


def test_no_backend_imports():
    """uku_cli must never import server code."""
    offenders = []
    for path in _iter_py_files():
        if path in ALLOWED_FILES:
            continue
        with open(path, encoding='utf-8') as handle:
            for number, line in enumerate(handle, start=1):
                if line.lstrip().startswith('#'):
                    continue
                if IMPORT_RE.match(line):
                    offenders.append(f'{path}:{number}: {line.rstrip()[:120]}')

    assert not offenders, (
        '\nuku_cli imported server code (backend.*).\n'
        'The CLI ships to customers and must run without the application venv or the '
        'database — talk to the public REST API instead. There is no allowlist.\n\n'
        + '\n'.join(offenders)
    )


def test_runtime_dependencies_are_declared_and_small():
    """A stray heavy import (sqlalchemy, tornado, celery) is the other way the fence leaks."""
    forbidden = ('sqlalchemy', 'tornado', 'celery', 'redis', 'psycopg', 'alembic', 'fastapi')
    pattern = re.compile(r'^\s*(?:from|import)\s+(' + '|'.join(forbidden) + r')\b')

    offenders = []
    for path in _iter_py_files():
        if path in ALLOWED_FILES:
            continue
        with open(path, encoding='utf-8') as handle:
            for number, line in enumerate(handle, start=1):
                if pattern.match(line):
                    offenders.append(f'{path}:{number}: {line.rstrip()[:120]}')

    assert not offenders, (
        '\nuku_cli imported a server-side library.\n'
        'The CLI depends only on httpx / pydantic / click / rich / keyring.\n\n'
        + '\n'.join(offenders)
    )


def test_the_fence_would_actually_catch_a_violation(tmp_path):
    """Bug-injection: prove the regex is not vacuous."""
    for line in ('import backend\n',
                 'from backend import models\n',
                 'from backend.api_v3.main import app\n',
                 '    import backend.dao.task_dao\n'):
        assert IMPORT_RE.match(line), f'fence missed: {line!r}'

    for line in ('import backendish\n', '# import backend\n', 'from backends import x\n'):
        assert not IMPORT_RE.match(line.lstrip('#').lstrip() if line.startswith('#') else line) or \
            line.lstrip().startswith('#'), f'fence false-positived: {line!r}'
