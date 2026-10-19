"""What the Docker screens show, worked out from a snapshot (`DockerPresentation` in the Kotlin core, `DockerTotals`
and `mainWebPort` in the Swift core's Fleet.swift)."""

from __future__ import annotations

import enum
from collections.abc import Callable
from dataclasses import dataclass
from urllib.parse import urlsplit

from .docker import Bookmark, DockerContainer, DockerSnapshot, DockerStack, is_compose_project_name
from .overview import Disk, Overview
from .stack_actions import NEEDS_COMPOSE_REASON
from .text import round_half_up

WEB_PORTS = (80, 443, 8080, 3000, 8000, 8443, 5000, 9000, 8081, 8888, 3001, 5173, 8096, 9443, 8123)


class Severity(enum.Enum):
    OK = "ok"
    WARNING = "warning"
    DANGER = "danger"
    IDLE = "idle"


def stack_status(stack: DockerStack) -> tuple[str, Severity]:
    """Unhealthy first, then not started, stopped, partly stopped; a healthy stack says nothing."""
    if stack.unhealthy_count > 0:
        return f"{stack.unhealthy_count} unhealthy", Severity.DANGER
    if not stack.containers:
        return "Not started", Severity.IDLE
    if stack.running_count == 0:
        return "Stopped", Severity.IDLE
    if stack.stopped_count > 0:
        return f"{stack.stopped_count} stopped", Severity.WARNING
    return "", Severity.OK


def summary(snapshot: DockerSnapshot) -> str:
    """"9 stacks · 20 containers · 19 healthy, 1 unhealthy, 1 stopped"."""
    stacks = sum(not s.is_standalone for s in snapshot.stacks)
    c = snapshot.containers
    unhealthy = sum(x.is_unhealthy for x in c)
    healthy = sum(x.is_running and not x.is_unhealthy for x in c)
    stopped = len(c) - healthy - unhealthy
    out = []
    if stacks:
        out.append(f"{stacks} {'stack' if stacks == 1 else 'stacks'}")
    out.append(f"{len(c)} {'container' if len(c) == 1 else 'containers'}")
    state = ", ".join(x for x in (f"{healthy} healthy" if healthy else "", f"{unhealthy} unhealthy" if unhealthy else "",
                                  f"{stopped} stopped" if stopped else "") if x)
    if state:
        out.append(state)
    return " · ".join(out)


def compose_blocked_reason(stack: DockerStack) -> str | None:
    """Why the compose actions are off for this stack, or None."""
    if stack.is_standalone:
        return NEEDS_COMPOSE_REASON
    if not is_compose_project_name(stack.name):
        return "Its compose project name has characters Rackoon won't send to a shell"
    if stack.working_dir is None or not (stack.config_files or stack.config_file):
        return "Its containers disagree about the compose folder or files, or don't say"
    return None


def main_web_port(stack: DockerStack) -> int | None:
    """The bookmark's port if published, else a published TCP port whose container side is a usual web port."""
    published = [p for c in stack.containers for p in c.ports if p.proto == "tcp"]
    for c in stack.containers:
        if c.bookmark is not None:
            try:
                port = urlsplit(c.bookmark.href).port
            except ValueError:
                port = None
            if port is not None and any(p.host_port == port for p in published):
                return port
    for web in WEB_PORTS:
        p = next((p for p in published if p.container_port == web), None)
        if p is not None:
            return p.host_port
    return None


def letter(name: str) -> str:
    return name[0].upper() if name else "?"


def hue(name: str) -> int:
    """djb2 over code points mod 360, the Mac's and Android's letter-tile colour."""
    h = 5381
    for ch in name:
        h = (h * 33 + ord(ch)) & 0xFFFFFFFFFFFFFFFF
    signed = h - (1 << 64) if h >= 1 << 63 else h
    r = signed % 360 if signed >= 0 else -((-signed) % 360)
    return r + 360 if r < 0 else r


def image_name(image: str) -> tuple[str, str | None]:
    """The repository (may be shortened) and the tag (never cut); a registry port's colon is not a tag."""
    at = image.find("@")
    if at >= 0:
        return image[:at], "@" + image[at + 1:at + 20]
    colon = image.rfind(":")
    if colon >= 0 and colon > image.rfind("/"):
        return image[:colon], image[colon:]
    return image, None


class LinkScope(enum.Enum):
    LOCAL = "local"
    TAILSCALE = "tailscale"
    PUBLIC = "public"


def link_scope(href: str) -> LinkScope:
    try:
        host = (urlsplit(href).hostname or "").lower()
    except ValueError:
        return LinkScope.PUBLIC
    if not host:
        return LinkScope.PUBLIC
    if host.endswith(".ts.net"):
        return LinkScope.TAILSCALE
    pieces = host.split(".")
    octets = [int(p) for p in pieces if p.isdigit()]
    if len(pieces) == 4 and len(octets) == 4:
        a, b = octets[0], octets[1]
        if a == 100 and 64 <= b <= 127:
            return LinkScope.TAILSCALE
        private = a in (10, 127) or (a == 192 and b == 168) or (a == 172 and 16 <= b <= 31)
        return LinkScope.LOCAL if private else LinkScope.PUBLIC
    local = (".local", ".lan", ".home", ".internal", ".home.arpa", ".localdomain")
    return LinkScope.LOCAL if "." not in host or host.endswith(local) else LinkScope.PUBLIC


def short_address(b: Bookmark) -> str:
    """The host, plus a port and a path when there is one ("app.example.com/tv")."""
    try:
        u = urlsplit(b.href)
        port = u.port
    except ValueError:
        return b.href
    if not u.hostname:
        return b.href
    path = u.path if u.path not in ("", "/") else ""
    return u.hostname + (f":{port}" if port else "") + path


@dataclass(frozen=True)
class DockerTotals:
    stacks: int
    containers: int
    running: int
    unhealthy: int
    cpu_percent_of_host: float | None
    memory_bytes: int
    memory_fraction_of_host: float | None
    data_disk: Disk | None


DATA_ROOT = "/var/lib/docker"


def disk_holding(path: str, disks: list[Disk]) -> Disk | None:
    """The mount that is the longest prefix of `path`."""
    holding = [d for d in disks if d.mount == "/" or path == d.mount or
               path.startswith(d.mount if d.mount.endswith("/") else d.mount + "/")]
    return max(holding, key=lambda d: len(d.mount), default=None)


def totals(snapshot: DockerSnapshot, host: Overview | None) -> DockerTotals:
    c = snapshot.containers
    cpus = [x.cpu_percent for x in c if x.cpu_percent is not None]
    memory = sum(x.memory_used_bytes or 0 for x in c)
    cores = host.cores if host else 0
    total_mem = host.memory.total_bytes if host else 0
    return DockerTotals(
        stacks=sum(not s.is_standalone for s in snapshot.stacks), containers=len(c),
        running=sum(x.is_running for x in c), unhealthy=sum(x.is_unhealthy for x in c),
        cpu_percent_of_host=sum(cpus) / cores if cpus and cores > 0 else None, memory_bytes=memory,
        memory_fraction_of_host=memory / total_mem if total_mem > 0 else None,
        data_disk=disk_holding(DATA_ROOT, host.disks) if host else None)


def usage_text(c: DockerContainer, format_bytes: Callable[[int], str]) -> str:
    """"6% · 147 MB", or the state when it isn't running."""
    if not c.is_running:
        return c.state
    if c.cpu_percent is None or c.memory_used_bytes is None:
        return "—"
    return f"{round_half_up(c.cpu_percent)}% · {format_bytes(c.memory_used_bytes)}"


def bookmark_items(snapshot: DockerSnapshot) -> list[tuple[DockerStack, DockerContainer, Bookmark]]:
    return [(s, c, c.bookmark) for s in snapshot.stacks for c in s.containers if c.bookmark is not None]


def bookmark_groups(snapshot: DockerSnapshot) -> list[str]:
    return sorted({b.group for _, _, b in bookmark_items(snapshot) if b.group}, key=str.casefold)
