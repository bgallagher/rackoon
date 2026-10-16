"""Confirm-the-exact-command, the web's version of `PendingAction` + `.confirmAction` on the Mac.

An endpoint that would change a server never runs anything itself: it builds the `Intent` and proposes it here, and
answers with the pending action (summary, the exact command or its readable preview, destructive or not). Only
`POST /api/actions/<id>/confirm` mints the `Confirmation`, through the shared `ActionPolicy`, and runs it; the
service that runs it authorizes the intent against that confirmation again, so Read-only switched on in between still
blocks it. A pending action is used once and expires after five minutes. Stage W5 brings the first real actions.
"""

from __future__ import annotations

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

    def json(self) -> dict[str, Any]:
        """What the confirm sheet shows. `command` is the readable preview when there is one."""
        return {"id": self.id, "summary": self.intent.summary,
                "command": self.intent.preview if self.intent.preview is not None else self.intent.command,
                "risk": self.intent.risk.value, "destructive": self.destructive}


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

    def propose(self, intent: Intent, run: Runner, destructive: bool = False) -> PendingAction:
        """Nothing runs yet. A change is refused up front while Read-only is on, so the user sees why."""
        if intent.risk is Risk.MUTATE and self.policy.is_read_only:
            raise ActionError(409, "readOnly", str(ReadOnly()))
        now = self.clock()
        self._pending = {k: v for k, v in self._pending.items() if v.expires > now}
        pending = PendingAction(secrets.token_urlsafe(16), intent, destructive, run, now + EXPIRES_SECONDS)
        self._pending[pending.id] = pending
        return pending

    def cancel(self, action_id: str) -> bool:
        return self._pending.pop(action_id, None) is not None

    async def confirm(self, action_id: str) -> Any:
        pending = self._pending.pop(action_id, None)
        if pending is None or pending.expires <= self.clock():
            raise ActionError(409, "expired", "This confirmation expired. Start the action again.")
        try:
            confirmation = self.policy.confirm(pending.intent)
        except ReadOnly as e:
            raise ActionError(409, "readOnly", str(e)) from None
        self.running += 1
        try:
            return await pending.run(confirmation)
        finally:
            self.running -= 1
