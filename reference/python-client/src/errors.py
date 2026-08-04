"""Typed errors and the exit-code taxonomy.

The whole point of this module is that an AI agent (or a shell script) can branch on
`$?` WITHOUT string-matching a human message. Every exit code maps to one class of
"what should I do differently", and every server error code from the API v3 error
reference lands on exactly one of them.

    0  ok
    1  generic / local failure
    2  validation — the request was malformed; fix the arguments
    3  auth — credentials missing, invalid, or incomplete; re-authenticate
    4  forbidden — authenticated but the key lacks the scope/right; use another key
    5  not found — the resource does not exist (or is not in this company)
    6  conflict / precondition — state moved under you; re-read and retry
    7  rate limited — back off and retry later
    8  server — the API (or the network to it) failed; retry later
"""
from __future__ import annotations

EXIT_OK = 0
EXIT_GENERIC = 1
EXIT_VALIDATION = 2
EXIT_AUTH = 3
EXIT_FORBIDDEN = 4
EXIT_NOT_FOUND = 5
EXIT_CONFLICT = 6
EXIT_RATE_LIMITED = 7
EXIT_SERVER = 8


class UkuError(Exception):
    """Base for everything the CLI raises. Carries the server's error envelope."""

    exit_code: int = EXIT_GENERIC

    def __init__(
        self,
        message: str,
        code: str = "CLI_ERROR",
        details: list | dict | None = None,
        status_code: int | None = None,
        request_id: str | None = None,
        retry_after: int | None = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.details = details
        self.status_code = status_code
        self.request_id = request_id
        self.retry_after = retry_after

    def to_envelope(self) -> dict:
        """The passthrough error envelope, byte-compatible with the server's own."""
        error: dict = {"code": self.code, "message": self.message}
        if self.details is not None:
            error["details"] = self.details
        if self.status_code is not None:
            error["status"] = self.status_code
        if self.request_id:
            error["request_id"] = self.request_id
        if self.retry_after is not None:
            error["retry_after"] = self.retry_after
        return {"error": error}


class CliError(UkuError):
    """Local failure — bad config, unreadable credential file, unusable argument."""

    exit_code = EXIT_GENERIC


class ValidationError(UkuError):
    exit_code = EXIT_VALIDATION


class ConfirmationRequired(ValidationError):
    """A write was invoked non-interactively without `--yes`.

    Exit 2 on purpose: this is a malformed INVOCATION, and it matches click's own
    convention of exit 2 for usage errors — an agent reading 2 knows to fix its
    command line, not its data.
    """


class WriteAborted(UkuError):
    """The operator answered "no" at the confirmation prompt."""

    exit_code = EXIT_GENERIC


class AuthError(UkuError):
    exit_code = EXIT_AUTH


class ForbiddenError(UkuError):
    exit_code = EXIT_FORBIDDEN


class NotFoundError(UkuError):
    exit_code = EXIT_NOT_FOUND


class ConflictError(UkuError):
    """409 CONFLICT, 412 STALE_WRITE, 428 PRECONDITION_REQUIRED."""

    exit_code = EXIT_CONFLICT


class RateLimitError(UkuError):
    exit_code = EXIT_RATE_LIMITED


class ServerError(UkuError):
    """5xx, and transport failures — both mean "not your fault, retry later"."""

    exit_code = EXIT_SERVER


# 400-status codes that are really "your CREDENTIAL setup is incomplete", not "your
# data is wrong". An agent that sees 2 (validation) retries with different DATA and
# loops forever; it needs 3 (auth) to know it must fix the company/key instead.
# These are exactly the X-API-Key-mode-needs-an-explicit-company failures.
_AUTH_CODES_AT_400 = frozenset({"MISSING_COMPANY", "INVALID_COMPANY", "MISSING_AUTH"})

_STATUS_MAP: dict[int, type[UkuError]] = {
    400: ValidationError,
    401: AuthError,
    403: ForbiddenError,
    404: NotFoundError,
    405: ValidationError,
    406: ValidationError,
    409: ConflictError,
    412: ConflictError,
    413: ValidationError,
    415: ValidationError,
    422: ValidationError,
    428: ConflictError,
    429: RateLimitError,
}


def error_from_response(
    status_code: int,
    code: str,
    message: str,
    details: list | dict | None = None,
    request_id: str | None = None,
    retry_after: int | None = None,
) -> UkuError:
    """Map an API v3 `{error:{code,message,details}}` response onto a typed exception."""
    if status_code == 400 and code in _AUTH_CODES_AT_400:
        cls: type[UkuError] = AuthError
    elif status_code >= 500:
        cls = ServerError
    else:
        cls = _STATUS_MAP.get(status_code, UkuError)
    return cls(
        message=message,
        code=code,
        details=details,
        status_code=status_code,
        request_id=request_id,
        retry_after=retry_after,
    )
