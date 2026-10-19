"""Docker per server, like `DockerSession` + `DockerModel` on the Mac: `docker ps -a` + `docker stats` every 10 s, but
only while a browser shows a Docker page of that server (`docker stats` takes seconds, so nothing polls it in the
background). A failed poll keeps the last stacks and sets `error`.

It also remembers what `docker ps` can't show: a stack that was just created but has no containers yet (shown "Not
started" until it appears) and a stack being deleted (kept on screen while its run streams). Everything the screens
show is worked out here from the core's rules, so the browser only lays it out.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

from rackoon.core import action_prompts, docker, docker_view, stack_actions
from rackoon.core.docker import DockerContainer, DockerSnapshot, DockerStack
from rackoon.core.jsonmodel import to_json
from rackoon.core.models import Server
from rackoon.core.overview import Overview
from rackoon.core.stack_files import editable
from rackoon.ssh import SSHError

from .connections import Connections, TrustError

log = logging.getLogger("rackoon.docker")

INTERVAL = 10.0
WATCH_SECONDS = 25.0
TIMEOUT = 30.0


@dataclass
class DockerEntry:
    server: Server
    snapshot: DockerSnapshot | None = None
    error: str | None = None
    problem: str | None = None
    """notInstalled, permission, daemon, malformed or connection."""
    updated_at: float | None = None
    watched_until: float = 0.0
    last_poll: float = 0.0
    created: dict[str, DockerStack] = field(default_factory=dict)
    removing: dict[str, DockerStack] = field(default_factory=dict)
    wake: asyncio.Event = field(default_factory=asyncio.Event)
    polled: asyncio.Event = field(default_factory=asyncio.Event)
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    task: asyncio.Task[None] | None = None

    @property
    def stacks(self) -> list[DockerStack]:
        live = self.snapshot.stacks if self.snapshot else []
        ids = {s.id for s in live}
        extra = [s for k, s in {**self.created, **self.removing}.items() if k not in ids]
        return sorted(live + extra, key=lambda s: (s.name.casefold(), s.is_standalone))

    def stack(self, stack_id: str) -> DockerStack | None:
        return next((s for s in self.stacks if s.id == stack_id), None)

    @property
    def containers(self) -> list[DockerContainer]:
        return self.snapshot.containers if self.snapshot else []


class DockerHub:
    def __init__(self, connections: Connections, clock: Callable[[], float] = time.time) -> None:
        self.connections = connections
        self.clock = clock
        self.entries: dict[str, DockerEntry] = {}
        self.running = True

    def entry(self, server: Server) -> DockerEntry:
        e = self.entries.get(server.id)
        if e is None or not e.server.connects_like(server):
            if e is not None:
                self.forget(server.id)
            e = self.entries[server.id] = DockerEntry(server)
        e.server = server
        return e

    def forget(self, server_id: str) -> None:
        e = self.entries.pop(server_id, None)
        if e is not None and e.task is not None:
            e.task.cancel()

    async def stop(self) -> None:
        self.running = False
        tasks = [e.task for e in self.entries.values() if e.task is not None]
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

    # --- polling while watched

    def watch(self, server: Server) -> DockerEntry:
        """A Docker page of this server is showing: poll it for a while. Starts the loop if it had stopped."""
        e = self.entry(server)
        e.watched_until = self.clock() + WATCH_SECONDS
        if self.running and (e.task is None or e.task.done()):
            e.polled.clear()
            e.task = asyncio.create_task(self._loop(e))
        return e

    async def settle(self, e: DockerEntry, seconds: float) -> None:
        """Waits briefly for the first reading, so an opened page starts with stacks rather than a spinner."""
        if e.snapshot is None and e.error is None:
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(e.polled.wait(), seconds)

    async def refresh(self, server: Server) -> DockerEntry:
        e = self.entry(server)
        await self.poll(e)
        return e

    def poke(self, server_id: str) -> None:
        """Poll soon (after an action finished)."""
        e = self.entries.get(server_id)
        if e is not None:
            e.wake.set()

    async def _loop(self, e: DockerEntry) -> None:
        while e.watched_until > self.clock():
            try:
                await self.poll(e)
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 - one bad poll must not end the loop
                log.exception("docker poll of %s failed", e.server.name)
            e.wake.clear()
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(e.wake.wait(), INTERVAL)

    async def poll(self, e: DockerEntry) -> None:
        async with e.lock:
            e.last_poll = self.clock()
            try:
                result = await self.connections.transport(e.server).run(docker.command(), timeout=TIMEOUT)
                if result.exit_code != 0:
                    raise SSHError(result.stderr.strip() or f"Command failed (exit {result.exit_code})")
                snapshot = docker.parse(result.stdout)
            except docker.NotInstalled as x:
                e.snapshot, e.error, e.problem = None, str(x), "notInstalled"
            except docker.Daemon as x:
                e.error = x.text
                e.problem = "permission" if docker.is_permission_problem(x.text) else "daemon"
                e.snapshot = None if e.problem == "permission" else e.snapshot
            except docker.DockerMalformed as x:
                e.error, e.problem = str(x), "malformed"
            except (SSHError, TrustError) as x:
                e.error, e.problem = str(x), "connection"
            else:
                e.snapshot, e.error, e.problem, e.updated_at = snapshot, None, None, self.clock()
                live = {s.id for s in snapshot.stacks}
                for k in [k for k in e.created if k in live]:
                    del e.created[k]
            finally:
                e.polled.set()


# --- what the screens show ------------------------------------------------------------------------------------------


def link_host(o: Overview | None) -> str | None:
    """Where a stack's web port is opened: the Tailscale address when there is one, else the LAN one."""
    if o is None:
        return None
    return o.tailscale_ip or o.ip_address


def container_json(c: DockerContainer, stack: DockerStack) -> dict[str, Any]:
    image, tag = docker_view.image_name(c.image)
    out: dict[str, Any] = to_json(c)
    out.update(imageName=image, imageTag=tag, isRunning=c.is_running, isUnhealthy=c.is_unhealthy,
               canRebuild=action_prompts.can_rebuild(c, stack), letter=docker_view.letter(c.service or c.name),
               hue=docker_view.hue(c.service or c.name))
    return out


def stack_json(s: DockerStack, e: DockerEntry, host: Overview | None, read_only: bool, running: Any,
               detail: bool = False) -> dict[str, Any]:
    """`running` is the run in progress on this server (any stack), or None."""
    text, severity = docker_view.stack_status(s)
    port = docker_view.main_web_port(s)
    where = link_host(host)
    other = running is not None
    folder = stack_actions.folder_problem(s) if not s.is_standalone else None
    out: dict[str, Any] = {
        "id": s.id, "name": s.name, "kind": s.kind_label, "isStandalone": s.is_standalone,
        "workingDir": s.working_dir, "configFiles": s.config_files or ([s.config_file] if s.config_file else []),
        "statusText": text, "severity": severity.value, "running": s.running_count, "stopped": s.stopped_count,
        "unhealthy": s.unhealthy_count, "total": len(s.containers), "hasBookmark": s.has_bookmark,
        "mainWebPort": port, "link": f"http://{where}:{port}" if port and where else None,
        "letter": docker_view.letter(s.name), "hue": docker_view.hue(s.name),
        "images": sorted({docker_view.image_name(c.image)[0] for c in s.containers}),
        "cpuPercent": sum(c.cpu_percent or 0 for c in s.containers) if any(c.cpu_percent is not None
                                                                            for c in s.containers) else None,
        "memoryBytes": sum(c.memory_used_bytes or 0 for c in s.containers),
        "notStarted": not s.containers, "removing": s.id in e.removing,
        "busy": running is not None and running.scope == s.id,
        "containers": [container_json(c, s) for c in s.containers],
    }
    if detail:
        out.update(
            composeBlocked=docker_view.compose_blocked_reason(s),
            blocked=(action_prompts.standalone_blocked_reason(s, read_only, other) if s.is_standalone
                     else action_prompts.blocked_reason(s, read_only, other)),
            pullable=stack_actions.pullable_image(s) if s.is_standalone else None,
            folderProblem=folder,
            files=[{"path": f.path, "name": f.file_name, "isEnv": f.is_env} for f in (editable(s) or [])],
            services=sorted({c.service for c in s.containers if c.service}),
        )
    return out


def matches(s: DockerStack, query: str) -> bool:
    """Every word in the stack, folder, container, service or image (the overview's search box)."""
    hay = " ".join([s.name, s.working_dir or ""] + [f"{c.name} {c.service or ''} {c.image}" for c in s.containers])
    hay = hay.casefold()
    return all(w in hay for w in query.casefold().split())


def health_of(s: DockerStack) -> str:
    """The overview's chips: running, attention (unhealthy or partly stopped) or stopped."""
    if s.unhealthy_count > 0 or (s.containers and 0 < s.stopped_count < len(s.containers)):
        return "attention"
    if not s.containers or s.running_count == 0:
        return "stopped"
    return "running"


def state_json(e: DockerEntry, host: Overview | None, read_only: bool, running: Any) -> dict[str, Any]:
    snap = e.snapshot
    status = ("ready" if snap is not None else "notInstalled" if e.problem == "notInstalled"
              else "failed" if e.error is not None else "loading")
    stacks = e.stacks
    out: dict[str, Any] = {
        "serverId": e.server.id, "status": status, "error": e.error, "problem": e.problem,
        "updatedAt": e.updated_at, "summary": docker_view.summary(snap) if snap else None,
        "totals": to_json(docker_view.totals(snap, host)) if snap else None,
        "stacks": [{**stack_json(s, e, host, read_only, running), "health": health_of(s)} for s in stacks],
        "running": running.json() if running is not None else None,
        "readOnly": read_only,
    }
    return out
