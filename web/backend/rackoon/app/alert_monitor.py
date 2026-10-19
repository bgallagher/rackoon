"""Alerts in the background (the Mac's `AlertMonitor`), and their delivery: Web Push to the browsers that subscribed,
an ntfy topic, or a webhook.

Every 15 s the book is fed from what the polls already hold (each server's connection and Overview). Every 5 minutes
each answering server is swept: the services scan (only services the user shows can alert), the light container check
(`docker_states`, through sudo only while Docker is unlocked), and an Unraid server's array; every 6 hours the https
bookmarks' certificates are read by a TLS handshake from this server (untrusted certificates are read, never trusted).
Everything is read-only. A source's first reading of a server is a baseline and never notifies, so starting Rackoon
doesn't flood; muted alerts never notify. The book is saved as `<data>/alerts.json`.

Delivery settings live in `<data>/notifications.json` (0600). The ntfy token and webhook secret are kept there and never
sent back to the browser. Web Push uses a VAPID key made on first use (`<data>/vapid.pem`, 0600).
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import hashlib
import hmac
import json
import logging
import ssl
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC
from pathlib import Path
from typing import TYPE_CHECKING, Any

import httpx

from rackoon.core import alerts, docker_states
from rackoon.core.alerts import AlertBook, CertificateCheck, ServerAlert, Source
from rackoon.core.models import Server, Severity
from rackoon.core.unraid import is_unraid
from rackoon.ssh import SSHError

from .connections import TrustError
from .storage import read_json, write_json

if TYPE_CHECKING:
    from .api import Rackoon

log = logging.getLogger("rackoon.alerts")

EVALUATE_EVERY = 15.0
SWEEP_EVERY = 300.0
CERTS_EVERY = 6 * 3600.0
FIRST_SWEEP_AFTER = 10.0


async def read_certificate(url: str, timeout: float = 8.0) -> float | None:
    """When the site's certificate expires (Unix seconds), from a TLS handshake. Not verified: this only reads the
    date, and trusts nothing."""
    from cryptography import x509
    from urllib.parse import urlsplit
    u = urlsplit(url)
    host, port = u.hostname, u.port or 443
    if not host:
        return None
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        reader, writer = await asyncio.wait_for(asyncio.open_connection(host, port, ssl=ctx, server_hostname=host),
                                                timeout)
    except (OSError, TimeoutError, ssl.SSLError):
        return None
    try:
        obj = writer.get_extra_info("ssl_object")
        der = obj.getpeercert(binary_form=True) if obj else None
        if not der:
            return None
        cert = x509.load_der_x509_certificate(der)
        return cert.not_valid_after_utc.replace(tzinfo=UTC).timestamp()
    finally:
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()


@dataclass
class Settings:
    enabled: bool = True
    ntfy_url: str = ""
    ntfy_token: str = ""
    webhook_url: str = ""
    webhook_secret: str = ""
    public_url: str = ""
    """Where this Rackoon is reached, for links in ntfy and webhook messages (optional)."""
    push: list[dict[str, Any]] = field(default_factory=list)
    last_error: str | None = None

    def json(self) -> dict[str, Any]:
        return {"enabled": self.enabled, "ntfyUrl": self.ntfy_url, "hasNtfyToken": bool(self.ntfy_token),
                "webhookUrl": self.webhook_url, "hasWebhookSecret": bool(self.webhook_secret),
                "publicUrl": self.public_url, "pushSubscriptions": len(self.push), "lastError": self.last_error}


class Notifier:
    def __init__(self, folder: Path, transport: httpx.AsyncBaseTransport | None = None) -> None:
        self.folder = folder
        self.transport = transport
        raw = read_json(folder / "notifications.json") or {}
        self.settings = Settings(**{k: v for k, v in raw.items() if k in Settings.__dataclass_fields__})

    def save(self) -> None:
        write_json(self.folder / "notifications.json", self.settings.__dict__)

    # --- Web Push

    def vapid(self) -> Any:
        from py_vapid import Vapid02  # type: ignore[import-untyped]
        path = self.folder / "vapid.pem"
        if path.exists():
            return Vapid02.from_file(str(path))
        v = Vapid02()
        v.generate_keys()
        path.write_bytes(v.private_pem())
        path.chmod(0o600)
        return v

    def public_key(self) -> str:
        from cryptography.hazmat.primitives import serialization
        raw = self.vapid().public_key.public_bytes(serialization.Encoding.X962,
                                                   serialization.PublicFormat.UncompressedPoint)
        return base64.urlsafe_b64encode(raw).decode().rstrip("=")

    def subscribe(self, subscription: dict[str, Any]) -> None:
        endpoint = subscription.get("endpoint")
        self.settings.push = [s for s in self.settings.push if s.get("endpoint") != endpoint] + [subscription]
        self.save()

    def unsubscribe(self, endpoint: str) -> None:
        self.settings.push = [s for s in self.settings.push if s.get("endpoint") != endpoint]
        self.save()

    # --- sending

    def message(self, a: ServerAlert) -> dict[str, Any]:
        path = f"/#/servers/{a.server_id}/alerts"
        return {"title": f"{a.server_name}: {a.title}", "body": a.detail or a.title, "severity": a.severity.value,
                "path": path, "url": (self.settings.public_url.rstrip("/") + path) if self.settings.public_url else None,
                "alert": a.json()}

    async def send(self, raised: list[ServerAlert]) -> list[str]:
        """Sends each raised alert everywhere that is set up. Returns what failed (also kept as `last_error`)."""
        if not raised or not self.settings.enabled:
            return []
        problems: list[str] = []
        for a in raised:
            problems += await self.deliver(self.message(a))
        self.settings.last_error = "; ".join(problems) or None
        self.save()
        return problems

    async def deliver(self, m: dict[str, Any]) -> list[str]:
        problems: list[str] = []
        s = self.settings
        async with httpx.AsyncClient(timeout=10, transport=self.transport) as client:
            if s.ntfy_url:
                headers = {"Title": m["title"], "Priority": "5" if m["severity"] == "critical" else "4",
                           "Tags": "rotating_light" if m["severity"] == "critical" else "warning"}
                if m["url"]:
                    headers["Click"] = m["url"]
                if s.ntfy_token:
                    headers["Authorization"] = f"Bearer {s.ntfy_token}"
                try:
                    r = await client.post(s.ntfy_url, content=m["body"].encode(), headers=headers)
                    if r.status_code >= 300:
                        problems.append(f"ntfy answered {r.status_code}")
                except httpx.HTTPError as e:
                    problems.append(f"ntfy: {e}")
            if s.webhook_url:
                body = json.dumps({"event": "alert", **m}).encode()
                headers = {"Content-Type": "application/json"}
                if s.webhook_secret:
                    sig = hmac.new(s.webhook_secret.encode(), body, hashlib.sha256).hexdigest()
                    headers["X-Rackoon-Signature"] = f"sha256={sig}"
                try:
                    r = await client.post(s.webhook_url, content=body, headers=headers)
                    if r.status_code >= 300:
                        problems.append(f"the webhook answered {r.status_code}")
                except httpx.HTTPError as e:
                    problems.append(f"webhook: {e}")
        if s.push:
            problems += await self.push(m)
        return problems

    async def push(self, m: dict[str, Any]) -> list[str]:
        from pywebpush import WebPushException, webpush_async  # type: ignore[import-untyped]
        problems: list[str] = []
        gone: list[str] = []
        data = json.dumps({"title": m["title"], "body": m["body"], "path": m["path"]})
        vapid = self.vapid()
        for sub in list(self.settings.push):
            try:
                await webpush_async(sub, data, vapid_private_key=vapid, vapid_claims={"sub": "mailto:rackoon@localhost"},
                                    timeout=10, ttl=3600)
            except WebPushException as e:
                code = getattr(e.response, "status", None) or getattr(e.response, "status_code", None)
                if code in (404, 410):
                    gone.append(str(sub.get("endpoint")))  # the browser dropped it
                else:
                    problems.append(f"Web Push: {e}")
            except Exception as e:  # noqa: BLE001 - a network failure must not stop the others
                problems.append(f"Web Push: {e}")
        if gone:
            self.settings.push = [s for s in self.settings.push if s.get("endpoint") not in gone]
        return problems


class AlertMonitor:
    def __init__(self, rackoon: Rackoon, clock: Callable[[], float] = time.time) -> None:
        self.rackoon = rackoon
        self.clock = clock
        self.path = rackoon.store.root / "alerts.json"
        try:
            self.book = AlertBook.from_json(read_json(self.path) or {})
        except (KeyError, ValueError, TypeError):
            self.book = AlertBook()
        self.notifier = Notifier(rackoon.store.root)
        self.states: dict[str, docker_states.DockerStatesReading] = {}
        self.certs: dict[str, list[CertificateCheck]] = {}
        self.last_sweep: dict[str, float] = {}
        self.last_certs: dict[str, float] = {}
        self.sweeping: set[str] = set()
        self.task: asyncio.Task[None] | None = None
        self.started = clock()

    def save(self) -> None:
        write_json(self.path, self.book.json())

    def start(self) -> None:
        self.task = asyncio.create_task(self._loop())

    async def stop(self) -> None:
        if self.task is not None:
            self.task.cancel()
            # gather collects the loop's own cancellation; a cancellation of this task still propagates.
            await asyncio.gather(self.task, return_exceptions=True)

    async def _loop(self) -> None:
        while True:
            try:
                await self.evaluate()
                now = self.clock()
                if now - self.started >= FIRST_SWEEP_AFTER:
                    for server in self.rackoon.store.load_servers():
                        if now - self.last_sweep.get(server.id, 0) >= SWEEP_EVERY:
                            await self.sweep(server)
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 - one bad round must not end the loop
                log.exception("alert round failed")
            await asyncio.sleep(EVALUATE_EVERY)

    async def record(self, server: Server, source: Source, signals: list[alerts.Signal]) -> None:
        raised = self.book.apply(server.id, server.name, source, signals, self.clock())
        self.save()
        if raised:
            await self.notifier.send(raised)

    async def evaluate(self) -> None:
        """From what the polls already hold: each server's connection and Overview."""
        monitor = self.rackoon.monitor
        for server in self.rackoon.store.load_servers():
            entry = monitor.entries.get(server.id)
            if entry is None or entry.connection == "connecting":
                continue
            reboot = self.rackoon.reboots.states.get(server.id)
            if reboot is not None and reboot.phase == "waiting":
                continue  # going away on purpose
            blocked = entry.state.error if entry.connection in ("hostKeyUnknown", "hostKeyChanged") else None
            error = entry.state.error if entry.connection not in ("ok", "hostKeyUnknown", "hostKeyChanged") else None
            await self.record(server, Source.CONNECTION, alerts.connection(error, blocked))
            o = entry.state.overview
            if o is not None and entry.connection == "ok":
                await self.record(server, Source.OVERVIEW, alerts.overview(o, None, is_unraid(o.os)))

    async def sweep(self, server: Server) -> None:
        """The slower checks of one answering server."""
        entry = self.rackoon.monitor.entries.get(server.id)
        if entry is None or entry.connection != "ok" or server.id in self.sweeping:
            return
        self.sweeping.add(server.id)
        self.last_sweep[server.id] = self.clock()
        try:
            base = self.rackoon.connections.transport(server)
            svc = self.rackoon.services
            scan = await svc.scan(server.id, base)
            if scan.value is not None:
                await self.record(server, Source.SERVICES, alerts.services(
                    scan.value, lambda s: svc.visibility.is_visible(s, server.id)))
            try:
                r = await self.rackoon.docker_transport(server).run(docker_states.command(), 15)
                if r.exit_code == 0:
                    reading = docker_states.parse(r.stdout)
                    self.states[server.id] = reading
                    await self.record(server, Source.CONTAINERS, alerts.containers(reading))
            except SSHError:
                pass
            o = entry.state.overview
            if o is not None and is_unraid(o.os):
                nas = await self.rackoon.nas.read(server.id, base)
                if nas.value is not None:
                    await self.record(server, Source.STORAGE, alerts.storage(nas.value))
            if self.clock() - self.last_certs.get(server.id, 0) >= CERTS_EVERY:
                self.last_certs[server.id] = self.clock()
                await self.check_certificates(server)
        except (SSHError, TrustError):
            pass
        finally:
            self.sweeping.discard(server.id)

    def hrefs(self, server_id: str) -> list[str]:
        out = [c.href for c in self.states.get(server_id, docker_states.DockerStatesReading([])).containers if c.href]
        e = self.rackoon.docker.entries.get(server_id)
        if e is not None and e.snapshot is not None:
            out += [c.bookmark.href for c in e.snapshot.containers if c.bookmark]
        return out

    async def check_certificates(self, server: Server) -> None:
        targets = alerts.certificate_targets(self.hrefs(server.id))
        checks = []
        for url in targets[:30]:
            from urllib.parse import urlsplit
            expires = await read_certificate(url)
            checks.append(CertificateCheck(url, urlsplit(url).hostname or url, expires, self.clock()))
        self.certs[server.id] = checks
        await self.record(server, Source.CERTIFICATES, alerts.certificates(checks, self.clock()))

    async def check_now(self, server_id: str | None = None) -> None:
        await self.evaluate()
        for server in self.rackoon.store.load_servers():
            if server_id is None or server.id == server_id:
                self.last_certs.pop(server.id, None)
                await self.sweep(server)

    def forget(self, server_id: str) -> None:
        if self.book.forget(server_id):
            self.save()
        self.states.pop(server_id, None)
        self.certs.pop(server_id, None)

    def summary(self) -> dict[str, Any]:
        servers = {s.id: {"unseen": self.book.unseen_count(s.id),
                          "worst": (w.value if (w := self.book.worst_unseen(s.id)) else None)}
                   for s in self.rackoon.store.load_servers()}
        worst = self.book.worst_unseen()
        return {"servers": servers, "unseen": self.book.unseen_count(), "worst": worst.value if worst else None}

    def json(self, server_id: str | None) -> dict[str, Any]:
        b = self.book
        return {"active": [a.json() for a in b.active(server_id)],
                "muted": [a.json(True) for a in b.muted_alerts(server_id)],
                "history": [a.json() for a in b.history(server_id)],
                "unseen": b.unseen_count(server_id),
                "worst": (w.value if (w := b.worst_unseen(server_id)) else None),
                "lastSweep": max((v for k, v in self.last_sweep.items() if server_id is None or k == server_id),
                                 default=None),
                "sweeping": bool(self.sweeping if server_id is None else server_id in self.sweeping),
                "notifications": self.notifier.settings.json()}


def severity_rank(s: Severity) -> int:
    return alerts.RANK[s]
