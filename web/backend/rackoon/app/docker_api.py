"""The Docker API (stage W5): the overview, a stack's page, container and stack actions with live output, logs, the
compose/.env editor, delete stack, add container and bookmarks, plus the dashboard's fleet view.

Nothing here runs a change straight away: each endpoint that would change a server builds the core's `Intent`,
proposes it to the `ActionCenter` with the words the apps use (`action_prompts`), and runs it only from
`POST /api/actions/<id>/confirm`. The one exception is starting a stopped container, which the apps also run on one
click, but it still goes through the policy (Read-only refuses it). Every runner authorizes its intent against the
confirmation again, and follow-on commands (the `up -d` after a save) were shown on the sheet as `then` and are
confirmed through the same policy when their turn comes.
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, replace
from typing import TYPE_CHECKING, Any, Literal

from fastapi import Depends, FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import Response
from pydantic import Field
from starlette.requests import HTTPConnection

from rackoon.core import action_prompts, add_container, compose_edit, docker, docker_view, favicon, logs, stack_files
from rackoon.core.add_container import AddDraft, ContainerSpec, EnvRow, Existing, ImageStatus, PortRow, Readings
from rackoon.core.add_container import RestartPolicy, VolumeRow
from rackoon.core.docker import Bookmark, ComposeAction, DockerAction, DockerStack
from rackoon.core.editor import CheckRow
from rackoon.core.jsonmodel import to_json
from rackoon.core.models import Server
from rackoon.core.policy import Confirmation, Intent, PolicyError, Risk
from rackoon.core.stack_actions import StackRemoval, StandaloneAction
from rackoon.core.stack_files import ComposeIssue, EditableFile, FileEdit, ValidationResult
from rackoon.core.stream import StreamedRun
from rackoon.ssh import SSHError

from .actions import ActionError, PendingAction
from .connections import Transport, TrustError
from .docker_hub import DockerEntry, link_host, stack_json, state_json
from .errors import ApiError, Body
from .runs import Run, RunFailed, note, stream_command
from .terminals import Client

if TYPE_CHECKING:
    from .api import Rackoon

READ_TIMEOUT = 30.0
SAVE_TIMEOUT = 90.0
IMAGE_TTL = 300.0
PORTS_TTL = 15.0


# --- request bodies -------------------------------------------------------------------------------------------------


class SizeIn(Body):
    """The size of the browser's output view, so compose's redrawing progress lines up."""

    cols: int = Field(default=120, ge=20, le=400)
    rows: int = Field(default=32, ge=5, le=200)


class ContainerActionIn(SizeIn):
    containerId: str = Field(max_length=64)
    action: Literal["start", "stop", "restart"]


class StackActionIn(SizeIn):
    stackId: str = Field(max_length=300)
    action: Literal["pull", "up", "restart", "rebuild", "recreate"]
    service: str | None = Field(default=None, max_length=64)


class StackIn(SizeIn):
    stackId: str = Field(max_length=300)


class DeleteIn(SizeIn):
    stackId: str = Field(max_length=300)
    removeVolumes: bool = False
    deleteFolder: bool = False


class ShellIn(Body):
    containerId: str = Field(max_length=64)
    cols: int = Field(default=80, ge=1, le=1000)
    rows: int = Field(default=24, ge=1, le=1000)


class FileIn(Body):
    stackId: str = Field(max_length=300)
    path: str = Field(max_length=4096)


class CheckIn(FileIn):
    original: str = Field(max_length=stack_files.MAX_BYTES)
    text: str = Field(max_length=stack_files.MAX_BYTES)
    checkServer: bool = True


class SaveIn(SizeIn):
    stackId: str = Field(max_length=300)
    path: str = Field(max_length=4096)
    original: str | None = Field(default=None, max_length=stack_files.MAX_BYTES)
    sha: str | None = Field(default=None, max_length=64)
    text: str = Field(max_length=stack_files.MAX_BYTES)
    redeploy: bool = False


class PortIn(Body):
    host: str = Field(default="", max_length=100)
    container: str = Field(default="", max_length=20)


class VolumeIn(Body):
    source: str = Field(default="", max_length=1024)
    target: str = Field(default="", max_length=1024)


class EnvIn(Body):
    key: str = Field(default="", max_length=200)
    value: str = Field(default="", max_length=4096)


class SpecIn(Body):
    name: str = Field(default="", max_length=100)
    image: str = Field(default="", max_length=300)
    ports: list[PortIn] = Field(default_factory=list, max_length=50)
    volumes: list[VolumeIn] = Field(default_factory=list, max_length=50)
    env: list[EnvIn] = Field(default_factory=list, max_length=100)
    restart: Literal["no", "always", "unless-stopped", "on-failure"] = "unless-stopped"


class DraftIn(Body):
    target: Literal["new", "existing"] = "new"
    spec: SpecIn = Field(default_factory=SpecIn)
    stackName: str = Field(default="", max_length=100)
    folder: str = Field(default="/opt/stacks", max_length=1024)
    existingName: str | None = Field(default=None, max_length=300)
    paste: bool = False
    pasteCompose: str = Field(default="", max_length=stack_files.MAX_BYTES)
    pasteEnv: str = Field(default="", max_length=stack_files.MAX_BYTES)

    def draft(self) -> AddDraft:
        s = self.spec
        spec = ContainerSpec(s.name.strip(), s.image.strip(), [PortRow(p.host.strip(), p.container.strip()) for p in s.ports],
                             [VolumeRow(v.source.strip(), v.target.strip()) for v in s.volumes],
                             [EnvRow(e.key.strip(), e.value) for e in s.env], RestartPolicy(s.restart))
        return AddDraft(self.target, spec, self.stackName.strip(), self.folder, self.existingName, self.paste,
                        self.pasteCompose, self.pasteEnv)


class DeployIn(SizeIn):
    draft: DraftIn
    start: bool = True


class BookmarkBody(Body):
    href: str = Field(max_length=2048)
    name: str | None = Field(default=None, max_length=200)
    group: str | None = Field(default=None, max_length=200)
    icon: str | None = Field(default=None, max_length=300)
    description: str | None = Field(default=None, max_length=500)


class BookmarkIn(SizeIn):
    stackId: str = Field(max_length=300)
    service: str = Field(max_length=64)
    bookmark: BookmarkBody | None = None
    apply: bool = True


# --- helpers --------------------------------------------------------------------------------------------------------


def issue_json(i: ComposeIssue) -> dict[str, Any]:
    return {"severity": i.severity.value, "line": i.line, "message": i.message}


def row_json(r: CheckRow) -> dict[str, Any]:
    return {"id": r.id, "state": r.state.value, "title": r.title, "detail": r.detail}


@dataclass
class Cached:
    value: Any
    at: float


class AddChecks:
    """The slow checks of the Add container page, remembered for a while so the page can ask again as it is typed."""

    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self.clock = clock
        self.images: dict[tuple[str, str], Cached] = {}
        self.ports: dict[str, Cached] = {}
        self.pending: dict[tuple[str, str], asyncio.Task[None]] = {}

    def image(self, server: Server, transport: Transport, image: str) -> ImageStatus | None:
        """The cached answer, else None while a background check runs (the row shows "checking")."""
        key = (server.id, image)
        hit = self.images.get(key)
        if hit is not None and self.clock() - hit.at < IMAGE_TTL:
            return hit.value  # type: ignore[no-any-return]
        if key not in self.pending:
            self.pending[key] = asyncio.create_task(self._check_image(key, transport, image))
        return None

    async def wait_image(self, server: Server, transport: Transport, image: str) -> ImageStatus | None:
        if self.image(server, transport, image) is None:
            task = self.pending.get((server.id, image))
            if task is not None:
                with contextlib.suppress(Exception):
                    await asyncio.wait_for(asyncio.shield(task), 30)
        return self.image(server, transport, image)

    async def _check_image(self, key: tuple[str, str], transport: Transport, image: str) -> None:
        try:
            command = add_container.image_command(image)
            if command is None:
                return
            try:
                result = await transport.run(command, 30)
                status = add_container.parse_image_status(result.stdout)
            except SSHError:
                status = ImageStatus.TIMED_OUT
            self.images[key] = Cached(status, self.clock())
        finally:
            self.pending.pop(key, None)

    async def listening(self, server: Server, transport: Transport) -> set[int] | None:
        hit = self.ports.get(server.id)
        if hit is not None and self.clock() - hit.at < PORTS_TTL:
            return hit.value  # type: ignore[no-any-return]
        try:
            result = await transport.run(add_container.listening_ports_command(), 15)
        except SSHError:
            return None
        found: set[int] = set()
        for line in result.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 4:
                tail = parts[3].rsplit(":", 1)[-1]
                if tail.isdigit():
                    found.add(int(tail))
        self.ports[server.id] = Cached(found, self.clock())
        return found


def register(app: FastAPI, rackoon: Rackoon, authenticated: Callable[[Request], str],
             identify: Callable[[HTTPConnection], tuple[str, str]], same_origin: Callable[[HTTPConnection], bool],
             find: Callable[[list[Server], str], Server]) -> None:
    Auth = Depends(authenticated)
    store = rackoon.store
    hub = rackoon.docker
    runs = rackoon.runs
    actions = rackoon.actions
    policy = rackoon.preferences.policy
    checks = AddChecks()

    def server_of(server_id: str) -> Server:
        return find(store.load_servers(), server_id)

    def transport(server: Server) -> Transport:
        try:
            return rackoon.connections.transport(server)
        except TrustError as e:
            raise ApiError(e.status, e.code, str(e)) from None

    def host(server: Server) -> Any:
        entry = rackoon.monitor.entries.get(server.id)
        return entry.state.overview if entry else None

    def entry_of(server: Server) -> DockerEntry:
        e = hub.entry(server)
        if e.snapshot is None and e.error is None:
            raise ApiError(409, "dockerLoading", "Docker hasn't answered yet. Try again in a moment.")
        return e

    def stack_of(e: DockerEntry, stack_id: str) -> DockerStack:
        s = e.stack(stack_id)
        if s is None:
            raise ApiError(404, "noSuchStack", "That stack is gone. It may have been removed on the server.")
        return s

    def target(server: Server) -> str:
        return f"{server.user or 'root'}@{server.host}"

    def not_busy(server: Server) -> None:
        if runs.running_on(server.id) is not None:
            raise ApiError(409, "busy", "Another action is running on this server. Wait for it to finish.")

    def refuse_read_only(what: str = "make changes") -> None:
        if rackoon.preferences.read_only:
            raise ApiError(409, "readOnly", f"Read-only mode is on. Turn it off to {what}.")

    def pending_json(p: PendingAction) -> dict[str, Any]:
        return {"pending": p.json()}

    def propose(intent: Intent, run: Callable[[Confirmation], Awaitable[Any]], **sheet: Any) -> dict[str, Any]:
        try:
            return pending_json(actions.propose(intent, run, **sheet))
        except ActionError as e:
            raise ApiError(e.status, e.code, str(e)) from None

    async def run_command(t: Transport, intent: Intent, confirmation: Confirmation, timeout: float) -> Any:
        """Runs a confirmed, non-streamed command: the policy is asked again first."""
        try:
            policy.authorize(intent, confirmation)
        except PolicyError as e:
            raise ApiError(409, "readOnly", str(e)) from None
        try:
            return await t.run(intent.command, timeout)
        except SSHError as e:
            raise ApiError(502, "connection", str(e)) from None

    def start_run(server: Server, scope: str, title: str, working: str, cols: int, rows: int,
                  steps: Callable[[Run], Awaitable[StreamedRun]],
                  on_done: Callable[[Run], None] | None = None) -> dict[str, Any]:
        def finished(run: Run) -> None:
            hub.poke(server.id)
            if on_done is not None:
                on_done(run)
        try:
            run = runs.start(server.id, scope, title, working, cols, rows, steps, finished)
        except RuntimeError as e:
            raise ApiError(409, "busy", str(e)) from None
        return {"run": run.json()}

    def streamed(server: Server, intent: Intent, confirmation: Confirmation,
                 intro: str | None = None) -> Callable[[Run], Awaitable[StreamedRun]]:
        async def steps(run: Run) -> StreamedRun:
            try:
                policy.authorize(intent, confirmation)
            except PolicyError as e:
                raise RunFailed(str(e)) from None
            if intro:
                run.emit(intro)
            return await stream_command(run, transport(server), intent.command)
        return steps

    def up_after(server: Server, stack: DockerStack, cols: int, rows: int, before: str | None = None) -> dict[str, Any]:
        """The `up -d` a sheet named as its `then`: confirmed now that the first step succeeded."""
        intent = ComposeAction.UP.intent(stack)
        if intent is None:
            return {}
        try:
            confirmation = policy.confirm(intent)
        except PolicyError:
            return {}
        prompt = action_prompts.stack(ComposeAction.UP, stack)
        return start_run(server, stack.id, "docker compose up", prompt.working, cols, rows,
                         streamed(server, intent, confirmation, before))

    # --- the overview and a stack's page

    @app.get("/api/servers/{server_id}/docker")
    async def docker_state(server_id: str, watch: bool = False, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        e = hub.watch(server) if watch else hub.entry(server)
        if watch:
            await hub.settle(e, 4.0)
        out = state_json(e, host(server), rackoon.preferences.read_only, runs.running_on(server_id))
        out["bookmarks"] = bookmarks_of(e)
        return out

    @app.post("/api/servers/{server_id}/docker/refresh")
    async def docker_refresh(server_id: str, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        e = await hub.refresh(server)
        return state_json(e, host(server), rackoon.preferences.read_only, runs.running_on(server_id))

    @app.get("/api/servers/{server_id}/docker/stack")
    async def docker_stack(server_id: str, id: str, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        e = hub.watch(server)
        await hub.settle(e, 4.0)
        s = stack_of(e, id[:300])
        running = runs.running_on(server_id)
        latest = runs.latest(server_id, s.id)
        return {"stack": stack_json(s, e, host(server), rackoon.preferences.read_only, running, detail=True),
                "run": latest.json() if latest else None, "updatedAt": e.updated_at, "error": e.error}

    # --- container and stack actions

    @app.post("/api/servers/{server_id}/docker/container-action")
    async def container_action(server_id: str, body: ContainerActionIn, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        e = entry_of(server)
        c = next((x for x in e.containers if x.id == body.containerId), None)
        if c is None:
            raise ApiError(404, "noSuchContainer", "That container is gone.")
        action = DockerAction(body.action)
        intent = action.intent(c.id)
        if intent is None:
            raise ApiError(422, "invalid", "That container can't be addressed safely.")
        refuse_read_only()
        not_busy(server)
        stack = next((s for s in e.stacks if any(x.id == c.id for x in s.containers)), None)
        scope = stack.id if stack else docker.standalone_id(c.name)
        intro = note(f"$ docker {action.value} {c.name}")
        prompt = action_prompts.container(action, c)
        working = prompt.working if prompt else f"Starting {c.name}…"

        def launch(confirmation: Confirmation) -> dict[str, Any]:
            return start_run(server, scope, f"docker {action.value} {c.name}", working, body.cols, body.rows,
                             streamed(server, intent, confirmation, intro))

        if prompt is None:  # start runs straight away, still through the policy
            try:
                return launch(policy.confirm(intent))
            except PolicyError as x:
                raise ApiError(409, "readOnly", str(x)) from None

        async def run(confirmation: Confirmation) -> dict[str, Any]:
            return launch(confirmation)

        return propose(intent, run, destructive=prompt.destructive, title=prompt.title, message=prompt.message,
                       target=target(server))

    @app.post("/api/servers/{server_id}/docker/stack-action")
    async def stack_action(server_id: str, body: StackActionIn, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        e = entry_of(server)
        s = stack_of(e, body.stackId)
        refuse_read_only()
        not_busy(server)
        blocked = action_prompts.blocked_reason(s, rackoon.preferences.read_only, False)
        if blocked:
            raise ApiError(409, "blocked", blocked)
        action = ComposeAction.from_raw(body.action)
        assert action is not None
        intent = action.intent(s, body.service)
        if intent is None:
            raise ApiError(422, "invalid", "That service can't be rebuilt." if body.service else
                           "This stack's compose files can't be addressed safely.")
        prompt = action_prompts.rebuild(body.service, s) if body.service else action_prompts.stack(action, s)
        title = f"docker compose {action.raw}" + (f" {body.service}" if body.service else "")

        async def run(confirmation: Confirmation) -> dict[str, Any]:
            return start_run(server, s.id, title, prompt.working, body.cols, body.rows,
                             streamed(server, intent, confirmation))

        return propose(intent, run, destructive=prompt.destructive, title=prompt.title, message=prompt.message,
                       target=target(server))

    @app.post("/api/servers/{server_id}/docker/pull-image")
    async def pull_image(server_id: str, body: StackIn, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        s = stack_of(entry_of(server), body.stackId)
        refuse_read_only()
        not_busy(server)
        intent = StandaloneAction("pull").intent(s)
        prompt = action_prompts.pull(s)
        if intent is None or prompt is None:
            raise ApiError(422, "invalid", "This container runs an image that can't be pulled by name.")

        async def run(confirmation: Confirmation) -> dict[str, Any]:
            return start_run(server, s.id, f"docker pull {docker_view.image_name(s.containers[0].image)[0]}",
                             prompt.working, body.cols, body.rows, streamed(server, intent, confirmation))

        return propose(intent, run, title=prompt.title, message=prompt.message, target=target(server))

    @app.post("/api/servers/{server_id}/docker/delete")
    async def delete_stack(server_id: str, body: DeleteIn, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        e = entry_of(server)
        s = stack_of(e, body.stackId)
        refuse_read_only()
        not_busy(server)
        if s.is_standalone:
            standalone = StandaloneAction("remove", volumes=body.removeVolumes)
            intent = standalone.intent(s)
            if intent is None:
                raise ApiError(422, "invalid", "This container can't be addressed safely.")
            title = f"Delete {s.name}?"
            message = (f"The container {s.name} is stopped and removed" +
                       (", with its anonymous volumes." if body.removeVolumes else ". Named volumes and the image stay.")
                       + " This can't be undone.")
            typed: str | None = s.name
            run_title = f"docker rm {s.name}"
        else:
            removal = StackRemoval(body.removeVolumes, body.deleteFolder)
            intent = removal.intent(s)
            if intent is None:
                raise ApiError(422, "invalid", stack_actions_reason(s, body.deleteFolder))
            title = f"Delete {s.name}?"
            parts = ["Its containers and networks are removed with docker compose down."]
            if body.removeVolumes:
                parts.append("Its named volumes are deleted, with the data in them.")
            if body.deleteFolder:
                parts.append(f"Then the folder {s.working_dir} is deleted, with its compose file and everything else "
                             "in it.")
            parts.append("Images are kept. This can't be undone.")
            message = " ".join(parts)
            typed = s.name if removal.loses_data else None
            run_title = "docker compose down"

        async def run(confirmation: Confirmation) -> dict[str, Any]:
            e.removing[s.id] = s

            def done(r: Run) -> None:
                e.removing.pop(s.id, None)
                if r.phase == "succeeded":
                    e.created.pop(s.id, None)
                elif not s.is_standalone:
                    # Failed or cancelled part way: keep it on screen ("Not started" once docker stops reporting
                    # it), so its Output can be read and its files are not orphaned.
                    e.created[s.id] = replace(s, containers=[])

            try:
                return start_run(server, s.id, run_title, f"Deleting {s.name}…", body.cols, body.rows,
                                 streamed(server, intent, confirmation), done)
            except ApiError:
                e.removing.pop(s.id, None)
                raise

        return propose(intent, run, destructive=True, title=title, message=message, typed=typed,
                       target=target(server))

    @app.post("/api/servers/{server_id}/docker/shell", status_code=201)
    async def container_shell(server_id: str, body: ShellIn, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        e = entry_of(server)
        c = next((x for x in e.containers if x.id == body.containerId), None)
        command = docker.shell_command(body.containerId) if c is not None else None
        if c is None or command is None:
            raise ApiError(404, "noSuchContainer", "That container is gone.")
        try:
            return rackoon.terminals.open(server, body.cols, body.rows, command, title=c.service or c.name).json()
        except PermissionError as x:
            raise ApiError(409, "readOnly", str(x)) from None
        except OverflowError as x:
            raise ApiError(409, "tooManyTabs", str(x)) from None

    # --- runs

    def run_of(run_id: str) -> Run:
        run = runs.runs.get(run_id)
        if run is None:
            raise ApiError(404, "noSuchRun", "That output was closed.")
        return run

    @app.get("/api/servers/{server_id}/runs")
    async def list_runs(server_id: str, _: str = Auth) -> list[dict[str, Any]]:
        server_of(server_id)
        return [r.json() for r in runs.for_server(server_id)]

    @app.get("/api/runs/{run_id}")
    async def get_run(run_id: str, _: str = Auth) -> dict[str, Any]:
        return run_of(run_id).json()

    @app.post("/api/runs/{run_id}/cancel")
    async def cancel_run(run_id: str, _: str = Auth) -> dict[str, Any]:
        run_of(run_id)
        return {"ok": runs.cancel(run_id)}

    @app.delete("/api/runs/{run_id}")
    async def close_run(run_id: str, _: str = Auth) -> dict[str, Any]:
        run_of(run_id)
        if not runs.close(run_id):
            raise ApiError(409, "running", "Cancel it first.")
        return {"ok": True}

    async def socket_gate(ws: WebSocket) -> bool:
        if ws.headers.get("origin") is None or not same_origin(ws):
            await ws.close(code=4403)
            return False
        try:
            identify(ws)
        except ApiError:
            await ws.close(code=4401)
            return False
        return True

    async def pump(ws: WebSocket, client: Client) -> None:
        """Sends the client's frames until it is closed, while reading (and ignoring) what the browser sends."""
        async def writer() -> None:
            while (frame := await client.queue.get()) is not None:
                if isinstance(frame, bytes):
                    await ws.send_bytes(frame)
                else:
                    await ws.send_text(frame)
            await ws.close()

        sending = asyncio.create_task(writer())
        try:
            while True:
                message = await ws.receive()
                if message["type"] == "websocket.disconnect":
                    break
        except (WebSocketDisconnect, RuntimeError):
            pass
        finally:
            sending.cancel()
            # gather collects the writer's own cancellation; a cancellation of this task still propagates.
            await asyncio.gather(sending, return_exceptions=True)

    @app.websocket("/api/runs/{run_id}/ws")
    async def run_socket(ws: WebSocket, run_id: str) -> None:
        if not await socket_gate(ws):
            return
        if run_id not in runs.runs:
            await ws.close(code=4404)
            return
        await ws.accept()
        run, client = runs.attach(run_id)
        try:
            await pump(ws, client)
        finally:
            runs.detach(run, client)

    # --- logs

    @app.websocket("/api/servers/{server_id}/docker/logs/ws")
    async def logs_socket(ws: WebSocket, server_id: str) -> None:
        """Follows the given containers' logs, merged: each gets its own `docker logs -f` on its own pty, and
        closing the socket types Ctrl-C into each, so nothing is left running on the server."""
        if not await socket_gate(ws):
            return
        servers = store.load_servers()
        server = next((s for s in servers if s.id == server_id), None)
        e = hub.entries.get(server_id)
        ids = [i for i in ws.query_params.get("ids", "").split(",") if i][:20]
        followed = [c for c in (e.containers if e else []) if c.id in ids]
        if server is None or not followed:
            await ws.close(code=4404)
            return
        await ws.accept()
        client = Client()
        await follow_logs(server, followed, client, ws)

    async def follow_logs(server: Server, followed: list[docker.DockerContainer], client: Client,
                          ws: WebSocket) -> None:
        t = transport(server)
        pending: list[dict[str, Any]] = []
        counter = [0]
        flush_now = asyncio.Event()

        async def follow(c: docker.DockerContainer) -> None:
            command = docker.logs_command(c.id)
            if command is None:
                return
            buffer = logs.LogBuffer()
            source = c.service or c.name
            try:
                async with t.stream(command, cols=200, rows=50) as s:
                    async for chunk in s:
                        for line in buffer.append(chunk):
                            p = logs.parts(line)
                            counter[0] += 1
                            pending.append({"id": counter[0], "source": source, "time": p.time,
                                            "level": p.level.value if p.level else None, "message": p.message})
                        flush_now.set()
            except SSHError as x:
                client.send(json.dumps({"type": "error", "source": source, "message": str(x)}))

        async def flusher() -> None:
            while True:
                await flush_now.wait()
                await asyncio.sleep(0.1)  # batches, so a chatty container can't flood the page
                flush_now.clear()
                batch, pending[:] = pending[:1000], pending[1000:]
                if batch:
                    client.send(json.dumps({"type": "lines", "entries": batch}))
                if pending:
                    flush_now.set()

        async def followers() -> None:
            client.send(json.dumps({"type": "state", "live": True,
                                    "containers": [{"id": c.id, "source": c.service or c.name} for c in followed]}))
            await asyncio.gather(*(follow(c) for c in followed), return_exceptions=True)
            await asyncio.sleep(0.15)
            client.send(json.dumps({"type": "state", "live": False}))

        tasks = [asyncio.create_task(followers()), asyncio.create_task(flusher())]
        try:
            await pump(ws, client)
        finally:
            for task in tasks:
                task.cancel()  # each stream's exit sends Ctrl-C before its connection closes
            await asyncio.gather(*tasks, return_exceptions=True)

    # --- the compose/.env editor

    def file_of(s: DockerStack, path: str) -> EditableFile:
        f = next((f for f in stack_files.editable(s) or [] if f.path == path), None)
        if f is None:
            raise ApiError(422, "notEditable", "Only the stack's own compose files and its .env can be edited.")
        return f

    async def read_file(server: Server, s: DockerStack, f: EditableFile) -> stack_files.RemoteFileState:
        command = stack_files.read_command(f, s)
        if command is None:
            raise ApiError(422, "notEditable", "That file can't be addressed safely.")
        try:
            result = await transport(server).run(command, READ_TIMEOUT)
            if result.exit_code != 0:
                raise ApiError(502, "readFailed", result.stderr.strip() or f"Reading failed (exit {result.exit_code})")
            return stack_files.parse_file_read(result.stdout)
        except SSHError as x:
            raise ApiError(502, "connection", str(x)) from None
        except stack_files.StackFileError as x:
            raise ApiError(502, "readFailed", str(x)) from None

    def file_json(f: EditableFile, state: stack_files.RemoteFileState) -> dict[str, Any]:
        out: dict[str, Any] = {"path": f.path, "name": f.file_name, "isEnv": f.is_env}
        if isinstance(state, stack_files.RemoteFile):
            out.update(status="file", content=state.content, sha=state.sha256, mode=state.mode, owner=state.owner)
        elif isinstance(state, stack_files.Missing):
            out.update(status="missing", content="", sha=None)
        else:
            out.update(status="tooLarge", content=None, sha=None)
        return out

    @app.post("/api/servers/{server_id}/docker/files/read")
    async def files_read(server_id: str, body: FileIn, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        s = stack_of(entry_of(server), body.stackId)
        f = file_of(s, body.path)
        return file_json(f, await read_file(server, s, f))

    async def validate(server: Server, s: DockerStack, f: EditableFile, text: str) -> tuple[ValidationResult | None,
                                                                                             str | None]:
        command = stack_files.validate_command(f, text, s)
        if command is None:
            return None, "This file can't be checked safely."
        try:
            result = await transport(server).run(command, 60)
            return stack_files.validation_of(f, result.exit_code, result.stdout, result.stderr), None
        except (SSHError, stack_files.StackFileError) as x:
            return None, str(x)

    @app.post("/api/servers/{server_id}/docker/files/check")
    async def files_check(server_id: str, body: CheckIn, _: str = Auth) -> dict[str, Any]:
        """The editor's verdict on exactly this text: the server's own `docker compose config` (with `.env` also
        checked here first), the checklist, and whether Save may be pressed."""
        server = server_of(server_id)
        s = stack_of(entry_of(server), body.stackId)
        f = file_of(s, body.path)
        validation, error = None, None
        local = stack_files.env_syntax(body.text) if f.is_env else []
        if body.checkServer and body.text != body.original and not local:
            validation, error = await validate(server, s, f, body.text)
        v = editor_verdict(f, server, body.original, body.text, validation, error, not body.checkServer)
        return v

    def editor_verdict(f: EditableFile, server: Server, original: str, text: str, validation: ValidationResult | None,
                       error: str | None, checking: bool) -> dict[str, Any]:
        from rackoon.core import editor
        v = editor.verdict(f.is_env, server.name, original, text, validation, text if validation else None, error,
                           rackoon.preferences.read_only, checking)
        return {"rows": [row_json(r) for r in v.rows], "canSave": v.can_save, "blocked": v.blocked_reason,
                "changedLines": v.changed_lines, "errorLines": v.error_lines, "changeCount": v.change_count,
                "issues": [issue_json(i) for i in (validation.issues if validation else [])],
                "checked": validation is not None}

    @app.post("/api/servers/{server_id}/docker/files/save")
    async def files_save(server_id: str, body: SaveIn, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        e = entry_of(server)
        s = stack_of(e, body.stackId)
        f = file_of(s, body.path)
        refuse_read_only()
        if body.redeploy:
            not_busy(server)
        if body.original is not None and body.sha is not None and \
                hashlib.sha256(body.original.encode()).hexdigest() != body.sha:
            raise ApiError(422, "invalid", "The original text doesn't match the file that was opened. Reload it.")
        edit = FileEdit(f, body.original, body.sha, body.text)
        intent = stack_files.save_intent(edit, s)
        if intent is None:
            raise ApiError(422, "invalid", "That file can't be saved safely.")
        up = ComposeAction.UP.command(s) if body.redeploy else None
        if body.redeploy and up is None:
            raise ApiError(422, "invalid", "This stack can't be updated from here.")
        name = f.file_name

        async def run(confirmation: Confirmation) -> dict[str, Any]:
            result = await run_command(transport(server), intent, confirmation, SAVE_TIMEOUT)
            out = save_result(edit, result.exit_code, result.stdout, result.stderr)
            if out["outcome"] == "saved" and body.redeploy:
                out.update(up_after(server, s, body.cols, body.rows, note(f"Saved {name}.")))
            return out

        return propose(intent, run, title=f"Save {name} and update {s.name}?" if body.redeploy else f"Save {name}?",
                       message=f"The server checks it first, and nothing is written if that fails. The previous "
                       f"version is kept as {name}.rackoon.bak." + (" Then the stack is updated: containers whose "
                       "image or settings changed are recreated." if body.redeploy else ""), then=up,
                       target=target(server))

    def save_result(edit: FileEdit, code: int, stdout: str, stderr: str) -> dict[str, Any]:
        try:
            outcome = stack_files.save_outcome_of(edit, code, stdout, stderr)
        except stack_files.StackFileError as x:
            raise ApiError(502, "saveFailed", str(x)) from None
        if isinstance(outcome, stack_files.Saved):
            return {"outcome": "saved", "sha": outcome.sha256}
        if isinstance(outcome, stack_files.ChangedOnServer):
            return {"outcome": "changed", "message": f"{edit.file.file_name} changed on the server after you opened "
                    "it, so nothing was saved."}
        return {"outcome": "invalid", "issues": [issue_json(i) for i in outcome.issues],
                "message": f"The server refused {edit.file.file_name}, so it was not saved."}

    # --- add container

    async def existing_of(server: Server, s: DockerStack) -> Existing:
        files = stack_files.editable(s) or []
        compose = next((f for f in files if not f.is_env), None)
        env = next((f for f in files if f.is_env), None)
        if compose is None or env is None:
            return Existing(None, None, "", None, "This stack's files can't be edited")
        c = await read_file(server, s, compose)
        v = await read_file(server, s, env)
        if not isinstance(c, stack_files.RemoteFile):
            return Existing(None, None, "", None, f"{compose.file_name} is missing or too large to edit")
        if isinstance(v, stack_files.TooLarge):
            return Existing(None, None, "", None, ".env is too large to edit")
        return Existing(c.content, c.sha256, v.content if isinstance(v, stack_files.RemoteFile) else "",
                        v.sha256 if isinstance(v, stack_files.RemoteFile) else None)

    async def evaluate(server: Server, e: DockerEntry, d: AddDraft, wait: bool) -> dict[str, Any]:
        t = transport(server)
        stack = next((s for s in e.stacks if s.id == d.existing_name), None) if d.target == "existing" else None
        if d.target == "existing" and d.existing_name is not None and stack is None:
            raise ApiError(404, "noSuchStack", "That stack is gone.")
        ex = await existing_of(server, stack) if stack is not None else None
        key = add_container.check_key(d, ex)
        validation, check_error = None, None
        local_env = stack_files.env_syntax(add_container.env_text(d, ex))
        if add_container.compose_skip_reason(d, ex, server.name) is None and not local_env:
            try:
                if d.target == "new":
                    command = add_container.new_stack_check_command(add_container.plan_of(d, ex))
                    if command is not None:
                        r = await t.run(command, 60)
                        validation = add_container.check_result(r.exit_code, r.stdout, r.stderr)
                elif stack is not None and ex is not None and ex.compose is not None:
                    compose_file = next(f for f in stack_files.editable(stack) or [] if not f.is_env)
                    validation, check_error = await validate(server, stack, compose_file,
                                                             add_container.compose_text(d, ex))
            except (SSHError, stack_files.StackFileError) as x:
                check_error = str(x)
        image_status = None
        if not add_container.pasted(d) and d.spec.image and d.spec.image_problem is None:
            image_status = (await checks.wait_image(server, t, d.spec.image) if wait
                            else checks.image(server, t, d.spec.image))
        listening = await checks.listening(server, t)
        readings = Readings(validation, key if validation is not None else None, check_error, image_status, listening)
        rows = add_container.rows(d, ex, readings, e.containers, server.name)
        plan = add_container.plan_of(d, ex)
        return {
            "rows": [row_json(r) for r in rows],
            "blocked": add_container.blocked_reason(d, ex, readings, e.stacks, e.containers, server.name,
                                                    rackoon.preferences.read_only),
            "missingVariables": add_container.missing_variables(d, ex, readings),
            "compose": add_container.compose_text(d, ex), "env": add_container.env_text(d, ex),
            "directory": plan.directory if d.target == "new" else (stack.working_dir if stack else None),
            "checking": any(r.state.value == "running" for r in rows),
            "_existing": ex, "_stack": stack, "_plan": plan,
        }

    def public(result: dict[str, Any]) -> dict[str, Any]:
        return {k: v for k, v in result.items() if not k.startswith("_")}

    @app.get("/api/servers/{server_id}/docker/add")
    async def add_defaults(server_id: str, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        e = entry_of(server)
        return {"defaultParent": add_container.default_parent(e.stacks, server.user),
                "stacks": [{"id": s.id, "name": s.name, "workingDir": s.working_dir}
                           for s in add_container.existing_candidates(e.stacks)],
                "restartPolicies": [p.value for p in RestartPolicy]}

    @app.post("/api/servers/{server_id}/docker/add/evaluate")
    async def add_evaluate(server_id: str, body: DraftIn, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        return public(await evaluate(server, entry_of(server), body.draft(), wait=False))

    @app.post("/api/servers/{server_id}/docker/add/deploy")
    async def add_deploy(server_id: str, body: DeployIn, _: str = Auth) -> dict[str, Any]:
        """Checks the draft again, exactly as it will be written, and proposes the create or the saves."""
        server = server_of(server_id)
        e = entry_of(server)
        refuse_read_only()
        if body.start:
            not_busy(server)
        d = body.draft.draft()
        result = await evaluate(server, e, d, wait=True)
        if result["blocked"]:
            raise ApiError(409, "blocked", result["blocked"])
        t = transport(server)
        start = body.start
        if d.target == "new":
            plan: add_container.NewStackPlan = result["_plan"]
            intent = add_container.new_stack_intent(plan)
            stack = plan.stack
            if intent is None or stack is None or plan.directory is None:
                raise ApiError(422, "invalid", "That stack can't be created safely.")
            new_stack = stack

            async def create(confirmation: Confirmation) -> dict[str, Any]:
                r = await run_command(t, intent, confirmation, SAVE_TIMEOUT)
                try:
                    outcome = add_container.create_outcome_of(r.exit_code, r.stdout, r.stderr)
                except stack_files.StackFileError as x:
                    raise ApiError(502, "createFailed", str(x)) from None
                if outcome == "exists":
                    return {"outcome": "exists", "message": f"{plan.directory} already exists on {server.name}, so "
                            "nothing was written. Choose another name or folder."}
                if isinstance(outcome, ValidationResult):
                    return {"outcome": "invalid", "issues": [issue_json(i) for i in outcome.issues],
                            "message": f"{server.name} refused the files, so nothing was created."}
                e.created[new_stack.id] = new_stack
                hub.poke(server.id)
                out: dict[str, Any] = {"outcome": "created", "stackId": new_stack.id}
                if start:
                    out.update(up_after(server, new_stack, body.cols, body.rows, note(f"Created {plan.directory}.")))
                return out

            return propose(intent, create, title=f"Create {plan.name} and start it?" if start else f"Create {plan.name}?",
                           message=f"Creates {plan.directory} on {server.name} with the files below. The server "
                           "checks them first and removes everything it made if that fails." +
                           (" Then the stack is started with docker compose up -d, which pulls any images it needs."
                            if start else ""), then=ComposeAction.UP.command(stack) if start else None,
                           target=target(server))

        ex: Existing | None = result["_existing"]
        existing: DockerStack | None = result["_stack"]
        if ex is None or existing is None or ex.compose is None:
            raise ApiError(409, "blocked", "The stack's files could not be read.")
        files = stack_files.editable(existing) or []
        compose_file = next(f for f in files if not f.is_env)
        env_file = next(f for f in files if f.is_env)
        edits = []
        env = add_container.env_text(d, ex)
        if env != ex.env:
            edits.append(FileEdit(env_file, ex.env if ex.env_sha else None, ex.env_sha, env))
        edits.append(FileEdit(compose_file, ex.compose, ex.compose_sha, add_container.compose_text(d, ex)))
        intents = [stack_files.save_intent(x, existing) for x in edits]
        if any(i is None for i in intents):
            raise ApiError(422, "invalid", "Those files can't be saved safely.")
        steps = [(x, i) for x, i in zip(edits, intents, strict=True) if i is not None]
        preview = "\n\n".join(f"{x.file.file_name}\n{i.preview}" for x, i in reversed(steps))
        composite = Intent(f"Add {d.spec.name} to {existing.name}", "\n".join(i.command for _, i in steps),
                           Risk.MUTATE, preview)
        target_stack = existing

        async def save_all(confirmation: Confirmation) -> dict[str, Any]:
            try:
                policy.authorize(composite, confirmation)
            except PolicyError as x:
                raise ApiError(409, "readOnly", str(x)) from None
            # .env first: if the compose save is then refused, a spare variable is harmless.
            for edit, intent in steps:
                try:
                    sub = policy.confirm(intent)  # shown as part of the sheet just confirmed
                except PolicyError as x:
                    raise ApiError(409, "readOnly", str(x)) from None
                r = await run_command(t, intent, sub, SAVE_TIMEOUT)
                out = save_result(edit, r.exit_code, r.stdout, r.stderr)
                if out["outcome"] != "saved":
                    return out
            hub.poke(server.id)
            done: dict[str, Any] = {"outcome": "saved", "stackId": target_stack.id}
            if start:
                done.update(up_after(server, target_stack, body.cols, body.rows, note("Saved the stack's files.")))
            return done

        return propose(composite, save_all,
                       title=f"Add {d.spec.name} to {existing.name} and start it?" if start else
                       f"Add {d.spec.name} to {existing.name}?",
                       message="The server checks each file first, and nothing is written if that fails. The previous "
                       "versions are kept as .rackoon.bak." + (" Then the stack is updated: the new container starts, "
                       "and any container whose settings changed is recreated." if start else ""),
                       then=ComposeAction.UP.command(existing) if start else None, target=target(server))

    # --- bookmarks

    def bookmarks_of(e: DockerEntry) -> list[dict[str, Any]]:
        if e.snapshot is None:
            return []
        return [{"stackId": s.id, "stackName": s.name, "service": c.service, "container": c.name,
                 "containerId": c.id, "bookmark": to_json(b), "address": docker_view.short_address(b),
                 "scope": docker_view.link_scope(b.href).value, "origin": favicon.origin(b.href),
                 "editable": c.service is not None and stack_files.editable(s) is not None}
                for s, c, b in docker_view.bookmark_items(e.snapshot)]

    @app.post("/api/servers/{server_id}/docker/bookmark")
    async def bookmark_save(server_id: str, body: BookmarkIn, _: str = Auth) -> dict[str, Any]:
        """Writes (or removes) a service's Homepage labels as line edits of the compose file that defines it."""
        server = server_of(server_id)
        e = entry_of(server)
        s = stack_of(e, body.stackId)
        refuse_read_only("change bookmarks")
        if body.apply:
            not_busy(server)
        files = [f for f in stack_files.editable(s) or [] if not f.is_env]
        if not files or not any(c.service == body.service for c in s.containers):
            raise ApiError(422, "notEditable", "Bookmarks are written into a compose stack's own compose file.")
        if body.bookmark is not None and not docker.is_valid_url(body.bookmark.href.strip()):
            raise ApiError(422, "invalid", "Enter an http:// or https:// address.")
        found: tuple[EditableFile, stack_files.RemoteFile] | None = None
        for f in files:
            state = await read_file(server, s, f)
            if isinstance(state, stack_files.RemoteFile) and compose_edit.defines_service(body.service, state.content):
                found = (f, state)
                break
        if found is None:
            raise ApiError(422, "notFound", f"No compose file of {s.name} defines {body.service}.")
        f, current = found
        b = body.bookmark
        changes = (compose_edit.bookmark_changes(Bookmark(b.href.strip(), b.name, b.group, b.icon, b.description))
                   if b is not None else compose_edit.bookmark_removal())
        try:
            text = compose_edit.setting_labels(changes, body.service, current.content)
        except compose_edit.ComposeEditError as x:
            raise ApiError(422, "cannotEdit", str(x)) from None
        if text == current.content:
            raise ApiError(422, "unchanged", "Nothing to change.")
        edit = FileEdit(f, current.content, current.sha256, text)
        intent = stack_files.save_intent(edit, s)
        if intent is None:
            raise ApiError(422, "invalid", "That file can't be saved safely.")
        what = f"Remove the bookmark from {body.service}" if b is None else f"Bookmark {body.service}"

        async def run(confirmation: Confirmation) -> dict[str, Any]:
            result = await run_command(transport(server), intent, confirmation, SAVE_TIMEOUT)
            out = save_result(edit, result.exit_code, result.stdout, result.stderr)
            if out["outcome"] == "saved":
                hub.poke(server.id)
                if body.apply:
                    out.update(up_after(server, s, body.cols, body.rows, note(f"Saved {f.file_name}.")))
            return out

        return propose(intent, run, title=f"{what} and update {s.name}?" if body.apply else f"{what}?",
                       message=f"The labels are written into {f.file_name}; the server checks the file first, and "
                       f"the old one is kept as {f.file_name}.rackoon.bak." + (
                           f" Then the stack is updated, which recreates {body.service} (a few seconds of downtime) "
                           "so the change shows up." if body.apply else
                           " It takes effect the next time the stack is updated."),
                       then=ComposeAction.UP.command(s) if body.apply else None, target=target(server))

    # --- the dashboard's fleet view

    @app.get("/api/fleet/docker")
    async def fleet_docker(watch: bool = False, _: str = Auth) -> dict[str, Any]:
        """Every answering server's Docker (never an unanswering or untrusted one), for the Dashboard's Docker and
        Bookmarks pages."""
        rows = []
        entries = []
        for server in store.load_servers():
            m = rackoon.monitor.entries.get(server.id)
            if m is None or m.connection != "ok":
                continue
            entries.append((server, hub.watch(server) if watch else hub.entry(server)))
        if watch:
            await asyncio.gather(*(hub.settle(e, 4.0) for _, e in entries))
        for server, e in entries:
            st = state_json(e, host(server), rackoon.preferences.read_only, runs.running_on(server.id))
            rows.append({"server": {"id": server.id, "name": server.name}, **st, "bookmarks": bookmarks_of(e),
                         "linkHost": link_host(host(server))})
        return {"servers": rows}

    # --- favicons

    def known_origins() -> set[str]:
        out: set[str] = set()
        for e in hub.entries.values():
            for item in bookmarks_of(e):
                if item["origin"]:
                    out.add(item["origin"])
            o = host(e.server)
            where = link_host(o)
            for s in e.stacks:
                port = docker_view.main_web_port(s)
                if port and where:
                    origin = favicon.origin(f"http://{where}:{port}")
                    if origin:
                        out.add(origin)
        return out

    @app.get("/api/favicons")
    async def get_favicon(href: str, refresh: bool = False, _: str = Auth) -> Response:
        """A bookmark's (or a stack link's) site icon, fetched by this server and cached. Only addresses that Docker
        reported are fetched, so this can't be used to reach anything else."""
        origin = favicon.origin(href[:2048])
        if origin is None or origin not in known_origins():
            raise ApiError(404, "noIcon", "No icon for that address.")
        icon = await rackoon.favicons.get(origin, refresh)
        if icon is None:
            return Response(status_code=204, headers={"Cache-Control": "private, max-age=3600"})
        data, kind = icon
        headers = {"Cache-Control": "private, max-age=86400",
                   "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; sandbox"}
        return Response(content=data, media_type=kind, headers=headers)


def stack_actions_reason(s: DockerStack, delete_folder: bool) -> str:
    from rackoon.core.stack_actions import folder_problem
    if delete_folder:
        problem = folder_problem(s)
        if problem:
            return problem
    return docker_view.compose_blocked_reason(s) or "This stack can't be addressed safely."
