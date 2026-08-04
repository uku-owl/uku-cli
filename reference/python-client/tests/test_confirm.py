"""The shared write gate: dry-run, TTY prompt, and `--yes` required off-TTY.

There is deliberately NO silent default. Defaulting to "no" would make the CLI useless
in scripts; defaulting to "yes" would make an agent's first typo destructive.
"""
from __future__ import annotations

import json

import httpx
import pytest

from uku_cli.client import DryRun
from uku_cli.errors import ConfirmationRequired, WriteAborted

from .conftest import build_client, json_response

TASK = {"data": {"id": 42, "title": "File VAT return", "status": "new",
                 "client_id": 3, "finished_at": None}}


def task_api(writes: list[httpx.Request]):
    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "GET":
            return json_response(TASK)
        writes.append(request)
        return json_response({"data": {**TASK["data"], "status": "finished"}})

    return handler


# --------------------------------------------------------------------------- #
# Client-level: the gate itself
# --------------------------------------------------------------------------- #

def test_non_interactive_write_without_yes_is_refused():
    client = build_client(lambda request: json_response({"data": {}}))
    with pytest.raises(ConfirmationRequired) as caught:
        client.guarded_write(
            action="complete task 42",
            execute=lambda: client.post("/tasks/42/complete", json_body={}),
            interactive=False,
        )
    # Exit 2 — a malformed invocation, same slot as click's own usage errors.
    assert caught.value.exit_code == 2


def test_non_interactive_write_with_yes_proceeds():
    writes: list[httpx.Request] = []
    client = build_client(task_api(writes))
    result = client.guarded_write(
        action="complete task 42",
        execute=lambda: client.post("/tasks/42/complete", json_body={}),
        interactive=False,
        assume_yes=True,
    )
    assert result.data["status"] == "finished"
    assert len(writes) == 1


def test_interactive_prompt_declined_aborts_without_writing():
    writes: list[httpx.Request] = []
    client = build_client(task_api(writes))
    with pytest.raises(WriteAborted):
        client.guarded_write(
            action="complete task 42",
            execute=lambda: client.post("/tasks/42/complete", json_body={}),
            interactive=True,
            confirm=lambda action: False,
        )
    assert writes == []


def test_interactive_prompt_accepted_writes():
    writes: list[httpx.Request] = []
    client = build_client(task_api(writes))
    client.guarded_write(
        action="complete task 42",
        execute=lambda: client.post("/tasks/42/complete", json_body={}),
        interactive=True,
        confirm=lambda action: True,
    )
    assert len(writes) == 1


def test_dry_run_performs_the_preview_get_but_never_writes():
    writes: list[httpx.Request] = []
    reads: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        (reads if request.method == "GET" else writes).append(request)
        return json_response(TASK)

    client = build_client(handler)
    result = client.guarded_write(
        action="complete task 42",
        preview=lambda: client.get("/tasks/42").data,
        execute=lambda: client.post("/tasks/42/complete", json_body={}),
        dry_run=True,
    )

    assert isinstance(result, DryRun)
    assert result.preview["title"] == "File VAT return"  # a REAL GET, not a stub
    assert len(reads) == 1
    assert writes == []


def test_dry_run_does_not_itself_require_yes():
    """It changes nothing; gating it behind --yes would be theatre."""
    client = build_client(lambda request: json_response(TASK))
    result = client.guarded_write(
        action="complete task 42",
        execute=lambda: client.post("/tasks/42/complete", json_body={}),
        dry_run=True,
        interactive=False,
        assume_yes=False,
    )
    assert isinstance(result, DryRun)


# --------------------------------------------------------------------------- #
# End to end through the real commands — proving no command bypasses the gate
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("argv", [
    ["tasks", "complete", "42"],
    ["tasks", "reopen", "42"],
    ["tasks", "create", "New task"],
    ["time", "log", "--task-id", "42", "--person-id", "5",
     "--start", "2026-08-03T09:00:00", "--duration", "3600"],
    ["api", "POST", "/tasks/42/complete"],
])
def test_every_write_command_requires_yes_when_non_interactive(argv, run_cli, capsys):
    writes: list[httpx.Request] = []
    exit_code = run_cli(argv, task_api(writes))
    captured = capsys.readouterr()

    assert exit_code == 2, f"{argv} was not gated"
    assert writes == [], f"{argv} wrote without confirmation"
    # stderr leads with the destination announcement (non-default base URL in the suite),
    # which --json cannot silence; the envelope is the JSON document after it.
    envelope = json.loads(captured.err[captured.err.index("{"):])
    assert envelope["error"]["code"] == "CONFIRMATION_REQUIRED"


def test_yes_lets_a_write_through(run_cli, capsys):
    writes: list[httpx.Request] = []
    exit_code = run_cli(["tasks", "complete", "42", "--yes"], task_api(writes))

    assert exit_code == 0
    assert len(writes) == 1
    assert json.loads(capsys.readouterr().out)["data"]["status"] == "finished"


def test_dry_run_command_exits_zero_and_reports_what_it_would_do(run_cli, capsys):
    writes: list[httpx.Request] = []
    exit_code = run_cli(["tasks", "complete", "42", "--dry-run"], task_api(writes))
    payload = json.loads(capsys.readouterr().out)

    assert exit_code == 0
    assert writes == []
    assert payload["dry_run"] is True
    assert payload["current"]["title"] == "File VAT return"


def test_global_yes_flag_also_satisfies_the_gate(run_cli):
    writes: list[httpx.Request] = []
    assert run_cli(["--yes", "tasks", "complete", "42"], task_api(writes)) == 0
    assert len(writes) == 1
