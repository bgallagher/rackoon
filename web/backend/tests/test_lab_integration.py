"""The checks in spec/integration/checks.json, run with the real asyncssh transport and the Python core against the
integration lab (test/lab; `tools/lab up`, then `eval "$(tools/lab env)"`). Skipped when RACKOON_LAB is unset.

Like LabIntegrationTests.swift / .kt, a check runs only while its feature is done for web in spec/features.json
(`RACKOON_PARITY_ALL=1` runs them all, never as proof). The lab's host key comes from the known_hosts file tools/lab
scanned; it is never trusted on first use. Every command comes from spec/ through the core.
"""

from __future__ import annotations

import asyncio
import os
import re
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

from rackoon.core import docker, overview, spec, stream, updates
from rackoon.ssh import (
    AsyncSSHTransport,
    AuthFailed,
    HostKey,
    HostKeyChanged,
    HostKeyUnknown,
    KnownHosts,
    SSHAuth,
    SSHEndpoint,
    Timeout,
    scan_host_key,
)

from .support import PLATFORM, done_features, load, run_everything

CHECKS = load("integration/checks.json")
FACTS: dict[str, Any] = CHECKS["lab"]
IMPLEMENTED = {"overview_parses", "updates_parse", "docker_parses", "stream_exit_status", "logs_cancel_leaves_nothing",
               "hostkey_mismatch_blocked", "stdin_exact_bytes", "sudo_password_checked"}


def applicable_checks() -> set[str]:
    done = done_features()
    return {c["id"] for c in CHECKS["checks"] if c["feature"] in done}


@dataclass
class Lab:
    host: str
    port: int
    user: str
    sudo_user: str
    sudo_password: str
    key: str
    host_key: HostKey

    def transport(self, user: str | None = None, host_key: HostKey | None = None,
                  auth: SSHAuth | None = None) -> AsyncSSHTransport:
        known = KnownHosts()
        known.trust(self.host, self.port, host_key or self.host_key)
        return AsyncSSHTransport(SSHEndpoint(self.host, user or self.user, auth or SSHAuth.key(self.key), self.port),
                                 known)


def _lab() -> Lab:
    env = os.environ
    if env.get("RACKOON_LAB") != "1":
        pytest.skip('integration lab not configured (tools/lab up, then eval "$(tools/lab env)")')
    line = next(ln for ln in Path(env["RACKOON_LAB_KNOWN_HOSTS"]).read_text().splitlines()
                if ln.strip() and not ln.startswith("#"))
    _, _, host_key = HostKey.from_known_hosts_line(line)
    return Lab(env["RACKOON_LAB_HOST"], int(env.get("RACKOON_LAB_PORT", "2222")), env.get("RACKOON_LAB_USER", "rk"),
               env.get("RACKOON_LAB_SUDO_USER", "rkpw"), env.get("RACKOON_LAB_SUDO_PASSWORD", ""),
               Path(env["RACKOON_LAB_KEY"]).read_text(), host_key)


def check_lab(check: str) -> Lab:
    lab = _lab()
    if check not in applicable_checks() and not run_everything():
        pytest.skip(f"{check}: its feature is not done on {PLATFORM}")
    return lab


@pytest.fixture
def lab() -> Lab:
    """For the transport's own spike tests, which are not checks.json checks and run whenever the lab is up."""
    return _lab()


async def lab_stack(t: AsyncSSHTransport) -> docker.DockerStack:
    result = await t.run(docker.command(), timeout=60)
    assert result.exit_code == 0, result.stderr
    stack = next((s for s in docker.parse(result.stdout).stacks if s.name == FACTS["stack"]), None)
    assert stack is not None, "labstack not found"
    return stack


def test_every_applicable_check_has_a_runner() -> None:
    for check in applicable_checks():
        assert check in IMPLEMENTED, f"{check} has no Python lab runner, but its feature is done on web"


# --- spec/integration/checks.json ---------------------------------------------------------------------------------


async def test_overview_parses() -> None:
    lab = check_lab("overview_parses")
    async with lab.transport() as t:
        result = await t.run(overview.command(), timeout=30)
    assert result.exit_code == 0, result.stderr
    o = overview.parse(result.stdout)
    assert o.hostname
    assert o.disks
    assert o.cpu.total > 0
    assert o.reboot_required
    assert o.tailscale_ip == FACTS["tailscaleIP"]
    assert o.pending_updates == len(FACTS["pending"])
    assert o.security_updates == len(FACTS["security"])


async def test_updates_parse() -> None:
    lab = check_lab("updates_parse")
    async with lab.transport() as t:
        result = await t.run(updates.command(), timeout=60)
    assert result.exit_code == 0, result.stderr
    snapshot = updates.parse(result.stdout)
    assert sorted(p.name for p in snapshot.packages) == sorted(FACTS["pending"])
    assert sorted(p.name for p in snapshot.packages if p.is_security) == sorted(FACTS["security"])
    assert snapshot.reboot_required


async def test_docker_parses() -> None:
    lab = check_lab("docker_parses")
    async with lab.transport() as t:
        stack = await lab_stack(t)
    ticker = next((c for c in stack.containers if c.service == FACTS["service"]), None)
    assert ticker is not None and ticker.state == "running"
    assert docker.ComposeAction.UP.command(stack) is not None


async def test_stream_exit_status() -> None:
    lab = check_lab("stream_exit_status")
    async with lab.transport() as t, t.stream(stream.wrap("echo lab-out; exit 3", 80, 24)) as s:
        text = "".join([chunk async for chunk in s])
    parser = stream.StreamOutputParser()
    shown = parser.push(text)
    rest, exit_code = parser.finish()
    assert exit_code == 3, text
    assert "lab-out" in shown + rest


async def test_logs_cancel_leaves_nothing() -> None:
    lab = check_lab("logs_cancel_leaves_nothing")
    async with lab.transport() as t:
        command = docker.logs_command((await lab_stack(t)).containers[0].id)
        assert command is not None
        seen = ""
        async with asyncio.timeout(30):
            async with t.stream(command) as s:
                async for chunk in s:
                    seen += chunk
                    if "tick" in seen:
                        break  # leaving the block types Ctrl-C into the pty, then closes
        left = "?"
        for _ in range(10):
            # `[l]` keeps the pattern from matching the shell that runs pgrep itself.
            left = (await t.run("pgrep -f 'docker [l]ogs -f' | wc -l", timeout=15)).stdout.strip()
            if left == "0":
                break
            await asyncio.sleep(0.5)
    assert left == "0", "docker logs is still running on the server after cancelling"


async def test_hostkey_mismatch_blocked() -> None:
    lab = check_lab("hostkey_mismatch_blocked")
    blob = bytearray(lab.host_key.blob)
    blob[-1] ^= 1
    wrong = HostKey(lab.host_key.key_type, bytes(blob))
    marker = f"/tmp/rk-lab-hostkey-{uuid.uuid4()}"
    async with lab.transport(host_key=wrong) as t:
        with pytest.raises(HostKeyChanged) as raised:
            await t.run(f"touch {marker}", timeout=20)
    assert raised.value.presented == lab.host_key
    async with lab.transport() as t:
        assert (await t.run(f"test -e {marker} && echo present || echo absent", timeout=15)).stdout.strip() == "absent"


async def test_stdin_exact_bytes() -> None:
    lab = check_lab("stdin_exact_bytes")
    size = 1 << 20
    async with lab.transport() as t:
        result = await t.run("wc -c", timeout=30, input="r" * size)
    assert result.exit_code == 0, result.stderr
    assert result.stdout.strip() == str(size)


async def test_sudo_password_checked() -> None:
    lab = check_lab("sudo_password_checked")
    async with lab.transport(user=lab.sudo_user) as sudo:
        # -k: ignore any cached credential, so the password is really checked each time.
        wrong = await sudo.run("sudo -k -S -p '' id -u", timeout=30, input="not-the-password\n")
        assert wrong.exit_code != 0
        # Stage W6 brings the core's classify_sudo_failure; until then sudo's own words.
        assert re.search(r"incorrect password|Sorry, try again|authentication failure", wrong.stderr, re.I), wrong.stderr
        right = await sudo.run("sudo -k -S -p '' id -u", timeout=30, input=lab.sudo_password + "\n")
    assert right.exit_code == 0, right.stderr
    assert right.stdout.strip() == "0"


# --- The transport's own checks from the W0 spike (not in checks.json) --------------------------------------------


async def test_spike_unknown_host_key_is_reported_not_trusted(lab: Lab) -> None:
    assert await scan_host_key(lab.host, lab.port) == lab.host_key
    t = AsyncSSHTransport(SSHEndpoint(lab.host, lab.user, SSHAuth.key(lab.key), lab.port), KnownHosts())
    with pytest.raises(HostKeyUnknown) as raised:
        await t.run("true", timeout=15)
    assert raised.value.presented.fingerprint == lab.host_key.fingerprint


async def test_spike_none_auth_refused_by_openssh_is_auth_failed(lab: Lab) -> None:
    # The lab's sshd is OpenSSH, which never accepts `none`; Tailscale SSH does. This proves the error mapping only.
    async with lab.transport(auth=SSHAuth.none()) as t:
        with pytest.raises(AuthFailed):
            await t.run("true", timeout=15)


async def test_spike_exit_codes_and_timeout(lab: Lab) -> None:
    async with lab.transport() as t:
        assert (await t.run("exit 7", timeout=15)).exit_code == 7
        assert (await t.run("kill -TERM $$", timeout=15)).exit_code == 15
        with pytest.raises(Timeout):
            await t.run("sleep 30", timeout=1)
        assert (await t.run("echo still-fine", timeout=15)).stdout.strip() == "still-fine"


async def test_spike_utf8_split_across_reads(lab: Lab) -> None:
    # 200k three-byte characters arrive in many reads; none may be cut in half.
    command = stream.wrap("python3 -c 'print(\"€\" * 200000)' 2>/dev/null || printf '€%.0s' $(seq 1 200000)", 80, 24)
    async with lab.transport() as t, t.stream(command) as s:
        text = "".join([chunk async for chunk in s])
    assert "�" not in text
    assert text.count("€") == 200000


async def test_spike_shell_resize_and_echo(lab: Lab) -> None:
    async with lab.transport() as t:
        shell = await t.open_shell(100, 30)
        try:
            shell.write(b"stty size; echo rk-$((40+2))\n")
            assert b"30 100" in await _read_until(shell, b"rk-42")
            shell.resize(132, 43)
            shell.write(b"stty size\n")
            assert b"43 132" in await _read_until(shell, b"43 132")
        finally:
            await shell.close()


async def _read_until(shell: Any, needle: bytes, seconds: float = 10) -> bytes:
    data = b""
    async with asyncio.timeout(seconds):
        while needle not in data:
            chunk = await shell.read()
            if not chunk:
                break
            data += chunk
    return data


def test_commands_used_here_exist_in_spec() -> None:
    for cid in ("overview", "updates", "docker", "docker_logs", "stream_wrap"):
        assert spec.script(cid)
