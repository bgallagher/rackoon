"""Updates, reboot and the sudo password sheet (stage W6), like the Mac's Updates screen and `RebootFlow`.

The update list is read from apt's own cache when the page opens and after each action (`updates`, read-only, never
`apt-get update` by itself). Refresh Lists / Install All / Install Security Updates are proposed and streamed like the
Docker actions. When sudo wants a password, the run says so (`needsPassword`); the page asks for it and proposes the
password variant (the spec's `sudo_prompt` in front of the unchanged script, a fresh nonce per attempt, its own
intent), which the user confirms again. The password reaches the server only on the pty at sudo's one nonce prompt,
or on `sudo -S`'s standard input for the reboot; it is never in a command, a log or the confirm sheet, and is not
kept after the run.

Reboot: the plain one uses `sudo -n` (or root); `noSudo` makes the page ask for the password and propose
`reboot_sudo`. Once scheduled, `RebootWatch` polls the kernel boot id every 4 s until it differs from the one read
before (the old system answers for a moment) or 10 minutes pass. Rackoon never decides a reboot is needed: the notice
is the server's own /var/run/reboot-required flag.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, Literal

from fastapi import Depends, FastAPI, Request
from pydantic import Field

from rackoon.core import apt, reboot, sudo, updates
from rackoon.core.apt import AptAction
from rackoon.core.jsonmodel import to_json
from rackoon.core.models import Server
from rackoon.core.policy import Confirmation, Intent, PolicyError
from rackoon.core.stream import StreamedRun, strip_ansi
from rackoon.core.updates import UpdatesSnapshot
from rackoon.ssh import SSHError

from .actions import ActionError
from .connections import Transport, TrustError
from .errors import ApiError, Body
from .runs import Run, RunFailed, stream_command

if TYPE_CHECKING:
    from .api import Rackoon

log = logging.getLogger("rackoon.updates")

SCOPE = "updates"


class AptIn(Body):
    action: Literal["refresh", "upgradeAll", "security"]
    cols: int = Field(default=120, ge=20, le=400)
    rows: int = Field(default=32, ge=5, le=200)
    password: str | None = Field(default=None, min_length=1, max_length=1024)


class RebootIn(Body):
    password: str | None = Field(default=None, min_length=1, max_length=1024)


@dataclass
class UpdatesEntry:
    snapshot: UpdatesSnapshot | None = None
    error: str | None = None
    not_installed: bool = False
    updated_at: float | None = None


@dataclass
class RebootState:
    phase: str
    """waiting, back or timedOut."""
    previous: str
    started: float
    elapsed: float | None = None
    task: asyncio.Task[None] | None = None

    def json(self) -> dict[str, Any]:
        return {"phase": self.phase, "started": self.started, "elapsed": self.elapsed}


class RebootWatch:
    """Waits for rebooted servers to come back with a new boot id."""

    def __init__(self, transport_for: Callable[[str], Transport | None], on_back: Callable[[str], Awaitable[None]],
                 clock: Callable[[], float] = time.time, interval: float = 4.0, timeout: float = 600.0) -> None:
        self.transport_for = transport_for
        self.on_back = on_back
        self.clock = clock
        self.interval = interval
        self.timeout = timeout
        self.states: dict[str, RebootState] = {}

    def start(self, server_id: str, previous_boot_id: str) -> RebootState:
        self.forget(server_id)
        state = RebootState("waiting", previous_boot_id, self.clock())
        self.states[server_id] = state
        state.task = asyncio.create_task(self._watch(server_id, state))
        return state

    def forget(self, server_id: str) -> None:
        old = self.states.pop(server_id, None)
        if old is not None and old.task is not None:
            old.task.cancel()

    def json(self, server_id: str) -> dict[str, Any] | None:
        s = self.states.get(server_id)
        return s.json() if s else None

    async def stop(self) -> None:
        tasks = [s.task for s in self.states.values() if s.task is not None]
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

    async def _watch(self, server_id: str, state: RebootState) -> None:
        # The old system is still up for a moment: don't even ask until the reboot has had a chance to begin.
        await asyncio.sleep(min(self.interval, 3.0))
        while self.clock() - state.started < self.timeout:
            t = self.transport_for(server_id)
            if t is not None:
                try:
                    r = await t.run(reboot.boot_id_command(), 10)
                    if reboot.is_back(state.previous, r.exit_code, r.stdout):
                        state.phase, state.elapsed = "back", self.clock() - state.started
                        with contextlib.suppress(Exception):
                            await self.on_back(server_id)
                        return
                except (SSHError, TrustError, OSError):
                    pass  # expected while it is down
            await asyncio.sleep(self.interval)
        state.phase = "timedOut"


def register(app: FastAPI, rackoon: Rackoon, authenticated: Callable[[Request], str],
             find: Callable[[list[Server], str], Server]) -> None:
    Auth = Depends(authenticated)
    store = rackoon.store
    runs = rackoon.runs
    policy = rackoon.preferences.policy
    entries: dict[str, UpdatesEntry] = {}

    def server_of(server_id: str) -> Server:
        return find(store.load_servers(), server_id)

    def transport(server: Server) -> Transport:
        try:
            return rackoon.connections.transport(server)
        except TrustError as e:
            raise ApiError(e.status, e.code, str(e)) from None

    def target(server: Server) -> str:
        return f"{server.user or 'root'}@{server.host}"

    async def read(server: Server) -> UpdatesEntry:
        e = entries.setdefault(server.id, UpdatesEntry())
        try:
            r = await transport(server).run(updates.command(), 30)
            if r.exit_code != 0:  # the script ends with a test that always succeeds: ssh itself failed
                raise SSHError(r.stderr.strip() or f"ssh exited {r.exit_code}")
            e.snapshot, e.error, e.not_installed, e.updated_at = updates.parse(r.stdout), None, False, rackoon.clock()
        except updates.AptNotInstalled as x:
            e.error, e.not_installed = str(x), True
        except (SSHError, updates.UpdatesParseError) as x:
            e.error = str(x)
        return e

    def entry_json(server: Server, e: UpdatesEntry) -> dict[str, Any]:
        s = e.snapshot
        now = int(rackoon.clock())
        read_only = rackoon.preferences.read_only
        latest = runs.latest(server.id, SCOPE)
        return {
            "serverId": server.id,
            "status": "ready" if s else "notInstalled" if e.not_installed else "failed" if e.error else "loading",
            "error": e.error, "updatedAt": e.updated_at, "readOnly": read_only,
            "packages": [to_json(p) for p in apt.sorted_packages(s.packages)] if s else [],
            "held": s.held if s else [], "refreshedAt": s.refreshed_at if s else None,
            "rebootRequired": s.reboot_required if s else False,
            "securityCount": s.security_count if s else 0,
            "subtitle": apt.subtitle(s) if s else None,
            "refreshedText": apt.refreshed_text(s, now) if s else None,
            "staleness": apt.staleness(s, now) if s else None,
            "securityHint": apt.install_security_hint(s.packages, read_only) if s else "Reading the update list…",
            "run": latest.json() if latest else None,
            "reboot": rackoon.reboots.json(server.id),
        }

    @app.get("/api/servers/{server_id}/updates")
    async def get_updates(server_id: str, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        return entry_json(server, await read(server))

    def propose(intent: Intent, run: Callable[[Confirmation], Awaitable[Any]], **sheet: Any) -> dict[str, Any]:
        try:
            return {"pending": rackoon.actions.propose(intent, run, **sheet).json()}
        except ActionError as e:
            raise ApiError(e.status, e.code, str(e)) from None

    @app.post("/api/servers/{server_id}/updates/action")
    async def apt_action(server_id: str, body: AptIn, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        if rackoon.preferences.read_only:
            raise ApiError(409, "readOnly", "Read-only mode is on. Turn it off to install updates.")
        if runs.running_on(server_id) is not None:
            raise ApiError(409, "busy", "Another action is running on this server. Wait for it to finish.")
        e = await read(server)
        s = e.snapshot
        if body.action == "security":
            if s is None or not apt.can_install_security(s.packages):
                raise ApiError(409, "blocked", apt.install_security_hint(s.packages if s else [], False) or
                               "No security updates")
            action = AptAction("upgrade", tuple(apt.security_names(s.packages)))
        else:
            action = AptAction("refresh" if body.action == "refresh" else "upgrade_all")
        credential = sudo.SudoCredential(body.password, sudo.make_nonce()) if body.password else None
        intent = action.password_intent(credential.nonce) if credential else action.intent
        if intent is None:
            raise ApiError(422, "invalid", "Refusing to run apt: invalid package name.")
        p = apt.prompt(action, len(s.packages) if s else 0, s.security_count if s else 0)

        def explain(result: StreamedRun) -> str | None:
            if result.exit_code is None:
                return None
            return apt.explain(strip_ansi(result.text), "", result.exit_code)

        async def after(run: Run) -> None:
            await read(server)
            await rackoon.monitor.refresh(server.id)  # the Overview's update counts and reboot flag

        async def confirmed(confirmation: Confirmation) -> dict[str, Any]:
            async def steps(run: Run) -> StreamedRun:
                try:
                    policy.authorize(intent, confirmation)
                except PolicyError as x:
                    raise RunFailed(str(x)) from None
                return await stream_command(run, transport(server), intent.command, credential)
            try:
                run = runs.start(server.id, SCOPE, p.output_title, p.working, body.cols, body.rows, steps, after,
                                 explain)
            except RuntimeError as x:
                raise ApiError(409, "busy", str(x)) from None
            return {"run": run.json()}

        return propose(intent, confirmed, title=p.title, destructive=False, target=target(server),
                       message=p.message + (" The sudo password is typed at sudo's own prompt only, and is not kept."
                                            if credential else ""))

    # --- reboot

    @app.post("/api/servers/{server_id}/reboot")
    async def request_reboot(server_id: str, body: RebootIn, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        if rackoon.preferences.read_only:
            raise ApiError(409, "readOnly", "Read-only mode is on. Turn it off to reboot.")
        password = body.password
        intent = reboot.sudo_intent() if password else reboot.intent()
        t = transport(server)

        async def confirmed(confirmation: Confirmation) -> dict[str, Any]:
            try:
                policy.authorize(intent, confirmation)
            except PolicyError as x:
                raise ApiError(409, "readOnly", str(x)) from None
            try:
                before = await t.run(reboot.boot_id_command(), 10)
                previous = before.stdout.strip()
                if before.exit_code != 0 or not previous:
                    return {"outcome": "failed", "message": "Could not read the server's boot id first: "
                            + before.stderr.strip()}
                if password:
                    r = await t.run(intent.command, 20, input=password + "\n")
                    failure = reboot.sudo_outcome_of(r.exit_code, r.stdout, r.stderr)
                else:
                    r = await t.run(intent.command, 15)
                    failure = reboot.outcome_of(r.exit_code, r.stdout, r.stderr)
            except SSHError as x:
                return {"outcome": "failed", "message": str(x)}
            if failure is not None:
                kinds = {"no_sudo": "noSudo", "bad_password": "badPassword", "sudo_refused": "sudoRefused"}
                return {"outcome": kinds.get(failure.kind, "failed"), "message": failure.message}
            rackoon.reboots.start(server.id, previous)
            return {"outcome": "rebooting"}

        return propose(intent, confirmed, destructive=True, title=f"Reboot {server.name}?", target=target(server),
                       message="The server restarts in two seconds. Everything on it stops until it is back, usually "
                       "a minute or two; Rackoon waits for it." +
                       (" The sudo password goes to sudo's standard input only, and is not kept." if password else ""))

    @app.post("/api/servers/{server_id}/reboot/dismiss")
    async def dismiss_reboot(server_id: str, _: str = Auth) -> dict[str, Any]:
        server_of(server_id)
        state = rackoon.reboots.states.get(server_id)
        if state is not None and state.phase != "waiting":
            rackoon.reboots.forget(server_id)
        return {"reboot": rackoon.reboots.json(server_id)}
