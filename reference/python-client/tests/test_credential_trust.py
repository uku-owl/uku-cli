"""Where a credential is allowed to travel, and what a path may address.

The bug these pin (audit 2026-08-03): `load_credentials` RETARGETED a stored credential
at whatever `--base-url` / `UKU_BASE_URL` named —

    stored = stored.model_copy(update={"base_url": resolved_base})

— so `uku --json --base-url http://127.0.0.1:18099 whoami` put a live production
`Authorization: Bearer …` on the wire to an unrelated host, in cleartext, and exited 0
with no warning. Nothing privileged is needed to reach it: an agent told to "fix the
connection", a poisoned `.env`, a CI variable, or prompt injection all set an
environment variable.

The guard already existed one layer down — `client._token_endpoint` refuses to POST the
REFRESH token off-origin — so these tests pin the SAME fence, generalised, over the
access token and the API key.

The load-bearing assertion in most of them is `recorder.requests == []`: not "the call
failed", but "nothing was ever sent".
"""
from __future__ import annotations

import json

import httpx
import pytest

from uku_cli import auth as auth_module
from uku_cli import cli as cli_module
from uku_cli import context as context_module
from uku_cli.config import DEFAULT_BASE_URL

from .conftest import TEST_COMPANY, json_response

PROD = DEFAULT_BASE_URL
STORED_TOKEN = "uku_live_production_secret"


def stderr_envelope(err: str) -> dict:
    """The JSON error envelope on stderr, past the destination-announcement line."""
    return json.loads(err[err.index("{"):])


class Recorder:
    """Every request that reached the wire. Empty is the point."""

    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        return json_response({"data": {"id": 1, "name": "Person"}})

    @property
    def auth_headers(self) -> list[str]:
        return [
            value
            for request in self.requests
            for name, value in request.headers.items()
            if name.lower() in ("authorization", "x-api-key")
        ]


@pytest.fixture
def stored_prod_login(tmp_path, monkeypatch):
    """A machine logged in to production, with no env credentials and no keyring.

    This is the state the exploit needs: a real stored credential plus an attacker who
    controls only the DESTINATION.
    """
    monkeypatch.setenv("UKU_CONFIG_DIR", str(tmp_path))
    monkeypatch.setattr(auth_module, "_keyring", lambda: None)
    for name in ("UKU_API_KEY", "UKU_COMPANY", "UKU_TOKEN", "UKU_BASE_URL"):
        monkeypatch.delenv(name, raising=False)
    (tmp_path / "credentials.json").write_text(json.dumps({
        "mode": "oauth",
        "token": STORED_TOKEN,
        "refresh_token": "rt-production",
        "client_id": "cli-abc",
        "token_endpoint": f"{PROD}/oauth/token",
        "base_url": PROD,
        "label": "personal key (scope: read write)",
    }))
    return tmp_path


@pytest.fixture
def run(monkeypatch):
    """The real entry point, with every client pinned to a recording transport."""
    def _run(argv: list[str]) -> tuple[int, Recorder]:
        recorder = Recorder()
        original = context_module.UkuClient

        def patched(*args, **kwargs):
            kwargs.setdefault("transport", httpx.MockTransport(recorder))
            return original(*args, **kwargs)

        monkeypatch.setattr(context_module, "UkuClient", patched)
        return cli_module.main(argv), recorder

    return _run


# --------------------------------------------------------------------------- #
# 1. Cross-origin credential refusal — the core fix
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("destination", [
    "http://127.0.0.1:18099",       # the demonstrated capture listener (loopback, so the
                                    # cleartext fence does NOT catch it — only this one does)
    "https://evil.example",         # a TLS host the user never configured
    "https://app.getuku.com.evil.example",   # a suffix that reads like production
])
def test_a_stored_production_credential_is_never_sent_to_another_origin(
    destination, stored_prod_login, run, capsys
):
    exit_code, recorder = run(["--json", "--base-url", destination, "whoami"])
    captured = capsys.readouterr()

    assert recorder.requests == [], f"a request reached {destination}"
    assert recorder.auth_headers == [], "the credential was put on the wire"
    assert exit_code == 3, "an origin refusal is an auth failure — re-authenticate"
    # The secret must not leak into the transcript by way of the error either.
    assert STORED_TOKEN not in captured.out + captured.err
    envelope = stderr_envelope(captured.err)
    assert envelope["error"]["code"] == "CREDENTIAL_ORIGIN_MISMATCH"
    # Actionable, and it names BOTH origins so the reader can see the swap.
    assert "app.getuku.com" in envelope["error"]["message"]
    assert "uku auth login --base-url" in envelope["error"]["message"]


def test_the_environment_variable_path_is_fenced_too(stored_prod_login, run, monkeypatch):
    """`--base-url` is the obvious vector; `UKU_BASE_URL` is the one an agent or a
    poisoned `.env` actually sets, and it is not on the command line to be noticed."""
    monkeypatch.setenv("UKU_BASE_URL", "https://evil.example")

    exit_code, recorder = run(["--json", "whoami"])

    assert recorder.requests == []
    assert exit_code == 3


def test_the_stored_credential_still_works_against_its_own_origin(stored_prod_login, run):
    """Non-vacuity: the fence must not have simply broken the CLI."""
    exit_code, recorder = run(["--json", "whoami"])

    assert exit_code == 0
    assert [str(r.url) for r in recorder.requests] == [f"{PROD}/api/v3/auth/me"]
    assert recorder.auth_headers == [f"Bearer {STORED_TOKEN}"]


def test_naming_the_stored_origin_explicitly_is_allowed(stored_prod_login, run):
    """Same origin, spelled with a trailing slash — an origin comparison, not a string one."""
    exit_code, recorder = run(["--json", "--base-url", f"{PROD}/", "whoami"])

    assert exit_code == 0
    assert recorder.auth_headers == [f"Bearer {STORED_TOKEN}"]


def test_the_escape_hatch_is_to_log_in_against_the_other_origin(stored_prod_login, run,
                                                               tmp_path, monkeypatch):
    """The legitimate flow — a developer moving to a local dev server — is a credential
    minted THERE, not the production one aimed at it."""
    (tmp_path / "credentials.json").write_text(json.dumps({
        "mode": "oauth", "token": "uku_live_dev", "base_url": "http://127.0.0.1:8885",
    }))

    exit_code, recorder = run(["--json", "--base-url", "http://127.0.0.1:8885", "whoami"])

    assert exit_code == 0
    assert recorder.auth_headers == ["Bearer uku_live_dev"]


# --------------------------------------------------------------------------- #
# 2. Cleartext refusal
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("destination", [
    "http://evil.example",
    "http://192.168.1.50:8885",     # a LAN address is REMOTE — the wire is still shared
    "http://127.0.0.2:8885",        # deliberately NOT loopback: the list is exactly four
])
def test_a_credential_is_never_sent_over_cleartext_to_another_machine(
    destination, run, cli_env, monkeypatch, capsys
):
    """The CI path: `UKU_API_KEY` + `UKU_COMPANY` in the environment, which is how an
    agent sandbox is usually credentialed."""
    monkeypatch.setenv("UKU_BASE_URL", destination)

    exit_code, recorder = run(["--json", "whoami"])
    captured = capsys.readouterr()

    assert recorder.requests == []
    assert exit_code == 2, "a refused destination is a malformed invocation — fix the URL"
    envelope = stderr_envelope(captured.err)
    assert envelope["error"]["code"] == "INSECURE_BASE_URL"
    assert TEST_COMPANY not in captured.err, "the company id leaked into the refusal"


@pytest.mark.parametrize("destination", [
    "http://127.0.0.1:8885",
    "http://localhost:8885",
    "http://api.localhost:4000",
    "http://[::1]:8885",
])
def test_loopback_over_plain_http_is_still_allowed(destination, run, cli_env, monkeypatch):
    """Deliberate and correct: that is where every dev server and fixture lives, and
    nothing leaves the machine."""
    monkeypatch.setenv("UKU_BASE_URL", destination)

    exit_code, recorder = run(["--json", "whoami"])

    assert exit_code == 0
    assert len(recorder.requests) == 1
    assert recorder.auth_headers, "loopback must still carry the credential"


@pytest.mark.parametrize("junk", ["app.getuku.com", "notaurl", "javascript:alert(1)",
                                  "file:///etc/passwd", "https://"])
def test_a_base_url_that_is_not_an_absolute_http_url_is_refused(junk, run, cli_env,
                                                                monkeypatch, capsys):
    monkeypatch.setenv("UKU_BASE_URL", junk)

    exit_code, recorder = run(["--json", "whoami"])

    assert recorder.requests == []
    assert exit_code == 2
    envelope = stderr_envelope(capsys.readouterr().err)
    assert envelope["error"]["code"] == "INVALID_BASE_URL"


# --------------------------------------------------------------------------- #
# 3. Destination announcement — the line an agent's supervisor reads
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("argv", [
    ["whoami"],
    ["--json", "whoami"],
    ["--quiet", "whoami"],
    ["--json", "--quiet", "whoami"],        # the exact shape an agent invokes
])
def test_a_non_default_destination_announces_itself_on_stderr(argv, run, cli_env,
                                                              monkeypatch, capsys):
    """`--quiet` silences progress chatter and `--json` makes stdout machine-readable.
    Neither may silence WHERE THE KEY WENT — that is the one line a human supervising an
    agent has to be able to see in the transcript."""
    monkeypatch.setenv("UKU_BASE_URL", "https://evil.example")

    exit_code, _ = run(argv)
    captured = capsys.readouterr()

    assert exit_code == 0
    assert "evil.example" in captured.err
    assert "sending Uku credentials to" in captured.err
    assert "evil.example" not in captured.out, "the announcement must not pollute stdout"


def test_the_announcement_names_the_real_host_not_the_userinfo(run, cli_env, monkeypatch,
                                                               capsys):
    """`https://app.getuku.com@evil.example/` goes to evil.example. A line reading
    "sending credentials to app.getuku.com@evil.example" invites exactly the glance that
    stops at the familiar word."""
    monkeypatch.setenv("UKU_BASE_URL", "https://app.getuku.com@evil.example")

    run(["--json", "whoami"])
    message = capsys.readouterr().err

    assert "sending Uku credentials to evil.example" in message


def test_the_default_production_host_stays_silent(stored_prod_login, run, capsys):
    """Otherwise the line appears on every command and becomes one people skip."""
    exit_code, _ = run(["--json", "whoami"])

    assert exit_code == 0
    assert "sending Uku credentials to" not in capsys.readouterr().err


def test_the_announcement_is_pure_ascii(run, cli_env, monkeypatch, capsys):
    """It must survive a stderr opened with a non-UTF-8 encoding (a redirected pipe
    under LC_ALL=C). A UnicodeEncodeError here would suppress the one warning this
    whole mechanism exists to deliver."""
    monkeypatch.setenv("UKU_BASE_URL", "https://evil.example")

    run(["--json", "whoami"])
    line = next(l for l in capsys.readouterr().err.splitlines() if "sending Uku" in l)

    line.encode("ascii")        # raises if anyone reintroduces an arrow or an em dash


def test_the_announcement_is_printed_once_per_invocation(run, cli_env, monkeypatch, capsys):
    monkeypatch.setenv("UKU_BASE_URL", "https://evil.example")

    run(["--json", "whoami"])
    first = capsys.readouterr().err
    run(["--json", "whoami"])
    second = capsys.readouterr().err

    assert first.count("sending Uku credentials to") == 1
    assert second.count("sending Uku credentials to") == 1, "reset per invocation"


# --------------------------------------------------------------------------- #
# 3b. `auth status` must survive the fence — it is how you diagnose it
# --------------------------------------------------------------------------- #

def test_auth_status_reports_an_origin_mismatch_instead_of_dying_on_it(
    stored_prod_login, run, capsys
):
    """The everyday regression this nearly shipped with: a developer logged in to a local
    dev server, running `uku auth status` with no flags, resolves to production and would
    have been refused by the fence — losing the one command that explains the refusal.
    It sends nothing, so it reports instead."""
    exit_code, recorder = run(["--json", "--base-url", "https://evil.example",
                               "auth", "status"])
    payload = json.loads(capsys.readouterr().out)["data"]

    assert exit_code == 0
    assert recorder.requests == [], "status must not call the API"
    assert payload["base_url"] == PROD                      # where the credential belongs
    assert payload["target_base_url"] == "https://evil.example"   # where we were pointed
    assert payload["usable_against_target"] is False
    assert STORED_TOKEN not in json.dumps(payload), "status must never print the secret"


def test_auth_status_confirms_a_matching_origin(stored_prod_login, run, capsys):
    exit_code, _ = run(["--json", "auth", "status"])
    payload = json.loads(capsys.readouterr().out)["data"]

    assert exit_code == 0
    assert payload["usable_against_target"] is True


# --------------------------------------------------------------------------- #
# 4. Path traversal — `..` escapes the /api/v3 prefix
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize("path", [
    "/../../oauth/token",
    "../../oauth/token",
    "/tasks/../../../oauth/token",
    "/%2e%2e/%2e%2e/oauth/token",       # a proxy in front of the API may decode this
])
def test_a_traversing_api_path_is_refused(path, run, cli_env, capsys):
    exit_code, recorder = run(["--json", "api", "GET", path])

    assert recorder.requests == [], f"{path} reached the server"
    assert exit_code == 2
    envelope = stderr_envelope(capsys.readouterr().err)
    assert envelope["error"]["code"] == "INVALID_PATH"


def test_a_curated_command_cannot_traverse_either(run, cli_env):
    """`uku tasks get X` interpolates into `f"/tasks/{task_id}"`, so the fence has to sit
    in `client.request`, not only in `uku api`."""
    exit_code, recorder = run(["--json", "tasks", "get", "../../oauth/token"])

    assert recorder.requests == []
    assert exit_code == 2


def test_an_absolute_url_is_not_a_path(run, cli_env):
    """httpx treats an absolute URL as a REPLACEMENT for base_url, not a suffix of it."""
    exit_code, recorder = run(["--json", "api", "GET", "https://evil.example/steal"])

    assert recorder.requests == []
    assert exit_code == 2


def test_ordinary_paths_are_untouched(run, cli_env):
    """Non-vacuity: the normaliser must not have broken normal use."""
    exit_code, recorder = run(["--json", "api", "GET", "tasks", "-Q", "status=open"])

    assert exit_code == 0
    assert recorder.requests[0].url.path == "/api/v3/tasks"
    assert recorder.requests[0].url.params["status"] == "open"
