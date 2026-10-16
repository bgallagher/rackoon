"""The checks in spec/integration/checks.json, run with the real asyncssh transport against the integration lab
(test/lab; `tools/lab up`, then `eval "$(tools/lab env)"`). Skipped when RACKOON_LAB is unset.

Stage W0 (spike): there is no Python core yet, so the three parse checks read the raw output's sections here and
assert the same facts the Mac and Android checks assert through their parsers. Stage W1 swaps in the core parsers
and gates each check on the web column of spec/features.json, like LabIntegrationTests.swift / .kt. Until then every
check runs. The lab's host key comes from the known_hosts file tools/lab scanned; it is never trusted on first use.
Commands come from spec/commands.json, never copied.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest

from rackoon.ssh import (
    AsyncSSHTransport,
    AuthFailed,
    HostKey,
    HostKeyChanged,
    HostKeyUnknown,
    KnownHosts,
    SSHAuth,
    SSHEndpoint,
    scan_host_key,
)

SPEC = Path(__file__).resolve().parents[3] / "spec"


def _json(name: str) -> Any:
    return json.loads((SPEC / name).read_text())


CHECKS = _json("integration/checks.json")
FACTS: dict[str, Any] = CHECKS["lab"]
COMMANDS = {c["id"]: c for c in _json("commands.json")["commands"]}


def script(command_id: str, **values: str) -> str:
    """A spec command, its `{name}` placeholders filled in one pass (like `Template.fill`)."""
    text: str = COMMANDS[command_id]["script"]
    return re.sub(r"\{([a-z_]+)\}", lambda m: values[m.group(1)] if m.group(1) in values else m.group(0), text)


def sections(output: str) -> dict[str, list[str]]:
    """`##name` sections of a batched script's output (W0 stand-in for the core parsers)."""
    found: dict[str, list[str]] = {}
    current: list[str] | None = None
    for line in output.splitlines():
        if line.startswith("##"):
            current = found.setdefault(line[2:].strip(), [])
        elif current is not None:
            current.append(line)
    return found


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


@pytest.fixture
def lab() -> Lab:
    env = os.environ
    if env.get("RACKOON_LAB") != "1":
        pytest.skip('integration lab not configured (tools/lab up, then eval "$(tools/lab env)")')
    line = next(ln for ln in Path(env["RACKOON_LAB_KNOWN_HOSTS"]).read_text().splitlines()
                if ln.strip() and not ln.startswith("#"))
    _, _, host_key = HostKey.from_known_hosts_line(line)
    return Lab(env["RACKOON_LAB_HOST"], int(env.get("RACKOON_LAB_PORT", "2222")), env.get("RACKOON_LAB_USER", "rk"),
               env.get("RACKOON_LAB_SUDO_USER", "rkpw"), env.get("RACKOON_LAB_SUDO_PASSWORD", ""),
               Path(env["RACKOON_LAB_KEY"]).read_text(), host_key)


async def ps_rows(t: AsyncSSHTransport) -> list[dict[str, Any]]:
    result = await t.run(script("docker"), timeout=60)
    assert result.exit_code == 0, result.stderr
    rows = [json.loads(line) for line in sections(result.stdout)["ps"] if line.startswith("{")]
    return [r for r in rows if f"com.docker.compose.project={FACTS['stack']}" in r["Labels"]]


def labels(row: dict[str, Any]) -> dict[str, str]:
    return dict(pair.split("=", 1) for pair in row["Labels"].split(",") if "=" in pair)


# --- spec/integration/checks.json ---------------------------------------------------------------------------------


async def test_overview_parses(lab: Lab) -> None:
    async with lab.transport() as t:
        result = await t.run(script("overview"), timeout=30)
    assert result.exit_code == 0, result.stderr
    s = sections(result.stdout)
    assert s["hostname"][0].strip()
    disks = [ln for ln in s["df"][1:] if ln.strip()]  # first line is df's header
    assert disks
    cpu = [int(v) for v in s["stat"][0].split()[1:]]
    assert sum(cpu) > 0
    assert s["reboot"][0].strip() == "yes"
    system = dict(ln.split("=", 1) for ln in s["system"] if "=" in ln)
    assert system["tailscale_ip"] == FACTS["tailscaleIP"]
    assert int(s["updates"][0]) == len(FACTS["pending"])
    assert int(s["security"][0]) == len(FACTS["security"])


async def test_updates_parse(lab: Lab) -> None:
    async with lab.transport() as t:
        result = await t.run(script("updates"), timeout=60)
    assert result.exit_code == 0, result.stderr
    s = sections(result.stdout)
    # `name/suite1,suite2 version arch [upgradable from: ...]`; apt's "Listing..." line has no slash.
    packages = [ln.split()[0] for ln in s["upgradable"] if "/" in ln.split(" ")[0]]
    names = sorted(p.split("/")[0] for p in packages)
    security = sorted(p.split("/")[0] for p in packages if any(x.endswith("-security") for x in p.split("/")[1].split(",")))
    assert names == sorted(FACTS["pending"])
    assert security == sorted(FACTS["security"])
    assert s["reboot"][0].strip() == "yes"


async def test_docker_parses(lab: Lab) -> None:
    async with lab.transport() as t:
        rows = await ps_rows(t)
    ticker = next(r for r in rows if labels(r).get("com.docker.compose.service") == FACTS["service"])
    assert ticker["State"] == "running"
    # A compose command can be built from the labels: an absolute working dir and absolute config files.
    lab_labels = labels(ticker)
    assert lab_labels["com.docker.compose.project.working_dir"].startswith("/")
    assert lab_labels["com.docker.compose.project.config_files"].startswith("/")


async def test_stream_exit_status(lab: Lab) -> None:
    command = script("stream_wrap", cols="80", rows="24", command="echo lab-out; exit 3")
    async with lab.transport() as t, t.stream(command) as s:
        text = "".join([chunk async for chunk in s])
    match = re.search(r"##rackoon-exit:(\d+)", text)
    assert match and int(match.group(1)) == 3, text
    assert "lab-out" in text
    # asyncssh also reports a pty channel's own exit status (the marker stays the cross-platform contract).
    assert s.exit_status == 0  # the wrapper's last command is `echo`


async def test_logs_cancel_leaves_nothing(lab: Lab) -> None:
    async with lab.transport() as t:
        container_id = (await ps_rows(t))[0]["ID"]
        assert re.fullmatch(r"[0-9a-f]{12,64}", container_id)
        seen = ""
        async with asyncio.timeout(30):
            async with t.stream(script("docker_logs", id=container_id)) as s:
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


async def test_hostkey_mismatch_blocked(lab: Lab) -> None:
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


async def test_stdin_exact_bytes(lab: Lab) -> None:
    size = 1 << 20
    async with lab.transport() as t:
        result = await t.run("wc -c", timeout=30, input="r" * size)
    assert result.exit_code == 0, result.stderr
    assert result.stdout.strip() == str(size)


async def test_sudo_password_checked(lab: Lab) -> None:
    async with lab.transport(user=lab.sudo_user) as sudo:
        # -k: ignore any cached credential, so the password is really checked each time.
        wrong = await sudo.run("sudo -k -S -p '' id -u", timeout=30, input="not-the-password\n")
        assert wrong.exit_code != 0
        # W1 classifies this with the core's classifySudoFailure; the lab's sudo says it plainly.
        assert re.search(r"incorrect password|Sorry, try again|authentication failure", wrong.stderr, re.I), wrong.stderr
        right = await sudo.run("sudo -k -S -p '' id -u", timeout=30, input=lab.sudo_password + "\n")
    assert right.exit_code == 0, right.stderr
    assert right.stdout.strip() == "0"


def test_every_check_has_a_runner() -> None:
    implemented = {
        "overview_parses", "updates_parse", "docker_parses", "stream_exit_status", "logs_cancel_leaves_nothing",
        "hostkey_mismatch_blocked", "stdin_exact_bytes", "sudo_password_checked",
    }
    assert {c["id"] for c in CHECKS["checks"]} <= implemented


# --- W0 spike extras (not in checks.json) -------------------------------------------------------------------------


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
    from rackoon.ssh import Timeout
    async with lab.transport() as t:
        assert (await t.run("exit 7", timeout=15)).exit_code == 7
        assert (await t.run("kill -TERM $$", timeout=15)).exit_code == 15
        with pytest.raises(Timeout):
            await t.run("sleep 30", timeout=1)
        assert (await t.run("echo still-fine", timeout=15)).stdout.strip() == "still-fine"


async def test_spike_utf8_split_across_reads(lab: Lab) -> None:
    # 200k three-byte characters arrive in many reads; none may be cut in half.
    command = script("stream_wrap", cols="80", rows="24",
                     command="python3 -c 'print(\"€\" * 200000)' 2>/dev/null || printf '€%.0s' $(seq 1 200000)")
    async with lab.transport() as t, t.stream(command) as s:
        text = "".join([chunk async for chunk in s])
    assert "�" not in text
    assert text.count("€") == 200000


async def test_spike_shell_resize_and_echo(lab: Lab) -> None:
    async with lab.transport() as t:
        shell = await t.open_shell(100, 30)
        try:
            shell.write(b"stty size; echo rk-$((40+2))\n")
            out = await _read_until(shell, b"rk-42")
            assert b"30 100" in out
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
