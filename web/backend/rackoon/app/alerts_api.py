"""Alerts, their delivery settings, and Search (stage W7). Everything here reads what the backend already holds; only
Check Now runs the (read-only) sweep at once."""

from __future__ import annotations

from collections.abc import Callable
from typing import TYPE_CHECKING, Any

from fastapi import Depends, FastAPI, Request
from pydantic import Field

from rackoon.core import command_library, search
from rackoon.core.docker import Bookmark
from rackoon.core.models import Server

from .errors import ApiError, Body

if TYPE_CHECKING:
    from .api import Rackoon


class SeenIn(Body):
    seen: bool = True


class MuteIn(Body):
    on: bool = True


class ServerScopeIn(Body):
    serverId: str | None = Field(default=None, max_length=64)


class NotificationsIn(Body):
    enabled: bool | None = None
    ntfyUrl: str | None = Field(default=None, max_length=2048)
    ntfyToken: str | None = Field(default=None, max_length=1024)
    webhookUrl: str | None = Field(default=None, max_length=2048)
    webhookSecret: str | None = Field(default=None, max_length=1024)
    publicUrl: str | None = Field(default=None, max_length=2048)


class SubscriptionKeys(Body):
    p256dh: str = Field(max_length=200)
    auth: str = Field(max_length=100)


class SubscriptionIn(Body):
    endpoint: str = Field(max_length=2048)
    expirationTime: float | None = None
    keys: SubscriptionKeys


class EndpointIn(Body):
    endpoint: str = Field(max_length=2048)


def _url_ok(url: str) -> bool:
    return url == "" or url.startswith(("https://", "http://"))


def register(app: FastAPI, rackoon: Rackoon, authenticated: Callable[[Request], str],
             find: Callable[[list[Server], str], Server]) -> None:
    Auth = Depends(authenticated)
    monitor = rackoon.alerts
    book = monitor.book
    notifier = monitor.notifier

    def known(alert_id: str) -> None:
        if not any(a.id == alert_id for a in book.alerts):
            raise ApiError(404, "noSuchAlert", "That alert is gone.")

    @app.get("/api/alerts")
    async def list_alerts(server: str | None = None, _: str = Auth) -> dict[str, Any]:
        return monitor.json(server)

    @app.get("/api/alerts/summary")
    async def summary(_: str = Auth) -> dict[str, Any]:
        return monitor.summary()

    @app.post("/api/alerts/{alert_id}/seen")
    async def seen(alert_id: str, body: SeenIn, _: str = Auth) -> dict[str, Any]:
        known(alert_id)
        book.acknowledge(alert_id, body.seen)
        monitor.save()
        return {"ok": True}

    @app.post("/api/alerts/{alert_id}/mute")
    async def mute(alert_id: str, body: MuteIn, _: str = Auth) -> dict[str, Any]:
        known(alert_id)
        book.mute(alert_id, body.on)
        monitor.save()
        return {"ok": True}

    @app.post("/api/alerts/seen-all")
    async def seen_all(body: ServerScopeIn, _: str = Auth) -> dict[str, Any]:
        book.acknowledge_all(body.serverId)
        monitor.save()
        return {"ok": True}

    @app.post("/api/alerts/clear-history")
    async def clear_history(body: ServerScopeIn, _: str = Auth) -> dict[str, Any]:
        book.clear_history(body.serverId)
        monitor.save()
        return {"ok": True}

    @app.post("/api/alerts/check")
    async def check_now(body: ServerScopeIn, _: str = Auth) -> dict[str, Any]:
        await monitor.check_now(body.serverId)
        return monitor.json(body.serverId)

    # --- delivery

    @app.get("/api/notifications")
    async def notifications(_: str = Auth) -> dict[str, Any]:
        return notifier.settings.json()

    @app.put("/api/notifications")
    async def set_notifications(body: NotificationsIn, _: str = Auth) -> dict[str, Any]:
        s = notifier.settings
        for url in (body.ntfyUrl, body.webhookUrl, body.publicUrl):
            if url is not None and not _url_ok(url.strip()):
                raise ApiError(422, "invalid", "Addresses start with https:// (or http:// on your own network).")
        if body.enabled is not None:
            s.enabled = body.enabled
        if body.ntfyUrl is not None:
            s.ntfy_url = body.ntfyUrl.strip()
        if body.ntfyToken is not None:
            s.ntfy_token = body.ntfyToken.strip()
        if body.webhookUrl is not None:
            s.webhook_url = body.webhookUrl.strip()
        if body.webhookSecret is not None:
            s.webhook_secret = body.webhookSecret
        if body.publicUrl is not None:
            s.public_url = body.publicUrl.strip()
        notifier.save()
        return s.json()

    @app.post("/api/notifications/test")
    async def test_notification(_: str = Auth) -> dict[str, Any]:
        problems = await notifier.deliver({"title": "Rackoon: test notification", "body": "Alerts will arrive like this.",
                                           "severity": "warning", "path": "/#/dashboard/alerts",
                                           "url": None, "alert": None})
        notifier.settings.last_error = "; ".join(problems) or None
        notifier.save()
        return {"ok": not problems, "problems": problems}

    @app.get("/api/notifications/push/key")
    async def push_key(_: str = Auth) -> dict[str, Any]:
        return {"publicKey": notifier.public_key()}

    @app.post("/api/notifications/push/subscribe")
    async def subscribe(body: SubscriptionIn, _: str = Auth) -> dict[str, Any]:
        if not body.endpoint.startswith("https://"):
            raise ApiError(422, "invalid", "That is not a push endpoint.")
        notifier.subscribe(body.model_dump())
        return notifier.settings.json()

    @app.post("/api/notifications/push/unsubscribe")
    async def unsubscribe(body: EndpointIn, _: str = Auth) -> dict[str, Any]:
        notifier.unsubscribe(body.endpoint)
        return notifier.settings.json()

    # --- search

    def items() -> list[search.SearchItem]:
        out: list[search.SearchItem] = []
        fleet = {r["id"]: r for r in rackoon.monitor.fleet_json(rackoon.store.load_servers())["servers"]}
        for server in rackoon.store.load_servers():
            row = fleet.get(server.id, {})
            o = row.get("overview")
            online = None if row.get("connection") in (None, "connecting") else row.get("connection") == "ok"
            out.append(search.server_item(server, "Online" if online else "Not answering" if online is False else "",
                                          online, o["os"]["prettyName"] if o else None,
                                          [a for a in ((o or {}).get("ipAddress"), (o or {}).get("tailscaleIP")) if a]))
            e = rackoon.docker.entries.get(server.id)
            if e is not None and e.snapshot is not None:
                out += search.docker_items(e.stacks, server)
                out += search.bookmark_items([(c.bookmark, c.service or c.name) for c in e.snapshot.containers
                                              if c.bookmark], server)
            elif server.id in monitor.states:
                reading = monitor.states[server.id]
                out += search.docker_state_items(reading, server)
                out += search.bookmark_items([(Bookmark(c.href), c.name) for c in reading.containers if c.href], server)
            snap = rackoon.services.snapshot(server.id)
            if snap is not None:
                out += search.service_items(snap, server, rackoon.services.shown(server.id))
        out += search.command_items(command_library.all_commands())
        out += search.alert_items(book.active())
        return out

    @app.get("/api/search")
    async def run_search(q: str, _: str = Auth) -> dict[str, Any]:
        results = search.run(q[:200], items())
        return {"query": q, "sections": [{"group": g, "title": search.TITLES[g], "items": [i.json() for i in found]}
                                         for g, found in results]}
