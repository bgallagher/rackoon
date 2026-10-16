"""Terminal tabs: an SSH shell per tab, kept by the backend so it survives switching screens, servers and reloading
the page (like the Mac's TerminalStore), until the tab is closed, the server is removed or its connection edited.

Each tab owns a pty shell, the output filter (highlighting, switchable live), a scrollback buffer replayed to a
browser that attaches, and the reconnect policy: only a lost connection is retried (1/2/4/8/15 s, a fresh budget
after 10 s connected); a shell that exits, a refused login or a host-key problem is final. Browsers attach over a
WebSocket: binary frames are terminal bytes both ways, text frames JSON control (resize from the browser; state from
here). While Read-only is on, new tabs can't be opened and keystrokes are refused (output keeps flowing), because a
shell can change anything, as on Android.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import secrets
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any, Protocol

from rackoon.core.models import Server
from rackoon.core.terminal import ReconnectPolicy, SessionEnd, TerminalOutputFilter
from rackoon.ssh import AuthFailed, HostKeyChanged, HostKeyUnknown, SSHError

log = logging.getLogger("rackoon.terminals")

SCROLLBACK_BYTES = 512 * 1024
MAX_TABS_PER_SERVER = 10
MAX_TABS = 50
TITLE_MAX = 40
DEFAULT_TITLE = "Shell"
CLIENT_QUEUE = 256


class Shell(Protocol):
    async def read(self) -> bytes: ...

    def write(self, data: bytes) -> None: ...

    def resize(self, cols: int, rows: int) -> None: ...

    @property
    def exit_status(self) -> int | None: ...

    async def close(self) -> None: ...


class Client:
    """One attached browser: frames queue here and a writer task sends them."""

    def __init__(self) -> None:
        self.queue: asyncio.Queue[bytes | str | None] = asyncio.Queue(CLIENT_QUEUE)

    def send(self, frame: bytes | str) -> bool:
        try:
            self.queue.put_nowait(frame)
            return True
        except asyncio.QueueFull:
            return False  # a browser that can't keep up is dropped; it reattaches and gets the replay

    def close(self) -> None:
        with contextlib.suppress(asyncio.QueueFull):
            self.queue.put_nowait(None)


def dim(text: str) -> bytes:
    return f"\r\n\x1b[2m[{text}]\x1b[0m\r\n".encode()


@dataclass
class TerminalTab:
    id: str
    server: Server
    title: str
    created: float
    cols: int = 80
    rows: int = 24
    state: str = "starting"
    """starting, connected, reconnecting, disconnected, exited."""
    detail: dict[str, Any] = field(default_factory=dict)
    buffer: bytearray = field(default_factory=bytearray)
    filter: TerminalOutputFilter = field(default_factory=TerminalOutputFilter)
    policy: ReconnectPolicy = field(default_factory=ReconnectPolicy)
    clients: set[Client] = field(default_factory=set)
    shell: Shell | None = None
    task: asyncio.Task[None] | None = None
    wake: asyncio.Event = field(default_factory=asyncio.Event)
    closing: bool = False

    def json(self) -> dict[str, Any]:
        return {"id": self.id, "serverId": self.server.id, "title": self.title, "state": self.state, **self.detail}

    def emit(self, data: bytes) -> None:
        if not data:
            return
        self.buffer += data
        if len(self.buffer) > SCROLLBACK_BYTES:
            del self.buffer[: len(self.buffer) - SCROLLBACK_BYTES]
        for c in list(self.clients):
            if not c.send(data):
                self.clients.discard(c)
                c.close()

    def set_state(self, state: str, **detail: Any) -> None:
        self.state = state
        self.detail = detail
        message = json.dumps({"type": "state", **self.json()})
        for c in list(self.clients):
            c.send(message)


class TerminalManager:
    def __init__(self, opener: Callable[[Server, int, int], Any], read_only: Callable[[], bool],
                 touch: Callable[[], None], highlight: Callable[[], bool], clock: Callable[[], float] = time.monotonic,
                 delays: tuple[float, ...] = (1, 2, 4, 8, 15)) -> None:
        self.delays = delays
        self.opener = opener
        self.read_only = read_only
        self.touch = touch
        self.highlight = highlight
        self.clock = clock
        self.tabs: dict[str, TerminalTab] = {}

    # --- tabs

    def for_server(self, server_id: str) -> list[TerminalTab]:
        return sorted((t for t in self.tabs.values() if t.server.id == server_id), key=lambda t: t.created)

    def open(self, server: Server, cols: int, rows: int) -> TerminalTab:
        if self.read_only():
            raise PermissionError("Read-only is on. A shell can change anything on the server, so turn Read-only off to "
                                  "open a session.")
        if len(self.for_server(server.id)) >= MAX_TABS_PER_SERVER or len(self.tabs) >= MAX_TABS:
            raise OverflowError("Too many terminal tabs are open. Close one first.")
        tab = TerminalTab(secrets.token_urlsafe(12), server, DEFAULT_TITLE, self.clock(), _clamp(cols, 20, 500),
                          _clamp(rows, 5, 300), filter=TerminalOutputFilter(self.highlight()),
                          policy=ReconnectPolicy(self.delays))
        self.tabs[tab.id] = tab
        tab.task = asyncio.create_task(self._run(tab))
        return tab

    def rename(self, tab_id: str, title: str) -> TerminalTab:
        tab = self.tabs[tab_id]
        clean = " ".join(title.split())[:TITLE_MAX]
        tab.title = clean or DEFAULT_TITLE
        tab.set_state(tab.state, **tab.detail)
        return tab

    async def close(self, tab_id: str) -> bool:
        tab = self.tabs.pop(tab_id, None)
        if tab is None:
            return False
        tab.closing = True
        tab.wake.set()
        if tab.shell is not None:
            with contextlib.suppress(Exception):
                await tab.shell.close()
        if tab.task is not None:
            tab.task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await tab.task
        for c in tab.clients:
            c.close()
        return True

    async def close_server(self, server_id: str) -> None:
        for tab in self.for_server(server_id):
            await self.close(tab.id)

    async def close_all(self) -> None:
        for tab_id in list(self.tabs):
            await self.close(tab_id)

    def reconnect(self, tab_id: str) -> TerminalTab:
        """Reconnect now (the button): forgets earlier failures and clears the screen of the old session."""
        tab = self.tabs[tab_id]
        if tab.state in ("reconnecting", "disconnected", "exited"):
            tab.policy.reset()
            tab.buffer.clear()
            tab.emit(b"\x1b[H\x1b[2J")
            restart = tab.state == "exited" and (tab.task is None or tab.task.done())
            tab.set_state("starting")
            tab.wake.set()
            if restart:
                tab.task = asyncio.create_task(self._run(tab))
        return tab

    def set_highlight(self, on: bool) -> None:
        for tab in self.tabs.values():
            tab.filter.is_enabled = on

    # --- browsers

    def attach(self, tab_id: str) -> tuple[TerminalTab, Client]:
        tab = self.tabs[tab_id]
        client = Client()
        client.send(json.dumps({"type": "state", **tab.json()}))
        if tab.buffer:
            client.send(bytes(tab.buffer))
        tab.clients.add(client)
        return tab, client

    def detach(self, tab: TerminalTab, client: Client) -> None:
        tab.clients.discard(client)

    def input(self, tab: TerminalTab, client: Client, data: bytes) -> None:
        if self.read_only():
            client.send(json.dumps({"type": "readOnly"}))
            return
        if tab.shell is not None and tab.state == "connected":
            self.touch()
            tab.shell.write(data)

    def resize(self, tab: TerminalTab, cols: int, rows: int) -> None:
        tab.cols, tab.rows = _clamp(cols, 20, 500), _clamp(rows, 5, 300)
        if tab.shell is not None:
            with contextlib.suppress(Exception):
                tab.shell.resize(tab.cols, tab.rows)

    # --- one tab's life

    async def _run(self, tab: TerminalTab) -> None:
        while not tab.closing:
            tab.wake.clear()
            tab.set_state("starting")
            started = self.clock()
            final = False
            try:
                tab.shell = await self.opener(tab.server, tab.cols, tab.rows)
            except (HostKeyUnknown, HostKeyChanged, AuthFailed) as e:
                tab.emit(dim(f"Could not sign in: {e}"))
                end, final = SessionEnd.CONNECTION_LOST, True  # retrying can't fix these
            except (SSHError, OSError) as e:
                tab.emit(dim(f"Could not connect: {e}"))
                end = SessionEnd.CONNECTION_LOST
            else:
                tab.set_state("connected")
                started = self.clock()
                end = await self._pump(tab)
            if tab.closing:
                return
            connected_for = self.clock() - started
            if end is SessionEnd.REMOTE_EXIT:
                code = tab.shell.exit_status if tab.shell else None
                tab.emit(dim(f"The shell ended (exit {code})."))
                tab.set_state("exited", exitCode=code)
                return
            decision = None if final else tab.policy.on_ended(end, connected_for)
            if decision is None:
                tab.emit(dim("Disconnected."))
                tab.set_state("disconnected")
                await tab.wake.wait()  # Reconnect Now
                continue
            tab.emit(dim(f"Connection lost. Reconnecting in {decision.delay_seconds:g} s "
                         f"(attempt {decision.attempt} of {decision.of})."))
            tab.set_state("reconnecting", attempt=decision.attempt, of=decision.of, delay=decision.delay_seconds)
            with contextlib.suppress(TimeoutError):
                await asyncio.wait_for(tab.wake.wait(), decision.delay_seconds)

    async def _pump(self, tab: TerminalTab) -> SessionEnd:
        shell = tab.shell
        assert shell is not None
        try:
            while True:
                chunk = await shell.read()
                if not chunk:
                    break
                tab.emit(tab.filter.process(chunk))
        except (SSHError, OSError):
            pass
        tab.emit(tab.filter.finish())
        return SessionEnd.REMOTE_EXIT if shell.exit_status is not None else SessionEnd.CONNECTION_LOST


def _clamp(value: int, low: int, high: int) -> int:
    return max(low, min(high, int(value)))
