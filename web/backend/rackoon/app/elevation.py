"""Docker through sudo, like the Mac's `DockerElevation` + `SudoTransport`: when Docker refuses the ssh user, the user
may unlock Docker for that server with their sudo password. Nothing on the server changes (no group membership, no
sudoers rule; Rackoon never suggests joining the docker group, which is root-equivalent): each Docker command runs as
`sudo -S -p '' sh -c '<command>'` with the password on standard input (on its own pinned connection), and a stream
answers one nonce prompt (`SudoHandshake`) before `sudo -n sh -c '<command>'`.

The password is held in memory only, for 15 minutes (sudo's own grace period does not carry from one ssh session to the
next, so polling Docker would otherwise mean a prompt every few seconds), and is dropped on Lock, on a wrong password,
when the server is edited or removed, and when the process stops. It is never written anywhere.
"""

from __future__ import annotations

import time
from collections.abc import AsyncIterable, AsyncIterator, Callable
from contextlib import AbstractAsyncContextManager, asynccontextmanager

from rackoon.core import sudo
from rackoon.core.sudo import ElevationWindow, SudoHandshake
from rackoon.ssh import CommandResult, SSHError

from .connections import Transport
from .runs import Keyboard


class SudoLocked(SSHError):
    def __init__(self) -> None:
        super().__init__("Docker access through sudo is locked again. Unlock it to continue.")


class SudoRejected(SSHError):
    def __init__(self) -> None:
        super().__init__("The server did not accept the sudo password, so Docker access was locked.")


class CannotElevate(SSHError):
    def __init__(self) -> None:
        super().__init__("This command can't be run through sudo.")


class SudoTransport:
    """Every command of `base` as root through sudo, with a password held for a limited time."""

    def __init__(self, base: Transport, password: str, valid_until: float, on_rejected: Callable[[], None],
                 clock: Callable[[], float] = time.time, make_nonce: Callable[[], str] = sudo.make_nonce) -> None:
        self.base = base
        self._password = password
        self.valid_until = valid_until
        self.on_rejected = on_rejected
        self.clock = clock
        self.make_nonce = make_nonce

    async def connect(self) -> None:
        await self.base.connect()

    async def close(self) -> None:
        pass  # the base transport belongs to Connections

    async def run(self, command: str, timeout: float, input: str | None = None) -> CommandResult:
        if self.clock() >= self.valid_until:
            raise SudoLocked()
        wrapped = sudo.elevated(command)
        if wrapped is None or input is not None:
            raise CannotElevate()
        result = await self.base.run(wrapped, timeout, input=self._password + "\n")
        if result.exit_code != 0 and sudo.is_sudo_auth_failure(result.stderr):
            self.on_rejected()
            raise SudoRejected()
        return result

    def stream(self, command: str, input: AsyncIterable[str] | None = None, cols: int = 80,
               rows: int = 24) -> AbstractAsyncContextManager[AsyncIterable[str]]:
        return self._stream(command, cols, rows)

    @asynccontextmanager
    async def _stream(self, command: str, cols: int, rows: int) -> AsyncIterator[AsyncIterable[str]]:
        if self.clock() >= self.valid_until:
            raise SudoLocked()
        nonce = self.make_nonce()
        full = sudo.elevated_stream(command, nonce)
        if full is None:
            raise CannotElevate()
        keyboard = Keyboard()
        handshake = SudoHandshake(nonce)
        password = self._password
        on_rejected = self.on_rejected

        async def chunks(raw: AsyncIterable[str]) -> AsyncIterator[str]:
            async for chunk in raw:
                shown, actions = handshake.push(chunk)
                for action in actions:
                    keyboard.type(password + "\n" if action == sudo.TYPE_PASSWORD else "\x03")
                shown = shown.replace(SudoHandshake.NOTICE, "")
                if shown:
                    yield shown
            rest = handshake.finish()
            keyboard.close()
            if rest:
                yield rest
            if handshake.outcome == sudo.REJECTED:
                on_rejected()
                raise SudoRejected()

        try:
            async with self.base.stream(full, input=keyboard, cols=cols, rows=rows) as raw:
                yield chunks(raw)
        finally:
            keyboard.close()


class DockerElevation:
    """Which servers have Docker unlocked, in memory only. Built on the core's `ElevationWindow`."""

    def __init__(self, clock: Callable[[], float] = time.time,
                 length: float = ElevationWindow.DEFAULT_LENGTH) -> None:
        self.clock = clock
        self.window = ElevationWindow(length)

    def unlock(self, server_id: str, password: str) -> None:
        self.window.unlock(server_id, password, self.clock())

    def lock(self, server_id: str, reason: str | None = None) -> None:
        self.window.lock(server_id, reason)

    def until(self, server_id: str) -> float | None:
        u = self.window.active(server_id, self.clock())
        return u.until if u else None

    def transport(self, server_id: str, base: Transport) -> Transport:
        """The transport Docker commands use: through sudo while unlocked, else the plain one."""
        u = self.window.active(server_id, self.clock())
        if u is None:
            return base
        return SudoTransport(base, u.password, u.until,
                             lambda: self.lock(server_id, "The server did not accept the sudo password."), self.clock)

    def json(self, server_id: str) -> dict[str, object]:
        return {"until": self.until(server_id), "lockReason": self.window.lock_reasons.get(server_id),
                "generation": self.window.generation(server_id)}

    @staticmethod
    def check_command() -> str:
        """What unlocking runs first, through `sudo -S` with the password on stdin: proves the password works."""
        return sudo.elevated("true") or ""
