"""Updates, sudo and reboot in demo mode: pending apt updates that installing really clears, a sudo that wants a
password on homelab (the demo password is "demo"; garage-nuc's user has passwordless sudo), a Docker unlock check, and
a reboot that takes the server away for about 12 seconds and brings it back with a new boot id. All in memory; the
commands are recognised by their spec templates, so keep this in step with spec/commands.json."""

from __future__ import annotations

import asyncio
import re
import time
from collections.abc import AsyncIterable, AsyncIterator
from dataclasses import dataclass

from rackoon.core import reboot, sudo, updates
from rackoon.ssh import CommandResult, Unreachable

DEMO_PASSWORD = "demo"
DOWN_SECONDS = 12.0


@dataclass
class DemoPackage:
    name: str
    suite: str
    new: str
    old: str

    def line(self) -> str:
        return f"{self.name}/{self.suite} {self.new} amd64 [upgradable from: {self.old}]"

    @property
    def security(self) -> bool:
        return self.suite.endswith("-security")


HOMELAB_UPDATES = [
    DemoPackage("openssl", "noble-updates,noble-security", "3.0.13-0ubuntu3.5", "3.0.13-0ubuntu3.4"),
    DemoPackage("libssl3t64", "noble-updates,noble-security", "3.0.13-0ubuntu3.5", "3.0.13-0ubuntu3.4"),
    DemoPackage("curl", "noble-updates", "8.5.0-2ubuntu10.6", "8.5.0-2ubuntu10.5"),
    DemoPackage("docker-ce", "noble", "5:27.4.1-1~ubuntu.24.04~noble", "5:27.3.1-1~ubuntu.24.04~noble"),
    DemoPackage("tzdata", "noble-updates", "2024b-0ubuntu0.24.04.1", "2024a-0ubuntu0.24.04"),
]


class DemoSystem:
    def __init__(self, hostname: str, user: str, needs_password: bool, pending: int, reboot_required: bool) -> None:
        self.hostname = hostname
        self.user = user
        self.needs_password = needs_password
        self.pending = list(HOMELAB_UPDATES[:pending])
        self.reboot_required = reboot_required
        self.boot = 1
        self.down_until = 0.0
        self.booted_at: float | None = None
        self.refreshed = int(time.time()) - 5 * 3600

    @property
    def down(self) -> bool:
        return time.time() < self.down_until

    @property
    def boot_id(self) -> str:
        return f"demo-boot-{self.boot}"

    @property
    def security(self) -> int:
        return sum(p.security for p in self.pending)

    def run(self, command: str, input: str | None) -> CommandResult | None:
        if command == updates.command():
            lines = ["##apt", "ok", "##upgradable", "Listing...", *[p.line() for p in self.pending], "##held",
                     "##refreshed", str(self.refreshed), "##reboot", "yes" if self.reboot_required else "no"]
            return CommandResult("\n".join(lines) + "\n", "", 0)
        if command == reboot.boot_id_command():
            return CommandResult(self.boot_id + "\n", "", 0)
        if command == reboot.reboot_command():
            if self.needs_password:
                return CommandResult("##no-sudo\n", "sudo: a password is required\n", 5)
            self._reboot()
            return CommandResult("##rebooting\n", "", 0)
        if command == reboot.sudo_reboot_command():
            if input != DEMO_PASSWORD + "\n":
                return CommandResult("sudo: 1 incorrect password attempt\n##sudo-failed\n", "", 6)
            self._reboot()
            return CommandResult("##rebooting\n", "", 0)
        if command == sudo.elevated("true"):
            if input == DEMO_PASSWORD + "\n" or not self.needs_password:
                return CommandResult("", "", 0)
            return CommandResult("", "Sorry, try again.\nsudo: 1 incorrect password attempt\n", 1)
        return None

    def _reboot(self) -> None:
        self.down_until = time.time() + 2 + DOWN_SECONDS
        self.boot += 1
        self.booted_at = self.down_until
        self.reboot_required = False

    async def stream(self, command: str, input: AsyncIterable[str] | None) -> AsyncIterator[str] | None:
        """Streams an apt script (plain or behind the sudo prefix), or None for anything else."""
        inner = re.search(r"\( (.*) \); rk=\$\?", command, re.S)
        script = inner.group(1) if inner else ""
        kind = ("apt_refresh" if "apt-get update" in script else "apt_upgrade_packages"
                if "apt-get install --only-upgrade" in script else "apt_upgrade" if "apt-get upgrade" in script else None)
        if kind is None:
            return None
        return self._apt(kind, script, input)

    async def _apt(self, kind: str, script: str, input: AsyncIterable[str] | None) -> AsyncIterator[str]:
        nonce = re.search(r"##rackoon-sudo-([0-9a-f]{32}):", script)
        if nonce is not None and self.needs_password:
            n = nonce.group(1)
            yield f"[sudo: ##rackoon-sudo-{n}:] Password: "
            keys = input.__aiter__() if input is not None else None
            typed = await keys.__anext__() if keys is not None else ""
            if typed != DEMO_PASSWORD + "\n":
                yield "\r\nsudo: Authentication failed, try again.\r\n"
                yield f"[sudo: ##rackoon-sudo-{n}:] Password: "
                if keys is not None:
                    await keys.__anext__()  # the Ctrl-C
                yield f"\r\n##rackoon-sudo-fail-{n}\r\n\r\n##rackoon-exit:7\r\n"
                return
            yield f"\r\n##rackoon-sudo-ok-{n}\r\n"
        elif nonce is not None:
            yield f"##rackoon-sudo-ok-{nonce.group(1)}\r\n"
        elif self.needs_password:
            await asyncio.sleep(0.3)
            yield "sudo: a password is required\r\n\r\n##rackoon-exit:1\r\n"
            return
        if kind == "apt_refresh":
            for line in ("Hit:1 http://archive.ubuntu.com/ubuntu noble InRelease",
                         "Get:2 http://security.ubuntu.com/ubuntu noble-security InRelease [126 kB]",
                         "Fetched 126 kB in 1s (182 kB/s)", "Reading package lists... Done"):
                await asyncio.sleep(0.35)
                yield line + "\r\n"
            self.refreshed = int(time.time())
        else:
            names = script.split("--force-confold")[-1].split() if kind == "apt_upgrade_packages" else None
            chosen = [p for p in self.pending if names is None or p.name in names]
            yield "Reading package lists... Done\r\nBuilding dependency tree... Done\r\n"
            for p in chosen:
                await asyncio.sleep(0.4)
                yield f"Unpacking {p.name} ({p.new}) over ({p.old}) ...\r\n"
            for p in chosen:
                await asyncio.sleep(0.25)
                yield f"Setting up {p.name} ({p.new}) ...\r\n"
            self.pending = [p for p in self.pending if p not in chosen]
            if any(p.name.startswith("libssl") for p in chosen):
                self.reboot_required = True
        yield "\r\n##rackoon-exit:0\r\n"

    def check_up(self) -> None:
        if self.down:
            raise Unreachable(f"ssh: connect to host {self.hostname}.demo port 22: Connection refused")
