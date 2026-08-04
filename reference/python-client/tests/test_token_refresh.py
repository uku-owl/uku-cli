"""Refresh-token persistence and the one-shot refresh-and-retry. Mocked transport only.

Access tokens expire in 24h. The CLI used to drop `payload["refresh_token"]` on the
floor, so every machine needed a browser login a day even though the server's refresh
grant worked. These tests pin the renewal, and — more importantly — the fences around it:

* the refresh token is sent AT MOST ONCE. Rotation is mandatory server-side and replaying
  a rotated token trips reuse detection, which revokes the whole family: a buggy retry
  path does not just fail, it logs the user out hard.
* nothing is written to storage unless BOTH halves of the new pair arrived.
* a failed refresh surfaces exit 3 with an actionable message, and never loops.

Every test that touches storage injects `persist=` or points `UKU_CONFIG_DIR` at a tmp
dir with the keyring disabled — the suite must never write to the developer's real
keyring under the shipping service name.
"""
from __future__ import annotations

import json
import stat
from pathlib import Path

import httpx
import pytest

from uku_cli import auth as auth_module
from uku_cli.auth import Credentials, delete_credentials, load_credentials, save_credentials
from uku_cli.client import UkuClient
from uku_cli.errors import AuthError

from .conftest import TEST_BASE_URL, error_response, json_response, key_credentials

TOKEN_PATH = "/oauth/token"
OLD_REFRESH = "rt-original"
NEW_REFRESH = "rt-rotated"


def oauth_creds(**overrides) -> Credentials:
    base = dict(mode="oauth", token="uku_live_old", refresh_token=OLD_REFRESH,
                client_id="cli-abc", token_endpoint=f"{TEST_BASE_URL}{TOKEN_PATH}",
                base_url=TEST_BASE_URL)
    base.update(overrides)
    return Credentials(**base)


class Recorder:
    """A mock server plus the audit trail every assertion here is made against."""

    def __init__(self, api, token=None):
        self.api = api
        self.token = token
        self.requests: list[httpx.Request] = []
        self.saved: list[Credentials] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        request.read()                       # materialize the body before we bank it
        self.requests.append(request)
        if request.url.path == TOKEN_PATH:
            if self.token is None:
                raise AssertionError(f"unexpected token-endpoint call: {request.url}")
            return self.token(request)
        return self.api(request)

    def persist(self, credentials: Credentials) -> str:
        self.saved.append(credentials)
        return "test store"

    def client(self, credentials: Credentials | None = None) -> UkuClient:
        return UkuClient(
            credentials=credentials or oauth_creds(),
            transport=httpx.MockTransport(self),
            persist=self.persist,
        )

    @property
    def token_calls(self) -> list[httpx.Request]:
        return [r for r in self.requests if r.url.path == TOKEN_PATH]

    @property
    def api_calls(self) -> list[httpx.Request]:
        return [r for r in self.requests if r.url.path != TOKEN_PATH]

    def refresh_tokens_sent(self) -> list[str]:
        import urllib.parse

        out = []
        for request in self.token_calls:
            form = urllib.parse.parse_qs(request.content.decode())
            out.extend(form.get("refresh_token", []))
        return out


def rotated_ok(request: httpx.Request) -> httpx.Response:
    return json_response({"access_token": "uku_live_new", "refresh_token": NEW_REFRESH,
                          "scope": "read write", "expires_in": 86400})


def sequence(*responses):
    """One handler that answers each call in turn, repeating the last forever."""
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        index = min(calls["n"], len(responses) - 1)
        calls["n"] += 1
        return responses[index]

    return handler


# --------------------------------------------------------------------------- #
# login() keeps the renewal material
# --------------------------------------------------------------------------- #

def test_login_surfaces_the_refresh_token_client_id_and_token_endpoint(monkeypatch):
    """Drives the real `oauth.login()` — its loopback listener and `state` check included
    — against a mocked authorization server, and pins that the refresh material survives
    the token exchange instead of being dropped with the rest of the payload."""
    import threading
    import urllib.parse

    from uku_cli import oauth as oauth_mod

    base = "https://uku.test"

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path.endswith("oauth-authorization-server"):
            return json_response({
                "issuer": base,
                "authorization_endpoint": f"{base}/oauth/authorize",
                "token_endpoint": f"{base}/oauth/token",
                "registration_endpoint": f"{base}/oauth/register",
            })
        if path == "/oauth/register":
            return json_response({"client_id": "cli-from-registration"}, status=201)
        if path == TOKEN_PATH:
            return json_response({"access_token": "uku_live_fresh",
                                  "refresh_token": "rt-from-login",
                                  "scope": "read write", "expires_in": 86400})
        raise AssertionError(f"unexpected call: {request.url}")

    def fake_open(url: str) -> bool:
        """Play the human: read `state` off the authorize URL and hit the REAL loopback
        listener `login()` bound, exactly as the browser's 302 would."""
        query = urllib.parse.parse_qs(urllib.parse.urlparse(url).query)
        callback = query["redirect_uri"][0]
        state = query["state"][0]
        threading.Thread(
            target=lambda: httpx.get(f"{callback}?code=the-code&state={state}", timeout=10.0),
            daemon=True,
        ).start()
        return True

    monkeypatch.setattr(oauth_mod.webbrowser, "open", fake_open)
    monkeypatch.setattr(oauth_mod, "LOGIN_TIMEOUT_SECONDS", 20)

    result = oauth_mod.login(base, transport=httpx.MockTransport(handler))

    assert result.access_token == "uku_live_fresh"
    assert result.refresh_token == "rt-from-login"
    assert result.client_id == "cli-from-registration"
    assert result.token_endpoint == f"{base}/oauth/token"


def test_the_login_command_stores_every_field_renewal_needs(monkeypatch):
    """The wiring, not the flow: whatever `login()` returned has to reach storage."""
    from click.testing import CliRunner

    from uku_cli import oauth as oauth_mod
    from uku_cli.commands import auth_cmd
    from uku_cli.context import Context

    saved: list[Credentials] = []
    monkeypatch.setattr(auth_cmd.oauth, "login", lambda *a, **k: oauth_mod.LoginResult(
        access_token="uku_live_x", scope="read write", refresh_token="rt-x",
        client_id="cli-x", token_endpoint="https://uku.test/oauth/token"))
    monkeypatch.setattr(auth_cmd, "save_credentials",
                        lambda creds: (saved.append(creds), "test store")[1])
    monkeypatch.setattr(auth_cmd, "UkuClient", lambda **kwargs: _FakeVerifier())

    runner = CliRunner()
    result = runner.invoke(auth_cmd.auth_group, ["login"],
                           obj=Context(force_json=True, quiet=True),
                           standalone_mode=False)

    assert result.exception is None, result.exception
    assert len(saved) == 1
    stored = saved[0]
    assert (stored.token, stored.refresh_token) == ("uku_live_x", "rt-x")
    assert stored.client_id == "cli-x"
    assert stored.token_endpoint == "https://uku.test/oauth/token"


class _FakeVerifier:
    """Stands in for the post-login `GET /auth/me` round trip."""

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def get(self, path):
        from uku_cli.client import Result

        return Result(data={"person_id": 1})


# --------------------------------------------------------------------------- #
# One refresh, one retry
# --------------------------------------------------------------------------- #

def test_a_401_is_refreshed_and_the_request_retried_once():
    recorder = Recorder(
        api=sequence(error_response(401, "UNAUTHORIZED"), json_response({"data": {"id": 7}})),
        token=rotated_ok,
    )
    client = recorder.client()

    result = client.get("/clients")

    assert result.data == {"id": 7}
    assert [r.url.path for r in recorder.requests] == [
        "/api/v3/clients", TOKEN_PATH, "/api/v3/clients",
    ]
    # The retry carried the NEW bearer, not the dead one.
    assert recorder.api_calls[1].headers["authorization"] == "Bearer uku_live_new"
    assert client.credentials.token == "uku_live_new"
    assert client.credentials.refresh_token == NEW_REFRESH


def test_the_rotated_pair_is_persisted_together():
    """One document, both halves. Saving the access token while losing the rotated
    refresh token would lock the user out — the old one is already dead server-side."""
    recorder = Recorder(
        api=sequence(error_response(401, "UNAUTHORIZED"), json_response({"data": {}})),
        token=rotated_ok,
    )
    recorder.client().get("/clients")

    assert len(recorder.saved) == 1
    assert recorder.saved[0].token == "uku_live_new"
    assert recorder.saved[0].refresh_token == NEW_REFRESH
    # Everything else survives the rotation.
    assert recorder.saved[0].client_id == "cli-abc"
    assert recorder.saved[0].base_url == TEST_BASE_URL


def test_the_refresh_request_carries_the_client_it_was_issued_to():
    """A public client has no secret, so `client_id` is the entire binding — the server
    refuses a refresh presented by anyone else."""
    import urllib.parse

    recorder = Recorder(
        api=sequence(error_response(401, "UNAUTHORIZED"), json_response({"data": {}})),
        token=rotated_ok,
    )
    recorder.client().get("/clients")

    form = urllib.parse.parse_qs(recorder.token_calls[0].content.decode())
    assert form["grant_type"] == ["refresh_token"]
    assert form["refresh_token"] == [OLD_REFRESH]
    assert form["client_id"] == ["cli-abc"]


def test_the_refreshed_retry_reuses_the_same_idempotency_key():
    """Same guarantee as the 429 retry: a re-minted key would let the retry create a
    second row."""
    recorder = Recorder(
        api=sequence(error_response(401, "UNAUTHORIZED"), json_response({"data": {}}, status=201)),
        token=rotated_ok,
    )
    recorder.client().post("/tasks", json_body={"title": "x"})

    first, second = recorder.api_calls
    assert first.headers["idempotency-key"] == second.headers["idempotency-key"]


# --------------------------------------------------------------------------- #
# Single use — the fence that matters most
# --------------------------------------------------------------------------- #

def test_a_refresh_token_is_never_sent_twice_however_many_401s_arrive():
    """The direct proof. The API 401s forever, so a client without the claim guard would
    refresh on every pass; replaying a rotated token trips reuse detection and revokes
    the family, logging the user out hard."""
    recorder = Recorder(api=sequence(error_response(401, "UNAUTHORIZED")), token=rotated_ok)
    client = recorder.client()

    for _ in range(3):
        with pytest.raises(AuthError):
            client.get("/clients")

    assert len(recorder.token_calls) == 1, "the refresh token was exchanged more than once"
    sent = recorder.refresh_tokens_sent()
    assert sent == [OLD_REFRESH], f"a refresh token was replayed: {sent}"


def test_a_401_after_a_successful_refresh_is_not_refreshed_again():
    """Within ONE request: refresh, retry, still 401 -> surface it. Never a second lap."""
    recorder = Recorder(api=sequence(error_response(401, "UNAUTHORIZED")), token=rotated_ok)

    with pytest.raises(AuthError) as caught:
        recorder.client().get("/clients")

    assert len(recorder.api_calls) == 2, "more than one retry"
    assert len(recorder.token_calls) == 1
    # The server's own 401, unmasked — the renewal itself did not fail.
    assert caught.value.code == "UNAUTHORIZED"
    assert caught.value.exit_code == 3


def test_a_concurrent_claim_cannot_hand_the_same_token_out_twice():
    """The guard is the claim, not the call site: whoever asks second gets nothing, so
    no arrangement of callers or threads can produce a replay."""
    client = UkuClient(credentials=oauth_creds(),
                       transport=httpx.MockTransport(lambda r: json_response({"data": {}})))
    assert client._claim_refresh_token() == OLD_REFRESH
    assert client._claim_refresh_token() is None


# --------------------------------------------------------------------------- #
# Failure surfaces as auth, not as a loop or a generic error
# --------------------------------------------------------------------------- #

def test_a_rejected_refresh_surfaces_the_auth_exit_code_without_looping():
    recorder = Recorder(
        api=sequence(error_response(401, "UNAUTHORIZED")),
        token=lambda request: httpx.Response(400, json={"error": "invalid_grant"}),
    )

    with pytest.raises(AuthError) as caught:
        recorder.client().get("/clients")

    assert caught.value.code == "SESSION_EXPIRED"
    assert caught.value.exit_code == 3
    assert "uku auth login" in caught.value.message
    assert len(recorder.requests) == 2, "the CLI retried after a failed refresh"
    assert not recorder.saved, "a failed refresh must not touch storage"


def test_a_refresh_response_without_a_rotated_token_is_treated_as_failure():
    """Rotation is mandatory. Keeping the old refresh token beside a new access token
    guarantees a family revoke on the next 401 — refuse instead."""
    recorder = Recorder(
        api=sequence(error_response(401, "UNAUTHORIZED")),
        token=lambda request: json_response({"access_token": "uku_live_new"}),
    )

    with pytest.raises(AuthError) as caught:
        recorder.client().get("/clients")

    assert caught.value.code == "SESSION_EXPIRED"
    assert not recorder.saved


def test_an_unreachable_token_endpoint_is_a_session_error_not_a_crash():
    def refuse(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused")

    recorder = Recorder(api=sequence(error_response(401, "UNAUTHORIZED")), token=refuse)
    with pytest.raises(AuthError) as caught:
        recorder.client().get("/clients")
    assert caught.value.code == "SESSION_EXPIRED"
    assert not recorder.saved


def test_a_storage_failure_still_completes_the_run_but_warns(capsys):
    recorder = Recorder(
        api=sequence(error_response(401, "UNAUTHORIZED"), json_response({"data": {"id": 1}})),
        token=rotated_ok,
    )
    client = recorder.client()
    client.persist = _explode

    assert client.get("/clients").data == {"id": 1}
    assert "uku auth login" in capsys.readouterr().err


def _explode(credentials):
    raise OSError("read-only file system")


# --------------------------------------------------------------------------- #
# Who must NOT refresh
# --------------------------------------------------------------------------- #

def test_an_integration_key_never_touches_the_token_endpoint():
    """Tenant-wide keys have no refresh token and no OAuth client to present."""
    recorder = Recorder(api=sequence(error_response(401, "UNAUTHORIZED")))

    with pytest.raises(AuthError) as caught:
        recorder.client(key_credentials()).get("/clients")

    assert caught.value.code == "UNAUTHORIZED"
    assert not recorder.token_calls


def test_a_401_without_a_stored_refresh_token_stays_a_plain_unauthorized():
    """`UKU_TOKEN` in the environment carries no refresh token. Telling that user to run
    a login that would not be persisted anyway is worse than the server's own message."""
    recorder = Recorder(api=sequence(error_response(401, "UNAUTHORIZED")))

    with pytest.raises(AuthError) as caught:
        recorder.client(oauth_creds(refresh_token="")).get("/clients")

    assert caught.value.code == "UNAUTHORIZED"
    assert not recorder.token_calls


def test_a_credential_minted_on_another_origin_is_never_refreshed_here():
    """`load_credentials` rewrites `base_url` whenever `--base-url` is given, but the
    credential was minted somewhere. If the recorded token endpoint is no longer on the
    origin we are talking to, this pair belongs to ANOTHER deployment — refreshing it
    would POST a live production refresh token at whatever `--base-url` names, which is
    G5.1 again one layer down. Refuse, and let the plain 401 ask for a real login.
    """
    recorder = Recorder(api=sequence(error_response(401, "UNAUTHORIZED")))

    with pytest.raises(AuthError) as caught:
        recorder.client(oauth_creds(token_endpoint="https://app.getuku.com/oauth/token")).get("/x")

    assert not recorder.token_calls, "the refresh token was sent to a different deployment"
    assert caught.value.code == "UNAUTHORIZED"
    assert caught.value.exit_code == 3


def test_a_token_endpoint_recorded_for_this_origin_is_honored():
    """Non-vacuity for the refusal above: an on-origin endpoint is still used verbatim,
    including a non-default path."""
    recorder = Recorder(
        api=sequence(error_response(401, "UNAUTHORIZED"), json_response({"data": {}})),
        token=rotated_ok,
    )
    recorder.client(oauth_creds(token_endpoint=f"{TEST_BASE_URL}/oauth/token")).get("/x")

    assert str(recorder.token_calls[0].url) == f"{TEST_BASE_URL}{TOKEN_PATH}"


# --------------------------------------------------------------------------- #
# Storage: atomic, 0600, and cleared by logout
# --------------------------------------------------------------------------- #

@pytest.fixture
def file_store(tmp_path, monkeypatch):
    """Point storage at a tmp dir AND disable the keyring, so nothing here can reach the
    developer's real credentials under the shipping service name."""
    monkeypatch.setenv("UKU_CONFIG_DIR", str(tmp_path))
    monkeypatch.setattr(auth_module, "_keyring", lambda: None)
    monkeypatch.delenv("UKU_API_KEY", raising=False)
    monkeypatch.delenv("UKU_TOKEN", raising=False)
    # Point at the SAME origin `oauth_creds()` was minted for. `load_credentials` refuses
    # to present a stored credential to any other origin, so leaving this unset would aim
    # every test here at production and get the credential refused rather than refreshed
    # — which is the origin fence doing its job, not the thing these tests are about.
    monkeypatch.setenv("UKU_BASE_URL", TEST_BASE_URL)
    return tmp_path / "credentials.json"


def test_the_stored_file_carries_both_tokens_at_0600(file_store: Path):
    save_credentials(oauth_creds())

    body = json.loads(file_store.read_text())
    assert body["token"] == "uku_live_old"
    assert body["refresh_token"] == OLD_REFRESH
    assert body["client_id"] == "cli-abc"
    assert stat.S_IMODE(file_store.stat().st_mode) == 0o600


def test_a_refresh_round_trips_through_the_real_file_store(file_store: Path):
    save_credentials(oauth_creds())
    recorder = Recorder(
        api=sequence(error_response(401, "UNAUTHORIZED"), json_response({"data": {}})),
        token=rotated_ok,
    )
    client = UkuClient(credentials=load_credentials(),
                       transport=httpx.MockTransport(recorder))   # real store, not injected

    client.get("/clients")

    reloaded = load_credentials()
    assert reloaded.token == "uku_live_new"
    assert reloaded.refresh_token == NEW_REFRESH


def test_a_torn_write_leaves_the_previous_pair_intact(file_store: Path, monkeypatch):
    """Atomicity, injected. The old refresh token is dead server-side the moment the
    exchange succeeds, so a half-written file is a lockout — the write must be
    all-or-nothing."""
    save_credentials(oauth_creds())
    before = file_store.read_text()

    def die(*args, **kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(auth_module.json, "dump", die)
    with pytest.raises(OSError):
        save_credentials(oauth_creds(token="uku_live_new", refresh_token=NEW_REFRESH))

    assert file_store.read_text() == before
    assert not list(file_store.parent.glob(".*tmp*")), "a temp file with secrets was left behind"


def test_logout_clears_the_refresh_token(file_store: Path):
    save_credentials(oauth_creds())
    assert OLD_REFRESH in file_store.read_text()

    removed = delete_credentials()

    assert removed == [str(file_store)]
    assert not file_store.exists()
    with pytest.raises(AuthError) as caught:
        load_credentials()
    assert caught.value.code == "MISSING_AUTH"


class _SecureBackend:
    """Stands in for an OS-managed store. `save_credentials` only trusts a backend whose
    module is on the allowlist, so the fake has to claim a real one — the string IS the
    contract being tested."""


_SecureBackend.__module__ = "keyring.backends.macOS"


class _FakeKeyring:
    """A keyring backend that appears mid-life — the case that strands a file."""

    def __init__(self) -> None:
        self.store: dict[tuple[str, str], str] = {}

    def get_keyring(self):
        """The real `keyring` module exposes this, and the CLI now asks WHICH backend it
        got before trusting it with a secret (a `keyrings.alt` plaintext backend accepts
        `set_password` just as happily as the Keychain does)."""
        return _SecureBackend()

    def set_password(self, service, username, value):
        self.store[(service, username)] = value

    def get_password(self, service, username):
        return self.store.get((service, username))

    def delete_password(self, service, username):
        self.store.pop((service, username), None)


def test_saving_to_the_keyring_removes_a_file_left_by_a_keyring_less_login(
    file_store: Path, monkeypatch
):
    """One copy, always. A user who logged in with no keyring backend has the pair in a
    file; if a keyring appears later, the ROTATED pair goes to the keyring and the file
    keeps the dead refresh token. The next keyring-less run would then present a used
    token — and the server revokes the whole family for that."""
    save_credentials(oauth_creds())                     # no keyring yet -> file
    assert file_store.exists()

    fake = _FakeKeyring()
    monkeypatch.setattr(auth_module, "_keyring", lambda: fake)
    save_credentials(oauth_creds(token="uku_live_new", refresh_token=NEW_REFRESH))

    assert not file_store.exists(), "a file holding the PREVIOUS refresh token survived"
    assert json.loads(fake.store[("uku-cli", "default")])["refresh_token"] == NEW_REFRESH


def test_logout_clears_both_stores(file_store: Path, monkeypatch):
    fake = _FakeKeyring()
    monkeypatch.setattr(auth_module, "_keyring", lambda: fake)
    save_credentials(oauth_creds())
    # Simulate the pre-fix divergence, so this proves logout sweeps both.
    file_store.write_text(json.dumps(oauth_creds().model_dump()))

    delete_credentials()

    assert not file_store.exists()
    assert not fake.store
    with pytest.raises(AuthError):
        load_credentials()


def test_credentials_written_by_an_older_cli_still_load(file_store: Path):
    """An upgrade must not log anyone out: the pre-refresh file has none of the new
    keys."""
    file_store.parent.mkdir(parents=True, exist_ok=True)
    file_store.write_text(json.dumps({
        "mode": "oauth", "token": "uku_live_legacy", "base_url": TEST_BASE_URL,
        "label": "personal key (scope: read write)",
    }))

    stored = load_credentials()

    assert stored.token == "uku_live_legacy"
    assert stored.refresh_token == ""
    assert stored.client_id is None
