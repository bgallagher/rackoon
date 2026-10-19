"""Stage W7 in demo mode: services (homelab answers like the spec's `synthetic-root-failed` capture, so its Services and
Alerts have a failed and a crash-looping unit; garage-nuc like `ubuntu-user-units-and-processes`), the light container
check built from the demo's containers, an in-memory folder tree for Files, and canned output for the Commands library.
Nothing is sent anywhere; keep the formats in step with spec/commands.json."""

from __future__ import annotations

import asyncio
import re
import time
from collections.abc import AsyncIterable, AsyncIterator
from dataclasses import dataclass, field

from rackoon.core import docker_states, remote_files, services, shell, spec
from rackoon.ssh import CommandResult, SSHError

from .demo_docker import DemoDocker

SERVICE_FIXTURE = {"homelab": "synthetic-root-failed", "garage-nuc": "ubuntu-user-units-and-processes"}


@dataclass
class Node:
    kind: str  # "d" or "f"
    data: bytes = b""
    modified: float = field(default_factory=time.time)


class DemoFiles:
    def __init__(self, user: str) -> None:
        home = "/root" if user == "root" else f"/home/{user}"
        self.home = home
        self.nodes: dict[str, Node] = {}
        for d in ("/", "/home", home, f"{home}/backups", f"{home}/notes", "/opt", "/opt/stacks", "/opt/stacks/jellyfin",
                  "/srv", "/srv/media", "/srv/media/films", "/etc"):
            self.nodes[d] = Node("d")
        files = {f"{home}/notes/todo.md": b"- renew the certificate\n- check the backup job\n",
                 f"{home}/backups/db-2026-10-18.sql.gz": b"\x1f\x8b" + b"\x00" * 2048,
                 f"{home}/.bashrc": b"export EDITOR=vim\n",
                 "/opt/stacks/jellyfin/compose.yaml": b"services:\n  jellyfin:\n    image: jellyfin/jellyfin:10.10\n",
                 "/etc/hostname": b"demo\n", "/srv/media/films/README.txt": b"Films go here.\n"}
        for path, data in files.items():
            self.nodes[path] = Node("f", data)

    def children(self, path: str) -> list[str]:
        prefix = path.rstrip("/") + "/"
        return sorted(p for p in self.nodes if p != path and p.startswith(prefix) and "/" not in p[len(prefix):])

    def listing(self, path: str) -> CommandResult:
        n = self.nodes.get(path)
        if n is None or n.kind != "d":
            return CommandResult("", "", 3)
        fields = [path]
        for child in self.children(path):
            c = self.nodes[child]
            fields += [c.kind, c.kind, str(len(c.data) if c.kind == "f" else 4096), f"{c.modified:.0f}",
                       "644" if c.kind == "f" else "755", "demo", child.rsplit("/", 1)[-1], ""]
        return CommandResult("\0".join(fields) + "\0", "", 0)


def _paths(command: str) -> list[str]:
    return [shell_unquote(m) for m in re.findall(r"'((?:[^']|'\\'')*)'", command)]


def shell_unquote(q: str) -> str:
    return q.replace("'\\''", "'")


class DemoExtras:
    def __init__(self, hostname: str, user: str, docker: DemoDocker) -> None:
        self.hostname = hostname
        self.docker = docker
        self.files = DemoFiles(user)
        fixture = SERVICE_FIXTURE.get(hostname)
        self.services = (spec.spec_dir() / "fixtures" / "services" / f"{fixture}.out.txt").read_text() if fixture else ""

    def run(self, command: str) -> CommandResult | None:
        if command == services.command():
            return CommandResult(self.services, "", 0) if self.services else None
        if command == docker_states.command():
            lines = []
            for b in self.docker.boxes:
                status = "Up 3 days" if b.state == "running" else f"Exited ({b.exit_code}) 2 hours ago"
                if b.health == "unhealthy" and b.state == "running":
                    status += " (unhealthy)"
                lines.append("\t".join([b.id + "0" * 52, b.name, b.state, status, b.project or "",
                                        b.labels.get("homepage.href", "")]))
            return CommandResult("\n".join(lines) + "\n", "", 0)
        if command == remote_files.home_command():
            return CommandResult(self.files.home + "\n", "", 0)
        if command.startswith("cd -P -- "):
            return self.files.listing(_paths(command)[0])
        for kind in ("files_mkdir", "files_rename", "files_delete_file", "files_delete_folder"):
            head = spec.script(kind).split("{")[0]
            if command.startswith(head) and _matches(command, spec.script(kind)):
                return self._op(kind, _paths(command))
        return None

    def _op(self, kind: str, paths: list[str]) -> CommandResult:
        nodes = self.files.nodes
        if kind == "files_mkdir":
            if paths[0] in nodes:
                return CommandResult("", "That name is already taken.\n", 5)
            nodes[paths[0]] = Node("d")
        elif kind == "files_rename":
            src, dst = paths[-2], paths[-1]  # mv -- {from} {to} ends the template
            if dst in nodes:
                return CommandResult("", "That name is already taken.\n", 5)
            for p in [p for p in nodes if p == src or p.startswith(src + "/")]:
                nodes[dst + p[len(src):]] = nodes.pop(p)
        else:
            for p in [p for p in nodes if p == paths[0] or p.startswith(paths[0] + "/")]:
                del nodes[p]
        return CommandResult("", "", 0)

    async def upload(self, command: str, chunks: AsyncIterable[bytes]) -> CommandResult:
        dest = _paths(command)[0]
        size = int(re.search(r"-ne (\d+)", command).group(1)) if re.search(r"-ne (\d+)", command) else -1  # type: ignore[union-attr]
        data = b""
        async for c in chunks:
            data += c
        if len(data) != size:
            return CommandResult("", "The upload was interrupted, so nothing was changed.\n", 1)
        if self.files.nodes.get(dest, Node("f")).kind == "d":
            return CommandResult("", "A folder with that name already exists.\n", 5)
        self.files.nodes[dest] = Node("f", data)
        return CommandResult("", "", 0)

    async def download(self, command: str) -> AsyncIterator[bytes]:
        path = _paths(command)[0]
        n = self.files.nodes.get(path)
        if n is None:
            raise SSHError(f"cat: {path}: No such file or directory")
        if n.kind == "f":
            yield n.data
            return
        import io
        import tarfile
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w") as tar:
            prefix = path.rstrip("/") + "/"
            for p, node in sorted(self.files.nodes.items()):
                if p.startswith(prefix):
                    info = tarfile.TarInfo("./" + p[len(prefix):])
                    if node.kind == "d":
                        info.type = tarfile.DIRTYPE
                        tar.addfile(info)
                    else:
                        info.size = len(node.data)
                        tar.addfile(info, io.BytesIO(node.data))
        yield buf.getvalue()

    async def library(self, script: str) -> AsyncIterator[str] | None:
        """Canned output for a Commands-library script, or None (then the demo says it ran nothing)."""
        answers = [
            ("df -hT", "Filesystem     Type  Size  Used Avail Use% Mounted on\r\n/dev/nvme0n1p2 ext4  466G  191G  252G  44% /\r\n"),
            ("ps -eo", "    PID USER     %CPU %MEM     ELAPSED COMMAND\r\n   1423 root      4.2  2.1  3-02:11:09 dockerd\r\n"),
            ("free -h", "               total        used        free\r\nMem:            15Gi       6.1Gi       2.3Gi\r\n"),
            ("uptime", " 10:42:07 up 27 days,  2 users,  load average: 0.48, 0.51, 0.48\r\n\r\ncores: 8\r\n"),
            ("ss -tulpn", "Netid State  Local Address:Port  Process\r\ntcp   LISTEN 0.0.0.0:22          sshd\r\n"),
            ("docker ps -a", "NAMES             STATUS          IMAGE\r\njellyfin-jellyfin-1  Up 3 days   jellyfin/jellyfin:10.10\r\n"),
            ("systemctl", "  UNIT                 LOAD   ACTIVE SUB    DESCRIPTION\r\n● backup-sync.service loaded failed failed Backup sync\r\n"),
        ]
        text = next((a for k, a in answers if k in script), None)
        if text is None:
            return None

        async def gen() -> AsyncIterator[str]:
            await asyncio.sleep(0.3)
            yield text
            yield "\r\n##rackoon-exit:0\r\n"
        return gen()


def _matches(command: str, template: str) -> bool:
    """The fixed text around a template's placeholders is all in the command."""
    return all(part in command for part in re.split(r"\{[a-z]+\}", template) if part.strip())


__all__ = ["DemoExtras", "shell"]
