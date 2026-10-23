"""The dashboard's view of every server: recent health history and fleet totals (`Fleet.swift` in the Swift core).
Pure functions of readings the backend already has."""

from __future__ import annotations

from dataclasses import dataclass, field

from .models import AttentionItem
from .overview import Overview

SPACING_SECONDS = 55.0
CAPACITY = 60


@dataclass
class ServerState:
    """One server's latest reading, as the Overview and dashboard show it."""

    overview: Overview | None = None
    cpu_percent: float | None = None
    attention: list[AttentionItem] = field(default_factory=list)
    error: str | None = None
    updated_at: float | None = None
    """Unix seconds of the last successful poll (or of the cached snapshot)."""
    is_stale: bool = False
    """`overview` is a cached snapshot from an earlier run, not yet refreshed."""


@dataclass(frozen=True)
class HealthSample:
    at: float
    up: bool
    cpu_percent: float | None = None
    memory_fraction: float | None = None
    disk_fraction: float | None = None
    """The fullest disk's use, 0 to 1."""

    @staticmethod
    def of(state: ServerState, at: float) -> HealthSample | None:
        """The check a poll's result stands for; None for a cached snapshot or no reading yet."""
        if state.error:
            return HealthSample(at, False)
        o = state.overview
        if o is None or state.is_stale:
            return None
        disks = [d.use_percent / 100 for d in o.disks]
        return HealthSample(at, True, state.cpu_percent, o.memory.used_fraction, max(disks) if disks else None)


@dataclass
class HealthHistory:
    """About one check a minute for the last hour; a server going down or coming back is always kept."""

    samples: list[HealthSample] = field(default_factory=list)

    def record(self, sample: HealthSample) -> None:
        last = self.samples[-1] if self.samples else None
        if last is not None and last.up == sample.up and sample.at - last.at < SPACING_SECONDS:
            return
        self.samples.append(sample)
        if len(self.samples) > CAPACITY:
            del self.samples[: len(self.samples) - CAPACITY]

    @property
    def uptime_fraction(self) -> float | None:
        return sum(s.up for s in self.samples) / len(self.samples) if self.samples else None

    @property
    def down_count(self) -> int:
        return sum(not s.up for s in self.samples)


@dataclass
class FleetTotals:
    servers: int = 0
    online: int = 0
    cpu_percent: float | None = None
    """Weighted by each server's cores; None until some server has two readings."""
    memory_used: int = 0
    memory_total: int = 0
    disk_used: int = 0
    disk_total: int = 0
    updates: int = 0
    security_updates: int = 0
    reboot_required: int = 0
    unhealthy_containers: int = 0

    @staticmethod
    def of(states: list[ServerState]) -> FleetTotals:
        """Online counts fresh, error-free readings; the sums use every server's last known numbers."""
        t = FleetTotals()
        weighted, cores = 0.0, 0
        for s in states:
            t.servers += 1
            if s.error is None and s.overview is not None and not s.is_stale:
                t.online += 1
            o = s.overview
            if o is None:
                continue
            if s.cpu_percent is not None:
                weighted += s.cpu_percent * max(o.cores, 1)
                cores += max(o.cores, 1)
            t.memory_used += o.memory.used_bytes
            t.memory_total += o.memory.total_bytes
            for d in o.disks:
                t.disk_used += d.used_bytes
                t.disk_total += d.total_bytes
            t.updates += o.pending_updates
            t.security_updates += o.security_updates
            t.reboot_required += 1 if o.reboot_required else 0
            t.unhealthy_containers += len(o.unhealthy_containers)
        t.cpu_percent = weighted / cores if cores > 0 else None
        return t
