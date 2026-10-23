"""Search across everything Rackoon knows (the Swift core's `Search` and `SearchItems`): servers, Docker stacks and
containers, services, bookmarks, the Commands library and alerts. Pure: the items are built from what the backend
already holds (nothing is fetched for a search), and `run` ranks and groups them."""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from typing import Any

from .alerts import ServerAlert
from .command_library import LibraryCommand
from .docker import Bookmark, DockerStack, standalone_id
from .docker_states import DockerStatesReading
from .models import Server, Severity
from .services import DiscoveredService, Kind, ServicesSnapshot, Status

GROUPS = ("servers", "docker", "services", "bookmarks", "commands", "alerts")
TITLES = {"servers": "Servers", "docker": "Docker", "services": "Services", "bookmarks": "Bookmarks",
          "commands": "Commands", "alerts": "Alerts"}
MINIMUM_LENGTH = 2


@dataclass(frozen=True)
class SearchItem:
    group: str
    id: str
    title: str
    subtitle: str
    target: dict[str, str]
    """Where it leads: {"kind": "server"|"stack"|"service"|"bookmark"|"command"|"alert", "server": .., "id": ..}."""
    server_name: str | None = None
    keywords: list[str] = field(default_factory=list)
    tone: str | None = None
    link: str | None = None

    def json(self) -> dict[str, Any]:
        return {"group": self.group, "id": self.id, "title": self.title, "subtitle": self.subtitle,
                "serverName": self.server_name, "target": self.target, "tone": self.tone, "link": self.link}


def is_searchable(query: str) -> bool:
    return len(query.strip()) >= MINIMUM_LENGTH


def fold(s: str) -> str:
    """Lowercase, accents removed."""
    return "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c)).casefold()


_SPLIT = re.compile(r"[^\w]|_", re.UNICODE)


def _words(s: str) -> list[str]:
    return [w for w in _SPLIT.split(s) if w]


def run(query: str, items: list[SearchItem]) -> list[tuple[str, list[SearchItem]]]:
    """Every word must be found: anywhere in the title, or at the start of a word of the subtitle, server or keywords
    (so "pi" finds Pi-hole, not every "pipe"). Addresses and paths ("100.64", "/admin") match as written. Ranked: the
    title is the query, starts with it, has a word starting with it, contains it, then elsewhere. In group order."""
    if not is_searchable(query):
        return []
    q = fold(query.strip())
    words = [w for w in q.split(" ") if w]
    scored: list[tuple[SearchItem, int]] = []
    for item in items:
        title = fold(item.title)
        rest = fold(" ".join([item.subtitle, item.server_name or "", *item.keywords]))
        rest_words = _words(rest)

        def in_rest(w: str) -> bool:
            return any(r.startswith(w) for r in rest_words) or (any(not c.isalnum() for c in w) and w in rest)
        if not all(w in title or in_rest(w) for w in words):
            continue
        score = 0
        if title == q:
            score += 1000
        if title.startswith(q):
            score += 500
        title_words = _words(title)
        for w in words:
            if any(t.startswith(w) for t in title_words):
                score += 100
            elif w in title:
                score += 50
            elif any(r.startswith(w) for r in rest_words):
                score += 20
            else:
                score += 5
        score -= min(len(title), 60) // 6
        if item.tone == "danger":
            score += 3
        scored.append((item, score))
    out = []
    for g in GROUPS:
        found = sorted((x for x in scored if x[0].group == g), key=lambda x: (-x[1], x[0].title.casefold()))
        if found:
            out.append((g, [i for i, _ in found]))
    return out


# --- building the items -------------------------------------------------------------------------------------------


def server_item(server: Server, summary: str, online: bool | None, os: str | None, addresses: list[str]) -> SearchItem:
    where = f"{server.user}@{server.host}" if server.user else server.host
    return SearchItem("servers", f"server|{server.id}", server.name, " · ".join(x for x in (where, os, summary) if x),
                      {"kind": "server", "server": server.id, "id": server.id}, None,
                      [server.host, server.ssh_config_alias or "", *addresses],
                      None if online is None else ("ok" if online else "danger"))


def docker_items(stacks: list[DockerStack], server: Server) -> list[SearchItem]:
    out = []
    for s in stacks:
        running, total = s.running_count, len(s.containers)
        state = "not started" if total == 0 else f"{running} of {total} running"
        tone = ("danger" if s.unhealthy_count > 0 else "idle" if total > 0 and running == 0 else
                "warn" if running < total else "ok")
        target = {"kind": "stack", "server": server.id, "id": s.id}
        out.append(SearchItem("docker", f"stack|{server.id}|{s.id}", s.name, f"{s.kind_label} · {state}", target,
                              server.name, [w for c in s.containers for w in (c.name, c.service or "", c.image)], tone))
        if s.is_standalone:
            continue
        for c in s.containers:
            out.append(SearchItem(
                "docker", f"container|{server.id}|{c.id}", c.service or c.name,
                f"Container in {s.name} · {c.image} · {'unhealthy' if c.is_unhealthy else c.state}", target,
                server.name, [c.name, c.image, *[str(p.host_port) for p in c.ports]],
                "danger" if c.is_unhealthy else "ok" if c.is_running else "idle"))
    return out


def docker_state_items(reading: DockerStatesReading, server: Server) -> list[SearchItem]:
    """From the light background check, when the server's Docker screen has not been read."""
    out = []
    projects: dict[str, list[Any]] = {}
    for c in reading.containers:
        if c.project:
            projects.setdefault(c.project, []).append(c)
    for project, cs in sorted(projects.items()):
        running = sum(c.state == "running" for c in cs)
        out.append(SearchItem("docker", f"stack|{server.id}|{project}", project,
                              f"Compose Stack · {running} of {len(cs)} running",
                              {"kind": "stack", "server": server.id, "id": project}, server.name, [c.name for c in cs],
                              "ok" if running == len(cs) else "idle" if running == 0 else "warn"))
    for c in reading.containers:
        stack = c.project or standalone_id(c.name)
        out.append(SearchItem("docker", f"container|{server.id}|{c.id}", c.name,
                              ("Standalone container" if not c.project else f"Container in {c.project}") + f" · {c.status}",
                              {"kind": "stack", "server": server.id, "id": stack}, server.name, [],
                              "danger" if "unhealthy" in c.status else "ok" if c.state == "running" else "idle"))
    return out


_STATE = {Status.RUNNING: "running", Status.STARTING: "starting", Status.RESTARTING: "crash loop",
          Status.STOPPING: "stopping", Status.STOPPED: "stopped", Status.FAILED: "failed"}


def service_items(snapshot: ServicesSnapshot, server: Server, shown: list[DiscoveredService]) -> list[SearchItem]:
    out = []
    for s in shown:
        kind = "Started by hand" if s.kind is Kind.PROCESS else "User service" if s.kind is Kind.USER else "System service"
        out.append(SearchItem("services", f"service|{server.id}|{s.id}", s.name,
                              f"{kind} · {_STATE[s.status]}" + (f" · {s.unit}" if s.unit else ""),
                              {"kind": "service", "server": server.id, "id": s.id}, server.name,
                              [s.detail, s.product or "", *[str(p.port) for p in s.ports]],
                              "danger" if s.is_problem else "ok" if s.status is Status.RUNNING else "idle"))
    return out


def bookmark_items(items: list[tuple[Bookmark, str]], server: Server) -> list[SearchItem]:
    seen: set[str] = set()
    out = []
    for b, service in items:
        if b.href in seen:
            continue
        seen.add(b.href)
        out.append(SearchItem("bookmarks", f"bookmark|{server.id}|{b.href}", b.name or service,
                              " · ".join(x for x in (b.href, b.group) if x),
                              {"kind": "bookmark", "server": server.id, "id": b.href}, server.name,
                              [service, b.description or ""], link=b.href))
    return out


def command_items(commands: list[LibraryCommand]) -> list[SearchItem]:
    return [SearchItem("commands", f"command|{c.id}", c.title,
                       f"{c.group} · {'changes the server, asks first' if c.is_mutating else 'read-only'}"
                       + (" · sudo" if c.root else ""),
                       {"kind": "command", "server": "", "id": c.id}, None, [c.summary, c.id.replace("_", " ")])
            for c in commands]


def alert_items(alerts: list[ServerAlert]) -> list[SearchItem]:
    return [SearchItem("alerts", f"alert|{a.id}", a.title,
                       f"{a.severity.value.capitalize()} · {a.category.title}" + (f" · {a.detail}" if a.detail else ""),
                       {"kind": "alert", "server": a.server_id, "id": a.id}, a.server_name, [a.key],
                       "danger" if a.severity is Severity.CRITICAL else "warn" if a.severity is Severity.WARNING else None)
            for a in alerts]
