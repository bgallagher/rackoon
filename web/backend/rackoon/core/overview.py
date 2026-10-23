"""`Overview` (spec/models.schema.json) and the parser for the `overview` command (spec/fixtures/overview)."""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from . import spec
from .jsonmodel import json
from .text import key_values, split_sections, split_spaces, to_float, to_int, to_int32, trim_blanks


class ParseError(Exception):
    pass


class MissingSection(ParseError):
    def __init__(self, name: str) -> None:
        super().__init__(f"missing section {name}")
        self.name = name


class Malformed(ParseError):
    def __init__(self, section: str, detail: str) -> None:
        super().__init__(f"malformed {section}: {detail}")


@dataclass(frozen=True)
class OS:
    id: str
    name: str
    version: str
    pretty_name: str


@dataclass(frozen=True)
class CPUCounters:
    """Cumulative /proc/stat counters; two readings give a percentage."""

    total: int
    idle: int


@dataclass(frozen=True)
class Memory:
    total_bytes: int
    available_bytes: int

    @property
    def used_bytes(self) -> int:
        return self.total_bytes - self.available_bytes

    @property
    def used_fraction(self) -> float:
        return self.used_bytes / self.total_bytes if self.total_bytes > 0 else 0.0


@dataclass(frozen=True)
class Disk:
    filesystem: str
    mount: str
    total_bytes: int
    used_bytes: int
    use_percent: int


@dataclass(frozen=True)
class Overview:
    vendor: str
    product: str
    machine_id: str = field(metadata=json("machineID"))
    kernel: str
    boot_id: str = field(metadata=json("bootID"))
    ip_address: str | None
    tailscale_ip: str | None = field(metadata=json("tailscaleIP"))
    server_time: int
    utc_offset_seconds: int
    time_zone_name: str
    hostname: str
    os: OS
    uptime_seconds: float
    load1: float
    load5: float
    load15: float
    cores: int
    cpu: CPUCounters
    memory: Memory
    disks: list[Disk]
    reboot_required: bool
    unhealthy_containers: list[str]
    pending_updates: int
    security_updates: int

    @property
    def model_name(self) -> str:
        return " ".join(p for p in (self.vendor, self.product) if p)

    def cpu_percent(self, since: Overview) -> float | None:
        """CPU use (0 to 100) between an earlier reading and this one; None if no time passed."""
        total = self.cpu.total - since.cpu.total
        idle = self.cpu.idle - since.cpu.idle
        if total <= 0:
            return None
        return min(100.0, max(0.0, (total - idle) / total * 100))


_DF_LINE = re.compile(r"^[ ]*(\S+)[ ]+(\S+)[ ]+(\S+)[ ]+(\S+)[ ]+(\S+)[ ]+(.+)$", re.ASCII)
_IPV4 = re.compile(r"^[0-9]{1,3}(\.[0-9]{1,3}){3}$")


def ipv4(value: str | None) -> str | None:
    """A dotted IPv4 address, or None: it is shown and copied, so anything else the server prints is dropped."""
    if value is None:
        return None
    v = trim_blanks(value)
    if not _IPV4.fullmatch(v) or not all(int(p) <= 255 for p in v.split(".")):
        return None
    return v


def _first_set(*values: str | None) -> str:
    """Kotlin's `a ?: b ?: c`: the first that is present, even if empty."""
    return next(v for v in values if v is not None)


def command() -> str:
    return spec.script("overview")


def parse(output: str) -> Overview:
    sections = split_sections(output)

    def section(name: str) -> list[str]:
        if name not in sections:
            raise MissingSection(name)
        return sections[name]

    def first(name: str) -> str | None:
        lines = section(name)
        return lines[0] if lines else None

    hostname = first("hostname") or ""

    os_map = key_values(section("os"))
    os_id = os_map.get("ID")
    if os_id is None:
        raise Malformed("os", "no ID")
    os = OS(id=os_id, name=os_map.get("NAME", os_id), version=os_map.get("VERSION_ID", ""),
            pretty_name=_first_set(os_map.get("PRETTY_NAME"), os_map.get("NAME"), os_id))

    line = first("uptime")
    pieces = split_spaces(line) if line is not None else []
    uptime = to_float(pieces[0]) if pieces else None
    if uptime is None:
        raise Malformed("uptime", "no seconds")

    line = first("loadavg")
    load = [v for v in (to_float(p) for p in (split_spaces(line)[:3] if line is not None else [])) if v is not None]
    if len(load) != 3:
        raise Malformed("loadavg", "need 3 numbers")

    cores = to_int32(first("nproc"))
    if cores is None:
        raise Malformed("nproc", "no number")

    # cpu  user nice system idle iowait irq softirq steal ...
    line = first("stat")
    stat = [v for v in (to_int(p) for p in (split_spaces(line)[1:] if line is not None else [])) if v is not None]
    if len(stat) < 8:
        raise Malformed("stat", "need at least 8 counters")
    cpu = CPUCounters(total=sum(stat[:8]), idle=stat[3] + stat[4])

    mem = key_values(section("meminfo"), ":")

    def kb(key: str) -> int:
        raw = mem.get(key)
        parts = split_spaces(raw) if raw is not None else []
        v = to_int(parts[0]) if parts else None
        if v is None:
            raise Malformed("meminfo", f"no {key}")
        return v * 1024

    memory = Memory(total_bytes=kb("MemTotal"), available_bytes=kb("MemAvailable"))

    disks: list[Disk] = []
    for df_line in section("df")[1:]:
        # Filesystem 1-blocks Used Available Capacity Mounted-on (the mount may contain spaces)
        m = _DF_LINE.match(df_line)
        if not m:
            continue
        f = m.groups()
        total, used, pct = to_int(f[1]), to_int(f[2]), to_int32(f[4][:-1])
        if total is None or used is None or pct is None:
            continue
        disks.append(Disk(f[0], f[5], total, used, pct))

    # Optional: output captured before these sections existed still parses.
    system = key_values(sections.get("system", []))
    time_parts = split_spaces(system.get("time", ""))
    utc_offset = 0
    if len(time_parts) >= 2 and len(time_parts[1]) == 5 and time_parts[1][0] in "+-":
        h, m_ = to_int32(time_parts[1][1:3]), to_int32(time_parts[1][3:5])
        if h is not None and m_ is not None:
            utc_offset = (-1 if time_parts[1][0] == "-" else 1) * (h * 3600 + m_ * 60)

    reboot = first("reboot") == "yes"
    unhealthy = sections.get("unhealthy", [])
    updates = sections.get("updates")
    security = sections.get("security")
    pending = (to_int32(updates[0]) if updates else None) or 0
    secure = (to_int32(security[0]) if security else None) or 0

    return Overview(
        vendor=system.get("vendor", ""), product=system.get("product", ""), machine_id=system.get("machine_id", ""),
        kernel=system.get("kernel", ""), boot_id=system.get("boot_id", ""),
        ip_address=ipv4(system.get("ip")), tailscale_ip=ipv4(system.get("tailscale_ip")),
        server_time=(to_int(time_parts[0]) if time_parts else None) or 0, utc_offset_seconds=utc_offset,
        time_zone_name=time_parts[2] if len(time_parts) >= 3 else "",
        hostname=hostname, os=os, uptime_seconds=uptime, load1=load[0], load5=load[1], load15=load[2], cores=cores,
        cpu=cpu, memory=memory, disks=disks, reboot_required=reboot, unhealthy_containers=list(unhealthy),
        pending_updates=pending, security_updates=secure,
    )
