"""Demo mode (`RACKOON_DEMO=1`): the whole app against made-up servers, for screenshots, trying it out and the
end-to-end tests. Nothing is sent anywhere: every server is a `DemoTransport` answering with canned output in the
formats the real parsers read (the Mac's homelab and garage-nuc, plus Android's old-nas, which never answers, and
backup-box, which refuses the login, so the failure screens can be seen). The data folder is a temporary one and the
demo is signed in as "demo" without a password, which is safe only because no real server is ever contacted.
"""

from __future__ import annotations

import asyncio
import math
import time
from dataclasses import dataclass

from rackoon.core import overview
from rackoon.core.models import Server
from rackoon.ssh import AuthFailed, CommandResult, HostKey, Unreachable

from .connections import CheckResult, Connections, Transport

DEMO_KEY = HostKey("ssh-ed25519", b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20" + bytes(range(32)))


@dataclass(frozen=True)
class DemoProfile:
    hostname: str
    pretty_name: str
    version_id: str
    vendor: str
    product: str
    kernel: str
    cores: int
    mem_total_kb: int
    mem_used_fraction: float
    disk_total: int
    disk_used_fraction: float
    uptime_days: float
    ip: str
    tailscale_ip: str | None
    updates: int
    security: int
    reboot_required: bool
    machine_id: str
    unhealthy: tuple[str, ...] = ()
    unreachable: bool = False
    refuses_login: bool = False


HOMELAB = DemoProfile(
    "homelab", "Ubuntu 24.04.2 LTS", "24.04", "Intel Corporation", "NUC13ANHi5", "6.8.0-52-generic", 8, 16_384_000, 0.39,
    500_107_862_016, 0.41, 27.4, "203.0.113.24", "100.100.40.7", 5, 2, True, "8c2f4e61b0a94d37a1c5d2e9f7b3a608",
    unhealthy=("promtail",))
NUC = DemoProfile(
    "garage-nuc", "Debian GNU/Linux 12 (bookworm)", "12", "Raspberry Pi", "Pi 5 Model B", "6.6.62+rpt-rpi-2712", 4,
    8_388_608, 0.22, 256_060_514_304, 0.18, 61.2, "192.168.1.52", None, 0, 0, False, "1d5b9e0c47a24f6e8b3a7c1f2e9d4a65")
OLD_NAS = DemoProfile(
    "old-nas", "Debian GNU/Linux 11 (bullseye)", "11", "", "", "5.10.0-28-amd64", 2, 4_194_304, 0.5, 4_000_000_000_000,
    0.8, 3.0, "192.168.1.60", None, 0, 0, False, "0" * 32, unreachable=True)
BACKUP = DemoProfile(
    "backup-box", "Ubuntu 22.04.5 LTS", "22.04", "", "", "5.15.0-125-generic", 2, 4_194_304, 0.3, 2_000_000_000_000, 0.6,
    9.0, "192.168.1.70", None, 0, 0, False, "1" * 32, refuses_login=True)

SERVERS: list[tuple[Server, DemoProfile]] = [
    (Server("demo-homelab", "homelab", "homelab.demo", user="ubuntu"), HOMELAB),
    (Server("demo-nuc", "garage-nuc", "garage-nuc.demo", user="pi"), NUC),
    (Server("demo-nas", "old-nas", "old-nas.demo", user="admin"), OLD_NAS),
    (Server("demo-backup", "backup-box", "backup-box.demo", user="backup"), BACKUP),
]


class DemoTransport:
    """Answers the `overview` command with a reading that moves a little between polls; anything else gets nothing."""

    def __init__(self, profile: DemoProfile) -> None:
        self.profile = profile
        self.started = time.time()
        self.last_poll = time.time()
        self.cpu_total = 3_400_000_000
        self.cpu_idle = 2_300_000_000

    async def connect(self) -> None:
        await self.run("true", 5)

    async def run(self, command: str, timeout: float, input: str | None = None) -> CommandResult:
        p = self.profile
        if p.unreachable:
            await asyncio.sleep(min(timeout, 1.5))
            raise Unreachable(f"ssh: connect to host {p.hostname}.demo port 22: Connection timed out")
        if p.refuses_login:
            raise AuthFailed(f"Permission denied for user backup on host {p.hostname}.demo")
        if command == overview.command():
            return CommandResult(self._overview(), "", 0)
        return CommandResult("", "", 0)

    async def close(self) -> None:
        pass

    def _overview(self) -> str:
        p = self.profile
        now = time.time()
        busy = 0.26 + 0.14 * math.sin((now - self.started) / 7)
        dt = max(0.1, now - self.last_poll)
        self.last_poll = now
        ticks = int(dt * p.cores * 100)
        self.cpu_total += ticks
        self.cpu_idle += int(ticks * (1 - busy))
        used_cpu = self.cpu_total - self.cpu_idle
        user = int(used_cpu * 0.7)
        system = used_cpu - user
        mem_avail = int(p.mem_total_kb * (1 - p.mem_used_fraction - 0.01 * math.sin((now - self.started) / 11)))
        used = int(p.disk_total * p.disk_used_fraction)
        debian = p.pretty_name.startswith("Debian")
        lines = [
            "##hostname", p.hostname,
            "##os", f'PRETTY_NAME="{p.pretty_name}"', f'NAME="{"Debian GNU/Linux" if debian else "Ubuntu"}"',
            f'VERSION_ID="{p.version_id}"', f"ID={'debian' if debian else 'ubuntu'}",
            "##uptime", f"{p.uptime_days * 86400 + now - self.started:.2f} 1000000.00",
            "##loadavg", f"{busy * p.cores * 0.6:.2f} 0.51 0.48 1/312 12345",
            "##nproc", str(p.cores),
            "##stat", f"cpu  {user} 0 {system} {self.cpu_idle} 0 0 0 0 0 0",
            "##meminfo", f"MemTotal:        {p.mem_total_kb} kB", f"MemAvailable:    {mem_avail} kB",
            "##df", "Filesystem        1-blocks        Used   Available Capacity Mounted on",
            f"/dev/nvme0n1p2 {p.disk_total} {used} {p.disk_total - used} {int(p.disk_used_fraction * 100)}% /",
            "/dev/nvme0n1p1    1073741824     6291456  1067450368       1% /boot/efi",
            "##system", f"vendor={p.vendor}", f"product={p.product}", f"machine_id={p.machine_id}", f"kernel={p.kernel}",
            "boot_id=demo-boot-1", f"time={int(now)} +0000 UTC", f"ip={p.ip}", f"tailscale_ip={p.tailscale_ip or ''}",
            "##reboot", "yes" if p.reboot_required else "no",
            "##updates", str(p.updates), "##security", str(p.security),
            "##unhealthy", *p.unhealthy,
        ]
        return "\n".join(lines) + "\n"


class DemoConnections(Connections):
    """Every server is a made-up one; host keys are always trusted."""

    def __init__(self, *args: object, **kwargs: object) -> None:
        super().__init__(*args, **kwargs)  # type: ignore[arg-type]
        self.profiles = {s.id: p for s, p in SERVERS}
        self._demo: dict[str, DemoTransport] = {}

    def transport(self, server: Server) -> Transport:
        profile = self.profiles.get(server.id, NUC)
        t = self._demo.get(server.id)
        if t is None:
            t = self._demo[server.id] = DemoTransport(profile)
        return t

    async def forget(self, server_id: str) -> None:
        self._demo.pop(server_id, None)

    async def scan(self, server: Server) -> CheckResult:
        return CheckResult("ok", "The host key is trusted.", DEMO_KEY, DEMO_KEY)

    async def check(self, server: Server) -> CheckResult:
        try:
            await self.transport(server).connect()
        except AuthFailed as e:
            return CheckResult("authFailed", str(e))
        except Unreachable as e:
            return CheckResult("unreachable", str(e))
        return CheckResult("ok", "Connected and signed in.")
