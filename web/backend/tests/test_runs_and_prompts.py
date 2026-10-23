"""The confirm sheet's words (the Kotlin ActionPromptsTests, with restarts destructive as on the Mac), the run
manager (one run per server, the exit marker as the only success, cancel, replay to a late browser, pruning), and the
favicon fetcher against canned sites (httpx.MockTransport: icon links, sniffed types, redirects checked hop by hop,
size limits, the day-long retry)."""

from __future__ import annotations

import asyncio
import json
from collections.abc import AsyncIterable, AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
import pytest

from rackoon.app.favicons import FaviconStore, fetchable, sniff
from rackoon.app.runs import KEEP_FINISHED, RunManager, stream_command
from rackoon.core import action_prompts as prompts
from rackoon.core.docker import ComposeAction, DockerAction, DockerContainer, DockerStack
from rackoon.core.stream import StreamedRun
from rackoon.ssh import CommandResult, ConnectionLost


def container(service: str | None, project: str | None = "media", working_dir: str | None = "/srv/media") -> \
        DockerContainer:
    return DockerContainer("abcdef012345", f"media-{service or 'x'}-1", "img", "running", "none", "Up", [],
                           project=project, service=service, working_dir=working_dir,
                           config_file=f"{working_dir}/compose.yaml" if working_dir else None,
                           config_files=[f"{working_dir}/compose.yaml"] if working_dir else [])


def stack(*cs: DockerContainer, standalone: bool = False) -> DockerStack:
    first = cs[0] if cs else None
    return DockerStack("media", first.working_dir if first else None, first.config_file if first else None,
                       first.config_files if first else [], list(cs), standalone)


def test_unavailable_reasons_come_in_the_macs_order() -> None:
    ok = stack(container("web"))
    assert prompts.blocked_reason(ok, False, False) is None
    assert prompts.blocked_reason(ok, True, True) == "Read-only mode is on"
    assert prompts.blocked_reason(ok, False, True) == "Another stack action is running"
    assert prompts.blocked_reason(stack(container("x", None, None), standalone=True), False, False) == \
        "These containers were not started with Docker Compose"
    assert prompts.blocked_reason(stack(container("web", working_dir=None)), False, False) == \
        "No single compose file was found for this stack"


def test_start_has_no_prompt_and_stop_and_restart_are_destructive() -> None:
    c = container("web")
    assert prompts.container(DockerAction.START, c) is None
    stop, restart = prompts.container(DockerAction.STOP, c), prompts.container(DockerAction.RESTART, c)
    assert stop is not None and stop.destructive and restart is not None and restart.destructive
    assert restart.title == "Restart media-web-1?"


def test_stack_prompts_name_the_stack_and_count_its_containers() -> None:
    s = stack(container("web"), container("db"))
    assert prompts.stack(ComposeAction.RESTART, s).title == "Restart all 2 containers in media?"
    assert prompts.stack(ComposeAction.RECREATE, stack(container("web"))).title == "Recreate all 1 container in media?"
    assert prompts.stack(ComposeAction.RECREATE, s).destructive and not prompts.stack(ComposeAction.UP, s).destructive
    assert prompts.stack(ComposeAction.UP, s).working == "Updating media…"
    assert all(prompts.stack(a, s).message for a in ComposeAction)


def test_rebuild_applies_only_to_a_service_the_stack_can_address() -> None:
    s = stack(container("web"))
    assert prompts.can_rebuild(container("web"), s)
    assert not prompts.can_rebuild(container(None), s)
    assert not prompts.can_rebuild(container("web"), stack(container("web", working_dir=None)))
    assert prompts.rebuild("web", s).title == "Rebuild web?"


# --- runs -----------------------------------------------------------------------------------------------------------


class Scripted:
    """A transport whose stream yields the given chunks, optionally waiting forever at the end."""

    def __init__(self, chunks: list[str], hang: bool = False, fail: bool = False) -> None:
        self.chunks = chunks
        self.hang = hang
        self.fail = fail
        self.commands: list[str] = []
        self.closed = False

    async def run(self, command: str, timeout: float, input: str | None = None) -> CommandResult:
        return CommandResult("", "", 0)

    def stream(self, command: str, input: AsyncIterable[str] | None = None, cols: int = 80, rows: int = 24):  # type: ignore[no-untyped-def]
        self.commands.append(command)

        @asynccontextmanager
        async def opened() -> AsyncIterator[AsyncIterator[str]]:
            async def gen() -> AsyncIterator[str]:
                for c in self.chunks:
                    await asyncio.sleep(0)
                    yield c
                if self.fail:
                    raise ConnectionLost("the connection dropped")
                if self.hang:
                    await asyncio.sleep(3600)
            try:
                yield gen()
            finally:
                self.closed = True
        return opened()

    async def connect(self) -> None:
        pass

    async def close(self) -> None:
        pass


async def wait(manager: RunManager, run_id: str) -> None:
    task = manager.runs[run_id].task
    assert task is not None
    await asyncio.wait_for(task, 5)


async def test_a_run_succeeds_only_with_the_exit_marker_and_strips_it() -> None:
    m = RunManager()
    t = Scripted(["Pulling…\r\n", "done\r\n##rack", "oon-exit:0\r\n"])
    run = m.start("s1", "media", "docker compose pull", "Pulling…", 100, 30,
                  lambda r: stream_command(r, t, "docker compose pull"))
    await wait(m, run.id)
    assert run.phase == "succeeded" and run.exit_code == 0 and "".join(run.output) == "Pulling…\r\ndone\r\n"
    assert t.commands[0].startswith("stty cols 100 rows 30") and "( docker compose pull )" in t.commands[0]
    t2 = Scripted(["no marker\r\n"])
    lost = m.start("s1", "media", "up", "Updating…", 80, 24, lambda r: stream_command(r, t2, "x"))
    await wait(m, lost.id)
    assert lost.phase == "failed" and lost.message == "The connection ended before up reported a result."
    t3 = Scripted(["half\r\n"], fail=True)
    dropped = m.start("s1", "media", "up", "Updating…", 80, 24, lambda r: stream_command(r, t3, "x"))
    await wait(m, dropped.id)
    assert dropped.phase == "failed" and dropped.message == "the connection dropped"
    t4 = Scripted(["boom\r\n##rackoon-exit:2\r\n"])
    failed = m.start("s1", "media", "up", "Updating…", 80, 24, lambda r: stream_command(r, t4, "x"))
    await wait(m, failed.id)
    assert failed.phase == "failed" and failed.exit_code == 2 and "exit 2" in (failed.message or "")
    assert m.latest("s1", "media") is failed


async def test_one_run_per_server_and_cancel_closes_the_stream() -> None:
    m = RunManager()
    t = Scripted(["working\r\n"], hang=True)
    run = m.start("s1", "media", "up", "Updating…", 80, 24, lambda r: stream_command(r, t, "x"))
    await asyncio.sleep(0.05)
    with pytest.raises(RuntimeError, match="Another action"):
        m.start("s1", "other", "up", "…", 80, 24, lambda r: stream_command(r, t, "x"))
    other = m.start("s2", "media", "up", "…", 80, 24,
                    lambda r: stream_command(r, Scripted(["##rackoon-exit:0\n"]), "x"))
    await wait(m, other.id)
    assert not m.close(run.id), "a running run can't be closed"
    late, client = m.attach(run.id)
    assert json.loads(str(client.queue.get_nowait()))["phase"] == "running"
    assert client.queue.get_nowait() == b"working\r\n", "a browser that comes late gets the replay"
    assert m.cancel(run.id)
    await wait(m, run.id)
    assert run.phase == "cancelled" and t.closed and run.message and run.message.startswith("Cancelled")
    frames = []
    while not client.queue.empty():
        frames.append(client.queue.get_nowait())
    assert json.loads(str(frames[0]))["phase"] == "cancelled" and frames[-1] is None
    assert m.close(run.id) and run.id not in m.runs


async def test_finished_runs_are_pruned_and_a_step_failure_is_shown() -> None:
    m = RunManager()

    async def ok(_: object) -> StreamedRun:
        return StreamedRun(0, False, None, "")

    for i in range(KEEP_FINISHED + 5):
        r = m.start("s1", f"stack{i}", "up", "…", 80, 24, ok)
        await wait(m, r.id)
    assert len(m.for_server("s1")) <= KEEP_FINISHED + 1

    async def broken(_: object) -> StreamedRun:
        raise ValueError("the save was refused")

    r = m.start("s1", "x", "save", "…", 80, 24, broken)
    await wait(m, r.id)
    assert r.phase == "failed" and r.message == "the save was refused"


# --- favicons -------------------------------------------------------------------------------------------------------

PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 40
SVG = b'<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"></svg>'


def site(routes: dict[str, httpx.Response]) -> tuple[httpx.MockTransport, list[str]]:
    asked: list[str] = []

    def handle(request: httpx.Request) -> httpx.Response:
        asked.append(str(request.url))
        return routes.get(str(request.url), httpx.Response(404))
    return httpx.MockTransport(handle), asked


def test_sniffing_and_fetchable() -> None:
    assert sniff(PNG) == "png" and sniff(SVG) == "svg" and sniff(b"<html>") is None
    assert sniff(b"\x00\x00\x01\x00rest") == "ico" and sniff(b"RIFF1234WEBPVP8 ") == "webp"
    assert fetchable("http://192.168.1.5:8096/x") and not fetchable("http://169.254.169.254/latest")
    assert not fetchable("file:///etc/passwd") and not fetchable("javascript:alert(1)")


async def test_the_best_icon_link_wins_and_is_cached(tmp_path: Path) -> None:
    page = '<link rel="icon" href="/small.ico"><link rel="apple-touch-icon" sizes="180x180" href="/touch.png">'
    transport, asked = site({
        "http://nas.lan:8096/": httpx.Response(200, text=page),
        "http://nas.lan:8096/touch.png": httpx.Response(200, content=PNG),
    })
    store = FaviconStore(tmp_path / "favicons", transport=transport)
    got = await store.get("http://nas.lan:8096")
    assert got == (PNG, "image/png") and asked == ["http://nas.lan:8096/", "http://nas.lan:8096/touch.png"]
    again = FaviconStore(tmp_path / "favicons", transport=site({})[0])
    assert await again.get("http://nas.lan:8096") == (PNG, "image/png"), "read back from the cache folder"


async def test_a_page_that_lies_about_its_icon_falls_back_and_a_failure_waits_a_day(tmp_path: Path) -> None:
    now = [1000.0]
    transport, asked = site({
        "http://a.lan/": httpx.Response(200, text='<link rel="icon" href="/fake.png">'),
        "http://a.lan/fake.png": httpx.Response(200, content=b"<html>not an image</html>"),
        "http://a.lan/favicon.ico": httpx.Response(200, content=SVG),
    })
    store = FaviconStore(tmp_path, clock=lambda: now[0], transport=transport)
    assert await store.get("http://a.lan") == (SVG, "image/svg+xml")
    bare, asked2 = site({})
    store2 = FaviconStore(tmp_path / "other", clock=lambda: now[0], transport=bare)
    assert await store2.get("http://b.lan") is None
    tries = len(asked2)
    assert await store2.get("http://b.lan") is None and len(asked2) == tries, "not asked again the same day"
    now[0] += 86401
    await store2.get("http://b.lan")
    assert len(asked2) > tries


async def test_redirects_are_checked_hop_by_hop_and_sizes_are_capped(tmp_path: Path) -> None:
    transport, asked = site({
        "http://c.lan/": httpx.Response(302, headers={"location": "http://169.254.169.254/"}),
        "http://c.lan/favicon.ico": httpx.Response(200, content=PNG + b"\x00" * (1024 * 1024)),
    })
    store = FaviconStore(tmp_path, transport=transport)
    assert await store.get("http://c.lan") is None
    assert "http://169.254.169.254/" not in asked
