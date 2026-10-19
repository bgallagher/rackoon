"""Docker through sudo (the Swift core's SudoTransportTests and ElevationTests): every command wrapped in
`sudo -S … sh -c`, the password on stdin only, only sudo's own refusal locks, nothing is sent once the window is over,
and a stream answers one nonce prompt and hides the handshake."""

from __future__ import annotations

from collections.abc import AsyncIterable, AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

import pytest

from rackoon.app.elevation import CannotElevate, DockerElevation, SudoLocked, SudoRejected, SudoTransport
from rackoon.core import docker
from rackoon.ssh import CommandResult

NONCE = "0123456789abcdef0123456789abcdef"


class Fake:
    def __init__(self, results: list[CommandResult] | None = None, chunks: list[str] | None = None,
                 asks: tuple[int, ...] = ()) -> None:
        self.results = results or []
        self.chunks = chunks or []
        self.asks = asks
        """After which chunks the fake waits for something to be typed (like sudo at its prompt)."""
        self.commands: list[str] = []
        self.inputs: list[str | None] = []
        self.typed: list[str] = []
        self.streamed: list[str] = []

    async def run(self, command: str, timeout: float, input: str | None = None) -> CommandResult:
        self.commands.append(command)
        self.inputs.append(input)
        return self.results.pop(0)

    def stream(self, command: str, input: AsyncIterable[str] | None = None, cols: int = 80, rows: int = 24) -> Any:
        self.streamed.append(command)
        fake = self

        @asynccontextmanager
        async def opened() -> AsyncIterator[AsyncIterator[str]]:
            keys = input.__aiter__() if input is not None else None

            async def gen() -> AsyncIterator[str]:
                for i, c in enumerate(fake.chunks):
                    yield c
                    if i in fake.asks and keys is not None:
                        fake.typed.append(await keys.__anext__())
            yield gen()
        return opened()

    async def connect(self) -> None:
        pass

    async def close(self) -> None:
        pass


def transport(base: Fake, until: float = 1e12, locked: list[int] | None = None) -> SudoTransport:
    hits = locked if locked is not None else []
    return SudoTransport(base, "hunter2", until, lambda: hits.append(1), clock=lambda: 1000.0,
                         make_nonce=lambda: NONCE)


async def test_run_wraps_the_whole_command_and_sends_the_password_on_stdin_only() -> None:
    base = Fake([CommandResult("##docker\nok\n", "", 0)])
    r = await transport(base).run(docker.command(), 20)
    assert r.stdout == "##docker\nok\n"
    assert base.commands[0].startswith("sudo -S -p '' sh -c '") and "hunter2" not in base.commands[0]
    assert base.inputs == ["hunter2\n"]


async def test_only_sudos_own_refusal_locks() -> None:
    locked: list[int] = []
    registry = Fake([CommandResult("", "unauthorized: authentication required\n", 1)])
    assert (await transport(registry, locked=locked).run("docker pull x", 20)).exit_code == 1
    assert locked == []
    for stderr in ("sudo: Authentication failed, try again.\nsudo: Authentication required but not attempted\n",
                   "Sorry, try again.\nsudo: 1 incorrect password attempt\n"):
        with pytest.raises(SudoRejected):
            await transport(Fake([CommandResult("", stderr, 1)]), locked=locked).run("docker ps", 20)
    assert locked == [1, 1]


async def test_nothing_is_sent_once_the_window_is_over_or_for_an_unquotable_command() -> None:
    base = Fake()
    with pytest.raises(SudoLocked):
        await transport(base, until=999).run("docker ps", 20)
    with pytest.raises(CannotElevate):
        await transport(base).run("echo a\x00b", 20)
    assert base.commands == []


async def test_streams_answer_one_prompt_and_hide_the_handshake() -> None:
    base = Fake(chunks=[f"[sudo: ##rackoon-sudo-{NONCE}:] Password: ****\r\n", f"##rackoon-sudo-ok-{NONCE}\r\n",
                        "web-1  | started\r\n", f"##rackoon-sudo-{NONCE}:\r\n"], asks=(0,))  # the last is a log line
    shown = ""
    async with transport(base).stream("docker logs -f --tail 100 abcdef012345") as s:
        async for chunk in s:
            shown += chunk
    assert base.typed == ["hunter2\n"]
    assert shown == f"web-1  | started\r\n##rackoon-sudo-{NONCE}:\r\n", "no prompt, no asterisks, no notice"
    sent = base.streamed[0]
    assert f"sudo -p '##rackoon-sudo-{NONCE}:' -v" in sent and "hunter2" not in sent
    assert sent.endswith("sudo -n sh -c 'docker logs -f --tail 100 abcdef012345'")


async def test_a_stream_with_a_wrong_password_locks() -> None:
    locked: list[int] = []
    base = Fake(chunks=[f"##rackoon-sudo-{NONCE}:\r\n", "sudo: Authentication failed, try again.\r\n",
                        f"##rackoon-sudo-{NONCE}:"], asks=(0, 2))
    with pytest.raises(SudoRejected):
        async with transport(base, locked=locked).stream("docker ps") as s:
            async for _ in s:
                pass
    assert locked == [1] and base.typed == ["hunter2\n", "\x03"]


def test_the_elevation_manager_holds_the_password_for_its_window_only() -> None:
    now = [1000.0]
    e = DockerElevation(clock=lambda: now[0], length=900)
    base = Fake()
    assert e.transport("s", base) is base
    e.unlock("s", "pw")
    assert isinstance(e.transport("s", base), SudoTransport) and e.until("s") == 1900
    now[0] = 1900
    assert e.transport("s", base) is base, "expired: the plain transport again"
    e.unlock("s", "pw")
    e.transport("s", base).on_rejected()  # type: ignore[attr-defined]
    assert e.until("s") is None and "did not accept" in str(e.json("s")["lockReason"])
    assert DockerElevation.check_command() == "sudo -S -p '' sh -c 'true'"
