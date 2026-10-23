"""Files (stage W7): browse a server's folders, download, upload, new folder, rename, delete. The browser is the other
end, so bytes pass through this server: they travel on the standard input or output of a plain remote command over the
shared connection (never sftp/scp, never inside a command), exactly as on the Mac.

An upload is a change: the page proposes it (name, folder and exact size), the user confirms the command on the
sheet, and the confirmation hands back a one-use upload token for that exact command; the file is then PUT as raw bytes.
The server writes to `.<name>.rackoon-part` and moves it into place only if exactly that many bytes arrived, so a
cancelled or dropped upload never replaces a real file. Read-only switched on in between still blocks it. Downloads are
reads: a file as it is, a folder as a tar of its contents. New folder and rename never replace anything; deleting a
folder is refused high up, for service data and home settings, and asks for its name to be typed.
"""

from __future__ import annotations

import secrets
import time
from collections.abc import AsyncIterable, AsyncIterator, Callable
from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, Literal, Protocol
from urllib.parse import quote

from fastapi import Depends, FastAPI, Request
from fastapi.responses import Response, StreamingResponse
from pydantic import Field

from rackoon.core import remote_files as rf
from rackoon.core.jsonmodel import to_json
from rackoon.core.models import Server
from rackoon.core.policy import Confirmation, Intent, PolicyError, Risk
from rackoon.ssh import CommandResult, SSHError

from .actions import ActionError
from .connections import TrustError
from .errors import ApiError, Body

if TYPE_CHECKING:
    from .api import Rackoon

UPLOAD_PREFIX = "/api/files/uploads/"
MAX_UPLOAD = 8 * 1024**3
TOKEN_SECONDS = 600


class Transfers(Protocol):
    async def run(self, command: str, timeout: float, input: str | None = None) -> CommandResult: ...

    async def upload(self, command: str, chunks: AsyncIterable[bytes], timeout: float) -> CommandResult: ...

    def download(self, command: str) -> AsyncIterator[bytes]: ...


class UploadIn(Body):
    directory: str = Field(max_length=4096)
    name: str = Field(max_length=255)
    size: int = Field(ge=0, le=MAX_UPLOAD)


class OpIn(Body):
    kind: Literal["mkdir", "rename", "delete"]
    directory: str = Field(max_length=4096)
    name: str = Field(max_length=255)
    to: str | None = Field(default=None, max_length=255)
    isFolder: bool = False


@dataclass
class Upload:
    server_id: str
    intent: Intent
    confirmation: Confirmation
    size: int
    expires: float


def register(app: FastAPI, rackoon: Rackoon, authenticated: Callable[[Request], str],
             find: Callable[[list[Server], str], Server]) -> None:
    Auth = Depends(authenticated)
    store = rackoon.store
    policy = rackoon.preferences.policy
    uploads: dict[str, Upload] = {}

    def server_of(server_id: str) -> Server:
        return find(store.load_servers(), server_id)

    def transport(server: Server) -> Transfers:
        try:
            t: Any = rackoon.connections.transport(server)
        except TrustError as e:
            raise ApiError(e.status, e.code, str(e)) from None
        if not hasattr(t, "upload"):
            raise ApiError(501, "unavailable", "File transfers aren't available for this connection.")
        out: Transfers = t
        return out

    def propose(intent: Intent, run: Callable[[Confirmation], Any], **sheet: Any) -> dict[str, Any]:
        try:
            return {"pending": rackoon.actions.propose(intent, run, **sheet).json()}
        except ActionError as e:
            raise ApiError(e.status, e.code, str(e)) from None

    @app.get("/api/servers/{server_id}/files/home")
    async def home(server_id: str, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        try:
            r = await transport(server).run(rf.home_command(), 10)
        except SSHError as e:
            raise ApiError(502, "connection", str(e)) from None
        path = r.stdout.strip()
        return {"path": path if r.exit_code == 0 and path.startswith("/") else "/"}

    @app.get("/api/servers/{server_id}/files/list")
    async def listing(server_id: str, path: str, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        command = rf.list_command(path[:4096])
        if command is None:
            raise ApiError(422, "invalid", "That is not an absolute path.")
        try:
            r = await transport(server).run(command, 20)
        except SSHError as e:
            raise ApiError(502, "connection", str(e)) from None
        if r.exit_code != 0:
            raise ApiError(404 if r.exit_code in (3, 4) else 502, "unreadable", rf.error_of(r.exit_code, r.stderr, path))
        found = rf.parse_listing(r.stdout)
        if found is None:
            raise ApiError(502, "unreadable", "The answer wasn't a folder listing.")
        entries = sorted(found.entries, key=lambda e: (not e.is_directory, e.name.casefold()))
        return {"path": found.path, "parent": rf.parent(found.path), "truncated": found.truncated,
                "crumbs": [{"name": n, "path": p} for n, p in rf.crumbs(found.path)],
                "entries": [{**to_json(e), "isDirectory": e.is_directory,
                             "deleteProblem": rf.delete_problem(rf.join(found.path, e.name)) if e.is_directory else None}
                            for e in entries]}

    @app.get("/api/servers/{server_id}/files/free-name")
    async def free_name(server_id: str, directory: str, name: str, _: str = Auth) -> dict[str, Any]:
        """For Keep Both: "report 2.pdf", the first name the folder does not have."""
        found = await listing(server_id, directory)
        return {"name": rf.keep_both_name(name[:255], {e["name"] for e in found["entries"]})}

    # --- upload: propose, confirm, then PUT the bytes with the token

    @app.post("/api/servers/{server_id}/files/upload")
    async def propose_upload(server_id: str, body: UploadIn, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        command = rf.upload_file_command(body.directory, body.name, body.size)
        if command is None:
            raise ApiError(422, "badName", f"“{body.name}” has a character in its name that can't be sent safely.")
        intent = Intent(f"Upload {body.name} to {body.directory}", command, Risk.MUTATE)

        async def confirmed(confirmation: Confirmation) -> dict[str, Any]:
            now = rackoon.clock()
            for k in [k for k, u in uploads.items() if u.expires <= now]:
                del uploads[k]
            token = secrets.token_urlsafe(24)
            uploads[token] = Upload(server.id, intent, confirmation, body.size, now + TOKEN_SECONDS)
            return {"upload": token}

        return propose(intent, confirmed, title=f"Upload {body.name}?", target=f"{server.user or 'root'}@{server.host}",
                       message=f"Writes {body.size:,} bytes to {rf.join(body.directory, body.name)}. If a file with "
                       "that name is there, it is replaced (keeping its owner and mode); nothing changes unless the "
                       "whole file arrives.")

    @app.put(UPLOAD_PREFIX + "{token}")
    async def put_upload(token: str, request: Request, _: str = Auth) -> dict[str, Any]:
        u = uploads.pop(token, None)
        if u is None or u.expires <= rackoon.clock():
            raise ApiError(409, "expired", "This upload expired. Start it again.")
        server = server_of(u.server_id)
        try:
            policy.authorize(u.intent, u.confirmation)  # Read-only switched on since the sheet still blocks it
        except PolicyError as e:
            raise ApiError(409, "readOnly", str(e)) from None
        length = request.headers.get("content-length")
        if length is not None and (not length.isdigit() or int(length) != u.size):
            raise ApiError(422, "sizeMismatch", "The file is not the size that was confirmed.")

        async def body() -> AsyncIterator[bytes]:
            async for chunk in request.stream():
                if chunk:
                    yield chunk
        started = time.monotonic()
        try:
            r = await transport(server).upload(u.intent.command, body(), timeout=max(600.0, u.size / 50_000))
        except SSHError as e:
            raise ApiError(502, "connection", str(e)) from None
        if r.exit_code != 0:
            raise ApiError(409 if r.exit_code == 5 else 502, "uploadFailed",
                           r.stderr.strip() or f"The server answered with status {r.exit_code}.")
        return {"ok": True, "seconds": time.monotonic() - started}

    # --- download (a read)

    @app.get("/api/servers/{server_id}/files/download")
    async def download(server_id: str, directory: str, name: str, folder: bool = False, _: str = Auth) -> Response:
        server = server_of(server_id)
        command = rf.download_command(directory[:4096], name[:255], folder)
        if command is None:
            raise ApiError(422, "badName", "That name can't be sent safely.")
        chunks = transport(server).download(command)
        try:
            first = await chunks.__anext__()
        except StopAsyncIteration:
            first = b""
        except SSHError as e:
            raise ApiError(404, "unreadable", str(e)) from None

        async def rest() -> AsyncIterator[bytes]:
            if first:
                yield first
            try:
                async for chunk in chunks:
                    yield chunk
            except SSHError:
                return  # the browser sees a short download; nothing on the server changed
        filename = name + (".tar" if folder else "")
        disposition = f"attachment; filename*=UTF-8''{quote(filename)}"
        return StreamingResponse(rest(), media_type="application/x-tar" if folder else "application/octet-stream",
                                 headers={"Content-Disposition": disposition})

    # --- new folder, rename, delete

    @app.post("/api/servers/{server_id}/files/op")
    async def operation(server_id: str, body: OpIn, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        op = rf.FileOperation(body.kind, body.directory, body.name, body.to, body.isFolder)
        command = op.command
        if command is None:
            problem = rf.delete_problem(rf.join(body.directory, body.name)) if body.kind == "delete" and body.isFolder \
                else None
            raise ApiError(422, "invalid", problem or "That change can't be made safely from here.")
        intent = Intent(op.summary, command, Risk.MUTATE)

        async def confirmed(confirmation: Confirmation) -> dict[str, Any]:
            try:
                policy.authorize(intent, confirmation)
                r = await transport(server).run(intent.command, 120)
            except PolicyError as e:
                raise ApiError(409, "readOnly", str(e)) from None
            except SSHError as e:
                raise ApiError(502, "connection", str(e)) from None
            if r.exit_code != 0:
                return {"ok": False, "message": r.stderr.strip() or f"The server answered with status {r.exit_code}."}
            return {"ok": True}

        titles = {"mkdir": f"Create the folder {body.name}?", "rename": f"Rename {body.name} to {body.to}?",
                  "delete": f"Delete {body.name}?"}
        deleting = body.kind == "delete"
        return propose(intent, confirmed, title=titles[body.kind], target=f"{server.user or 'root'}@{server.host}",
                       destructive=deleting, typed=body.name if deleting and body.isFolder else None,
                       message=("The folder and everything in it are deleted. This can't be undone." if deleting and
                                body.isFolder else "The file is deleted (a link is removed, never followed). This "
                                "can't be undone." if deleting else "Nothing that is already there is replaced."))
