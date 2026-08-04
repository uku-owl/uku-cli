"""The object every command receives — output mode, flags, and a lazy client."""
from __future__ import annotations

from typing import Sequence

from .auth import load_credentials
from .client import DryRun, Result, UkuClient
from .config import DEFAULT_TIMEOUT
from .output import OutputMode, emit, resolve_mode


class Context:
    def __init__(
        self,
        *,
        force_json: bool = False,
        force_table: bool = False,
        quiet: bool = False,
        base_url: str | None = None,
        timeout: float = DEFAULT_TIMEOUT,
        yes: bool = False,
    ) -> None:
        self.mode: OutputMode = resolve_mode(force_json, force_table)
        self.quiet = quiet
        self.base_url = base_url
        self.timeout = timeout
        self.yes = yes
        self._client: UkuClient | None = None

    @property
    def client(self) -> UkuClient:
        """Built on first use, so `uku --help` never touches the keyring."""
        if self._client is None:
            self._client = UkuClient(
                credentials=load_credentials(self.base_url), timeout=self.timeout
            )
        return self._client

    def emit(
        self,
        result: Result | DryRun,
        *,
        columns: Sequence[tuple[str, str]] | None = None,
        title: str | None = None,
    ) -> None:
        emit(result, mode=self.mode, quiet=self.quiet, columns=columns, title=title)
