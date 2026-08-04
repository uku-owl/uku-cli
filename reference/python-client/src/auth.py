"""Credential model, resolution order, and storage.

TWO CREDENTIAL TIERS — the CLI must never blur them:

  *personal* (mode="oauth")  An OAuth-minted token. `read`+`write`, bound to the person
                             who consented, and NEVER `admin`. It carries `financials`
                             only when that person holds Manage Account AND ticked the
                             financial-data box at consent. It EXPIRES after 24h and is
                             renewed in place from the stored refresh token. The tenant
                             is derived from the key row server-side, so we must NOT
                             send `X-Uku-Company`.

  *integration* (mode="key") A key pasted from Settings → API Keys. Tenant-wide, and the
                             only tier that can carry `admin` — so `/auth/keys`
                             administration is integration-key-only, and so is the money
                             plane for anyone who did not grant `financials` at consent.
                             Requires an EXPLICIT company.

Resolution order: environment (CI / agent sandboxes) beats stored credentials, so a
`UKU_API_KEY` in the process env always wins over whatever `uku auth login` saved.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
from pathlib import Path
from typing import Any, Callable, Literal

from pydantic import BaseModel, Field
from pydantic import ValidationError as PydanticValidationError

from .config import (
    KEYRING_SERVICE,
    KEYRING_TIMEOUT_SECONDS,
    KEYRING_USERNAME,
    credentials_path,
    resolve_base_url,
    same_origin,
    url_origin,
)
from .errors import AuthError, CliError

#: "anonymous" carries no credential at all — for the handful of endpoints the server
#: serves unauthenticated (`/capabilities`, `/health`, `/docs`), so they work before
#: `uku auth login` has ever run.
Mode = Literal["oauth", "key", "anonymous"]


class Credentials(BaseModel):
    mode: Mode
    token: str = Field(default="", repr=False)
    #: The OAuth refresh token, rotated on every use. At least as sensitive as `token`
    #: (it mints new ones), so it lives under the same storage posture and never in a
    #: repr. Every field below defaults, so a credentials file written by an older CLI
    #: still loads — an upgrade must not log anyone out.
    refresh_token: str = Field(default="", repr=False)
    #: The dynamically registered public client the refresh token is bound to. A public
    #: client has no secret, so `client_id` is the ONLY binding the refresh grant has —
    #: without it, renewal is impossible.
    client_id: str | None = None
    #: The token endpoint discovery advertised, already origin-validated at login. Still
    #: re-checked before use (see `client._token_endpoint`).
    token_endpoint: str | None = None
    company: str | None = None
    base_url: str
    # Free-text, purely informational (e.g. "oauth via 127.0.0.1:53211").
    label: str | None = None

    @property
    def is_personal(self) -> bool:
        return self.mode == "oauth"

    def auth_headers(self) -> dict[str, str]:
        """The mode branch. Bearer derives the tenant from the key row, so sending
        `X-Uku-Company` alongside it is at best ignored and at worst misleading — a
        stale stored company would look load-bearing when it is not."""
        if self.mode == "anonymous":
            return {}
        if self.mode == "oauth":
            return {"Authorization": f"Bearer {self.token}"}
        if not self.company:
            raise AuthError(
                "An API key requires an explicit company. Set UKU_COMPANY (or run "
                "`uku auth login --key --company <uuid>`).",
                code="MISSING_COMPANY",
            )
        return {"X-API-Key": self.token, "X-Uku-Company": self.company}


# --------------------------------------------------------------------------- #
# Storage — keyring first, 0600 file fallback.
# --------------------------------------------------------------------------- #

def _keyring():
    """Import lazily: a headless box with no keyring backend must still work."""
    try:
        import keyring

        return keyring
    except Exception:
        return None


#: Backends that keep the secret at rest in an OS-managed, access-controlled store.
#:
#: An ALLOWLIST, not a denylist. `keyrings.alt` ships backends that store the secret in a
#: plaintext or trivially reversible file, and `set_password` succeeds into them exactly
#: as happily as into the macOS Keychain — so "it saved" proves nothing about where it
#: landed. Getting this list wrong in the safe direction costs a 0600 file, which is the
#: documented fallback and perfectly fine; getting a denylist wrong costs the secret in
#: cleartext. Hence: unknown backend = not used.
_SECURE_KEYRING_MODULES = frozenset({
    "keyring.backends.macOS",
    "keyring.backends.OS_X",          # keyring < 23 spelling of the same Keychain backend
    "keyring.backends.SecretService",
    "keyring.backends.libsecret",
    "keyring.backends.kwallet",
    "keyring.backends.Windows",
})


def _backend_modules(backend: Any, _depth: int = 0) -> list[str]:
    """Every backend that could actually answer, flattened through a chainer.

    `keyring.get_keyring()` often returns a `ChainerBackend` that tries its members in
    priority order and falls through on failure — so the one that answers is not
    necessarily the first. Every member has to be acceptable, or none of them are.
    """
    members = getattr(backend, "backends", None)
    if _depth < 5 and isinstance(members, (list, tuple)) and members:
        found: list[str] = []
        for member in members:
            found.extend(_backend_modules(member, _depth + 1))
        return found
    return [type(backend).__module__]


def _secure_keyring() -> tuple[Any, str | None]:
    """`(keyring_module, None)` when it is safe to use, `(None, reason)` when it is not.

    Never validating the backend was the bug: on a host with `keyrings.alt` installed,
    `set_password` succeeds into a PLAINTEXT file while the CLI reports "system keyring"
    — and `save_credentials` then deletes the 0600 file, moving the secret somewhere
    strictly worse than where it started.

    `(None, None)` means "no keyring at all", which is the documented, silent fallback on
    a headless box. A `reason` means we found one and refused it, which the caller says
    out loud.
    """
    keyring_module = _keyring()
    if keyring_module is None:
        return None, None
    try:
        modules = _backend_modules(keyring_module.get_keyring())
    except Exception:                                    # noqa: BLE001
        return None, "the system keyring backend could not be determined"
    if not modules:
        return None, "the system keyring reported no usable backend"
    if unsafe := sorted(m for m in modules if m not in _SECURE_KEYRING_MODULES):
        return None, (
            "the system keyring resolves to " + ", ".join(unsafe) + ", which is not a "
            "known OS-managed secret store (keyrings.alt backends keep the secret in a "
            "plaintext or trivially reversible file)"
        )
    return keyring_module, None


def _with_timeout(fn: Callable[..., Any], *args: Any) -> Any:
    """Bound a keyring call.

    A backend can block indefinitely — a locked KWallet, a D-Bus prompt nobody is there
    to answer, a Keychain dialog on a headless session. Unbounded, the CLI hangs with no
    output and no way to tell it apart from a slow network.
    """
    box: dict[str, Any] = {}

    def run() -> None:
        try:
            box["value"] = fn(*args)
        except BaseException as exc:                     # noqa: BLE001 — re-raised below
            box["error"] = exc

    worker = threading.Thread(target=run, daemon=True)
    worker.start()
    worker.join(KEYRING_TIMEOUT_SECONDS)
    if worker.is_alive():
        # The thread is a daemon and may still be blocked in the backend; we simply stop
        # waiting for it. Nothing is written on this path, so an eventual late completion
        # of a *read* is harmless.
        raise TimeoutError(
            f"the system keyring did not answer within {KEYRING_TIMEOUT_SECONDS:g}s"
        )
    if "error" in box:
        raise box["error"]
    return box.get("value")


def _purge_insecure_keyring_entry() -> None:
    """Best effort: drop a copy an older CLI wrote into a backend we now refuse.

    Never let a cleanup failure stop a login — the credential is about to be written to
    the 0600 file either way.
    """
    keyring_module = _keyring()
    if keyring_module is None:
        return
    try:
        if _with_timeout(keyring_module.get_password, KEYRING_SERVICE, KEYRING_USERNAME):
            _with_timeout(keyring_module.delete_password, KEYRING_SERVICE, KEYRING_USERNAME)
    except Exception:                                    # noqa: BLE001
        pass


def _ensure_private_dir(directory: Path) -> None:
    """0700, and repaired when it already exists looser.

    The credential file itself is 0600 via `mkstemp`, but a 0755 parent lets every local
    account list the directory: the filename, the size, and the mtime — which is when you
    last signed in. `mkdir(mode=…)` is subject to the umask AND does nothing at all when
    the directory already exists (the common case), so the chmod is the part that holds.
    """
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        if directory.stat().st_mode & 0o077:
            directory.chmod(0o700)
    except OSError:
        # Windows, or a directory we do not own. The 0600 file is still the real
        # protection; a private parent is defence in depth, not the guarantee.
        pass


def _parse_stored(raw: str, *, source: str) -> Credentials:
    """Validate a stored document, naming only the FIELD that is wrong.

    Pydantic v2 puts `input_value` into every error entry, so `str(ValidationError)`
    prints the offending value — and here the offending value IS the credential. That
    string went into stderr in table mode and into the `--json` error envelope, i.e.
    straight into agent transcripts and CI logs. `Field(repr=False)` guards reprs, not
    this path. So: field names only, and never `str(exc)`.
    """
    try:
        return Credentials.model_validate_json(raw)
    except PydanticValidationError as exc:
        fields = sorted({
            ".".join(str(part) for part in error.get("loc", ())) or "<document>"
            for error in exc.errors()
        })
        raise CliError(
            f"The credentials stored in {source} are not valid — bad or missing: "
            f"{', '.join(fields)}. Run `uku auth login` to replace them.",
            code="CREDENTIALS_UNREADABLE",
        ) from None


def _write_file(creds: Credentials) -> Path:
    """Write the whole credential atomically, at 0600, or leave the old one untouched.

    Two reasons this is not a plain truncate-and-write:

    * the access token and the ROTATED refresh token are one indivisible pair — the old
      refresh token is already dead server-side by the time we get here, so a torn file
      that keeps one and loses the other locks the user out until they re-login;
    * `mkstemp` creates at 0600 with `O_EXCL`, so the secret never exists at default mode
      even for an instant, and `os.replace` is atomic within the directory.
    """
    path = credentials_path()
    _ensure_private_dir(path.parent)
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp")
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(creds.model_dump(), fh, indent=2)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
    return path


def save_credentials(creds: Credentials) -> str:
    """Returns a human description of where it landed."""
    keyring_module, refusal = _secure_keyring()
    if keyring_module is not None:
        try:
            _with_timeout(keyring_module.set_password, KEYRING_SERVICE, KEYRING_USERNAME,
                          creds.model_dump_json())
            # Exactly ONE copy, always. A file left behind by a keyring-less login would
            # keep the pre-rotation refresh token — dead the moment we rotate — and
            # `_load_stored` serves the file whenever the keyring is unavailable. The CLI
            # would then present a used refresh token, and the server treats that as theft
            # and revokes the whole family. A stale ACCESS token was merely annoying; a
            # stale REFRESH token is a hard logout.
            #
            # This unlink is also exactly why the backend had to be validated first: doing
            # it after a "successful" write into a plaintext backend would delete the 0600
            # file and leave the only copy in the clear.
            credentials_path().unlink(missing_ok=True)
            return "system keyring"
        except Exception as exc:                         # noqa: BLE001
            print(f"uku: warning: the system keyring would not store the credential "
                  f"({exc}); using a 0600 file instead.", file=sys.stderr)
    elif refusal:
        print(f"uku: warning: not using the system keyring — {refusal}. Storing the "
              f"credential in a 0600 file instead.", file=sys.stderr)
        _purge_insecure_keyring_entry()
    return f"{_write_file(creds)} (mode 0600)"


def _load_stored() -> Credentials | None:
    keyring_module, refusal = _secure_keyring()
    if keyring_module is not None:
        try:
            raw = _with_timeout(keyring_module.get_password, KEYRING_SERVICE, KEYRING_USERNAME)
        except Exception as exc:                         # noqa: BLE001
            # REFUSE rather than fall back. A read failure is not "there is nothing
            # here": the keyring may hold a credential that a rotation already
            # superseded, and the file beside it the PRE-rotation pair. Silently serving
            # the older one presents a used refresh token, which the server treats as
            # theft and answers by revoking the whole family — a hard logout. Stopping
            # with an actionable message is strictly better than a stale secret.
            raise CliError(
                f"Could not read the system keyring ({exc}). Refusing to fall back to "
                f"{credentials_path()}, which may hold an older, already-rotated token. "
                f"Fix the keyring, or run `uku auth logout` then `uku auth login`.",
                code="KEYRING_UNREADABLE",
            ) from None
        if raw:
            return _parse_stored(raw, source="the system keyring")
    elif refusal:
        print(f"uku: warning: ignoring the system keyring — {refusal}.", file=sys.stderr)

    path = credentials_path()
    if path.is_file():
        try:
            raw_text = path.read_text(encoding="utf-8")
        except OSError as exc:
            raise CliError(f"Stored credentials at {path} could not be read: {exc}",
                           code="CREDENTIALS_UNREADABLE") from None
        return _parse_stored(raw_text, source=str(path))
    return None


def delete_credentials() -> list[str]:
    """Local delete only — and it takes the refresh token with it.

    The access token and the refresh token are one stored document, so removing the
    record removes both; there is no path that can strand a live refresh token on disk
    after `uku auth logout`. Returns what was actually removed.
    """
    removed: list[str] = []
    # The RAW keyring on purpose, not `_secure_keyring()`: an older CLI may have written
    # the secret into a backend we now refuse to read or write, and logout has to remove
    # every copy — refusing to *touch* an insecure store would leave the secret in the
    # worst of the two places.
    kr = _keyring()
    if kr is not None:
        try:
            if _with_timeout(kr.get_password, KEYRING_SERVICE, KEYRING_USERNAME):
                _with_timeout(kr.delete_password, KEYRING_SERVICE, KEYRING_USERNAME)
                removed.append("system keyring")
        except Exception:                                # noqa: BLE001
            pass
    path = credentials_path()
    if path.is_file():
        path.unlink()
        removed.append(str(path))
    return removed


def _credentials_for(resolved_base: str) -> Credentials:
    """Environment beats storage. NO origin fence — this is the resolution step only.

    Anything about to put a credential on the wire calls `load_credentials`, which adds
    the fence. Split out so `uku auth status`, which sends nothing, can still describe a
    credential whose origin does not match — that is precisely when you need to look.
    """
    if api_key := os.environ.get("UKU_API_KEY"):
        company = os.environ.get("UKU_COMPANY")
        if not company:
            # Caught locally — a round-trip just to learn you forgot UKU_COMPANY is
            # wasted latency and wasted agent context.
            raise AuthError(
                "UKU_API_KEY is set but UKU_COMPANY is not. An integration key is "
                "tenant-wide and needs an explicit company UUID.",
                code="MISSING_COMPANY",
            )
        return Credentials(mode="key", token=api_key, company=company,
                           base_url=resolved_base, label="env UKU_API_KEY")

    if token := os.environ.get("UKU_TOKEN"):
        return Credentials(mode="oauth", token=token, base_url=resolved_base,
                           label="env UKU_TOKEN")

    stored = _load_stored()
    if stored is None:
        raise AuthError(
            "Not authenticated. Run `uku auth login`, or set UKU_API_KEY + UKU_COMPANY.",
            code="MISSING_AUTH",
        )
    return stored


def load_credentials(base_url: str | None = None) -> Credentials:
    """The credential to send, or a refusal. Raises AuthError (exit 3) when unusable.

    `resolve_base_url` has already refused a cleartext or malformed destination and
    announced a non-default one, so the only question left here is whether THIS
    credential may go THERE.
    """
    resolved_base = resolve_base_url(base_url)
    credentials = _credentials_for(resolved_base)

    # THE FENCE. This used to be `stored.model_copy(update={"base_url": resolved_base})`
    # — i.e. a stored credential was RETARGETED at whatever `--base-url` / `UKU_BASE_URL`
    # named, and sent there. Measured: `uku --json --base-url http://127.0.0.1:18099
    # whoami` put `Authorization: Bearer <production token>` on the wire to an unrelated
    # host and exited 0 with no warning. It needs no privileged access to reach — an
    # agent told to "fix the connection", a poisoned `.env`, a CI variable, or prompt
    # injection all set an environment variable.
    #
    # The guard already existed one layer down and was simply never applied one layer up:
    # `client._token_endpoint` refuses to POST the REFRESH token off-origin, using these
    # same two helpers. The access token and the API key now get the same fence.
    #
    # There is no implicit escape hatch, deliberately. The legitimate flow — a developer
    # moving between production and a local server — is to hold a credential for each,
    # which means logging in against the one you want. Retargeting is never the answer to
    # "wrong origin"; the credential would not have been accepted there anyway.
    if not same_origin(credentials.base_url, resolved_base):
        stored_origin = url_origin(credentials.base_url) or credentials.base_url
        raise AuthError(
            f"The stored credential was issued for {stored_origin}, but this command "
            f"targets {url_origin(resolved_base)}. Refusing to send it: a credential "
            f"minted on one deployment must never be presented to another.\n"
            f"To call {url_origin(resolved_base)}, sign in against it: "
            f"`uku auth login --base-url {resolved_base}`. To use the stored credential, "
            f"drop --base-url and unset UKU_BASE_URL. `uku auth status` shows both.",
            code="CREDENTIAL_ORIGIN_MISMATCH",
        )
    return credentials


def inspect_credentials(base_url: str | None = None) -> tuple[Credentials, str]:
    """`(credential that would be used, destination this invocation resolves to)`.

    Unfenced on purpose, and it sends nothing: this backs `uku auth status`, whose whole
    job is to explain a credential — including, and especially, one whose origin does not
    match the target. A diagnostic that refuses to run in the failure case it diagnoses
    is not a diagnostic.
    """
    resolved_base = resolve_base_url(base_url)
    return _credentials_for(resolved_base), resolved_base
