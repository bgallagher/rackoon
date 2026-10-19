"""Polling every saved server, like `ServerSession` + `FleetMonitor` on the Mac: one task per server runs the
`overview` command every 5 s while a browser is watching that server's Overview, and once a minute otherwise. A failed
poll keeps the last good reading and sets `error`; CPU % comes from two readings; the cached snapshot from an earlier
run is shown (stale) until the first poll answers. A server whose host key is unknown or changed is not polled again
until the key is trusted or the user asks.
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Callable
from datetime import UTC, datetime
from dataclasses import dataclass, field
from typing import Any

from rackoon.core import attention, connection_failure, overview, unraid_view
from rackoon.core.models import AttentionItem
from rackoon.core.fleet import FleetTotals, HealthHistory, HealthSample, ServerState
from rackoon.core.jsonmodel import to_json
from rackoon.core.models import Server
from rackoon.core.unraid import UnraidSnapshot, is_unraid
from rackoon.ssh import AuthFailed, HostKeyChanged, HostKeyUnknown, SSHError

from .connections import Connections, TrustError, key_id_of
from .storage import DataStore

log = logging.getLogger("rackoon.monitor")

WATCHED_INTERVAL = 5.0
BACKGROUND_INTERVAL = 60.0
WATCH_SECONDS = 20.0
SNAPSHOT_EVERY = 60.0
POLL_TIMEOUT = 15.0


@dataclass
class Entry:
    server: Server
    state: ServerState = field(default_factory=ServerState)
    connection: str = "connecting"
    """ok, connecting, hostKeyUnknown, hostKeyChanged, authFailed, unreachable, failed."""
    previous: overview.Overview | None = None
    history: HealthHistory = field(default_factory=HealthHistory)
    watched_until: float = 0.0
    last_poll: float = 0.0
    last_snapshot: float = 0.0
    wake: asyncio.Event = field(default_factory=asyncio.Event)
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    polled: asyncio.Event = field(default_factory=asyncio.Event)
    task: asyncio.Task[None] | None = None


class Monitor:
    def __init__(self, store: DataStore, connections: Connections, clock: Callable[[], float] = time.time) -> None:
        self.store = store
        self.connections = connections
        self.clock = clock
        self.entries: dict[str, Entry] = {}
        self.running = False
        self.nas_for: Callable[[str], UnraidSnapshot | None] | None = None

    # --- lifecycle

    def _entry(self, server: Server) -> Entry:
        entry = Entry(server)
        cached = self.store.load_snapshot(server.id)
        if cached is not None:
            entry.state = ServerState(overview=cached.overview, attention=attention.evaluate(cached.overview),
                                      updated_at=_parse_time(cached.saved_at), is_stale=True)
        return entry

    def sync(self, servers: list[Server]) -> None:
        """Follows the saved list: new servers start polling, removed ones stop, a changed connection starts over."""
        wanted = {s.id: s for s in servers}
        for server_id in list(self.entries):
            if server_id not in wanted:
                self._stop(server_id)
        for server in servers:
            entry = self.entries.get(server.id)
            if entry is not None and not entry.server.connects_like(server):
                self._stop(server.id)
                entry = None
            if entry is None:
                entry = self.entries[server.id] = self._entry(server)
                if self.running:
                    entry.task = asyncio.create_task(self._loop(entry))
            else:
                entry.server = server

    def start(self) -> None:
        self.running = True
        for entry in self.entries.values():
            if entry.task is None:
                entry.task = asyncio.create_task(self._loop(entry))

    async def stop(self) -> None:
        self.running = False
        tasks = [e.task for e in self.entries.values() if e.task is not None]
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

    def _stop(self, server_id: str) -> None:
        entry = self.entries.pop(server_id, None)
        if entry is not None and entry.task is not None:
            entry.task.cancel()

    # --- polling

    def watch(self, server_id: str) -> bool:
        """A browser shows this server's Overview: poll it every few seconds for a while. True when that woke a
        poll (the reading is older than the watched interval)."""
        entry = self.entries.get(server_id)
        if entry is None:
            return False
        was_watched = entry.watched_until > self.clock()
        entry.watched_until = self.clock() + WATCH_SECONDS
        if not was_watched and self.clock() - entry.last_poll > WATCHED_INTERVAL and self.running:
            entry.polled.clear()
            entry.wake.set()
            return True
        return False

    async def settle(self, server_id: str, seconds: float) -> None:
        """Waits (briefly) for the poll a `watch` woke, so a newly opened Overview starts with a fresh reading."""
        entry = self.entries.get(server_id)
        if entry is not None:
            try:
                await asyncio.wait_for(entry.polled.wait(), seconds)
            except TimeoutError:
                pass

    async def refresh(self, server_id: str) -> None:
        """Poll now (also after a host key was trusted or a connection was edited)."""
        entry = self.entries.get(server_id)
        if entry is not None:
            await self.poll(entry)
            entry.wake.set()

    async def _loop(self, entry: Entry) -> None:
        while True:
            try:
                await self.poll(entry)
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 - one bad poll must not end the loop
                log.exception("poll of %s failed", entry.server.name)
            entry.wake.clear()
            blocked = entry.connection in ("hostKeyUnknown", "hostKeyChanged")
            interval = WATCHED_INTERVAL if entry.watched_until > self.clock() else BACKGROUND_INTERVAL
            try:
                if blocked:
                    await entry.wake.wait()
                else:
                    await asyncio.wait_for(entry.wake.wait(), interval)
            except TimeoutError:
                pass

    async def poll(self, entry: Entry) -> None:
        async with entry.lock:
            entry.last_poll = self.clock()
            state = entry.state
            try:
                transport = self.connections.transport(entry.server)
                result = await transport.run(overview.command(), timeout=POLL_TIMEOUT)
                if result.exit_code != 0:
                    raise SSHError(result.stderr.strip() or f"Command failed (exit {result.exit_code})")
                reading = overview.parse(result.stdout)
            except (SSHError, TrustError, overview.ParseError) as e:
                if isinstance(e, (HostKeyUnknown, HostKeyChanged, AuthFailed)) or not isinstance(e, SSHError):
                    await self.connections.forget(entry.server.id)
                entry.connection = _connection_of(e)
                state.error = str(e)
            else:
                cpu = reading.cpu_percent(entry.previous) if entry.previous is not None else None
                state.overview = reading
                state.cpu_percent = cpu if cpu is not None else state.cpu_percent
                state.attention = attention.evaluate(reading)
                state.error = None
                state.updated_at = self.clock()
                state.is_stale = False
                entry.previous = reading
                entry.connection = "ok"
                if self.clock() - entry.last_snapshot >= SNAPSHOT_EVERY:
                    entry.last_snapshot = self.clock()
                    self.store.save_snapshot(entry.server.id, reading)
            sample = HealthSample.of(state, self.clock())
            if sample is not None:
                entry.history.record(sample)
            entry.polled.set()

    # --- what the API returns

    def attention_of(self, server_id: str) -> list[AttentionItem]:
        """The Overview's items; on Unraid, `df`'s disk items give way to the NAS rules (once the NAS was read)."""
        entry = self.entries.get(server_id)
        if entry is None:
            return []
        o = entry.state.overview
        if o is None or not is_unraid(o.os):
            return entry.state.attention
        return unraid_view.merge(entry.state.attention, True, self.nas_for(server_id) if self.nas_for else None)

    def state_json(self, server_id: str) -> dict[str, Any] | None:
        entry = self.entries.get(server_id)
        if entry is None:
            return None
        s = entry.state
        failure = None
        if s.error:
            sign_in = (connection_failure.SignIn.KEY if key_id_of(entry.server, self.store.keys_dir)
                       else connection_failure.SignIn.TAILSCALE)
            explained = connection_failure.explain(s.error, sign_in)
            if explained is not None:
                failure = {"kind": explained.kind.value, "headline": explained.headline, "advice": explained.advice}
        return {
            "serverId": server_id,
            "connection": entry.connection,
            "overview": to_json(s.overview) if s.overview else None,
            "cpuPercent": s.cpu_percent,
            "attention": [{**to_json(i), "red": attention.is_red(i), "short": attention.short_message(i)}
                          for i in attention.sorted_items(self.attention_of(server_id))],
            "error": s.error,
            "failure": failure,
            "updatedAt": s.updated_at,
            "isStale": s.is_stale,
            "isUnraid": bool(s.overview and is_unraid(s.overview.os)),
            "derived": _derived(s.overview),
            "polling": "watched" if entry.watched_until > self.clock() else "background",
        }

    def fleet_json(self, servers: list[Server]) -> dict[str, Any]:
        rows = []
        states = []
        for server in servers:
            entry = self.entries.get(server.id)
            if entry is None:
                continue
            states.append(entry.state)
            o = entry.state.overview
            rows.append({
                "id": server.id, "name": server.name, "host": server.host, "connection": entry.connection,
                "error": entry.state.error, "isStale": entry.state.is_stale, "updatedAt": entry.state.updated_at,
                "cpuPercent": entry.state.cpu_percent,
                "overview": to_json(o) if o else None,
                "derived": _derived(o),
                "attentionCount": len(self.attention_of(server.id)),
                "redCount": sum(attention.is_red(i) for i in self.attention_of(server.id)),
                "history": [to_json(h) for h in entry.history.samples],
                "uptimeFraction": entry.history.uptime_fraction,
            })
        return {"totals": to_json(FleetTotals.of(states)), "servers": rows}


def _derived(o: overview.Overview | None) -> dict[str, Any] | None:
    """Numbers the screens show that are worked out from a reading, so the browser does no arithmetic on it."""
    if o is None:
        return None
    fullest = max(o.disks, key=lambda d: d.use_percent, default=None)
    return {"memoryUsedBytes": o.memory.used_bytes, "memoryUsedFraction": o.memory.used_fraction,
            "modelName": o.model_name, "fullestDisk": to_json(fullest) if fullest else None}


def _connection_of(e: Exception) -> str:
    if isinstance(e, HostKeyUnknown):
        return "hostKeyUnknown"
    if isinstance(e, HostKeyChanged):
        return "hostKeyChanged"
    if isinstance(e, AuthFailed):
        return "authFailed"
    if isinstance(e, SSHError) and connection_failure.explain(str(e)) is not None:
        return "unreachable"
    return "failed"


def _parse_time(text: str) -> float | None:
    try:
        return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC).timestamp()
    except ValueError:
        return None
