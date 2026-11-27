"""The Security screen (docs/security-plan.md, stage S5 for web): hardening checks, open ports, the opt-in
vulnerability lookup and Check Deeper with sudo. Everything here only reads the server.

- The `security` command runs as the ssh user when the page asks (at most every 5 minutes unless Check Now) and
  hourly in the alert sweep. A reading made as root (Check Deeper) is replaced only by Check Now.
- Check Deeper runs the same command through sudo, only when the user asks: through the Docker unlock while one is
  active, else with a password sent for this one reading (checked first with `sudo -S` on its own connection, never
  kept).
- The vulnerability lookup is off until the user turns it on for a server or for all of them
  (`<data>/security/settings.json`). Only then are source package names and versions sent from this backend to
  OSV.dev; answers are kept in memory for a day.
"""

from __future__ import annotations

import asyncio
import json
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any

import httpx
from fastapi import Depends, FastAPI, Request
from pydantic import Field

from rackoon.core import security, spec, vulnerabilities
from rackoon.core.models import Server
from rackoon.core.overview import Overview
from rackoon.ssh import SSHError

from .connections import Transport, TrustError
from .elevation import SudoTransport
from .errors import ApiError, Body
from .storage import write_json

if TYPE_CHECKING:
    from .api import Rackoon

FRESH_FOR = 300.0
SWEEP_EVERY = 3600.0
PRIVACY_NOTE = ("Sends this server's package names and versions (nothing else: no host names or addresses) from this "
                "Rackoon server to OSV.dev, a vulnerability database run by Google. Answers are kept for a day.")
LIMITS = ("Matched by package version with OSV.dev's Debian and Ubuntu data. Kernel advisories depend on how the kernel "
          "is built and used, a backported fix can make a version look affected when it is not, and software outside "
          "apt (Docker images, binaries in /opt, pip or npm installs) is not covered.")
DISCLAIMER = ("These checks look for a small set of common hardening problems. They are not a complete security review "
              "and can be wrong: a setting may be overridden somewhere Rackoon does not read, and new issues appear "
              "every day. Treat a clean result as \"nothing obvious found\", not \"secure\".")


class DeeperIn(Body):
    password: str | None = Field(default=None, min_length=1, max_length=1024)


class LookupSettingIn(Body):
    serverId: str | None = Field(default=None, max_length=64)
    enabled: bool


@dataclass
class Reading:
    snapshot: security.SecuritySnapshot | None
    at: float
    error: str | None = None
    deep: bool = False


@dataclass
class VulnState:
    findings: list[vulnerabilities.VulnerabilityFinding] | None = None
    at: float | None = None
    error: str | None = None
    supported: bool = True
    running: bool = False


@dataclass
class LookupSettings:
    all: bool = False
    servers: set[str] = field(default_factory=set)

    def is_on(self, server_id: str) -> bool:
        return self.all or server_id in self.servers


class HttpxOSV:
    """OSV.dev over httpx: no cookies, normal certificate checks, a plain user agent."""

    async def post(self, url: str, body: bytes) -> bytes:
        async with httpx.AsyncClient(timeout=20, headers={"User-Agent": "Rackoon"}) as client:
            r = await client.post(url, content=body, headers={"Content-Type": "application/json"})
        if r.status_code // 100 != 2:
            raise vulnerabilities.OSVError(f"OSV.dev answered with HTTP {r.status_code}.")
        return r.content

    async def get(self, url: str) -> bytes:
        async with httpx.AsyncClient(timeout=20, headers={"User-Agent": "Rackoon"}) as client:
            r = await client.get(url)
        if r.status_code // 100 != 2:
            raise vulnerabilities.OSVError(f"OSV.dev answered with HTTP {r.status_code}.")
        return r.content


class DemoOSV:
    """Demo mode: answers from spec/osv's made-up records (ids in 2099), so a demo sends nothing anywhere."""

    def __init__(self) -> None:
        folder = spec.spec_dir() / "osv" / "vulns"
        self.records = {p.stem: p.read_bytes() for p in folder.glob("*.json")}
        self.by_package: dict[str, list[str]] = {}
        for vid, raw in self.records.items():
            for a in vulnerabilities.parse_record(raw).affected:
                self.by_package.setdefault(a.name, []).append(vid)

    async def post(self, url: str, body: bytes) -> bytes:
        queries = json.loads(body)["queries"]
        results = [{"vulns": [{"id": v, "modified": "2099-01-01T00:00:00Z"}
                              for v in self.by_package.get(q["package"]["name"], [])]} for q in queries]
        return json.dumps({"results": results}).encode()

    async def get(self, url: str) -> bytes:
        return self.records[url.rsplit("/", 1)[-1]]


class SecurityStore:
    def __init__(self, folder: Path, clock: Callable[[], float] = time.time, demo: bool = False) -> None:
        self.folder = folder
        self.clock = clock
        self.readings: dict[str, Reading] = {}
        self.vulns: dict[str, VulnState] = {}
        self.cache = vulnerabilities.OSVCache()
        self.client: vulnerabilities.OSVClient = DemoOSV() if demo else HttpxOSV()
        self.settings = LookupSettings()
        try:
            raw = json.loads((folder / "settings.json").read_text())
            self.settings = LookupSettings(bool(raw.get("osvAll", False)), {str(s) for s in raw.get("osvServers", [])})
        except (OSError, ValueError, AttributeError):
            pass

    def save(self) -> None:
        self.folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        write_json(self.folder / "settings.json", {"osvAll": self.settings.all,
                                                   "osvServers": sorted(self.settings.servers)})

    def set_lookup(self, server_id: str | None, enabled: bool) -> None:
        if server_id is None:
            self.settings.all = enabled
        elif enabled:
            self.settings.servers.add(server_id)
        else:
            self.settings.servers.discard(server_id)
        self.save()
        for sid in list(self.vulns):
            if not self.settings.is_on(sid):
                self.vulns.pop(sid)

    async def read(self, server_id: str, transport: Transport, force: bool = False, deep: bool = False) -> Reading:
        r = self.readings.get(server_id)
        if r is not None and not force and not deep and (r.deep or self.clock() - r.at < FRESH_FOR):
            return r
        try:
            result = await transport.run(security.command(), 25)
            if result.exit_code != 0:  # the script ends in `true`: ssh (or sudo) itself failed
                raise SSHError(result.stderr.strip() or f"ssh exited {result.exit_code}")
            snap = security.parse(result.stdout)
            r = Reading(snap, self.clock(), None, deep and snap.is_root)
        except (SSHError, TrustError, ValueError) as e:
            r = Reading(r.snapshot if r else None, self.clock(), str(e), r.deep if r else False)
        self.readings[server_id] = r
        return r

    async def lookup(self, server_id: str, transport: Transport) -> VulnState:
        state = self.vulns.setdefault(server_id, VulnState())
        if state.running:
            return state
        state.running = True
        try:
            r = await transport.run(vulnerabilities.command(), 25)
            if r.exit_code != 0:
                raise SSHError(r.stderr.strip() or f"ssh exited {r.exit_code}")
            inventory = vulnerabilities.parse_inventory(r.stdout)
            if vulnerabilities.ecosystem(inventory.os.id, inventory.os.version) is None:
                state.supported, state.findings, state.error = False, None, None
                return state
            state.supported = True
            pending: list[vulnerabilities.PendingPackage] = []
            from rackoon.core import updates
            u = await transport.run(updates.command(), 60)
            if u.exit_code == 0:
                try:
                    pending = [vulnerabilities.PendingPackage(p.name, p.new_version)
                               for p in updates.parse(u.stdout).packages]
                except Exception:  # noqa: BLE001 - no pending list just means no "fix waiting" marks
                    pending = []
            state.findings = await vulnerabilities.lookup(inventory, pending, self.client, self.cache, self.clock())
            state.at = self.clock()
            state.error = None
        except (SSHError, TrustError, ValueError, vulnerabilities.OSVError, httpx.HTTPError) as e:
            state.error = str(e) or type(e).__name__
        finally:
            state.running = False
        return state

    def forget(self, server_id: str) -> None:
        self.readings.pop(server_id, None)
        self.vulns.pop(server_id, None)
        if server_id in self.settings.servers:
            self.settings.servers.discard(server_id)
            self.save()


def context_of(o: Overview | None) -> security.SecurityContext:
    return security.SecurityContext(o.security_updates if o else None, o.reboot_required if o else None)


def register(app: FastAPI, rackoon: Rackoon, authenticated: Callable[[Request], str],
             find: Callable[[list[Server], str], Server]) -> None:
    Auth = Depends(authenticated)
    store: SecurityStore = rackoon.security_checks

    def server_of(server_id: str) -> Server:
        return find(rackoon.store.load_servers(), server_id)

    def transport(server: Server) -> Transport:
        try:
            return rackoon.connections.transport(server)
        except TrustError as e:
            raise ApiError(e.status, e.code, str(e)) from None

    def overview_of(server: Server) -> Overview | None:
        e = rackoon.monitor.entries.get(server.id)
        return e.state.overview if e else None

    def page(server: Server, r: Reading) -> dict[str, Any]:
        snap = r.snapshot
        body = security.to_screen_json(snap, security.evaluate(snap, context_of(overview_of(server)))) if snap else \
            {"findings": [], "ports": []}
        v = store.vulns.get(server.id)
        return {"serverId": server.id, "status": "ready" if snap else "failed" if r.error else "loading",
                "error": r.error, "updatedAt": r.at, "deep": r.deep, "isRoot": snap.is_root if snap else None,
                "user": server.user, "disclaimer": DISCLAIMER,
                "dockerUnlocked": rackoon.elevation.until(server.id) is not None,
                **body,
                "vulnerabilities": {
                    "enabled": store.settings.is_on(server.id), "all": store.settings.all,
                    "thisServer": server.id in store.settings.servers, "privacyNote": PRIVACY_NOTE, "limits": LIMITS,
                    "supported": v.supported if v else True, "running": v.running if v else False,
                    "error": v.error if v else None, "updatedAt": v.at if v else None,
                    "findings": [vulnerabilities.finding_json(f) for f in v.findings] if v and v.findings is not None
                    else None}}

    @app.get("/api/servers/{server_id}/security")
    async def security_page(server_id: str, refresh: bool = False, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        r = await store.read(server.id, transport(server), refresh)
        return page(server, r)

    @app.post("/api/servers/{server_id}/security/deeper")
    async def security_deeper(server_id: str, body: DeeperIn, _: str = Auth) -> dict[str, Any]:
        """The same read-only checks as root, only when asked: through the Docker unlock while it is active, else with
        the password sent for this one reading (checked with `sudo -S` first, never kept)."""
        server = server_of(server_id)
        base = transport(server)
        if rackoon.elevation.until(server.id) is not None:
            sudo_transport = rackoon.docker_transport(server)
        elif body.password is None:
            raise ApiError(428, "needsPassword", "Checking as root needs the sudo password.")
        else:
            from rackoon.core import sudo as sudo_rules
            try:
                result = await base.run(rackoon.elevation.check_command(), 30, input=body.password + "\n")
            except SSHError as x:
                raise ApiError(502, "connection", str(x)) from None
            if result.exit_code != 0:
                said = result.stderr + "\n" + result.stdout
                if sudo_rules.is_auth_failure(said):
                    raise ApiError(422, "badPassword", "The server did not accept that password.")
                raise ApiError(409, "sudoRefused", sudo_rules.explain_refusal(said))
            sudo_transport = SudoTransport(base, body.password, rackoon.clock() + 120, lambda: None, rackoon.clock)
        r = await store.read(server.id, sudo_transport, force=True, deep=True)
        await rackoon.alerts.record_security(server)
        return page(server, r)

    @app.put("/api/security/vulnerabilities")
    async def set_lookup(body: LookupSettingIn, _: str = Auth) -> dict[str, Any]:
        if body.serverId is not None:
            server_of(body.serverId)
        store.set_lookup(body.serverId, body.enabled)
        return {"all": store.settings.all, "servers": sorted(store.settings.servers)}

    @app.post("/api/servers/{server_id}/security/vulnerabilities")
    async def run_lookup(server_id: str, _: str = Auth) -> dict[str, Any]:
        server = server_of(server_id)
        if not store.settings.is_on(server.id):
            raise ApiError(409, "lookupOff", "The vulnerability lookup is off for this server.")
        await store.lookup(server.id, transport(server))
        r = store.readings.get(server.id) or Reading(None, rackoon.clock())
        return page(server, r)

    @app.get("/api/fleet/security")
    async def fleet_security(_: str = Auth) -> dict[str, Any]:
        """Every answering server's Security reading (read now if the last one is over 5 minutes old), for the
        Dashboard's Security page: what to fix, how many ports other networks can reach, what could not be checked."""
        servers = rackoon.store.load_servers()
        answering = [s for s in servers if (m := rackoon.monitor.entries.get(s.id)) is not None and m.connection == "ok"]

        async def one(server: Server) -> Reading | None:
            try:
                return await store.read(server.id, rackoon.connections.transport(server))
            except TrustError:
                return None

        readings = await asyncio.gather(*(one(s) for s in answering))
        rows = []
        for server, r in zip(answering, readings):
            snap = r.snapshot if r else None
            found = security.evaluate(snap, context_of(overview_of(server))) if snap else []
            screen = security.to_screen_json(snap, found) if snap else {"findings": [], "ports": []}
            rows.append({"server": {"id": server.id, "name": server.name}, "updatedAt": r.at if r else None,
                         "deep": r.deep if r else False, "error": r.error if r else None,
                         "toFix": [f for f in screen["findings"] if f["severity"] in ("critical", "warning")],
                         "exposedPorts": sum(1 for p in screen["ports"] if p["scope"] in ("all", "public")),
                         "unknown": sum(1 for f in found if f.severity == security.Severity.UNKNOWN)})
        return {"servers": rows, "checked": len(rows), "total": len(servers), "disclaimer": DISCLAIMER}
