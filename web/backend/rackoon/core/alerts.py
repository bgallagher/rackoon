"""Alerts: everything that needs the user, across every server, with a memory (the Swift core's `AlertRules`,
`AlertBook`, `CertificateCheck`). Each server's readings come in by source; the rules turn a reading into signals and
the book keeps the alerts: first and last seen, when each went away, whether the user has seen or muted it, and which
ones are new enough to notify about. A reading only resolves alerts of its own source, so a check that did not run never
clears another check's alerts. Pure."""

from __future__ import annotations

import enum
from collections.abc import Callable
from dataclasses import dataclass, field, replace
from typing import Any
from urllib.parse import urlsplit

from . import attention, connection_failure, unraid_view
from .docker_states import DockerStatesReading
from .models import Severity
from .overview import Overview
from .services import DiscoveredService, ServicesSnapshot, Status
from .unraid import UnraidSnapshot

RANK = {Severity.INFO: 0, Severity.WARNING: 1, Severity.CRITICAL: 2}
HISTORY_DAYS = 7
HISTORY_LIMIT = 300
CERT_WARNING_DAYS = 21.0
CERT_CRITICAL_DAYS = 7.0


class Source(enum.Enum):
    CONNECTION = "connection"
    OVERVIEW = "overview"
    SERVICES = "services"
    CONTAINERS = "containers"
    STORAGE = "storage"
    CERTIFICATES = "certificates"


class Category(enum.Enum):
    CONNECTION = "connection"
    DISK = "disk"
    CONTAINERS = "containers"
    SERVICES = "services"
    UPDATES = "updates"
    STORAGE = "storage"
    CERTIFICATES = "certificates"

    @property
    def title(self) -> str:
        return self.value.capitalize()


@dataclass(frozen=True)
class Fix:
    """Where to deal with it: a screen and, when it helps, the thing on it (a stack id, a service id, an address)."""

    screen: str
    target: str | None = None


@dataclass(frozen=True)
class Signal:
    key: str
    category: Category
    severity: Severity
    title: str
    detail: str | None = None
    fix: Fix | None = None


@dataclass
class ServerAlert:
    id: str
    """`<server id>|<source>|<key>`."""
    server_id: str
    server_name: str
    source: Source
    key: str
    category: Category
    severity: Severity
    title: str
    detail: str | None
    fix: Fix | None
    first_seen: float
    last_seen: float
    resolved_at: float | None = None
    acknowledged: bool = False

    @property
    def is_active(self) -> bool:
        return self.resolved_at is None

    def json(self, muted: bool = False) -> dict[str, Any]:
        return {"id": self.id, "serverId": self.server_id, "serverName": self.server_name, "source": self.source.value,
                "key": self.key, "category": self.category.value, "severity": self.severity.value, "title": self.title,
                "detail": self.detail, "fix": {"screen": self.fix.screen, "target": self.fix.target} if self.fix else None,
                "firstSeen": self.first_seen, "lastSeen": self.last_seen, "resolvedAt": self.resolved_at,
                "acknowledged": self.acknowledged, "muted": muted}

    @staticmethod
    def from_json(d: dict[str, Any]) -> ServerAlert:
        fix = d.get("fix")
        return ServerAlert(d["id"], d["serverId"], d["serverName"], Source(d["source"]), d["key"], Category(d["category"]),
                           Severity(d["severity"]), d["title"], d.get("detail"),
                           Fix(fix["screen"], fix.get("target")) if fix else None, float(d["firstSeen"]),
                           float(d["lastSeen"]), d.get("resolvedAt"), bool(d.get("acknowledged")))


def alert_id(server: str, source: Source, key: str) -> str:
    return f"{server}|{source.value}|{key}"


@dataclass
class AlertBook:
    alerts: list[ServerAlert] = field(default_factory=list)
    muted: set[str] = field(default_factory=set)
    baselined: set[str] = field(default_factory=set)
    """`<server>|<source>` pairs that had a reading: the very first reading of a server never notifies."""

    def apply(self, server: str, server_name: str, source: Source, signals: list[Signal], now: float) -> list[ServerAlert]:
        """Records one reading. Returns the alerts worth a notification: new ones (warning or worse) and ones that
        just became critical, never on the source's first reading and never muted ones."""
        baseline = f"{server}|{source.value}"
        first = baseline not in self.baselined
        self.baselined.add(baseline)
        raised: list[ServerAlert] = []
        seen: set[str] = set()
        for s in signals:
            aid = alert_id(server, source, s.key)
            if aid in seen:
                continue
            seen.add(aid)
            existing = next((a for a in self.alerts if a.id == aid and a.is_active), None)
            if existing is not None:
                worse = s.severity is Severity.CRITICAL and existing.severity is not Severity.CRITICAL
                existing.severity, existing.title, existing.detail, existing.fix = s.severity, s.title, s.detail, s.fix
                existing.category, existing.server_name, existing.last_seen = s.category, server_name, now
                if worse:
                    existing.acknowledged = False
                    if not first and aid not in self.muted:
                        raised.append(existing)
            else:
                a = ServerAlert(aid, server, server_name, source, s.key, s.category, s.severity, s.title, s.detail, s.fix,
                                now, now)
                self.alerts.append(a)
                if not first and s.severity is not Severity.INFO and aid not in self.muted:
                    raised.append(a)
        for a in self.alerts:
            if a.server_id == server and a.source is source and a.is_active and a.id not in seen:
                a.resolved_at = now
        self.prune(now)
        return raised

    def active(self, server: str | None = None, include_muted: bool = False) -> list[ServerAlert]:
        """Worst first, then oldest first."""
        out = [a for a in self.alerts if a.is_active and (server is None or a.server_id == server)
               and (include_muted or a.id not in self.muted)]
        return sorted(out, key=lambda a: (-RANK[a.severity], a.first_seen))

    def muted_alerts(self, server: str | None = None) -> list[ServerAlert]:
        out = [a for a in self.alerts if a.is_active and a.id in self.muted and (server is None or a.server_id == server)]
        return sorted(out, key=lambda a: -a.first_seen)

    def history(self, server: str | None = None) -> list[ServerAlert]:
        out = [a for a in self.alerts if not a.is_active and (server is None or a.server_id == server)]
        return sorted(out, key=lambda a: -(a.resolved_at or 0))

    def unseen_count(self, server: str | None = None) -> int:
        """What a badge counts: active warnings and critical ones neither seen nor muted."""
        return sum(1 for a in self.active(server) if not a.acknowledged and a.severity is not Severity.INFO)

    def worst_unseen(self, server: str | None = None) -> Severity | None:
        sev = [a.severity for a in self.active(server) if not a.acknowledged and a.severity is not Severity.INFO]
        return max(sev, key=lambda s: RANK[s]) if sev else None

    def acknowledge(self, aid: str, seen: bool = True) -> None:
        for a in self.alerts:
            if a.id == aid and a.is_active:
                a.acknowledged = seen

    def acknowledge_all(self, server: str | None = None) -> None:
        for a in self.alerts:
            if a.is_active and (server is None or a.server_id == server):
                a.acknowledged = True

    def mute(self, aid: str, on: bool = True) -> None:
        if on:
            self.muted.add(aid)
        else:
            self.muted.discard(aid)

    def clear_history(self, server: str | None = None) -> None:
        self.alerts = [a for a in self.alerts if a.is_active or (server is not None and a.server_id != server)]

    def forget(self, server_id: str) -> bool:
        before = (len(self.alerts), len(self.muted), len(self.baselined))
        self.alerts = [a for a in self.alerts if a.server_id != server_id]
        self.muted = {m for m in self.muted if not m.startswith(server_id + "|")}
        self.baselined = {b for b in self.baselined if not b.startswith(server_id + "|")}
        return before != (len(self.alerts), len(self.muted), len(self.baselined))

    def prune(self, now: float) -> None:
        cutoff = now - HISTORY_DAYS * 86400
        self.alerts = [a for a in self.alerts if a.resolved_at is None or a.resolved_at >= cutoff]
        resolved = sorted((a for a in self.alerts if not a.is_active), key=lambda a: a.resolved_at or 0)
        if len(resolved) > HISTORY_LIMIT:
            drop = {a.id for a in resolved[:len(resolved) - HISTORY_LIMIT]}
            self.alerts = [a for a in self.alerts if a.is_active or a.id not in drop]

    def json(self) -> dict[str, Any]:
        return {"alerts": [a.json() for a in self.alerts], "muted": sorted(self.muted),
                "baselined": sorted(self.baselined)}

    @staticmethod
    def from_json(d: dict[str, Any]) -> AlertBook:
        return AlertBook([ServerAlert.from_json(a) for a in d.get("alerts", [])], set(d.get("muted", [])),
                         set(d.get("baselined", [])))


# --- rules: from readings to signals ------------------------------------------------------------------------------


def connection(error: str | None, blocked: str | None) -> list[Signal]:
    if blocked:
        changed = "changed" in blocked.lower()
        return [Signal("host_key_changed" if changed else "host_key_unknown", Category.CONNECTION,
                       Severity.CRITICAL if changed else Severity.INFO,
                       "Host key changed" if changed else "Host key not trusted yet", blocked, Fix("overview"))]
    if error:
        explained = connection_failure.explain(error)
        refused = "Permission denied" in error
        return [Signal("login_refused" if refused else "not_answering", Category.CONNECTION, Severity.CRITICAL,
                       "Login refused" if refused else "Not answering",
                       explained.headline if explained else error.split("\n")[0], Fix("overview"))]
    return []


def overview(o: Overview, unraid_snapshot: UnraidSnapshot | None = None, is_unraid: bool = False) -> list[Signal]:
    items = attention.evaluate(o)
    if is_unraid:
        items = [i for i in items if not i.id.startswith("disk_high:")]  # storage alerts judge an Unraid array
    out = []
    for item in items:
        category = (Category.DISK if item.id.startswith("disk") else Category.CONTAINERS
                    if item.id.startswith("container") else Category.UPDATES)
        title = {"security_updates": "Security updates available", "reboot_required": "Reboot required"}.get(
            item.id, "Disk almost full" if item.id.startswith("disk_high") else "Container unhealthy")
        out.append(Signal(item.id, category, item.severity, title, item.message, Fix(item.fix)))
    return out


def services(snapshot: ServicesSnapshot, is_watched: Callable[[DiscoveredService], bool]) -> list[Signal]:
    out = []
    for s in snapshot.services:
        if not is_watched(s):
            continue
        fix = Fix("services", s.id)
        if s.status is Status.FAILED:
            detail = " · ".join(x for x in (s.unit, f"result: {s.result}" if s.result else None) if x)
            out.append(Signal(f"service_failed:{s.id}", Category.SERVICES, Severity.CRITICAL, f"{s.name} failed",
                              detail, fix))
        elif s.status is Status.RESTARTING:
            out.append(Signal(f"service_crashing:{s.id}", Category.SERVICES, Severity.CRITICAL,
                              f"{s.name} keeps crashing", f"systemd has restarted {s.unit or s.name} {s.restarts} "
                              f"time{'' if s.restarts == 1 else 's'}.", fix))
        elif s.status is Status.STOPPED and s.enabled_at_boot is True:
            out.append(Signal(f"service_stopped:{s.id}", Category.SERVICES, Severity.WARNING, f"{s.name} is stopped",
                              f"{s.unit or s.name} starts at boot but is not running now.", fix))
    return out


def containers(reading: DockerStatesReading) -> list[Signal]:
    """Down containers: restarting, dead, or exited with an error (0, 130, 137 and 143 are not problems)."""
    if reading.problem == "notInstalled":
        return []
    if reading.problem == "permissionDenied":
        return [Signal("docker_needs_sudo", Category.CONTAINERS, Severity.INFO, "Containers not checked",
                       "Docker refuses this user, so background checks can't see containers. Unlock Docker with sudo on "
                       "the Docker screen to look.", Fix("docker"))]
    if reading.problem == "other":
        return [Signal("docker_unreadable", Category.CONTAINERS, Severity.WARNING, "Docker did not answer",
                       reading.problem_text, Fix("docker"))]
    out = []
    for c in reading.containers:
        fix = Fix("docker", c.project or f"standalone/{c.name}")
        if c.state == "restarting":
            out.append(Signal(f"container_down:{c.name}", Category.CONTAINERS, Severity.CRITICAL,
                              f"{c.name} keeps restarting", c.status, fix))
        elif c.state == "dead":
            out.append(Signal(f"container_down:{c.name}", Category.CONTAINERS, Severity.CRITICAL, f"{c.name} is dead",
                              "Docker could not stop or remove it cleanly.", fix))
        elif c.state == "exited":
            code = c.exit_code
            if code is not None and code not in (0, 130, 137, 143):
                out.append(Signal(f"container_down:{c.name}", Category.CONTAINERS, Severity.WARNING,
                                  f"{c.name} stopped with an error", c.status, fix))
    return out


def storage(snapshot: UnraidSnapshot) -> list[Signal]:
    return [Signal(i.id, Category.STORAGE, i.severity,
                   "Array needs attention" if i.id.startswith(("array", "parity")) else "Disk needs attention",
                   i.message, Fix("overview")) for i in unraid_view.evaluate(snapshot)]


@dataclass(frozen=True)
class CertificateCheck:
    url: str
    host: str
    expires: float | None
    """Unix seconds; None when the site could not be reached or showed no certificate."""
    checked_at: float


def certificate_targets(hrefs: list[str]) -> list[str]:
    """The https addresses worth checking: one per host and port."""
    seen: set[str] = set()
    out = []
    for href in hrefs:
        try:
            u = urlsplit(href)
            port = u.port
        except ValueError:
            continue
        if u.scheme.lower() != "https" or not u.hostname:
            continue
        key = f"{u.hostname.lower()}:{port or 443}"
        if key in seen:
            continue
        seen.add(key)
        out.append(f"https://{u.hostname}{f':{port}' if port else ''}/")
    return out


def _days(d: float) -> str:
    n = int(d)
    return "less than a day" if n < 1 else f"{n} day{'' if n == 1 else 's'}"


def certificates(checks: list[CertificateCheck], now: float) -> list[Signal]:
    out = []
    for c in checks:
        if c.expires is None:
            continue
        days = (c.expires - now) / 86400
        fix = Fix("bookmarks", c.url)
        if days <= 0:
            out.append(Signal(f"cert:{c.host}", Category.CERTIFICATES, Severity.CRITICAL,
                              f"Certificate expired: {c.host}", f"It expired {_days(-days)} ago.", fix))
        elif days <= CERT_WARNING_DAYS:
            out.append(Signal(f"cert:{c.host}", Category.CERTIFICATES,
                              Severity.CRITICAL if days <= CERT_CRITICAL_DAYS else Severity.WARNING,
                              f"Certificate expires soon: {c.host}", f"It expires in {_days(days)}.", fix))
    return out


def with_severity(s: Signal, severity: Severity) -> Signal:
    return replace(s, severity=severity)
