"""Rendering: machine output when piped, human output when interactive.

The mode is decided by the TTY, NOT by a flag (the `gh`/`docker` convention). An AI
agent or a shell pipeline gets JSON on stdout with zero extra arguments; a human at a
terminal gets a table. `--json` / `--table` force either way.

stdout carries the payload and nothing else. Prompts, warnings and errors go to stderr,
so `uku tasks list | jq` is always safe.
"""
from __future__ import annotations

import json
import sys
from enum import Enum
from typing import Any, Sequence

from rich.console import Console
from rich.table import Table

from .client import DryRun, Result
from .errors import UkuError


class OutputMode(str, Enum):
    JSON = "json"
    TABLE = "table"


def resolve_mode(force_json: bool = False, force_table: bool = False) -> OutputMode:
    if force_json:
        return OutputMode.JSON
    if force_table:
        return OutputMode.TABLE
    return OutputMode.TABLE if sys.stdout.isatty() else OutputMode.JSON


def _err_console() -> Console:
    return Console(stderr=True, soft_wrap=True)


def _out_console() -> Console:
    return Console(soft_wrap=True)


def _dumps(payload: Any) -> str:
    return json.dumps(payload, indent=2, ensure_ascii=False, default=str)


# --------------------------------------------------------------------------- #
# Success
# --------------------------------------------------------------------------- #

def emit(
    result: Result | DryRun,
    *,
    mode: OutputMode,
    quiet: bool = False,
    columns: Sequence[tuple[str, str]] | None = None,
    title: str | None = None,
) -> None:
    if mode is OutputMode.JSON:
        print(_dumps(result.envelope()))
        return

    if isinstance(result, DryRun):
        _render_dry_run(result, quiet=quiet)
        return

    _render_human(result, quiet=quiet, columns=columns, title=title)


def _render_dry_run(run: DryRun, *, quiet: bool) -> None:
    console = _out_console()
    console.print(f"[yellow]DRY RUN[/yellow] — would {run.action}. Nothing was written.")
    if run.body is not None:
        console.print("[dim]Would send:[/dim]")
        console.print(_dumps(run.body))
    if run.preview is not None:
        console.print("[dim]Current state:[/dim]")
        _render_value(console, run.preview, columns=None)
    if not quiet:
        console.print("[dim]Re-run without --dry-run (and with --yes) to apply.[/dim]")


def _render_human(
    result: Result,
    *,
    quiet: bool,
    columns: Sequence[tuple[str, str]] | None,
    title: str | None,
) -> None:
    console = _out_console()

    if result.data is None:
        if not quiet:
            console.print("[green]OK[/green]")
    else:
        _render_value(console, result.data, columns=columns, title=title)

    if result.warnings and not quiet:
        warn = _err_console()
        for item in result.warnings:
            if isinstance(item, dict):
                warn.print(f"[yellow]warning[/yellow] {item.get('code', '')}: {item.get('message', '')}")
            else:
                warn.print(f"[yellow]warning[/yellow] {item}")

    if result.meta and not quiet:
        console.print(f"[dim]{_summarize(result.meta, result.data)}[/dim]")


def _summarize(meta: dict, data: Any) -> str:
    shown = len(data) if isinstance(data, list) else 1
    total = meta.get("total")
    bits = [f"{shown} shown"] if total is None else [f"{shown} of {total}"]
    if (offset := meta.get("offset")) is not None:
        bits.append(f"offset {offset}")
    if meta.get("has_more"):
        bits.append("more available — raise --limit or advance --offset")
    if cursor := meta.get("next_cursor"):
        bits.append(f"next cursor {cursor}")
    return " · ".join(bits)


def _render_value(
    console: Console,
    value: Any,
    *,
    columns: Sequence[tuple[str, str]] | None,
    title: str | None = None,
) -> None:
    if isinstance(value, list):
        if not value:
            console.print("[dim]No results.[/dim]")
            return
        if all(isinstance(row, dict) for row in value):
            console.print(_build_table(value, columns, title))
            return
        for row in value:
            console.print(row)
        return

    if isinstance(value, dict):
        console.print(_build_kv_table(value, title))
        return

    console.print(value)


# Keep an auto-derived table narrow enough to read; `--json` is always there for the
# full row. Curated commands pass explicit `columns` instead.
_AUTO_COLUMN_LIMIT = 6
_AUTO_COLUMN_PREFERRED = ("id", "name", "title", "status", "date", "due_date", "client_id")


def _build_table(
    rows: list[dict],
    columns: Sequence[tuple[str, str]] | None,
    title: str | None,
) -> Table:
    if not columns:
        keys = list(rows[0].keys())
        ordered = [k for k in _AUTO_COLUMN_PREFERRED if k in keys]
        ordered += [k for k in keys if k not in ordered]
        columns = [(k, k) for k in ordered[:_AUTO_COLUMN_LIMIT]]

    table = Table(title=title, header_style="bold", show_lines=False)
    for _, header in columns:
        table.add_column(header, overflow="fold")
    for row in rows:
        table.add_row(*[_cell(row.get(key)) for key, _ in columns])
    return table


def _build_kv_table(value: dict, title: str | None) -> Table:
    table = Table(title=title, show_header=False, box=None, pad_edge=False)
    table.add_column("field", style="dim")
    table.add_column("value", overflow="fold")
    for key, item in value.items():
        table.add_row(key, _cell(item))
    return table


def _cell(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False, default=str)
    return str(value)


# --------------------------------------------------------------------------- #
# Failure — always stderr, never stdout
# --------------------------------------------------------------------------- #

def emit_error(error: UkuError, *, mode: OutputMode) -> None:
    """In JSON mode, the passthrough error envelope — the same shape the API emits, so
    an agent parses one format everywhere. In table mode, a readable line."""
    if mode is OutputMode.JSON:
        print(_dumps(error.to_envelope()), file=sys.stderr)
        return

    console = _err_console()
    console.print(f"[red]{error.code}[/red]: {error.message}")
    if error.details:
        console.print(_dumps(error.details))
    if error.request_id:
        console.print(f"[dim]request id {error.request_id}[/dim]")
