"""Confirm-the-exact-command, the web's version of `PendingAction` + `.confirmAction` on the Mac.

An endpoint that would change a server never runs anything itself: it builds the `Intent` and proposes it here, and
answers with the pending action (summary, the exact command or its readable preview, destructive or not). Only
`POST /api/actions/<id>/confirm` mints the `Confirmation`, through the shared `ActionPolicy`, and runs it; the
service that runs it authorizes the intent against that confirmation again, so Read-only switched on in between still
blocks it. A pending action is used once and expires after five minutes.

A sheet can ask for a word to be typed (deleting a stack with its data): the backend checks it, not the page. A sheet
can also name a follow-on command (`then`, the `up -d` after a save): it was shown to the user, so the runner may
confirm it through the same policy after the first step succeeded (Android and the Mac do the same).
"""

from __future__ import annotations

import hmac
import secrets
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any

from rackoon.core.policy import ActionPolicy, Confirmation, Intent, ReadOnly, Risk

EXPIRES_SECONDS = 300

Runner = Callable[[Confirmation], Awaitable[Any]]


@dataclass(frozen=True)
class PendingAction:
    id: str
    intent: Intent
    destructive: bool
    run: Runner
    expires: float
    title: str | None = None
    message: str | None = None
    typed: str | None = None
    then: str | None = None
    target: str | None = None

    def json(self) -> dict[str, Any]:
        """What the confirm sheet shows. `command` is the readable preview when there is one."""
        return {"id": self.id, "summary": self.intent.summary,
                "command": self.intent.preview if self.intent.preview is not None else self.intent.command,
                "isPreview": self.intent.preview is not None,
                "risk": self.intent.risk.value, "destructive": self.destructive, "title": self.title or
                self.intent.summary, "message": self.message, "typed": self.typed, "then": self.then,
                "target": self.target}


class ActionError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code


class ActionCenter:
    def __init__(self, policy: ActionPolicy, clock: Callable[[], float] = time.time) -> None:
        self.policy = policy
        self.clock = clock
        self._pending: dict[str, PendingAction] = {}
        self.running = 0

    def propose(self, intent: Intent, run: Runner, destructive: bool = False, title: str | None = None,
                message: str | None = None, typed: str | None = None, then: str | None = None,
                target: str | None = None) -> PendingAction:
        """Nothing runs yet. A change is refused up front while Read-only is on, so the user sees why."""
        if intent.risk is Risk.MUTATE and self.policy.is_read_only:
            raise ActionError(409, "readOnly", str(ReadOnly()))
        now = self.clock()
        self._pending = {k: v for k, v in self._pending.items() if v.expires > now}
        pending = PendingAction(secrets.token_urlsafe(16), intent, destructive, run, now + EXPIRES_SECONDS, title,
                                message, typed, then, target)
        self._pending[pending.id] = pending
        return pending

    def cancel(self, action_id: str) -> bool:
        return self._pending.pop(action_id, None) is not None

    async def confirm(self, action_id: str, typed: str | None = None) -> Any:
        pending = self._pending.get(action_id)
        if pending is None or pending.expires <= self.clock():
            self._pending.pop(action_id, None)
            raise ActionError(409, "expired", "This confirmation expired. Start the action again.")
        if pending.typed is not None and not hmac.compare_digest((typed or "").encode(), pending.typed.encode()):
            raise ActionError(422, "typedMismatch", f"Type {pending.typed} to confirm.")
        del self._pending[action_id]
        try:
            confirmation = self.policy.confirm(pending.intent)
        except ReadOnly as e:
            raise ActionError(409, "readOnly", str(e)) from None
        self.running += 1
        try:
            return await pending.run(confirmation)
        finally:
            self.running -= 1
