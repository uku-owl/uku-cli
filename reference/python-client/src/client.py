"""The hand-written core over httpx. Everything hard about API v3 lives here exactly once.

Owns, in order of how often they bite:

  * auth-header injection, branching on credential mode (bearer vs X-API-Key+company);
  * the `{data, meta, warnings}` envelope unwrap;
  * `{error:{code,message,details}}` -> typed exception -> exit code;
  * **ETag lifted verbatim from the response HEADER** (never rebuilt from the body);
  * `Idempotency-Key` minting (uuid4 per write, overridable);
  * retry on 429 ONLY, honoring `Retry-After`;
  * ONE refresh-and-retry on 401, with a single-use guarantee on the refresh token;
  * the shared dry-run / confirm gate for every write.

This is deliberately NOT generated. A generator would have to hand-roll the custom
envelope across ~182 operations and every regen would produce an unreviewable diff.
"""
from __future__ import annotations

import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable

import httpx

from .auth import Credentials, save_credentials
from .config import (
    API_PREFIX,
    DEFAULT_TIMEOUT,
    MAX_RATE_LIMIT_RETRIES,
    MAX_RETRY_SLEEP_SECONDS,
    USER_AGENT,
    normalize_api_path,
    same_origin,
    url_origin,
)
from .errors import (
    AuthError,
    ConfirmationRequired,
    ServerError,
    UkuError,
    WriteAborted,
    error_from_response,
)

WRITE_METHODS = frozenset({"POST", "PUT", "PATCH", "DELETE"})


@dataclass
class Result:
    """One unwrapped API response."""

    data: Any = None
    meta: dict | None = None
    warnings: list | None = None
    #: The `ETag` response header, VERBATIM. See `read_for_update`.
    etag: str | None = None
    status_code: int = 200
    request_id: str | None = None

    def envelope(self) -> dict:
        """Re-emit the passthrough envelope, dropping empty keys."""
        out: dict = {"data": self.data}
        if self.meta is not None:
            out["meta"] = self.meta
        if self.warnings:
            out["warnings"] = self.warnings
        return out


@dataclass
class DryRun:
    """A write that was previewed and deliberately not performed."""

    action: str
    preview: Any = None
    body: Any = None

    def envelope(self) -> dict:
        out: dict = {"dry_run": True, "action": self.action}
        if self.body is not None:
            out["would_send"] = self.body
        if self.preview is not None:
            out["current"] = self.preview
        return out


@dataclass
class UkuClient:
    credentials: Credentials
    timeout: float = DEFAULT_TIMEOUT
    #: Injectable for tests — an `httpx.MockTransport` keeps the suite off the network.
    transport: httpx.BaseTransport | None = None
    #: Where a refreshed credential is written. Injectable so tests never touch the
    #: developer's real keyring; `None` means the real keyring/0600-file store.
    persist: Callable[[Credentials], Any] | None = None
    _http: httpx.Client = field(init=False, repr=False)
    _refresh_lock: threading.Lock = field(init=False, repr=False,
                                          default_factory=threading.Lock)
    #: Set the instant the refresh token is handed out — see `_claim_refresh_token`.
    _refresh_used: bool = field(init=False, repr=False, default=False)

    def __post_init__(self) -> None:
        self._http = httpx.Client(
            base_url=self.credentials.base_url.rstrip("/") + API_PREFIX,
            timeout=self.timeout,
            transport=self.transport,
            headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
            follow_redirects=False,
        )

    def close(self) -> None:
        self._http.close()

    def __enter__(self) -> "UkuClient":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # ------------------------------------------------------------------ #
    # Request pipeline
    # ------------------------------------------------------------------ #

    def request(
        self,
        method: str,
        path: str,
        *,
        params: dict | None = None,
        json_body: Any = None,
        headers: dict[str, str] | None = None,
        idempotency_key: str | None = None,
        if_match: str | None = None,
    ) -> Result:
        method = method.upper()
        # Here rather than only in `uku api`, because every curated command interpolates
        # an argument into its path (`f"/tasks/{task_id}"`), so `uku tasks get
        # '../../oauth/token'` is the same escape by another door. httpx resolves dot
        # segments during base-URL merging, so this must be refused before the merge.
        path = normalize_api_path(path)
        request_headers: dict[str, str] = dict(self.credentials.auth_headers())

        if method in WRITE_METHODS:
            # Minted once and REUSED across 429 retries — that is the entire point of
            # the header. A fresh key per attempt would let a retry create a second row.
            request_headers["Idempotency-Key"] = idempotency_key or str(uuid.uuid4())
        if if_match:
            request_headers["If-Match"] = if_match
        if headers:
            request_headers.update(headers)

        clean_params = (
            {k: v for k, v in params.items() if v is not None} if params else None
        )

        attempt = 0
        refresh_tried = False
        while True:
            try:
                response = self._http.request(
                    method,
                    path,
                    params=clean_params,
                    json=json_body,
                    headers=request_headers,
                )
            except httpx.HTTPError as exc:
                # Transport failure is "not your fault, retry later" — same class as 5xx.
                raise ServerError(
                    f"Could not reach the Uku API: {exc}",
                    code="CONNECTION_FAILED",
                ) from exc

            if response.status_code == 429 and attempt < MAX_RATE_LIMIT_RETRIES:
                time.sleep(_retry_after_seconds(response))
                attempt += 1
                continue

            if response.status_code == 401 and not refresh_tried and self._can_refresh():
                # Exactly ONE refresh-and-retry, and the flag is set BEFORE the attempt:
                # whatever happens below, this request can never re-enter this branch.
                refresh_tried = True
                if not self._refresh_access_token():
                    raise AuthError(
                        "Your Uku session has expired and could not be renewed. "
                        "Run `uku auth login` to sign in again.",
                        code="SESSION_EXPIRED",
                        status_code=401,
                    )
                # Only the auth header changes. The Idempotency-Key is deliberately NOT
                # re-minted — same request, same key, so the retried write cannot create
                # a second row.
                request_headers.update(self.credentials.auth_headers())
                continue
            break

        self._raise_for_error(response)
        data, meta, warnings = _unwrap(response)
        return Result(
            data=data,
            meta=meta,
            warnings=warnings,
            # VERBATIM off the header. `format_etag` emits `...+00:00` while the JSON
            # body serializes `updated_at` as `...Z` — rebuilding the value from the
            # body is a guaranteed 412 STALE_WRITE. This already bit the MCP invoice
            # tools; do not "simplify" it.
            etag=response.headers.get("ETag"),
            status_code=response.status_code,
            request_id=response.headers.get("X-Request-ID"),
        )

    def get(self, path: str, **kwargs: Any) -> Result:
        return self.request("GET", path, **kwargs)

    def post(self, path: str, **kwargs: Any) -> Result:
        return self.request("POST", path, **kwargs)

    def patch(self, path: str, **kwargs: Any) -> Result:
        return self.request("PATCH", path, **kwargs)

    def delete(self, path: str, **kwargs: Any) -> Result:
        return self.request("DELETE", path, **kwargs)

    # ------------------------------------------------------------------ #
    # Token renewal — a personal key expires in 24h, so without this every
    # machine needs a browser login a day.
    # ------------------------------------------------------------------ #

    def _can_refresh(self) -> bool:
        """Integration keys have no refresh token and must never ask for one.

        NOTE the in-process boundary: `_claim_refresh_token` guarantees single use within
        THIS process. Two concurrent `uku` processes both holding the same stored pair can
        still each present it, and the loser trips reuse detection — a hard logout, not a
        leak. Serializing that would need a cross-process lock around exchange-and-persist.
        """
        return (
            self.credentials.is_personal
            and bool(self.credentials.refresh_token)
            and not self._refresh_used
            and self._token_endpoint() is not None
        )

    def _claim_refresh_token(self) -> str | None:
        """Hand the stored refresh token out AT MOST ONCE, for the life of this client.

        Rotation is mandatory server-side, and replaying a rotated token trips RFC 9700
        reuse detection, which revokes the WHOLE family — the user is logged out hard,
        including the access key a successful rotation just minted. So the single-use
        guarantee lives here rather than at the call site: once the token leaves this
        method it can never leave it again, no matter how many callers or threads ask,
        and no matter what happens to the exchange afterwards.
        """
        with self._refresh_lock:
            if self._refresh_used or not self.credentials.refresh_token:
                return None
            self._refresh_used = True
            return self.credentials.refresh_token

    def _token_endpoint(self) -> str | None:
        """Where to POST the refresh token — or `None` when there is no safe answer.

        Same fence as `oauth._discover`, one layer down. `load_credentials` rewrites
        `base_url` whenever `--base-url` / `UKU_BASE_URL` is given, but the credential was
        minted somewhere: if the endpoint login recorded is no longer on the origin we are
        talking to, this pair belongs to ANOTHER deployment. Retargeting it would POST a
        live production refresh token at whatever `--base-url` names — so refuse, and let
        the plain 401 tell the user to log in against this server instead. Nothing is lost:
        the access token would not have worked here either.
        """
        base = self.credentials.base_url.rstrip("/")
        if url_origin(base) is None:
            return None
        stored = self.credentials.token_endpoint
        if stored and not same_origin(stored, base):
            return None
        return stored or f"{base}/oauth/token"

    def _refresh_access_token(self) -> bool:
        """One `grant_type=refresh_token` exchange. True only if credentials rotated.

        Storage is touched ONLY on a 200 carrying BOTH halves of the new pair. Every
        other outcome — transport error, non-200, a response missing either token —
        writes nothing, so the next process still finds the pair it had. (The in-memory
        token is burned regardless: after a transport error we cannot tell "rotated but
        the response was lost" from "never arrived", and re-sending it is the one thing
        that would revoke the family.)
        """
        # Resolved BEFORE the claim: no reason to burn a good refresh token when there is
        # nowhere safe to send it.
        endpoint = self._token_endpoint()
        if endpoint is None:
            return False
        refresh_token = self._claim_refresh_token()
        if refresh_token is None:
            return False
        try:
            response = self._http.post(
                endpoint,
                data={
                    "grant_type": "refresh_token",
                    "refresh_token": refresh_token,
                    # A public client has no secret; client_id is the whole binding.
                    "client_id": self.credentials.client_id or "",
                },
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )
        except httpx.HTTPError:
            return False
        if response.status_code != 200:
            return False
        try:
            payload = response.json()
        except Exception:
            return False
        access_token = payload.get("access_token")
        rotated_refresh = payload.get("refresh_token")
        if not access_token or not rotated_refresh:
            # Rotation is mandatory. Storing a new access token beside the OLD refresh
            # token would guarantee a reuse-detection family revoke on the next 401.
            return False

        rotated = self.credentials.model_copy(
            update={"token": access_token, "refresh_token": rotated_refresh}
        )
        try:
            (self.persist or save_credentials)(rotated)
        except Exception as exc:                                    # noqa: BLE001
            # The exchange already happened, so the stored pair is dead server-side.
            # Finish this run on the new token, but say plainly that the next one will
            # need a browser login — silently "succeeding" here strands the user.
            print(
                f"uku: warning: renewed your session but could not save it ({exc}). "
                "The next command may need `uku auth login`.",
                file=sys.stderr,
            )
        self.credentials = rotated
        return True

    def read_for_update(self, path: str, **kwargs: Any) -> Result:
        """GET a row and keep its ETag for a subsequent `If-Match` write.

        Always pass `result.etag` straight through to `if_match=`. Never derive the
        value from `result.data["updated_at"]` — the two serializations differ.
        """
        return self.get(path, **kwargs)

    # ------------------------------------------------------------------ #
    # Shared write gate — dry-run preview + confirmation, once, for every command
    # ------------------------------------------------------------------ #

    def guarded_write(
        self,
        *,
        action: str,
        execute: Callable[[], Result],
        preview: Callable[[], Any] | None = None,
        body: Any = None,
        dry_run: bool = False,
        assume_yes: bool = False,
        interactive: bool | None = None,
        confirm: Callable[[str], bool] | None = None,
    ) -> Result | DryRun:
        """Gate every write identically, so no command can forget to.

        * `--dry-run` runs the REAL `preview` GETs and returns without writing (and is
          never itself gated behind `--yes` — it changes nothing).
        * On a TTY, prompt unless `--yes`.
        * Non-interactively, `--yes` is REQUIRED. There is deliberately no silent
          default in either direction: defaulting to "no" would make the CLI useless
          in scripts, defaulting to "yes" would make it dangerous.
        """
        current = preview() if preview is not None else None

        if dry_run:
            return DryRun(action=action, preview=current, body=body)

        if not assume_yes:
            if interactive is None:
                interactive = sys.stdin.isatty() and sys.stderr.isatty()
            if not interactive:
                raise ConfirmationRequired(
                    f"Refusing to {action} without confirmation. Re-run with --yes to "
                    f"proceed, or --dry-run to preview.",
                    code="CONFIRMATION_REQUIRED",
                )
            if confirm is None:
                confirm = _default_confirm
            if not confirm(action):
                raise WriteAborted(f"Aborted: did not {action}.", code="ABORTED")

        return execute()

    # ------------------------------------------------------------------ #

    @staticmethod
    def _raise_for_error(response: httpx.Response) -> None:
        if response.status_code < 400:
            return

        code = f"HTTP_{response.status_code}"
        message = f"HTTP {response.status_code}"
        details = None
        try:
            body = response.json()
        except Exception:
            body = None
        if isinstance(body, dict):
            error = body.get("error")
            if isinstance(error, dict):
                code = error.get("code") or code
                message = error.get("message") or message
                details = error.get("details")
            elif isinstance(body.get("detail"), str):
                # A non-v3 layer (proxy, framework default) answered.
                message = body["detail"]
        elif response.text:
            # nginx/LB HTML — say so rather than dumping a page into an agent's context.
            message = f"HTTP {response.status_code} (non-JSON response from the server)"

        raise error_from_response(
            status_code=response.status_code,
            code=code,
            message=message,
            details=details,
            request_id=response.headers.get("X-Request-ID"),
            retry_after=_retry_after_header(response),
        )


def _default_confirm(action: str) -> bool:
    import click

    # Prompt on stderr so stdout stays a clean machine channel.
    return click.confirm(f"About to {action}. Continue?", default=False, err=True)


def _retry_after_header(response: httpx.Response) -> int | None:
    raw = response.headers.get("Retry-After")
    if raw is None:
        return None
    try:
        return int(float(raw))
    except (TypeError, ValueError):
        return None


def _retry_after_seconds(response: httpx.Response) -> float:
    seconds = _retry_after_header(response)
    if seconds is None or seconds < 0:
        seconds = 1
    return min(seconds, MAX_RETRY_SLEEP_SECONDS)


def _unwrap(response: httpx.Response) -> tuple[Any, dict | None, list | None]:
    """`{data, meta, warnings}` -> the three parts. Anything else passes through."""
    if response.status_code == 204 or not response.content:
        return None, None, None
    try:
        body = response.json()
    except Exception as exc:
        raise ServerError(
            "The API returned a body that is not valid JSON.",
            code="INVALID_RESPONSE",
            status_code=response.status_code,
        ) from exc
    if isinstance(body, dict) and "data" in body:
        return body["data"], body.get("meta"), body.get("warnings")
    return body, None, None


__all__ = ["UkuClient", "Result", "DryRun", "UkuError"]
