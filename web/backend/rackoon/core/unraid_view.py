"""What an Unraid server's Overview shows and what needs attention on it (the Swift core's `UnraidSnapshot` helpers,
`UnraidAttention` and `merge`). Pure; the parser is `unraid.py`. On Unraid, `df`'s disk-full items are dropped
(every ZFS dataset reads about 1%, and array disks are judged from emhttp's own numbers) and the NAS items added."""

from __future__ import annotations

from dataclasses import dataclass, field

from .attention import DISK_THRESHOLD_PERCENT
from .models import AttentionItem, Severity
from .unraid import Device, Filesystem, Operation, ParityCheck, Role, Sensor, Share, UnraidSnapshot

NORMAL, WARNING, CRITICAL = "normal", "warning", "critical"

_STATUS = {"DISK_OK": "healthy", "DISK_NP": "not assigned", "DISK_NP_MISSING": "missing",
           "DISK_NP_DSBL": "missing and disabled", "DISK_DSBL": "disabled", "DISK_DSBL_NEW": "new and disabled",
           "DISK_INVALID": "invalid", "DISK_WRONG": "the wrong disk", "DISK_NEW": "new"}


def status_description(d: Device) -> str:
    return _STATUS.get(d.status) or d.status.replace("DISK_", "").replace("_", " ").lower()


def is_empty_slot(d: Device) -> bool:
    return d.status == "DISK_NP" or (not d.device and not d.identity)


def model(d: Device) -> str:
    """"ST12000VN0007-2GS116" from "ST12000VN0007-2GS116_ZJV16MMX": the serial is dropped."""
    at = d.identity.rfind("_")
    return d.identity if at < 0 else d.identity[:at].replace("_", " ")


def temperature_limits(d: Device) -> tuple[int, int]:
    """Unraid's own defaults: hard drives warn at 45 °C and are critical at 55 °C; solid state runs hotter."""
    return (45, 55) if d.rotational else (60, 70)


def temperature_level(d: Device) -> str:
    if d.temperature is None:
        return NORMAL
    warn, crit = temperature_limits(d)
    return CRITICAL if d.temperature >= crit else WARNING if d.temperature >= warn else NORMAL


def describe(action: str) -> str:
    """"check P Q" -> "Parity check", "recon D3" -> "Rebuilding disk 3"."""
    parts = action.split()
    if parts and parts[0] == "check":
        return "Parity check"
    if parts and parts[0] == "recon":
        disk = next((p for p in parts[1:] if p.startswith("D")), None)
        return f"Rebuilding disk {disk[1:]}" if disk else "Parity sync"
    if parts and parts[0] == "clear":
        return "Clearing disk"
    return action or "Parity operation"


def remaining_seconds(op: Operation) -> float | None:
    if not op.bytes_per_second or op.bytes_per_second <= 0:
        return None
    return max(0, op.size_ki_b - op.position_ki_b) * 1024 / op.bytes_per_second


def parity_disks(s: UnraidSnapshot) -> list[Device]:
    return [d for d in s.devices if d.role is Role.PARITY and not is_empty_slot(d)]


def data_disks(s: UnraidSnapshot) -> list[Device]:
    return [d for d in s.devices if d.role is Role.DATA and not is_empty_slot(d)]


def flash(s: UnraidSnapshot) -> Device | None:
    return next((d for d in s.devices if d.role is Role.FLASH), None)


def array_bytes(s: UnraidSnapshot) -> tuple[int, int, int]:
    """The data disks' filesystems added up: total, used, free."""
    fs = [d.filesystem for d in data_disks(s) if d.filesystem is not None]
    return sum(f.total_bytes for f in fs), sum(f.used_bytes for f in fs), sum(f.free_bytes for f in fs)


@dataclass
class Pool:
    name: str
    devices: list[Device] = field(default_factory=list)
    filesystem: Filesystem | None = None
    health: str | None = None

    @property
    def kind(self) -> str | None:
        """"ZFS raid1", "BTRFS 2 devices", "XFS"."""
        fs = self.filesystem
        if fs is None:
            return None
        layout = fs.profile or (f"{len(self.devices)} devices" if len(self.devices) > 1 else None)
        return " ".join(x for x in (fs.type.upper(), layout) if x)


def pools(s: UnraidSnapshot) -> list[Pool]:
    """disks.ini lists a pool's first device with the filesystem and `devices="N"`, then its other members, so
    membership follows order and count, not names."""
    out: list[Pool] = []
    remaining = 0
    for d in s.devices:
        if d.role is not Role.POOL:
            continue
        if remaining > 0 and out:
            out[-1].devices.append(d)
            remaining -= 1
            continue
        health = next((z.health for z in s.zfs_pools if z.name == d.name), None)
        out.append(Pool(d.name, [d], d.filesystem, health))
        remaining = max(0, (d.filesystem.devices if d.filesystem else 1) - 1)
    return out


def _plausible(c: float) -> bool:
    return -40 < c < 150


def cpu_temperature(s: UnraidSnapshot) -> float | None:
    """Intel's package, else AMD's Tdie, else Tctl, else the hottest CPU-driver reading."""
    cpu = [t for t in s.temperatures if t.chip in ("coretemp", "k10temp", "zenpower", "cpu_thermal") and
           _plausible(t.value)]
    for label in ("Package id 0", "Tdie", "Tctl"):
        hit = next((t for t in cpu if t.label == label), None)
        if hit is not None:
            return hit.value
    return max((t.value for t in cpu), default=None)


def board_sensors(s: UnraidSnapshot) -> list[tuple[str, float]]:
    """Readable sensors other than the CPU and the drives, the hottest per name."""
    out: list[tuple[str, float]] = []
    for t in s.temperatures:
        if not _plausible(t.value) or t.chip in ("coretemp", "k10temp", "zenpower", "cpu_thermal", "nvme", "drivetemp"):
            continue
        if t.chip == "acpitz":
            name = "Motherboard"
        elif t.chip in ("spd5118", "jc42"):
            name = "Memory"
        elif t.chip.startswith(("eth", "en")) or "phy" in t.chip:
            name = f"Network {t.chip}"
        elif t.chip.startswith(("it8", "nct", "f71")):
            name = t.label or "Board"
        else:
            name = f"{t.chip} {t.label}" if t.label else t.chip
        i = next((i for i, (n, _) in enumerate(out) if n == name), None)
        if i is None:
            out.append((name, t.value))
        else:
            out[i] = (name, max(out[i][1], t.value))
    return out


def spinning_fans(s: UnraidSnapshot) -> list[Sensor]:
    return [f for f in s.fans if f.value > 0]


def last_parity_check(s: UnraidSnapshot) -> ParityCheck | None:
    return s.parity_checks[-1] if s.parity_checks else None


def condition(s: UnraidSnapshot) -> tuple[str, str]:
    """The array in one word and its level: ("Protected", normal), ("Degraded", critical)..."""
    a = s.array
    if not a.is_started:
        return (a.state.replace("_", " ").title() if a.state else "Unknown"), CRITICAL
    if a.disabled > 0 or a.invalid > 0 or a.missing > 0:
        return "Degraded", CRITICAL
    if a.operation is not None:
        return "Checking", NORMAL
    return ("Protected", NORMAL) if parity_disks(s) else ("No parity", WARNING)


def slot_title(name: str) -> str:
    """"Parity", "Parity 2", "Disk 1", "Cache 2", "Fast": how Unraid's own UI names the slots."""
    if name == "parity":
        return "Parity"
    if name.startswith("parity") and name[6:].isdigit():
        return f"Parity {int(name[6:])}"
    if name.startswith("disk") and name[4:].isdigit():
        return f"Disk {int(name[4:])}"
    base = name.rstrip("0123456789")
    if base and base != name:
        return base[:1].upper() + base[1:] + " " + name[len(base):]
    return name[:1].upper() + name[1:]


def fill_level(fraction: float) -> str:
    p = fraction * 100
    return CRITICAL if p >= 95 else WARNING if p > DISK_THRESHOLD_PERCENT else NORMAL


def cpu_level(celsius: float) -> str:
    return CRITICAL if celsius >= 90 else WARNING if celsius >= 80 else NORMAL


def placement(share: Share) -> str:
    """Where new files go, in Unraid's own words."""
    pool = share.cache_pool or "cache"
    return {"only": f"{pool} only", "prefer": f"{pool}, then array", "yes": f"{pool}, moved to array"}.get(
        share.use_cache, "array")


def evaluate(s: UnraidSnapshot) -> list[AttentionItem]:
    items: list[AttentionItem] = []

    def add(id: str, sev: Severity, message: str) -> None:
        items.append(AttentionItem(id, sev, message, ""))
    a = s.array
    if not a.is_started:
        add("array_stopped", Severity.CRITICAL,
            f"The array is {a.state.lower().replace('_', ' ') if a.state else 'not started'}.")
    if a.disabled > 0:
        add("array_disabled", Severity.CRITICAL, f"{a.disabled} disk(s) disabled: the array is running unprotected.")
    if a.missing > 0:
        add("array_missing", Severity.CRITICAL, f"{a.missing} disk(s) missing from the array.")
    if a.invalid > 0:
        add("array_invalid", Severity.WARNING, f"{a.invalid} disk(s) have invalid contents (parity is not in sync).")
    for d in s.devices:
        if is_empty_slot(d) or d.role is Role.FLASH:
            continue
        if d.status != "DISK_OK":
            add(f"disk_status:{d.name}", Severity.CRITICAL, f"{d.name} is {status_description(d)}.")
        elif d.errors > 0:
            add(f"disk_errors:{d.name}", Severity.WARNING, f"{d.name} has {d.errors} read/write error(s).")
        level = temperature_level(d)
        if level == CRITICAL:
            add(f"disk_hot:{d.name}", Severity.CRITICAL, f"{d.name} is at {d.temperature or 0} °C.")
        elif level == WARNING:
            add(f"disk_hot:{d.name}", Severity.WARNING, f"{d.name} is warm: {d.temperature or 0} °C.")
        fs = d.filesystem
        if fs is not None and fs.status == "Mounted" and fs.use_percent > DISK_THRESHOLD_PERCENT:
            add(f"disk_full:{d.name}", Severity.CRITICAL if fs.use_percent >= 95 else Severity.WARNING,
                f"{d.name} is {fs.use_percent}% full.")
        elif fs is not None and fs.status != "Mounted" and a.is_started and fs.status:
            add(f"disk_unmountable:{d.name}", Severity.CRITICAL, f"{d.name} is {fs.status.lower()}.")
    for pool in s.zfs_pools:
        if pool.health != "ONLINE":
            add(f"zfs_health:{pool.name}", Severity.WARNING if pool.health == "DEGRADED" else Severity.CRITICAL,
                f"ZFS pool {pool.name} is {pool.health}.")
    last = last_parity_check(s)
    if last is not None and last.errors > 0:
        add("parity_errors", Severity.WARNING, f"The last {describe(last.action).lower()} found {last.errors} error(s).")
    cpu = cpu_temperature(s)
    if cpu is not None and cpu >= 90:
        add("cpu_hot", Severity.WARNING, f"The CPU is at {int(cpu)} °C.")
    return items


def merge(base: list[AttentionItem], unraid: bool, snapshot: UnraidSnapshot | None) -> list[AttentionItem]:
    if not unraid:
        return base
    return [i for i in base if not i.id.startswith("disk_high:")] + (evaluate(snapshot) if snapshot else [])
