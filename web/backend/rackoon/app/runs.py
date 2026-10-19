"""Streamed runs of confirmed actions, the web's `ActionOutput` + `StreamRunner`: a compose or container action (and a
file save before a redeploy) runs here once its confirmation was given, its output goes to every browser showing that
stack's Output tab over `/api/runs/<id>/ws`, and the run outlives the page (a reload replays it).

The command is wrapped by `stream_wrap` at the size of the browser's output view and run on its own pty connection, so
compose draws its normal progress; the wrapper's exit marker is taken off the output and is the only proof of
success. Cancelling cancels the task, which types Ctrl-C into the pty before the connection closes. One run at a time
per server, like the apps.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import secrets
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any

from rackoon.core import stream
from rackoon.core.stream import StreamedRun, StreamOutputParser
from rackoon.core.sudo import TYPE_PASSWORD, SudoCredential, SudoHandshake
from rackoon.ssh import SSHError

from .connections import Transport
from .terminals import Client

log = logging.getLogger("rackoon.runs")

MAX_OUTPUT = 1_000_000
KEEP_FINISHED = 20


@dataclass
class Run:
    id: str
    server_id: str
    scope: str
    """The stack it belongs to (`DockerStack.id`), so the stack page finds its Output."""
    title: str
    working: str
    cols: int
    rows: int
    started: float
    phase: str = "running"
    """running, succeeded, failed or cancelled."""
    exit_code: int | None = None
    message: str | None = None
    finished: float | None = None
    output: list[str] = field(default_factory=list)
    size: int = 0
    clients: set[Client] = field(default_factory=set)
    task: asyncio.Task[None] | None = None
    cancelling: bool = False
    needs_password: bool = False
    """The page may offer the sudo password sheet (sudo wanted one, or rejected the one given)."""
    sudo: str | None = None
    """How the password step went: accepted, rejected, refused, other_prompt, unfinished."""

    @property
    def running(self) -> bool:
        return self.phase == "running"

    def json(self) -> dict[str, Any]:
        return {"id": self.id, "serverId": self.server_id, "scope": self.scope, "title": self.title,
                "working": self.working, "phase": self.phase, "exitCode": self.exit_code, "message": self.message,
                "started": self.started, "finished": self.finished, "cols": self.cols, "rows": self.rows,
                "needsPassword": self.needs_password, "sudo": self.sudo}

    def emit(self, text: str) -> None:
        if not text:
            return
        self.output.append(text)
        self.size += len(text)
        while self.size > MAX_OUTPUT and len(self.output) > 1:
            self.size -= len(self.output.pop(0))
        data = text.encode()
        for c in list(self.clients):
            if not c.send(data):
                self.clients.discard(c)
                c.close()

    def _publish(self) -> None:
        frame = json.dumps({"type": "state", **self.json()})
        for c in list(self.clients):
            c.send(frame)
            if not self.running:
                c.close()


Work = Callable[[Run], Awaitable[StreamedRun]]


class RunManager:
    def __init__(self, touch: Callable[[], None] = lambda: None, clock: Callable[[], float] = time.time) -> None:
        self.touch = touch
        self.clock = clock
        self.runs: dict[str, Run] = {}

    def running_on(self, server_id: str) -> Run | None:
        return next((r for r in self.runs.values() if r.server_id == server_id and r.running), None)

    def for_server(self, server_id: str) -> list[Run]:
        return sorted((r for r in self.runs.values() if r.server_id == server_id), key=lambda r: r.started)

    def latest(self, server_id: str, scope: str) -> Run | None:
        return next((r for r in reversed(self.for_server(server_id)) if r.scope == scope), None)

    def start(self, server_id: str, scope: str, title: str, working: str, cols: int, rows: int, work: Work,
              on_done: Callable[[Run], Awaitable[None] | None] | None = None,
              explain: Callable[[StreamedRun], str | None] | None = None) -> Run:
        """Starts `work` now. The caller has the confirmation; `work` streams through `stream_command`."""
        if self.running_on(server_id) is not None:
            raise RuntimeError("Another action is running on this server. Wait for it to finish.")
        run = Run(secrets.token_urlsafe(12), server_id, scope, title, working, max(20, min(400, cols)),
                  max(5, min(200, rows)), self.clock())
        self.runs[run.id] = run
        self._prune(server_id)
        run.task = asyncio.create_task(self._run(run, work, on_done, explain))
        return run

    def cancel(self, run_id: str) -> bool:
        run = self.runs.get(run_id)
        if run is None or not run.running or run.task is None:
            return False
        run.cancelling = True
        run.task.cancel()
        return True

    def close(self, run_id: str) -> bool:
        """Forgets a finished run (its Output tab was closed)."""
        run = self.runs.get(run_id)
        if run is None or run.running:
            return False
        del self.runs[run_id]
        return True

    async def close_server(self, server_id: str) -> None:
        for run in self.for_server(server_id):
            if run.running and run.task is not None:
                run.cancelling = True
                run.task.cancel()
                await asyncio.gather(run.task, return_exceptions=True)
            self.runs.pop(run.id, None)

    async def close_all(self) -> None:
        for server_id in {r.server_id for r in self.runs.values()}:
            await self.close_server(server_id)

    def _prune(self, server_id: str) -> None:
        finished = [r for r in self.for_server(server_id) if not r.running]
        for r in finished[:-KEEP_FINISHED]:
            del self.runs[r.id]

    async def _run(self, run: Run, work: Work, on_done: Callable[[Run], Awaitable[None] | None] | None,
                   explain: Callable[[StreamedRun], str | None] | None = None) -> None:
        result: StreamedRun | None = None
        try:
            result = await work(run)
        except asyncio.CancelledError:
            if not run.cancelling:
                raise
            result = StreamedRun(None, True, None, "")
        except RunFailed as e:
            run.phase, run.message = "failed", str(e)
        except Exception as e:  # noqa: BLE001 - shown in the Output tab, never lost
            log.exception("run %s failed", run.title)
            run.phase, run.message = "failed", str(e) or type(e).__name__
        if result is not None:
            run.exit_code = result.exit_code
            run.phase = "succeeded" if result.succeeded else ("cancelled" if result.cancelled and result.exit_code is None
                                                              else "failed")
            run.message = result.failure_message(run.title)
            run.sudo = result.sudo.kind if result.sudo is not None else None
            run.needs_password = not result.succeeded and result.needs_sudo_password
            if result.sudo_problem is not None:
                run.phase, run.message = "failed", result.sudo_problem
            elif explain is not None and not result.succeeded and not result.cancelled:
                run.message = explain(result) or run.message
        run.finished = self.clock()
        self.touch()  # a long run is activity: Read-only's idle timer starts after it ends
        run._publish()
        if on_done is not None:
            try:
                done = on_done(run)
                if done is not None:
                    await done
            except Exception:  # noqa: BLE001
                log.exception("after run %s", run.title)

    # --- browsers

    def attach(self, run_id: str) -> tuple[Run, Client]:
        run = self.runs[run_id]
        client = Client()
        client.send(json.dumps({"type": "state", **run.json()}))
        text = "".join(run.output)
        if text:
            client.send(text.encode())
        if run.running:
            run.clients.add(client)
        else:
            client.close()
        return run, client

    def detach(self, run: Run, client: Client) -> None:
        run.clients.discard(client)


class RunFailed(Exception):
    """A step before or after the stream failed with a message for the Output tab."""


class Keyboard:
    """What is typed into a stream's pty (the sudo password at its one prompt, or a Ctrl-C), as an async iterable."""

    def __init__(self) -> None:
        self._queue: asyncio.Queue[str | None] = asyncio.Queue()

    def type(self, text: str) -> None:
        self._queue.put_nowait(text)

    def close(self) -> None:
        self._queue.put_nowait(None)

    def __aiter__(self) -> AsyncIterator[str]:
        return self._keys()

    async def _keys(self) -> AsyncIterator[str]:
        while (text := await self._queue.get()) is not None:
            yield text


async def stream_command(run: Run, transport: Transport, command: str,
                         credential: SudoCredential | None = None) -> StreamedRun:
    """Streams one vetted command into the run and returns what it came to (the wrapper's exit marker, or none).

    With `credential`, `command` must be the password variant built with the same nonce: the password is typed at the
    first nonce prompt only, the handshake's lines are not shown, and after the ok marker nothing is looked at again.
    """
    parser = StreamOutputParser()
    handshake = SudoHandshake(credential.nonce) if credential is not None else None
    keyboard = Keyboard() if credential is not None else None
    text: list[str] = []

    def show(chunk: str) -> None:
        visible = chunk
        if handshake is not None and keyboard is not None and credential is not None:
            visible, actions = handshake.push(chunk)
            for action in actions:
                keyboard.type(credential.password + "\n" if action == TYPE_PASSWORD else "\x03")
        shown = parser.push(visible)
        if sum(len(t) for t in text) < 200_000:
            text.append(shown)
        run.emit(shown)

    def end() -> tuple[str, int | None]:
        if handshake is not None:
            run.emit(parser.push(handshake.finish()))
        if keyboard is not None:
            keyboard.close()
        held, code = parser.finish()
        run.emit(held)
        return held, code

    error: str | None = None
    try:
        async with transport.stream(stream.wrap(command, run.cols, run.rows), input=keyboard, cols=run.cols,
                                    rows=run.rows) as s:
            async for chunk in s:
                show(chunk)
    except SSHError as e:
        error = str(e)
    except asyncio.CancelledError:
        if keyboard is not None:
            keyboard.close()
        raise
    held, code = end()
    return StreamedRun(code, False, error, "".join(text) + held, handshake.outcome if handshake else None)


def note(text: str) -> str:
    """A dim line in the Output view, for what Rackoon itself did (a save before a redeploy)."""
    return f"\x1b[2m{text}\x1b[0m\r\n"
