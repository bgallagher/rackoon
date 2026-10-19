"""Commands, Services and the Unraid NAS page (stage W7).

Commands: the library from spec/command-library.json. A read entry runs straight away with live output; a mutating
one runs its read-only dry run first and then the standard confirm sheet; root entries use `$S` and get the sudo
password variant when sudo wants one; interactive ones open a terminal tab (Read-only gates them like any shell). The
free-form box always asks first and is refused in Read-only mode; its history lives in the browser only. Each entry's
last output is the latest run of its own scope, so selecting another command never shows the wrong output.

Services: one read-only scan (`services`) per server, at most every 25 s while a page shows it, tied to units,
listeners and hand-started processes by the core's discovery. Show/hide per server or everywhere is saved in
`<data>/services/visibility.json`. Actions are `LibraryCommand`s (`core/service_actions.py`) run like Commands.

NAS: an Unraid server's array, pools, parity, temperatures and shares (`unraid`, read-only: it only reads what emhttp
already wrote, so no drive spins up), read while its Overview shows; the Overview's attention then uses the NAS rules.
"""

from __future__ import annotations

import json
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any

from fastapi import Depends, FastAPI, Request
from pydantic import Field

from rackoon.core import command_library, services, sudo, unraid, unraid_view
from rackoon.core.command_library import LibraryCommand
from rackoon.core.jsonmodel import to_json
from rackoon.core.models import Server
from rackoon.core.policy import Confirmation, Intent, PolicyError, Risk
from rackoon.core.service_actions import ServiceAction, ServiceVisibility
from rackoon.core import service_actions
from rackoon.core.stream import StreamedRun
from rackoon.ssh import SSHError

from .actions import ActionError
from .connections import Transport, TrustError
from .errors import ApiError, Body
from .runs import Run, RunFailed, stream_command
from .storage import write_json

if TYPE_CHECKING:
    from .api import Rackoon

SCAN_EVERY = 25.0
NAS_EVERY = 12.0


class RunIn(Body):
    id: str = Field(max_length=200)
    params: dict[str, str] = Field(default_factory=dict, max_length=10)
    cols: int = Field(default=120, ge=20, le=400)
    rows: int = Field(default=32, ge=5, le=200)
    password: str | None = Field(default=None, min_length=1, max_length=1024)


class CustomIn(Body):
    text: str = Field(min_length=1, max_length=4000)
    cols: int = Field(default=120, ge=20, le=400)
    rows: int = Field(default=32, ge=5, le=200)


class ServiceActionIn(Body):
    serviceId: str = Field(max_length=300)
    action: str = Field(max_length=20)
    cols: int = Field(default=120, ge=20, le=400)
    rows: int = Field(default=32, ge=5, le=200)
    password: str | None = Field(default=None, min_length=1, max_length=1024)


class VisibilityIn(Body):
    serverId: str = Field(max_length=64)
    serviceId: str = Field(max_length=300)
    visible: bool | None = None
    everywhere: bool = False


class FollowIn(Body):
    serviceId: str = Field(max_length=300)
    cols: int = Field(default=100, ge=1, le=1000)
    rows: int = Field(default=30, ge=1, le=1000)


def command_json(c: LibraryCommand) -> dict[str, Any]:
    return {"id": c.id, "title": c.title, "group": c.group, "summary": c.summary, "risk": c.risk.value,
            "root": c.root, "needs": c.needs, "warning": c.warning, "interactive": c.interactive,
            "params": [{"id": p.id, "label": p.label, "kind": p.kind.value, "placeholder": p.placeholder}
                       for p in c.params],
            "readable": c.readable_script(), "readablePreview": c.readable_script(c.preview) if c.preview else None,
            "full": c.full_script() if not c.params else None}


@dataclass
class Cached:
    value: Any
    at: float
    error: str | None = None


class ServicesStore:
    """Each server's last scan and the user's show/hide choices (saved on this host)."""

    def __init__(self, folder: Path, clock: Callable[[], float] = time.time) -> None:
        self.folder = folder
        self.clock = clock
        self.scans: dict[str, Cached] = {}
        try:
            raw = json.loads((folder / "visibility.json").read_text())
            self.visibility = ServiceVisibility({str(k): bool(v) for k, v in raw.items()})
        except (OSError, ValueError, AttributeError):
            self.visibility = ServiceVisibility()

    def save(self) -> None:
        self.folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        write_json(self.folder / "visibility.json", self.visibility.overrides)

    def snapshot(self, server_id: str) -> services.ServicesSnapshot | None:
        c = self.scans.get(server_id)
        return c.value if c is not None else None

    def shown(self, server_id: str) -> list[services.DiscoveredService]:
        snap = self.snapshot(server_id)
        return [s for s in snap.services if self.visibility.is_visible(s, server_id)] if snap else []

    async def scan(self, server_id: str, transport: Transport, force: bool = False) -> Cached:
        c = self.scans.get(server_id)
        if c is not None and not force and self.clock() - c.at < SCAN_EVERY:
            return c
        try:
            r = await transport.run(services.command(), 30)
            if r.exit_code != 0:
                raise SSHError(r.stderr.strip() or f"ssh exited {r.exit_code}")
            c = Cached(services.parse(r.stdout), self.clock())
        except (SSHError, TrustError, ValueError) as e:
            c = Cached(c.value if c else None, self.clock(), str(e))
        self.scans[server_id] = c
        return c

    def forget(self, server_id: str) -> None:
        self.scans.pop(server_id, None)
        if self.visibility.forget(server_id):
            self.save()


class NASStore:
    def __init__(self, clock: Callable[[], float] = time.time) -> None:
        self.clock = clock
        self.reads: dict[str, Cached] = {}

    def snapshot(self, server_id: str) -> unraid.UnraidSnapshot | None:
        c = self.reads.get(server_id)
        return c.value if c is not None else None

    async def read(self, server_id: str, transport: Transport, force: bool = False) -> Cached:
        c = self.reads.get(server_id)
        if c is not None and not force and self.clock() - c.at < NAS_EVERY:
            return c
        try:
            r = await transport.run(unraid.command(), 20)
            if r.exit_code != 0:  # the script ends in `true`: ssh itself failed
                raise SSHError(r.stderr.strip() or f"ssh exited {r.exit_code}")
            c = Cached(unraid.parse(r.stdout), self.clock())
        except unraid.NotUnraid:
            c = Cached(None, self.clock(), "This server does not look like Unraid (no /etc/unraid-version).")
        except (SSHError, TrustError, ValueError) as e:
            c = Cached(c.value if c else None, self.clock(), str(e))
        self.reads[server_id] = c
        return c


def service_json(s: services.DiscoveredService, visible: bool, chosen: bool, link_host: str | None) -> dict[str, Any]:
    out: dict[str, Any] = to_json(s)
    out.update(visible=visible, chosen=chosen, isProblem=s.is_problem,
               actions=[a.value for a in ServiceAction if s.unit and a.applies(s)
                        and service_actions.command(a, s) is not None],
               canFollow=service_actions.follow_logs_command(s) is not None,
               links=[f"http://{h}:{p.port}" for p in s.ports if p.is_likely_web and (h := p.link_host(link_host))])
    return out


def nas_json(s: unraid.UnraidSnapshot) -> dict[str, Any]:
    v = unraid_view
    total, used, free = v.array_bytes(s)
    title, level = v.condition(s)

    def device(d: unraid.Device) -> dict[str, Any]:
        out: dict[str, Any] = to_json(d)
        out.update(title=v.slot_title(d.name), model=v.model(d), statusText=v.status_description(d),
                   temperatureLevel=v.temperature_level(d), emptySlot=v.is_empty_slot(d),
                   fillLevel=v.fill_level(d.filesystem.used_bytes / d.filesystem.total_bytes)
                   if d.filesystem and d.filesystem.total_bytes else None)
        return out
    op = s.array.operation
    cpu = v.cpu_temperature(s)
    return {
        "version": s.version, "cpuModel": s.cpu_model, "condition": {"title": title, "level": level},
        "array": {**to_json(s.array), "totalBytes": total, "usedBytes": used, "freeBytes": free,
                  "fillLevel": v.fill_level(used / total) if total else None},
        "operation": {**to_json(op), "label": v.describe(op.action), "fraction": op.fraction,
                      "remainingSeconds": v.remaining_seconds(op)} if op else None,
        "parity": [device(d) for d in v.parity_disks(s)], "data": [device(d) for d in v.data_disks(s)],
        "pools": [{"name": p.name, "title": v.slot_title(p.name), "kind": p.kind, "health": p.health,
                   "filesystem": to_json(p.filesystem) if p.filesystem else None,
                   "fillLevel": v.fill_level(p.filesystem.used_bytes / p.filesystem.total_bytes)
                   if p.filesystem and p.filesystem.total_bytes else None,
                   "devices": [device(d) for d in p.devices]} for p in v.pools(s)],
        "flash": device(f) if (f := v.flash(s)) else None,
        "cpuTemperature": cpu, "cpuLevel": v.cpu_level(cpu) if cpu is not None else None,
        "sensors": [{"name": n, "celsius": c} for n, c in v.board_sensors(s)],
        "fans": [to_json(f) for f in v.spinning_fans(s)],
        "parityChecks": [{**to_json(p), "label": v.describe(p.action), "completed": p.exit_code == 0}
                         for p in reversed(s.parity_checks)],
        "shares": [{**to_json(sh), "placement": v.placement(sh)} for sh in s.shares],
    }


def register(app: FastAPI, rackoon: Rackoon, authenticated: Callable[[Request], str],
             find: Callable[[list[Server], str], Server]) -> None:
    Auth = Depends(authenticated)
    store = rackoon.store
    runs = rackoon.runs
    policy = rackoon.preferences.policy
    svc = rackoon.services
    nas = rackoon.nas

    def server_of(server_id: str) -> Server:
        return find(store.load_servers(), server_id)

    def transport(server: Server) -> Transport:
        try:
            return rackoon.connections.transport(server)
        except TrustError as e:
            raise ApiError(e.status, e.code, str(e)) from None

    def target(server: Server) -> str:
        return f"{server.user or 'root'}@{server.host}"

    def propose(intent: Intent, run: Callable[[Confirmation], Any], **sheet: Any) -> dict[str, Any]:
        try:
            return {"pending": rackoon.actions.propose(intent, run, **sheet).json()}
        except ActionError as e:
            raise ApiError(e.status, e.code, str(e)) from None

    def start(server: Server, scope: str, title: str, intent: Intent, confirmation: Confirmation, cols: int, rows: int,
              credential: sudo.SudoCredential | None) -> dict[str, Any]:
        async def steps(run: Run) -> StreamedRun:
            try:
                policy.authorize(intent, confirmation)
            except PolicyError as x:
                raise RunFailed(str(x)) from None
            return await stream_command(run, transport(server), intent.command, credential)
        try:
            run = runs.start(server.id, scope, title, f"Running {title}…", cols, rows, steps)
        except RuntimeError as x:
            raise ApiError(409, "busy", str(x)) from None
        return {"run": run.json()}

    async def dry_run(server: Server, c: LibraryCommand, params: dict[str, str]) -> str:
        script = c.full_script(c.preview, params) if c.preview else None
        if script is None:
            return ""
        try:
            r = await transport(server).run(script, 30)
        except SSHError:
            return "Could not read the preview from the server."
        return "\n".join(x for x in (r.stdout, r.stderr) if x).strip()

    async def run_library(server: Server, c: LibraryCommand, scope: str, params: dict[str, str], cols: int, rows: int,
                          password: str | None) -> dict[str, Any]:
        if c.interactive:
            script = c.full_script(params=params)
            if script is None:
                raise ApiError(422, "invalid", "Fill in what the command asks for.")
            try:
                return {"tab": rackoon.terminals.open(server, cols, rows, script, title=c.title).json()}
            except PermissionError as x:
                raise ApiError(409, "readOnly", str(x)) from None
            except OverflowError as x:
                raise ApiError(409, "tooManyTabs", str(x)) from None
        if runs.running_on(server.id) is not None:
            raise ApiError(409, "busy", "Another command is running on this server. Wait for it to finish.")
        credential = sudo.SudoCredential(password, sudo.make_nonce()) if password else None
        intent = c.password_intent(credential.nonce, params) if credential else c.intent(params)
        if intent is None:
            raise ApiError(422, "invalid", "Fill in what the command asks for (a valid name)." if c.params else
                           "This command has no sudo variant.")
        if c.risk is Risk.READ:
            return start(server, scope, c.title, intent, policy.confirm(intent), cols, rows, credential)
        details = await dry_run(server, c, params)

        async def confirmed(confirmation: Confirmation) -> dict[str, Any]:
            return start(server, scope, c.title, intent, confirmation, cols, rows, credential)
        return propose(intent, confirmed, title=f"{c.title}?", target=target(server), destructive=c.warning is not None,
                       message=" ".join(x for x in (c.summary, c.warning) if x), details=details or None)

    # --- commands

    @app.get("/api/commands")
    async def library(_: str = Auth) -> dict[str, Any]:
        return {"groups": command_library.groups(), "commands": [command_json(c) for c in command_library.all_commands()]}

    @app.post("/api/servers/{server_id}/commands/run")
    async def run_command(server_id: str, body: RunIn, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        c = next((c for c in command_library.all_commands() if c.id == body.id), None)
        if c is None:
            raise ApiError(404, "noSuchCommand", "There is no such command.")
        return await run_library(server, c, f"command:{c.id}", body.params, body.cols, body.rows, body.password)

    @app.post("/api/servers/{server_id}/commands/custom")
    async def run_custom(server_id: str, body: CustomIn, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        intent = command_library.custom_intent(body.text)
        if intent is None:
            raise ApiError(422, "invalid", "Type a command.")
        if runs.running_on(server.id) is not None:
            raise ApiError(409, "busy", "Another command is running on this server. Wait for it to finish.")

        async def confirmed(confirmation: Confirmation) -> dict[str, Any]:
            return start(server, "command:custom", body.text.strip()[:80], intent, confirmation, body.cols, body.rows,
                         None)
        return propose(intent, confirmed, title="Run this command?", target=target(server),
                       message="Anything typed by hand can't be checked, so it always asks. It runs as typed.")

    # --- services

    def link_host(server: Server) -> str | None:
        m = rackoon.monitor.entries.get(server.id)
        o = m.state.overview if m else None
        return (o.tailscale_ip or o.ip_address) if o else None

    @app.get("/api/servers/{server_id}/services")
    async def list_services(server_id: str, refresh: bool = False, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        c = await svc.scan(server.id, transport(server), refresh)
        snap: services.ServicesSnapshot | None = c.value
        host = link_host(server)
        rows = [service_json(s, svc.visibility.is_visible(s, server.id), svc.visibility.is_chosen(s, server.id), host)
                for s in snap.services] if snap else []
        return {"serverId": server.id, "status": "ready" if snap else "failed" if c.error else "loading",
                "error": c.error, "updatedAt": c.at, "isRoot": snap.is_root if snap else None,
                "hasSystemd": snap.has_systemd if snap else None, "services": rows,
                "runs": {r.scope: r.json() for r in runs.for_server(server.id) if r.scope.startswith("service:")}}

    @app.put("/api/services/visibility")
    async def set_visibility(body: VisibilityIn, _: str = Auth) -> dict[str, Any]:
        server_of(body.serverId)
        svc.visibility.set(body.visible, body.serviceId, body.serverId, body.everywhere)
        svc.save()
        return {"ok": True}

    def service_of(server: Server, service_id: str) -> services.DiscoveredService:
        snap = svc.snapshot(server.id)
        s: services.DiscoveredService | None = (next((x for x in snap.services if x.id == service_id), None)
                                                 if snap else None)
        if s is None:
            raise ApiError(404, "noSuchService", "That service is gone. Refresh the list.")
        return s

    @app.post("/api/servers/{server_id}/services/action")
    async def service_action(server_id: str, body: ServiceActionIn, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        s = service_of(server, body.serviceId)
        try:
            action = ServiceAction(body.action)
        except ValueError:
            raise ApiError(422, "invalid", "There is no such action.") from None
        c = service_actions.command(action, s) if action.applies(s) else None
        if c is None:
            raise ApiError(422, "invalid", "That can't be done to this service.")
        return await run_library(server, c, f"service:{s.id}", {}, body.cols, body.rows, body.password)

    @app.post("/api/servers/{server_id}/services/follow", status_code=201)
    async def follow_service(server_id: str, body: FollowIn, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        command = service_actions.follow_logs_command(service_of(server, body.serviceId))
        if command is None:
            raise ApiError(422, "invalid", "This one has no journal to follow.")
        try:
            return rackoon.terminals.open(server, body.cols, body.rows, command, title="journal").json()
        except PermissionError as x:
            raise ApiError(409, "readOnly", str(x)) from None
        except OverflowError as x:
            raise ApiError(409, "tooManyTabs", str(x)) from None

    # --- the NAS page

    @app.get("/api/servers/{server_id}/nas")
    async def nas_page(server_id: str, refresh: bool = False, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        c = await nas.read(server.id, transport(server), refresh)
        return {"serverId": server.id, "status": "ready" if c.value else "failed" if c.error else "loading",
                "error": c.error, "updatedAt": c.at, "nas": nas_json(c.value) if c.value else None}
