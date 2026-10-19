"""Demo mode (`RACKOON_DEMO=1`): the whole app against made-up servers, for screenshots, trying it out and the
end-to-end tests. Nothing is sent anywhere: every server is a `DemoTransport` answering with canned output in the
formats the real parsers read (the Mac's homelab and garage-nuc, plus Android's old-nas, which never answers, and
backup-box, which refuses the login, so the failure screens can be seen). The data folder is a temporary one and the
demo is signed in as "demo" without a password, which is safe only because no real server is ever contacted.
"""

from __future__ import annotations

import asyncio
import math
import re
import shlex
import time
from collections.abc import AsyncIterable, AsyncIterator
from dataclasses import dataclass

from rackoon.core import overview
from rackoon.core.models import Server
from rackoon.ssh import AuthFailed, CommandResult, HostKey, Unreachable

from .connections import CheckResult, Connections, Transport
from .demo_docker import DemoDocker, DemoStream
from .demo_extras import DemoExtras
from .demo_system import DEMO_PASSWORD, DemoSystem

ELEVATED = "sudo -S -p '' sh -c "
ELEVATED_STREAM = "sudo -n sh -c "

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
        self.docker = DemoDocker(profile.hostname)
        self.extras = DemoExtras(profile.hostname, {"homelab": "ubuntu", "garage-nuc": "pi"}.get(profile.hostname, "root"),
                                 self.docker)
        self.system = DemoSystem(profile.hostname, "", needs_password=profile.hostname == "homelab",
                                 pending=profile.updates, reboot_required=profile.reboot_required)

    async def connect(self) -> None:
        await self.run("true", 5)

    async def run(self, command: str, timeout: float, input: str | None = None) -> CommandResult:
        p = self.profile
        if p.unreachable:
            await asyncio.sleep(min(timeout, 1.5))
            raise Unreachable(f"ssh: connect to host {p.hostname}.demo port 22: Connection timed out")
        if p.refuses_login:
            raise AuthFailed(f"Permission denied for user backup on host {p.hostname}.demo")
        self.system.check_up()
        answer_ = self.system.run(command, input)
        if answer_ is None and command.startswith(ELEVATED):
            # Docker through sudo: the password must be the demo's; then the inner command runs as before.
            if self.system.needs_password and input != DEMO_PASSWORD + "\n":
                return CommandResult("", "Sorry, try again.\nsudo: 1 incorrect password attempt\n", 1)
            command, input = shlex.split(command[len(ELEVATED):])[0], None
            answer_ = self.system.run(command, input)
        if answer_ is not None:
            await asyncio.sleep(0.15)
            return answer_
        if command == overview.command():
            return CommandResult(self._overview(), "", 0)
        extra = self.extras.run(command)
        if extra is not None:
            await asyncio.sleep(0.1)
            return extra
        answer = self.docker.run(command)
        if answer is not None:
            await asyncio.sleep(0.15)
            return answer
        return CommandResult("", "", 0)

    def stream(self, command: str, input: AsyncIterable[str] | None = None, cols: int = 80,
               rows: int = 24) -> DemoStream:
        return DemoStream(self._stream(command, input))

    async def _stream(self, command: str, input: AsyncIterable[str] | None) -> AsyncIterator[str]:
        await self.run("true", 5)  # the unreachable and refusing servers fail here, as a real one would
        at = command.find(ELEVATED_STREAM)
        if at >= 0:
            # Docker through sudo: answer the one nonce prompt like sudo would, then stream the inner command.
            nonce = re.search(r"##rackoon-sudo-([0-9a-f]{32}):", command)
            n = nonce.group(1) if nonce else ""
            if self.system.needs_password:
                yield f"[sudo: ##rackoon-sudo-{n}:] Password: "
                keys = input.__aiter__() if input is not None else None
                typed = await keys.__anext__() if keys is not None else ""
                if typed != DEMO_PASSWORD + "\n":
                    yield f"\r\nsudo: Authentication failed, try again.\r\n[sudo: ##rackoon-sudo-{n}:] Password: "
                    return
                yield "\r\n"
            yield f"##rackoon-sudo-ok-{n}\r\n"
            command = shlex.split(command[at + len(ELEVATED_STREAM):])[0]
        apt = await self.system.stream(command, input)
        inner = re.search(r"\( (.*) \); rk=\$\?", command, re.S)
        library = (await self.extras.library(inner.group(1)) if inner and 'PATH="$PATH:/usr/local/sbin' in inner.group(1)
                   else None)
        if apt is None and library is None and inner and 'PATH="$PATH:/usr/local/sbin' in inner.group(1):
            library = self._nothing()
        chunks = apt if apt is not None else library if library is not None else self.docker.stream(command)
        async for chunk in chunks:
            yield chunk

    async def close(self) -> None:
        pass

    async def upload(self, command: str, chunks: AsyncIterable[bytes], timeout: float) -> CommandResult:
        await self.run("true", 5)
        return await self.extras.upload(command, chunks)

    async def download(self, command: str) -> AsyncIterator[bytes]:
        await self.run("true", 5)
        async for chunk in self.extras.download(command):
            yield chunk

    async def _nothing(self) -> AsyncIterator[str]:
        await asyncio.sleep(0.2)
        yield "\x1b[2m(demo: nothing was run on a server)\x1b[0m\r\n\r\n##rackoon-exit:0\r\n"

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
            "##uptime", f"{(now - self.system.booted_at) if self.system.booted_at else p.uptime_days * 86400 + now - self.started:.2f} 1000000.00",
            "##loadavg", f"{busy * p.cores * 0.6:.2f} 0.51 0.48 1/312 12345",
            "##nproc", str(p.cores),
            "##stat", f"cpu  {user} 0 {system} {self.cpu_idle} 0 0 0 0 0 0",
            "##meminfo", f"MemTotal:        {p.mem_total_kb} kB", f"MemAvailable:    {mem_avail} kB",
            "##df", "Filesystem        1-blocks        Used   Available Capacity Mounted on",
            f"/dev/nvme0n1p2 {p.disk_total} {used} {p.disk_total - used} {int(p.disk_used_fraction * 100)}% /",
            "/dev/nvme0n1p1    1073741824     6291456  1067450368       1% /boot/efi",
            "##system", f"vendor={p.vendor}", f"product={p.product}", f"machine_id={p.machine_id}", f"kernel={p.kernel}",
            f"boot_id={self.system.boot_id}", f"time={int(now)} +0000 UTC", f"ip={p.ip}", f"tailscale_ip={p.tailscale_ip or ''}",
            "##reboot", "yes" if self.system.reboot_required else "no",
            "##updates", str(len(self.system.pending)), "##security", str(self.system.security),
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
        pass  # a made-up server keeps its state (installed updates, its boot id) for the whole demo

    async def scan(self, server: Server) -> CheckResult:
        return CheckResult("ok", "The host key is trusted.", DEMO_KEY, DEMO_KEY)

    async def open_shell(self, server: Server, cols: int, rows: int,  # type: ignore[override]
                         command: str | None = None) -> DemoShell:
        profile = self.profiles.get(server.id, NUC)
        await self.transport(server).connect()  # the unreachable and refusing servers fail here, as a real one would
        shell = DemoShell(profile, "root" if command else server.user or "root", container=command is not None)
        shell.resize(cols, rows)
        return shell

    async def check(self, server: Server) -> CheckResult:
        try:
            await self.transport(server).connect()
        except AuthFailed as e:
            return CheckResult("authFailed", str(e))
        except Unreachable as e:
            return CheckResult("unreachable", str(e))
        return CheckResult("ok", "Connected and signed in.")


class DemoShell:
    """A scripted pretend shell for terminal tabs in demo mode: a login banner, a prompt, a few canned answers, line
    editing and Ctrl-C. Whatever is typed is never run anywhere."""

    def __init__(self, profile: DemoProfile, user: str, container: bool = False) -> None:
        self.profile = profile
        self.container = container
        self.user = user
        self.line = ""
        self.out: asyncio.Queue[bytes] = asyncio.Queue()
        self._exit: int | None = None
        self.cols, self.rows = 80, 24
        banner = (f"Welcome to {profile.pretty_name} (GNU/Linux {profile.kernel} x86_64)\r\n\r\n"
                  f"  System load:  0.48           Usage of /:   {int(profile.disk_used_fraction * 100)}% of "
                  f"{profile.disk_total // 10**9} GB\r\n  IPv4 address for eth0: {profile.ip}\r\n"
                  + (f"  IPv4 address for tailscale0: {profile.tailscale_ip}\r\n" if profile.tailscale_ip else "")
                  + "\r\nThis is Rackoon's demo: nothing you type is sent anywhere. Try: help\r\n\r\n")
        if container:
            banner = "This is a demo container shell: nothing you type is sent anywhere. Try: help\r\n\r\n"
        self.out.put_nowait(banner.encode() + self._prompt())

    def _prompt(self) -> bytes:
        if self.container:
            return b"/app # "
        return f"\x1b[1;32m{self.user}@{self.profile.hostname}\x1b[0m:\x1b[1;34m~\x1b[0m$ ".encode()

    async def read(self) -> bytes:
        return await self.out.get()

    def write(self, data: bytes) -> None:
        for ch in data.decode("utf-8", "replace"):
            if ch in "\r\n" and self.line.strip() == "drop":
                # Pretend the link went away (no exit status), to show the terminal reconnecting.
                self.line = ""
                self.out.put_nowait(b"\r\n")
                self.out.put_nowait(b"")
                return
            if ch in "\r\n":
                self.out.put_nowait(b"\r\n" + self._answer(self.line.strip()))
                self.line = ""
                if self._exit is not None:
                    self.out.put_nowait(b"")
                    return
                self.out.put_nowait(self._prompt())
            elif ch == "\x03":
                self.line = ""
                self.out.put_nowait(b"^C\r\n" + self._prompt())
            elif ch in "\x7f\x08":
                if self.line:
                    self.line = self.line[:-1]
                    self.out.put_nowait(b"\b \b")
            elif ch == "\x04" and not self.line:
                self._exit = 0
                self.out.put_nowait(b"logout\r\n")
                self.out.put_nowait(b"")
            elif ch >= " ":
                self.line += ch
                self.out.put_nowait(ch.encode())

    def _answer(self, command: str) -> bytes:
        p = self.profile
        word = command.split(" ")[0] if command else ""
        answers = {
            "": "",
            "help": "Demo commands: ls, uptime, df -h, ip -4 a, whoami, hostname, size, echo, clear, drop (lose the "
                    "connection), exit",
            "ls": "compose  notes.txt  stacks",
            "whoami": self.user,
            "hostname": p.hostname,
            "uptime": f" 10:42:07 up {int(p.uptime_days)} days,  2 users,  load average: 0.48, 0.51, 0.48",
            "df": (f"Filesystem      Size  Used Avail Use% Mounted on\r\n/dev/nvme0n1p2  {p.disk_total // 10**9}G  "
                   f"{int(p.disk_total * p.disk_used_fraction) // 10**9}G  "
                   f"{int(p.disk_total * (1 - p.disk_used_fraction)) // 10**9}G  {int(p.disk_used_fraction * 100)}% /\r\n"
                   "/dev/nvme0n1p1  1.1G  6.3M  1.1G   1% /boot/efi\r\n/dev/sdb1       2.0T  1.9T  0.1T  95% /mnt/backup"),
            "ip": (f"2: eth0    inet {p.ip}/24 brd 192.168.1.255 scope global eth0"
                   + (f"\r\n3: tailscale0    inet {p.tailscale_ip}/32 scope global tailscale0" if p.tailscale_ip else "")),
            "size": f"{self.cols} columns x {self.rows} rows",
            "clear": "\x1b[H\x1b[2J",
        }
        if word == "exit":
            self._exit = 0
            return b"logout\r\n"
        if word == "echo":
            return command[5:].encode() + b"\r\n"
        if word in answers:
            text = answers[word]
            return (text + ("\r\n" if text and word != "clear" else "")).encode()
        return f"{word}: not run (this is the demo; nothing is sent anywhere)\r\n".encode()

    def resize(self, cols: int, rows: int) -> None:
        self.cols, self.rows = cols, rows

    @property
    def exit_status(self) -> int | None:
        return self._exit

    async def close(self) -> None:
        self._exit = self._exit if self._exit is not None else 0
        self.out.put_nowait(b"")
