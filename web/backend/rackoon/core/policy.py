"""The gate every state-changing command goes through (spec/scenarios/action-policy.json). Checked in the service
layer, never only in the UI: reads always pass; a mutation needs read-only off and a confirmation for exactly that
intent, and read-only is checked again at run time."""

from __future__ import annotations

import enum
from dataclasses import dataclass


class Risk(enum.Enum):
    READ = "read"
    MUTATE = "mutate"


@dataclass(frozen=True)
class Intent:
    """One thing about to run on a server, as the confirm sheet shows it. `preview` replaces the raw command when that
    is not readable (a file save carries its content encoded); it is part of the intent, so a confirmation only
    matches the exact preview that was shown."""

    summary: str
    command: str
    risk: Risk
    preview: str | None = None


class PolicyError(Exception):
    pass


class ReadOnly(PolicyError):
    def __init__(self) -> None:
        super().__init__("Read-only mode is on. Turn it off to make changes.")


class NotConfirmed(PolicyError):
    def __init__(self) -> None:
        super().__init__("This change was not confirmed.")


class InvalidTarget(PolicyError):
    def __init__(self) -> None:
        super().__init__("Refusing to run: invalid target.")


_MINT = object()


class Confirmation:
    """Proof the user was asked about exactly this intent. Only `ActionPolicy.confirm` makes one."""

    __slots__ = ("intent",)

    def __init__(self, intent: Intent, _token: object = None) -> None:
        if _token is not _MINT:
            raise TypeError("only ActionPolicy.confirm makes a Confirmation")
        self.intent = intent


class ActionPolicy:
    def __init__(self, read_only: bool = False) -> None:
        self.is_read_only = read_only

    def confirm(self, intent: Intent) -> Confirmation:
        """Called once the user said yes (or straight away for actions treated as low-risk)."""
        if intent.risk is Risk.MUTATE and self.is_read_only:
            raise ReadOnly()
        return Confirmation(intent, _MINT)

    def authorize(self, intent: Intent, confirmation: Confirmation | None) -> None:
        """Checked again at run time, so read-only switched on after a confirmation still blocks it."""
        if intent.risk is not Risk.MUTATE:
            return
        if self.is_read_only:
            raise ReadOnly()
        if confirmation is None or confirmation.intent != intent:
            raise NotConfirmed()
