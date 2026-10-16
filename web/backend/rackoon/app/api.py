"""The web backend's HTTP API (stage W2): signing in, saved servers, importing from ssh_config, host-key trust and
SSH keys. JSON in and out, camelCase like spec/models.schema.json; errors are `{"error": code, "message": text}`.

Every request but /api/health and the sign-in endpoints needs a session cookie (`__Host-rackoon`: HttpOnly, Secure,
SameSite=Strict) or a forward-auth header from a trusted proxy. Requests that change something also need the
`X-Rackoon-CSRF` header (from GET /api/auth/state), a same-origin `Origin` when the browser sends one, and a JSON
body. Nothing here runs a command on a server: changing a server goes through the action policy (stages W5 on).
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import hmac
import logging
import tempfile
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager
from dataclasses import replace
from pathlib import Path
from typing import Any

import asyncssh

from fastapi import Depends, FastAPI, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field

from rackoon.core import ssh_config
from rackoon.core.jsonmodel import to_json
from rackoon.core.models import Server, server_input_problem
from rackoon.ssh import HostKey

from rackoon.core import server_list

from . import security
from .actions import ActionCenter, ActionError
from .connections import CheckResult, Connections, Scanner, TrustError, key_id_of
from .demo import SERVERS as DEMO_SERVERS
from .demo import DemoConnections
from .keys import KeyError_, KeyStore
from .monitor import Monitor
from .preferences import Preferences
from .settings import Settings
from .static import mount_frontend
from .storage import DataStore, KeyInfo, new_id

log = logging.getLogger("rackoon.api")

COOKIE = "__Host-rackoon"
CSRF_HEADER = "x-rackoon-csrf"
UNSAFE = {"POST", "PUT", "PATCH", "DELETE"}
MAX_BODY = 64 * 1024
USER = "admin"


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str, headers: dict[str, str] | None = None) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.headers = headers


class Body(BaseModel):
    model_config = ConfigDict(extra="forbid")


class SetupIn(Body):
    token: str = Field(max_length=200)
    password: str = Field(max_length=1024)


class LoginIn(Body):
    password: str = Field(max_length=1024)
    code: str | None = Field(default=None, max_length=16)


class PasswordIn(Body):
    current: str = Field(max_length=1024)
    new: str = Field(max_length=1024)


class CodeIn(Body):
    code: str = Field(max_length=16)


class DisableTotpIn(Body):
    password: str = Field(max_length=1024)
    code: str = Field(max_length=16)


class ServerIn(Body):
    name: str = Field(max_length=200)
    host: str = Field(max_length=255)
    user: str | None = Field(default=None, max_length=64)
    port: int | None = None
    keyId: str | None = Field(default=None, max_length=64)


class OrderIn(Body):
    ids: list[str] = Field(max_length=1000)


class ImportIn(Body):
    aliases: list[str] = Field(max_length=200)
    importKeys: bool = True


class TrustIn(Body):
    scanId: str = Field(max_length=64)
    fingerprint: str = Field(max_length=100)


class MoveIn(Body):
    onto: str | None = Field(default=None, max_length=64)
    by: int | None = Field(default=None, ge=-1000, le=1000)


class AppearanceIn(Body):
    selection: str = Field(max_length=100)


class SafetyIn(Body):
    readOnly: bool | None = None
    auto: str | None = Field(default=None, max_length=20)


class GenerateKeyIn(Body):
    name: str = Field(max_length=200)


class ImportKeyIn(Body):
    name: str = Field(max_length=200)
    privateKey: str = Field(max_length=40_000)
    passphrase: str | None = Field(default=None, max_length=1024)


class Rackoon:
    """Everything the API works with, made once per app."""

    def __init__(self, settings: Settings, scanner: Scanner | None, clock: Callable[[], float]) -> None:
        self.settings = settings
        self.clock = clock
        self.demo = settings.demo
        data_dir = Path(tempfile.mkdtemp(prefix="rackoon-demo-")) if self.demo else settings.data_dir
        self.store = DataStore(data_dir)
        managed = security.password_from_file(settings.admin_password_file) if settings.admin_password_file else None
        self.account = security.Account(self.store.load_auth(), self.store.save_auth, managed)
        self.sessions = security.SessionStore(clock=clock)
        self.limiter = security.RateLimiter(clock=clock)
        self.secret = self.store.secret()
        self.keys = KeyStore(self.store)
        if self.demo:
            self.connections: Connections = DemoConnections(self.store, self.keys)
            self.store.save_servers([server for server, _ in DEMO_SERVERS])
        elif scanner:
            self.connections = Connections(self.store, self.keys, scanner)
        else:
            self.connections = Connections(self.store, self.keys)
        self.preferences = Preferences(self.store, clock)
        self.actions = ActionCenter(self.preferences.policy, clock)
        self.monitor = Monitor(self.store, self.connections, clock)
        self.monitor.sync(self.store.load_servers())
        self.setup_token: security.SetupToken | None = None
        if self.demo:
            log.warning("Demo mode: made-up servers in %s; nothing is sent anywhere, and no sign-in is needed.", data_dir)
        elif self.account.needs_setup:
            self.setup_token = security.SetupToken()
            self.store.write_setup_token(self.setup_token.value)
            log.warning("No admin password is set. Open Rackoon and enter this one-time setup token: %s "
                        "(also in %s)", self.setup_token.value, settings.data_dir / "setup-token")
        else:
            self.store.write_setup_token(None)

    # --- who is asking

    def client_address(self, request: Request) -> str:
        """The peer, or the last address before our trusted proxies in X-Forwarded-For."""
        peer = request.client.host if request.client else ""
        if not self.settings.is_trusted_proxy(peer):
            return peer
        hops = [h.strip() for h in request.headers.get("x-forwarded-for", "").split(",") if h.strip()]
        for hop in reversed(hops):
            if not self.settings.is_trusted_proxy(hop):
                return hop
        return peer

    def forward_user(self, request: Request) -> str | None:
        header = self.settings.forward_auth_header
        if not header:
            return None
        value = request.headers.get(header, "").strip()
        if not value:
            return None
        peer = request.client.host if request.client else ""
        if not self.settings.is_trusted_proxy(peer):
            log.warning("ignored %s from untrusted %s", header, peer)
            return None
        if self.settings.forward_auth_users and value not in self.settings.forward_auth_users:
            return None
        return value

    def forward_csrf(self, user: str) -> str:
        return hmac.new(self.secret, f"csrf:{user}".encode(), hashlib.sha256).hexdigest()


def _same_origin(request: Request, rackoon: Rackoon) -> bool:
    origin = request.headers.get("origin")
    if origin is None:
        return True
    host = request.headers.get("host", "")
    peer = request.client.host if request.client else ""
    if rackoon.settings.is_trusted_proxy(peer):
        host = request.headers.get("x-forwarded-host", host).split(",")[0].strip()
    netloc = origin.split("://", 1)[-1].rstrip("/")
    return origin != "null" and netloc.lower() == host.lower()


def _server_json(server: Server, keys_dir: Path) -> dict[str, Any]:
    out: dict[str, Any] = to_json(server)
    out["keyId"] = key_id_of(server, keys_dir)
    return out


def _key_json(key: KeyInfo) -> dict[str, Any]:
    out: dict[str, Any] = to_json(key)
    return out


def _check_json(result: CheckResult) -> dict[str, Any]:
    out: dict[str, Any] = {"status": result.status, "message": result.message}
    if result.host_key is not None:
        out["hostKey"] = {"keyType": result.host_key.key_type, "fingerprint": result.host_key.fingerprint}
    if result.trusted is not None:
        out["trusted"] = {"keyType": result.trusted.key_type, "fingerprint": result.trusted.fingerprint}
    if result.scan_id is not None:
        out["scanId"] = result.scan_id
    return out


def create_app(settings: Settings, scanner: Scanner | None = None,
               clock: Callable[[], float] = time.time, poll: bool = True) -> FastAPI:
    """`poll=False` keeps the monitor from contacting servers (tests that use made-up addresses)."""
    rackoon = Rackoon(settings, scanner, clock)

    async def idle_watch() -> None:
        while True:
            await asyncio.sleep(15)
            if rackoon.preferences.check_idle(busy=rackoon.actions.running > 0):
                log.info("Read-only turned itself back on after %s", rackoon.preferences.auto.label.lower())

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        if poll:
            rackoon.monitor.start()
        idle = asyncio.create_task(idle_watch())
        yield
        idle.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await idle
        await rackoon.monitor.stop()
        await rackoon.connections.close()

    app = FastAPI(title="Rackoon", docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)
    app.state.rackoon = rackoon

    @app.exception_handler(ApiError)
    async def api_error(_: Request, e: ApiError) -> JSONResponse:
        return JSONResponse({"error": e.code, "message": e.message}, status_code=e.status, headers=e.headers)

    @app.exception_handler(RequestValidationError)
    async def invalid(_: Request, e: RequestValidationError) -> JSONResponse:
        first = e.errors()[0] if e.errors() else {}
        where = ".".join(str(p) for p in first.get("loc", []) if p != "body")
        return JSONResponse({"error": "invalid", "message": f"{where}: {first.get('msg', 'invalid')}".strip(": ")},
                            status_code=422)

    @app.middleware("http")
    async def guard(request: Request, call_next: Callable[[Request], Awaitable[Response]]) -> Response:
        if request.method in UNSAFE and request.url.path.startswith("/api/"):
            if not _same_origin(request, rackoon):
                return JSONResponse({"error": "crossOrigin", "message": "Cross-origin requests are refused."}, 403)
            length = request.headers.get("content-length")
            if length and (not length.isdigit() or int(length) > MAX_BODY):
                return JSONResponse({"error": "tooLarge", "message": "The request is too large."}, 413)
            if length not in (None, "0"):
                kind = request.headers.get("content-type", "").split(";")[0].strip().lower()
                if kind != "application/json":
                    return JSONResponse({"error": "unsupported", "message": "Send JSON."}, 415)
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["X-Frame-Options"] = "DENY"
        if request.url.path.startswith("/api/"):
            response.headers["Cache-Control"] = "no-store"
        return response

    def authenticated(request: Request) -> str:
        """The signed-in user; for a change also checks the CSRF header."""
        forward = "demo" if rackoon.demo else rackoon.forward_user(request)
        if forward is not None:
            expected = rackoon.forward_csrf(forward)
            user = forward
        else:
            session = rackoon.sessions.get(request.cookies.get(COOKIE))
            if session is None:
                raise ApiError(401, "signedOut", "Sign in first.")
            expected = session.csrf
            user = session.user
        if request.method in UNSAFE:
            sent = request.headers.get(CSRF_HEADER, "")
            if not hmac.compare_digest(sent.encode(), expected.encode()):
                raise ApiError(403, "csrf", "Missing or wrong CSRF token. Reload the page.")
            rackoon.preferences.touch()
        return user

    Auth = Depends(authenticated)

    def start_session(response: Response) -> str:
        token, session = rackoon.sessions.create(USER)
        response.set_cookie(COOKIE, token, max_age=security.SESSION_MAX_SECONDS, path="/", secure=True,
                            httponly=True, samesite="strict")
        return session.csrf

    def limited(request: Request) -> str:
        client = rackoon.client_address(request)
        wait = rackoon.limiter.retry_after(client)
        if wait is not None:
            raise ApiError(429, "tooManyAttempts", "Too many failed attempts. Try again later.",
                           {"Retry-After": str(int(wait) + 1)})
        return client

    # --- health and auth

    @app.get("/api/health")
    async def health() -> dict[str, Any]:
        return {"ok": True}

    @app.get("/api/auth/state")
    async def auth_state(request: Request) -> dict[str, Any]:
        account = rackoon.account
        state: dict[str, Any] = {"setupRequired": account.needs_setup, "passwordManaged": account.password_managed,
                                 "totpEnabled": account.totp_enabled, "authenticated": False,
                                 "forwardAuth": rackoon.settings.forward_auth_header is not None, "demo": rackoon.demo}
        forward = "demo" if rackoon.demo else rackoon.forward_user(request)
        if forward is not None:
            state.update(authenticated=True, user=forward, via="demo" if rackoon.demo else "forwardAuth",
                         csrf=rackoon.forward_csrf(forward), setupRequired=False)
        else:
            session = rackoon.sessions.get(request.cookies.get(COOKIE))
            if session is not None:
                state.update(authenticated=True, user=session.user, via="session", csrf=session.csrf)
        return state

    @app.post("/api/auth/setup")
    async def setup(body: SetupIn, request: Request, response: Response) -> dict[str, Any]:
        client = limited(request)
        token = rackoon.setup_token
        if not rackoon.account.needs_setup or token is None:
            raise ApiError(409, "alreadySetUp", "The admin password is already set.")
        if not token.matches(body.token):
            rackoon.limiter.failed(client)
            raise ApiError(403, "badToken", "That is not the setup token from the log.")
        problem = security.password_problem(body.password)
        if problem:
            raise ApiError(422, "weakPassword", problem)
        rackoon.account.set_password(body.password)
        token.used()
        rackoon.setup_token = None
        rackoon.store.write_setup_token(None)
        return {"csrf": start_session(response)}

    @app.post("/api/auth/login")
    async def login(body: LoginIn, request: Request, response: Response) -> dict[str, Any]:
        client = limited(request)
        if rackoon.account.needs_setup:
            raise ApiError(409, "setupRequired", "Set the admin password first.")
        if not rackoon.account.check(body.password, body.code, rackoon.clock()):
            rackoon.limiter.failed(client)
            log.warning("failed sign-in from %s", client)
            raise ApiError(401, "badCredentials", "Wrong password or code.")
        rackoon.limiter.succeeded(client)
        return {"csrf": start_session(response)}

    @app.post("/api/auth/logout")
    async def logout(request: Request, response: Response, _: str = Auth) -> dict[str, Any]:
        rackoon.sessions.end(request.cookies.get(COOKIE))
        response.delete_cookie(COOKIE, path="/", secure=True, httponly=True, samesite="strict")
        return {"ok": True}

    @app.post("/api/auth/password")
    async def change_password(body: PasswordIn, request: Request, response: Response,
                              _: str = Auth) -> dict[str, Any]:
        client = limited(request)
        if rackoon.account.password_managed:
            raise ApiError(409, "passwordManaged", "The password is set by RACKOON_ADMIN_PASSWORD_FILE.")
        hashed = rackoon.account.password_hash
        if hashed is None or not security.verify_password(hashed, body.current):
            rackoon.limiter.failed(client)
            raise ApiError(403, "badCredentials", "The current password is wrong.")
        problem = security.password_problem(body.new)
        if problem:
            raise ApiError(422, "weakPassword", problem)
        rackoon.account.set_password(body.new)
        rackoon.sessions.end_all()  # everyone else is signed out; this browser gets a new session
        return {"csrf": start_session(response)}

    @app.post("/api/auth/totp/setup")
    async def totp_setup(_: str = Auth) -> dict[str, Any]:
        secret = rackoon.account.begin_totp()
        return {"secret": secret, "uri": security.totp_uri(secret)}

    @app.post("/api/auth/totp/enable")
    async def totp_enable(body: CodeIn, _: str = Auth) -> dict[str, Any]:
        if not rackoon.account.enable_totp(body.code, rackoon.clock()):
            raise ApiError(422, "badCode", "That code doesn't match. Check the authenticator app's clock.")
        return {"totpEnabled": True}

    @app.post("/api/auth/totp/disable")
    async def totp_disable(body: DisableTotpIn, request: Request, _: str = Auth) -> dict[str, Any]:
        client = limited(request)
        if not rackoon.account.check(body.password, body.code, rackoon.clock()):
            rackoon.limiter.failed(client)
            raise ApiError(403, "badCredentials", "Wrong password or code.")
        rackoon.account.disable_totp()
        return {"totpEnabled": False}

    # --- servers

    store = rackoon.store

    def find(servers: list[Server], server_id: str) -> Server:
        server = next((s for s in servers if s.id == server_id), None)
        if server is None:
            raise ApiError(404, "noSuchServer", "There is no such server.")
        return server

    def server_from(body: ServerIn, server_id: str, alias: str | None) -> Server:
        name = " ".join(body.name.split())
        if not name:
            raise ApiError(422, "invalid", "A name is needed.")
        problem = server_input_problem(body.host, body.user or "", "" if body.port is None else str(body.port))
        if problem:
            raise ApiError(422, "invalid", problem)
        identity: str | None = None
        if body.keyId is not None:
            if rackoon.keys.get(body.keyId) is None:
                raise ApiError(422, "noSuchKey", "That key no longer exists.")
            identity = str(store.key_path(body.keyId))
        user = (body.user or "").strip() or None
        return Server(server_id, name, body.host.strip(), user=user, port=body.port, ssh_config_alias=alias,
                      identity_file=identity)

    def saved(servers: list[Server]) -> None:
        store.save_servers(servers)
        rackoon.monitor.sync(servers)

    @app.get("/api/servers")
    async def list_servers(query: str = "", _: str = Auth) -> list[dict[str, Any]]:
        return [_server_json(s, store.keys_dir) for s in server_list.filter_servers(store.load_servers(), query[:200])]

    @app.post("/api/servers", status_code=201)
    async def add_server(body: ServerIn, _: str = Auth) -> dict[str, Any]:
        server = server_from(body, new_id(), None)
        saved(store.load_servers() + [server])
        return _server_json(server, store.keys_dir)

    @app.get("/api/servers/{server_id}")
    async def get_server(server_id: str, _: str = Auth) -> dict[str, Any]:
        return _server_json(find(store.load_servers(), server_id), store.keys_dir)

    @app.put("/api/servers/order")
    async def reorder(body: OrderIn, _: str = Auth) -> list[dict[str, Any]]:
        servers = store.load_servers()
        if sorted(body.ids) != sorted(s.id for s in servers):
            raise ApiError(422, "invalid", "Send every server's id exactly once.")
        by_id = {s.id: s for s in servers}
        ordered = [by_id[i] for i in body.ids]
        saved(ordered)
        return [_server_json(s, store.keys_dir) for s in ordered]

    @app.put("/api/servers/{server_id}")
    async def edit_server(server_id: str, body: ServerIn, _: str = Auth) -> dict[str, Any]:
        servers = store.load_servers()
        old = find(servers, server_id)
        # The ssh_config link survives only while the host is still what that entry resolved to.
        new = server_from(body, server_id, old.ssh_config_alias if body.host.strip() == old.host else None)
        saved([new if s.id == server_id else s for s in servers])
        if not new.connects_like(old):
            # A new address or key: the open connection and the cached reading belong to the old one.
            await rackoon.connections.forget(server_id)
            store.delete_snapshot(server_id)
        return _server_json(new, store.keys_dir)

    @app.delete("/api/servers/{server_id}")
    async def remove_server(server_id: str, _: str = Auth) -> dict[str, Any]:
        servers = store.load_servers()
        find(servers, server_id)
        saved([s for s in servers if s.id != server_id])
        await rackoon.connections.forget(server_id)
        store.delete_snapshot(server_id)
        return {"ok": True}

    # --- host keys

    @app.post("/api/servers/{server_id}/host-key/scan")
    async def scan(server_id: str, _: str = Auth) -> dict[str, Any]:
        return _check_json(await rackoon.connections.scan(find(store.load_servers(), server_id)))

    @app.post("/api/servers/{server_id}/host-key/trust")
    async def trust(server_id: str, body: TrustIn, _: str = Auth) -> dict[str, Any]:
        server = find(store.load_servers(), server_id)
        try:
            key = rackoon.connections.trust(server, body.scanId, body.fingerprint)
        except TrustError as e:
            raise ApiError(e.status, e.code, str(e)) from None
        await rackoon.connections.forget(server_id)
        await rackoon.monitor.refresh(server_id)
        return {"trusted": {"keyType": key.key_type, "fingerprint": key.fingerprint}}

    @app.post("/api/servers/{server_id}/check")
    async def check(server_id: str, _: str = Auth) -> dict[str, Any]:
        return _check_json(await rackoon.connections.check(find(store.load_servers(), server_id)))

    @app.post("/api/servers/{server_id}/move")
    async def move(server_id: str, body: MoveIn, _: str = Auth) -> list[dict[str, Any]]:
        servers = store.load_servers()
        find(servers, server_id)
        if body.onto is not None:
            moved = server_list.moving_onto(server_id, body.onto, servers)
        elif body.by is not None:
            moved = server_list.moving_by(server_id, body.by, servers)
        else:
            raise ApiError(422, "invalid", "Say where to move it: onto another server, or by a number of places.")
        saved(moved)
        return [_server_json(s, store.keys_dir) for s in moved]

    # --- readings

    @app.get("/api/servers/{server_id}/state")
    async def server_state(server_id: str, watch: bool = False, _: str = Auth) -> dict[str, Any]:
        find(store.load_servers(), server_id)
        if watch and rackoon.monitor.watch(server_id):
            await rackoon.monitor.settle(server_id, 2.5)
        state = rackoon.monitor.state_json(server_id)
        if state is None:
            raise ApiError(404, "noSuchServer", "There is no such server.")
        return state

    @app.post("/api/servers/{server_id}/refresh")
    async def refresh(server_id: str, _: str = Auth) -> dict[str, Any]:
        find(store.load_servers(), server_id)
        await rackoon.connections.forget(server_id)
        await rackoon.monitor.refresh(server_id)
        state = rackoon.monitor.state_json(server_id)
        assert state is not None
        return state

    @app.get("/api/fleet")
    async def fleet(_: str = Auth) -> dict[str, Any]:
        return rackoon.monitor.fleet_json(store.load_servers())

    # --- appearance and safety

    @app.get("/api/appearance")
    async def appearance(_: str = Auth) -> dict[str, Any]:
        return rackoon.preferences.appearance_json()

    @app.put("/api/appearance")
    async def set_appearance(body: AppearanceIn, _: str = Auth) -> dict[str, Any]:
        try:
            rackoon.preferences.set_theme(body.selection)
        except ValueError:
            raise ApiError(422, "noSuchTheme", "There is no such theme.") from None
        return rackoon.preferences.appearance_json()

    @app.get("/api/safety")
    async def safety(_: str = Auth) -> dict[str, Any]:
        return rackoon.preferences.safety_json()

    @app.put("/api/safety")
    async def set_safety(body: SafetyIn, _: str = Auth) -> dict[str, Any]:
        if body.auto is not None:
            rackoon.preferences.set_auto(body.auto)
        if body.readOnly is not None:
            rackoon.preferences.set_read_only(body.readOnly)
        return rackoon.preferences.safety_json()

    @app.post("/api/activity")
    async def activity(_: str = Auth) -> dict[str, Any]:
        return {"readOnly": rackoon.preferences.read_only}  # authenticated() already noted the touch

    # --- confirming an action

    @app.post("/api/actions/{action_id}/confirm")
    async def confirm_action(action_id: str, _: str = Auth) -> dict[str, Any]:
        try:
            return {"ok": True, "result": await rackoon.actions.confirm(action_id)}
        except ActionError as e:
            raise ApiError(e.status, e.code, str(e)) from None

    @app.post("/api/actions/{action_id}/cancel")
    async def cancel_action(action_id: str, _: str = Auth) -> dict[str, Any]:
        return {"ok": rackoon.actions.cancel(action_id)}

    # --- ssh_config import

    def config_hosts() -> tuple[Path, list[ssh_config.SSHConfigHost]]:
        path = rackoon.settings.ssh_config
        if path is None:
            raise ApiError(404, "noSSHConfig", "No ssh_config is mounted (set RACKOON_SSH_CONFIG).")
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as e:
            raise ApiError(404, "noSSHConfig", f"Can't read {path}: {e.strerror}") from None
        return path, ssh_config.parse(text)

    def key_file(config_path: Path, entry: ssh_config.SSHConfigHost) -> Path | None:
        """The entry's private key inside the mounted folder: `~/.ssh/<name>` maps to the folder the config is in.
        Without an IdentityFile, ssh's default key names are tried."""
        folder = config_path.parent
        names = entry.identity_files or ["~/.ssh/id_ed25519", "~/.ssh/id_ecdsa", "~/.ssh/id_rsa"]
        for name in names:
            if "%" in name:
                continue
            if name.startswith("~/.ssh/"):
                candidate = folder / name[len("~/.ssh/"):]
            elif name.startswith("/"):
                candidate = Path(name)
            else:
                candidate = folder / name
            try:
                resolved = candidate.resolve()
                if resolved.is_relative_to(folder.resolve()) and resolved.is_file():
                    return resolved
            except OSError:
                continue
        return None

    def taken(servers: list[Server], entry: ssh_config.SSHConfigHost) -> bool:
        r = entry.resolved("")
        return any(s.ssh_config_alias == entry.alias or (s.host, s.user, s.port) == (r.host, r.user, r.port)
                   for s in servers)

    @app.get("/api/ssh-config")
    async def list_config(_: str = Auth) -> dict[str, Any]:
        path, hosts = config_hosts()
        servers = store.load_servers()
        return {"path": str(path), "hosts": [{
            "alias": h.alias, "hostName": h.host_name, "user": h.user, "port": h.port,
            "keyFile": (lambda k: k.name if k else None)(key_file(path, h)),
            "supported": h.proxy_jump is None, "alreadyAdded": taken(servers, h),
            "note": f"Uses ProxyJump {h.proxy_jump}, which the web version can't do yet." if h.proxy_jump else None,
        } for h in hosts]}

    @app.post("/api/ssh-config/import", status_code=201)
    async def import_config(body: ImportIn, _: str = Auth) -> dict[str, Any]:
        path, hosts = config_hosts()
        by_alias = {h.alias: h for h in hosts}
        servers = store.load_servers()
        added: list[dict[str, Any]] = []
        notes: list[str] = []
        for alias in body.aliases:
            entry = by_alias.get(alias)
            if entry is None:
                notes.append(f"{alias}: not in {path.name}.")
                continue
            if entry.proxy_jump is not None:
                notes.append(f"{alias}: uses ProxyJump, which the web version can't do yet.")
                continue
            if taken(servers, entry):
                notes.append(f"{alias}: already added.")
                continue
            server = entry.resolved(new_id())
            problem = server_input_problem(server.host, server.user or "", str(server.port or ""))
            if problem:
                notes.append(f"{alias}: {problem}")
                continue
            if body.importKeys:
                found = key_file(path, entry)
                if found is not None:
                    key_id = _import_key_file(rackoon.keys, alias, found, notes)
                    if key_id is not None:
                        server = replace(server, identity_file=str(store.key_path(key_id)))
            servers.append(server)
            added.append(_server_json(server, store.keys_dir))
        saved(servers)
        return {"added": added, "notes": notes}

    # --- keys

    @app.get("/api/keys")
    async def list_keys(_: str = Auth) -> list[dict[str, Any]]:
        return [_key_json(k) for k in rackoon.keys.list()]

    @app.post("/api/keys/generate", status_code=201)
    async def generate_key(body: GenerateKeyIn, _: str = Auth) -> dict[str, Any]:
        try:
            return _key_json(rackoon.keys.generate(body.name))
        except KeyError_ as e:
            raise ApiError(422, "invalid", str(e)) from None

    @app.post("/api/keys/import", status_code=201)
    async def import_key(body: ImportKeyIn, _: str = Auth) -> dict[str, Any]:
        try:
            return _key_json(rackoon.keys.import_key(body.name, body.privateKey, body.passphrase))
        except KeyError_ as e:
            raise ApiError(422, "invalid", str(e)) from None

    @app.delete("/api/keys/{key_id}")
    async def delete_key(key_id: str, _: str = Auth) -> dict[str, Any]:
        users = [s.name for s in store.load_servers() if key_id_of(s, store.keys_dir) == key_id]
        if users:
            raise ApiError(409, "keyInUse", f"Used by {', '.join(users)}. Choose another key for them first.")
        if not rackoon.keys.delete(key_id):
            raise ApiError(404, "noSuchKey", "There is no such key.")
        return {"ok": True}

    if settings.static_dir is not None:
        mount_frontend(app, settings.static_dir)
    return app


def _import_key_file(keys: KeyStore, alias: str, path: Path, notes: list[str]) -> str | None:
    """Adds a key file found next to the ssh_config, or reuses the stored key with the same fingerprint."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        notes.append(f"{alias}: can't read {path.name}; added without a key.")
        return None
    try:
        return keys.import_key(f"{path.name} (from ssh_config)", text).id
    except KeyError_ as e:
        if "already" in str(e):
            fingerprint = HostKey.from_asyncssh(asyncssh.import_private_key(text)).fingerprint
            return next((k.id for k in keys.list() if k.fingerprint == fingerprint), None)
        notes.append(f"{alias}: {path.name}: {e} Added without a key; import it on the Keys page.")
        return None

