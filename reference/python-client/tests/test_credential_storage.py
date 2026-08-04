"""How a credential is stored, and what a storage failure is allowed to say.

Three defects from the 2026-08-03 audit, all in `auth.py`:

* a pydantic `ValidationError` was interpolated into a user-facing string. Pydantic v2
  carries `input_value` in every error, so a malformed stored credential printed ITS OWN
  CONTENT — into stderr in table mode and into the `--json` error envelope, i.e. into
  agent transcripts and CI logs. `Field(repr=False)` guards reprs, not that path;
* the config directory was created with no mode, landing at 0755 under a normal umask;
* the keyring backend was never validated. With `keyrings.alt` installed `set_password`
  succeeds into a PLAINTEXT file while the CLI reports "system keyring" — and it then
  deletes the 0600 file, leaving the only copy in the clear.
"""
from __future__ import annotations

import json
import stat
import time
from pathlib import Path

import pytest

from uku_cli import auth as auth_module
from uku_cli.auth import Credentials, _load_stored, delete_credentials, save_credentials
from uku_cli.config import DEFAULT_BASE_URL
from uku_cli.errors import CliError

SECRET = "uku_live_do_not_print_me"
#: Pydantic ELIDES the middle of a long `input_value` (`{'mode': 'oauth', 'token'...me'}`)
#: but keeps the tail, so "is the whole secret in the string?" is the wrong question — a
#: short token leaks whole, a long one leaks its tail, and either is a disclosure. Every
#: assertion below is made against this fragment for that reason.
SECRET_TAIL = SECRET[-12:]


def creds() -> Credentials:
    return Credentials(mode="oauth", token=SECRET, refresh_token="rt-secret",
                       base_url=DEFAULT_BASE_URL)


@pytest.fixture
def store(tmp_path, monkeypatch):
    """Storage in a tmp dir, keyring off — nothing here may touch the developer's real
    credentials under the shipping service name."""
    monkeypatch.setenv("UKU_CONFIG_DIR", str(tmp_path / "uku"))
    monkeypatch.setattr(auth_module, "_keyring", lambda: None)
    return tmp_path / "uku" / "credentials.json"


# --------------------------------------------------------------------------- #
# FIX-2 — a credential must never appear in its own error message
# --------------------------------------------------------------------------- #

def test_an_invalid_stored_credential_names_the_field_not_the_value(store: Path):
    """The realistic shape: a truncated or half-written file. Pydantic reports the
    MISSING field with `input` set to the whole parent document — which contains the
    token."""
    store.parent.mkdir(parents=True, exist_ok=True)
    store.write_text(json.dumps({"mode": "oauth", "token": SECRET}))   # no base_url

    with pytest.raises(CliError) as caught:
        _load_stored()

    message = str(caught.value) + str(caught.value.to_envelope())
    assert SECRET_TAIL not in message, "the stored token was echoed into the error"
    assert "base_url" in message, "the offending field must still be named"
    assert "uku auth login" in message, "and the error must say how to recover"


def test_a_wrongly_typed_token_does_not_print_the_token(store: Path):
    """The other shape: the bad value IS the secret, so it is the error's `input_value`."""
    store.parent.mkdir(parents=True, exist_ok=True)
    store.write_text(json.dumps({"mode": "oauth", "token": {"nested": SECRET},
                                 "base_url": DEFAULT_BASE_URL}))

    with pytest.raises(CliError) as caught:
        _load_stored()

    assert SECRET_TAIL not in str(caught.value) + str(caught.value.to_envelope())
    assert "token" in str(caught.value)


def test_a_file_that_is_not_json_at_all_says_so_without_quoting_it(store: Path):
    store.parent.mkdir(parents=True, exist_ok=True)
    store.write_text(f"this is not json, but it does contain {SECRET}")

    with pytest.raises(CliError) as caught:
        _load_stored()

    assert SECRET_TAIL not in str(caught.value)


@pytest.mark.parametrize("document", [
    {"mode": "oauth", "token": SECRET},                                     # truncated file
    {"mode": "oauth", "token": {"nested": SECRET},
     "base_url": DEFAULT_BASE_URL},                                         # wrong type
])
def test_the_leak_assertions_are_not_vacuous(document):
    """Bug injection, in place: prove pydantic really does put the value in the string
    the old code interpolated. Without this, the assertions above could pass because
    pydantic changed, not because the fix works."""
    from pydantic import ValidationError as PydanticValidationError

    with pytest.raises(PydanticValidationError) as caught:
        Credentials.model_validate_json(json.dumps(document))

    assert SECRET_TAIL in str(caught.value), (
        "pydantic no longer echoes input_value — the FIX-2 assertions above would now "
        "pass for the wrong reason; re-check them against the current pydantic."
    )


# --------------------------------------------------------------------------- #
# FIX-3 — the config directory is not world-listable
# --------------------------------------------------------------------------- #

def test_the_config_directory_is_created_private(store: Path):
    save_credentials(creds())

    assert stat.S_IMODE(store.parent.stat().st_mode) == 0o700
    assert stat.S_IMODE(store.stat().st_mode) == 0o600


def test_an_existing_world_listable_directory_is_repaired(store: Path):
    """`mkdir(mode=…)` does nothing when the directory already exists, which is the
    common case — every user who ran an earlier CLI has a 0755 one."""
    store.parent.mkdir(parents=True, exist_ok=True)
    store.parent.chmod(0o755)

    save_credentials(creds())

    assert stat.S_IMODE(store.parent.stat().st_mode) == 0o700


# --------------------------------------------------------------------------- #
# FIX-4 — the keyring backend is validated before it is trusted
# --------------------------------------------------------------------------- #

def _backend_named(module: str):
    cls = type("Backend", (), {})
    cls.__module__ = module
    return cls()


class FakeKeyring:
    def __init__(self, backend_module: str, *, on_get=None, on_set=None) -> None:
        self.backend_module = backend_module
        self.store: dict[tuple[str, str], str] = {}
        self.on_get = on_get
        self.on_set = on_set

    def get_keyring(self):
        return _backend_named(self.backend_module)

    def set_password(self, service, username, value):
        if self.on_set:
            self.on_set()
        self.store[(service, username)] = value

    def get_password(self, service, username):
        if self.on_get:
            self.on_get()
        return self.store.get((service, username))

    def delete_password(self, service, username):
        self.store.pop((service, username), None)


@pytest.mark.parametrize("backend", [
    "keyrings.alt.file",            # plaintext / obfuscated
    "keyrings.alt.Windows",
    "keyring.backends.fail",        # "there is no backend", dressed as one
    "keyring.backends.null",        # accepts writes and discards them
])
def test_an_insecure_backend_is_refused_and_the_0600_file_is_used(backend, store: Path,
                                                                  monkeypatch, capsys):
    fake = FakeKeyring(backend)
    monkeypatch.setattr(auth_module, "_keyring", lambda: fake)

    location = save_credentials(creds())

    assert fake.store == {}, f"the secret was written into {backend}"
    assert "0600" in location and str(store) in location
    assert stat.S_IMODE(store.stat().st_mode) == 0o600
    warning = capsys.readouterr().err
    assert "not using the system keyring" in warning
    assert backend in warning, "the message must name what it refused, so it is fixable"


def test_a_secure_backend_is_still_used(store: Path, monkeypatch):
    """Non-vacuity: the allowlist must not have disabled the keyring for everyone."""
    fake = FakeKeyring("keyring.backends.macOS")
    monkeypatch.setattr(auth_module, "_keyring", lambda: fake)

    location = save_credentials(creds())

    assert location == "system keyring"
    assert json.loads(fake.store[("uku-cli", "default")])["token"] == SECRET
    assert not store.exists(), "exactly one copy — the file must not survive"


def test_a_chainer_is_only_trusted_when_every_member_is(store: Path, monkeypatch):
    """`keyring.get_keyring()` commonly returns a chainer that falls through to the NEXT
    backend on failure, so the one that answers is not necessarily the first."""
    class Chainer(FakeKeyring):
        def get_keyring(self):
            chainer = _backend_named("keyring.backends.chainer")
            chainer.backends = [_backend_named("keyring.backends.SecretService"),
                                _backend_named("keyrings.alt.file")]
            return chainer

    fake = Chainer("unused")
    monkeypatch.setattr(auth_module, "_keyring", lambda: fake)

    location = save_credentials(creds())

    assert fake.store == {}
    assert "0600" in location


def test_an_insecure_backend_holding_an_older_copy_is_purged(store: Path, monkeypatch):
    """An earlier CLI wrote the secret there. Refusing to READ it must not mean leaving
    it sitting in the clear."""
    fake = FakeKeyring("keyrings.alt.file")
    fake.store[("uku-cli", "default")] = json.dumps(creds().model_dump())
    monkeypatch.setattr(auth_module, "_keyring", lambda: fake)

    save_credentials(creds())

    assert fake.store == {}, "a plaintext copy from an older CLI survived the login"


def test_a_keyring_read_failure_refuses_rather_than_serving_the_file(store: Path,
                                                                    monkeypatch):
    """A silent fallback can present a STALE, pre-rotation token. Replaying a rotated
    refresh token trips reuse detection, which revokes the whole family — a hard logout.
    Stopping with an actionable message is strictly better."""
    def boom():
        raise RuntimeError("d-bus is not running")

    fake = FakeKeyring("keyring.backends.SecretService", on_get=boom)
    monkeypatch.setattr(auth_module, "_keyring", lambda: fake)
    store.parent.mkdir(parents=True, exist_ok=True)
    store.write_text(json.dumps(creds().model_dump()))       # a tempting stale copy

    with pytest.raises(CliError) as caught:
        _load_stored()

    assert caught.value.code == "KEYRING_UNREADABLE"
    assert "already-rotated" in str(caught.value)


def test_a_hanging_keyring_is_bounded_by_a_timeout(store: Path, monkeypatch):
    """A locked KWallet or an unanswered D-Bus prompt would otherwise hang the CLI with
    no output and nothing to distinguish it from a slow network."""
    monkeypatch.setattr(auth_module, "KEYRING_TIMEOUT_SECONDS", 0.2)
    fake = FakeKeyring("keyring.backends.kwallet", on_get=lambda: time.sleep(30))
    monkeypatch.setattr(auth_module, "_keyring", lambda: fake)

    started = time.monotonic()
    with pytest.raises(CliError) as caught:
        _load_stored()
    elapsed = time.monotonic() - started

    assert elapsed < 5, f"the keyring call was not bounded ({elapsed:.1f}s)"
    assert caught.value.code == "KEYRING_UNREADABLE"


def test_logout_still_purges_a_backend_we_refuse_to_use(store: Path, monkeypatch):
    """Logout uses the RAW keyring on purpose: refusing to touch an insecure store would
    leave the secret in the worst of the two places."""
    fake = FakeKeyring("keyrings.alt.file")
    fake.store[("uku-cli", "default")] = json.dumps(creds().model_dump())
    monkeypatch.setattr(auth_module, "_keyring", lambda: fake)

    removed = delete_credentials()

    assert fake.store == {}
    assert "system keyring" in removed
