"""Unraid NAS: the `unraid` command's parser (spec/fixtures/unraid), ported from the Swift core's Unraid.swift.

Everything comes from files Unraid's own web UI (emhttp) keeps current, so reading never spins a sleeping disk up.
Ini files arrive as `[section]` lines followed by `key="value"` lines; sizes are KiB.
"""

from __future__ import annotations

import enum
from dataclasses import dataclass

from . import spec
from .overview import OS
from .text import key_values, round_half_up, split_sections, to_float, to_int, trim_blanks


class NotUnraid(Exception):
    """No `##unraid` version: the server is not Unraid (or /etc/unraid-version is unreadable)."""


def is_unraid(os: OS) -> bool:
    i, name = os.id.lower(), os.name.lower()
    return i in ("unraid-os", "unraid") or name.startswith("unraid")


@dataclass(frozen=True)
class Operation:
    """A running parity check, sync, rebuild or clear, in KiB as `md` reports it."""

    action: str
    position_ki_b: int
    size_ki_b: int
    bytes_per_second: float | None

    @property
    def fraction(self) -> float:
        return min(1.0, self.position_ki_b / self.size_ki_b) if self.size_ki_b > 0 else 0.0


@dataclass(frozen=True)
class ArrayStatus:
    state: str
    fs_state: str
    num_disks: int
    disabled: int
    invalid: int
    missing: int
    share_count: int
    operation: Operation | None
    last_sync_start: int | None
    last_sync_end: int | None
    last_sync_errors: int | None
    last_sync_exit: int | None

    @property
    def is_started(self) -> bool:
        return self.state == "STARTED"


@dataclass(frozen=True)
class Filesystem:
    type: str
    status: str
    mount: str
    total_bytes: int
    used_bytes: int
    free_bytes: int
    devices: int
    profile: str

    @property
    def use_percent(self) -> int:
        return round_half_up(self.used_bytes / self.total_bytes * 100) if self.total_bytes > 0 else 0


class Role(enum.Enum):
    PARITY = "parity"
    DATA = "data"
    POOL = "pool"
    FLASH = "flash"
    OTHER = "other"


@dataclass(frozen=True)
class Device:
    name: str
    device: str
    identity: str
    size_bytes: int
    transport: str
    rotational: bool
    spun_down: bool
    status: str
    temperature: int | None
    errors: int
    role: Role
    filesystem: Filesystem | None


@dataclass(frozen=True)
class Share:
    name: str
    comment: str
    use_cache: str
    cache_pool: str
    free_bytes: int


@dataclass(frozen=True)
class Sensor:
    chip: str
    label: str
    value: float


@dataclass(frozen=True)
class ZFSPool:
    name: str
    health: str


@dataclass(frozen=True)
class ParityCheck:
    finished: str
    duration_seconds: int
    bytes_per_second: int
    exit_code: int
    errors: int
    action: str
    size_ki_b: int


@dataclass(frozen=True)
class UnraidSnapshot:
    version: str
    cpu_model: str
    array: ArrayStatus
    devices: list[Device]
    shares: list[Share]
    zfs_pools: list[ZFSPool]
    temperatures: list[Sensor]
    fans: list[Sensor]
    parity_checks: list[ParityCheck]


def command() -> str:
    return spec.script("unraid")


def _kib(value: str | None) -> int:
    return (to_int(value) or 0) * 1024


def ini_sections(lines: list[str]) -> list[dict[str, str]]:
    """`["disk1"]` / `[disk1]` headers, each followed by its key="value" lines."""
    out: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    current_name = ""
    for line in lines:
        if line.startswith("["):
            if current is not None:
                current["_section"] = current_name
                out.append(current)
            current_name = line.strip('[]" ')
            current = {}
        elif current is not None:
            current.update(key_values([line]))
    if current is not None:
        current["_section"] = current_name
        out.append(current)
    return out


_ROLES = {"Parity": Role.PARITY, "Data": Role.DATA, "Cache": Role.POOL, "Flash": Role.FLASH}


def _device(s: dict[str, str]) -> Device:
    filesystem: Filesystem | None = None
    fs_type, mount = s.get("fsType"), s.get("fsMountpoint")
    if fs_type and mount is not None:
        filesystem = Filesystem(fs_type, s.get("fsStatus", ""), mount, _kib(s.get("fsSize")), _kib(s.get("fsUsed")),
                                _kib(s.get("fsFree")), to_int(s.get("devices")) or 1, s.get("fsProfile", ""))
    temp = s.get("temp")
    name = s.get("name")
    return Device(
        name=name if name is not None else s.get("_section", ""), device=s.get("device", ""),
        identity=s.get("id", ""), size_bytes=_kib(s.get("size")), transport=s.get("transport", ""),
        rotational=s.get("rotational") == "1", spun_down=s.get("spundown") == "1", status=s.get("status", ""),
        temperature=to_int(temp) if temp is not None else None, errors=to_int(s.get("numErrors")) or 0,
        role=_ROLES.get(s.get("type", ""), Role.OTHER), filesystem=filesystem)


def _sensors(lines: list[str], scale: float) -> list[Sensor]:
    """`coretemp|Package id 0|63000` -> 63 °C. Unreadable values are dropped."""
    out: list[Sensor] = []
    for line in lines:
        f = line.split("|")
        raw = to_float(trim_blanks(f[2])) if len(f) == 3 else None
        if raw is not None:
            out.append(Sensor(f[0], f[1], raw / scale))
    return out


def _parity_check(line: str) -> ParityCheck | None:
    """`2026 Sep 29 12:38:31|228495|113790929|0|0|check P Q|25391267788`; older logs have five fields."""
    f = line.split("|")
    duration = to_int(f[1]) if len(f) >= 5 else None
    if duration is None:
        return None
    return ParityCheck(
        finished=" ".join(p for p in f[0].split(" ") if p), duration_seconds=duration,
        bytes_per_second=to_int(f[2]) or 0, exit_code=to_int(f[3]) or 0, errors=to_int(f[4]) or 0,
        action=f[5] if len(f) > 5 else "check P", size_ki_b=(to_int(f[6]) or 0) if len(f) > 6 else 0)


def parse(output: str) -> UnraidSnapshot:
    sections = split_sections(output)
    version_lines = sections.get("unraid")
    version = trim_blanks(version_lines[0]) if version_lines else ""
    if not version:
        raise NotUnraid()
    v = key_values(sections.get("var", []))

    def num(key: str) -> int:
        return to_int(v.get(key, "")) or 0

    def num64(key: str) -> int | None:
        return to_int(v.get(key, ""))

    def positive(key: str) -> int | None:
        n = num64(key)
        return n if n is not None and n > 0 else None

    operation: Operation | None = None
    size = num64("mdResync")
    if size is not None and size > 0:
        dt = to_float(v.get("mdResyncDt", "")) or 0.0
        db = to_float(v.get("mdResyncDb", "")) or 0.0
        operation = Operation(v.get("mdResyncAction", ""), num64("mdResyncPos") or 0, positive("mdResyncSize") or size,
                              db / dt * 1024 if dt > 0 and db > 0 else None)
    exit_text = v.get("sbSyncExit")
    array = ArrayStatus(
        state=v.get("mdState", ""), fs_state=v.get("fsState", ""), num_disks=num("mdNumDisks"),
        disabled=num("mdNumDisabled"), invalid=num("mdNumInvalid"), missing=num("mdNumMissing"),
        share_count=num("shareCount"), operation=operation, last_sync_start=positive("sbSynced"),
        last_sync_end=positive("sbSynced2"), last_sync_errors=num64("sbSyncErrs"),
        last_sync_exit=to_int(exit_text) if exit_text is not None else None)

    devices = [_device(s) for s in ini_sections(sections.get("disks", []))]
    shares = [Share(s.get("name", ""), s.get("comment", ""), s.get("useCache", "no"), s.get("cachePool", ""),
                    _kib(s.get("free"))) for s in ini_sections(sections.get("shares", []))]
    shares = [s for s in shares if s.name]
    zfs = [ZFSPool(f[0], f[4]) for f in ([p for p in line.split("\t") if p] for line in sections.get("zpool", []))
           if len(f) >= 5]
    cpu = sections.get("cpu")
    return UnraidSnapshot(
        version=version, cpu_model=trim_blanks(cpu[0]) if cpu else "", array=array, devices=devices, shares=shares,
        zfs_pools=zfs, temperatures=_sensors(sections.get("temps", []), 1000), fans=_sensors(sections.get("fans", []), 1),
        parity_checks=[p for p in (_parity_check(x) for x in sections.get("parity", [])) if p is not None])
