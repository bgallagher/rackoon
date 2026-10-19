"""Docker in demo mode: made-up stacks (the Mac's homelab and garage-nuc) answered in the formats the real parsers
read, compose files that can be opened, checked and saved, stacks that can be created and deleted, actions that
stream believable output ending with the usual exit marker, and logs that keep coming. All of it lives in memory;
nothing is sent anywhere. The commands are recognised by their spec templates, so keep this in step with
spec/commands.json.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import random
import re
import time
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from types import TracebackType

from rackoon.core import compose_edit, docker, spec
from rackoon.ssh import CommandResult


@dataclass
class Box:
    """One demo container."""

    id: str
    name: str
    image: str
    project: str | None
    service: str | None
    ports: list[tuple[int, int]] = field(default_factory=list)
    state: str = "running"
    health: str = "none"
    exit_code: int = 0
    cpu: float = 0.5
    mem_mib: float = 64.0
    labels: dict[str, str] = field(default_factory=dict)
    started: float = field(default_factory=lambda: time.time() - 86400 * 3)


def _id(name: str) -> str:
    return hashlib.sha256(name.encode()).hexdigest()[:12]


def _href(site: str) -> dict[str, str]:
    return {"homepage.href": site}


HOMELAB: list[tuple[str, list[tuple[str, str, list[tuple[int, int]], dict[str, str]]], dict[str, str]]] = [
    ("immich", [
        ("immich-server", "ghcr.io/immich-app/immich-server:release", [(2283, 2283)],
         {"homepage.name": "Immich", "homepage.group": "Media", "homepage.href": "https://immich.app",
          "homepage.description": "Photos and videos"}),
        ("immich-machine-learning", "ghcr.io/immich-app/immich-machine-learning:release", [], {}),
        ("database", "tensorchord/pgvecto-rs:pg14-v0.2.0", [], {}),
        ("redis", "redis:7-alpine", [], {})],
     {"UPLOAD_LOCATION": "/mnt/photos", "DB_PASSWORD": "demo-not-a-secret"}),
    ("jellyfin", [("jellyfin", "jellyfin/jellyfin:10.10", [(8096, 8096)],
                   {"homepage.name": "Jellyfin", "homepage.group": "Media", "homepage.href": "https://jellyfin.org"})],
     {}),
    ("paperless", [
        ("webserver", "ghcr.io/paperless-ngx/paperless-ngx:2.13", [(8000, 8000)],
         {"homepage.name": "Paperless", "homepage.group": "Documents", "homepage.href": "https://docs.paperless-ngx.com"}),
        ("broker", "redis:7", [], {})], {"PAPERLESS_TIME_ZONE": "Europe/Dublin"}),
    ("grafana", [
        ("grafana", "grafana/grafana:11.3.0", [(3000, 3000)],
         {"homepage.name": "Grafana", "homepage.group": "Monitoring", "homepage.href": "https://grafana.com"}),
        ("prometheus", "prom/prometheus:v2.55.0", [(9090, 9090)], {}),
        ("promtail", "grafana/promtail:3.2.1", [], {})], {}),
    ("uptime-kuma", [("uptime-kuma", "louislam/uptime-kuma:1", [(3001, 3001)],
                      {"homepage.name": "Uptime Kuma", "homepage.group": "Monitoring",
                       "homepage.href": "https://uptime.kuma.pet"})], {}),
    ("homepage", [("homepage", "ghcr.io/gethomepage/homepage:v0.9.10", [(3002, 3000)],
                   {"homepage.name": "Homepage", "homepage.group": "Tools", "homepage.href": "https://gethomepage.dev"})],
     {}),
    ("vaultwarden", [("vaultwarden", "vaultwarden/server:1.32.5", [(8081, 80)],
                      {"homepage.name": "Vaultwarden", "homepage.group": "Tools",
                       "homepage.href": "https://github.com/dani-garcia/vaultwarden"})], {"DOMAIN": "https://vault.example"}),
    ("nextcloud", [("app", "nextcloud:30", [(8443, 443)], {}), ("db", "mariadb:11", [], {})],
     {"MYSQL_PASSWORD": "demo-not-a-secret"}),
    ("traefik", [("traefik", "traefik:v3.2", [(80, 80), (443, 443)], {})], {}),
    ("backup", [("restic", "restic/restic:0.17.3", [], {})], {}),
]
NUC: list[tuple[str, list[tuple[str, str, list[tuple[int, int]], dict[str, str]]], dict[str, str]]] = [
    ("homeassistant", [("homeassistant", "ghcr.io/home-assistant/home-assistant:2024.11", [(8123, 8123)],
                        {"homepage.name": "Home Assistant", "homepage.group": "Home",
                         "homepage.href": "https://www.home-assistant.io"})], {"TZ": "Europe/Dublin"}),
    ("mosquitto", [("mosquitto", "eclipse-mosquitto:2", [(1883, 1883)], {})], {}),
]
STANDALONE = {"homelab": [("pihole", "pihole/pihole:2024.07.0", [(53, 53), (8053, 80)]),
                          ("portainer", "portainer/portainer-ce:2.21.4", [(9443, 9443)])],
              "garage-nuc": []}

_B64 = re.compile(r"echo '?([A-Za-z0-9+/=]+)'? \| base64 -d")
_QUOTED = r"'((?:[^']|'\\'')*)'"


def _unquote(q: str) -> str:
    return q.replace("'\\''", "'")


def compose_of(services: list[tuple[str, str, list[tuple[int, int]], dict[str, str]]], env: dict[str, str]) -> str:
    lines = ["services:"]
    for service, image, ports, labels in services:
        lines += [f"  {service}:", f"    image: {image}", "    restart: unless-stopped"]
        if ports:
            lines.append("    ports:")
            lines += [f'      - "{h}:{c}"' for h, c in ports]
        if env and service == services[0][0]:
            lines.append("    environment:")
            lines += [f"      - {k}=${{{k}}}" for k in env]
        if labels:
            lines.append("    labels:")
            lines += [f"      - {k}={v}" for k, v in labels.items()]
    return "\n".join(lines) + "\n"


class DemoDocker:
    def __init__(self, hostname: str) -> None:
        self.hostname = hostname
        self.boxes: list[Box] = []
        self.files: dict[str, str] = {}
        rng = random.Random(hostname)
        for project, services, env in (HOMELAB if hostname == "homelab" else NUC if hostname == "garage-nuc" else []):
            directory = f"/opt/stacks/{project}"
            self.files[f"{directory}/compose.yaml"] = compose_of(services, env)
            if env:
                self.files[f"{directory}/.env"] = "".join(f"{k}={v}\n" for k, v in env.items())
            for service, image, ports, labels in services:
                box = Box(_id(f"{hostname}/{project}/{service}"), f"{project}-{service}-1", image, project, service,
                          ports, labels=dict(labels), cpu=round(rng.uniform(0.1, 4.0), 2),
                          mem_mib=round(rng.uniform(20, 900), 1))
                self.boxes.append(box)
        for name, image, ports in STANDALONE.get(hostname, []):
            self.boxes.append(Box(_id(f"{hostname}/{name}"), name, image, None, None, ports,
                                  cpu=round(rng.uniform(0.1, 2.0), 2), mem_mib=round(rng.uniform(40, 200), 1)))
        for b in self.boxes:
            if b.service == "promtail":
                b.health = "unhealthy"
            if b.project == "backup":
                b.state, b.exit_code = "exited", 0
            if b.project == "nextcloud" and b.service == "db":
                b.state, b.exit_code = "exited", 1

    # --- reading

    def ps(self) -> str:
        rows, stats = [], []
        for b in self.boxes:
            labels = dict(b.labels)
            if b.project:
                directory = f"/opt/stacks/{b.project}"
                labels.update({"com.docker.compose.project": b.project, "com.docker.compose.service": b.service or "",
                               "com.docker.compose.project.working_dir": directory,
                               "com.docker.compose.project.config_files": f"{directory}/compose.yaml"})
            running = b.state == "running"
            up = max(60, int(time.time() - b.started))
            status = (f"Up {up // 86400} days" if up >= 86400 else f"Up {up // 60} minutes") if running \
                else f"Exited ({b.exit_code}) 2 hours ago"
            if running and b.health == "unhealthy":
                status += " (unhealthy)"
            ports = ", ".join(f"0.0.0.0:{h}->{c}/tcp" for h, c in b.ports) if running else ""
            rows.append(json.dumps({"ID": b.id, "Names": b.name, "Image": b.image, "State": b.state, "Status": status,
                                    "Labels": ",".join(f"{k}={v}" for k, v in labels.items()), "Ports": ports},
                                   separators=(",", ":")))
            if running:
                cpu = max(0.0, b.cpu + random.uniform(-0.3, 0.3))
                stats.append(json.dumps({"ID": b.id, "CPUPerc": f"{cpu:.2f}%",
                                         "MemUsage": f"{b.mem_mib:.1f}MiB / 15.62GiB"}, separators=(",", ":")))
        return "\n".join(["##docker", "ok", "##ps", *rows, "##stats", *stats]) + "\n"

    def listening(self) -> str:
        ports = {22} | {h for b in self.boxes if b.state == "running" for h, _ in b.ports}
        return "".join(f"LISTEN 0 4096 0.0.0.0:{p} 0.0.0.0:*\n" for p in sorted(ports))

    @staticmethod
    def _compose_problem(text: str) -> str | None:
        for n, line in enumerate(text.split("\n"), 1):
            if "\t" in line:
                return f"yaml: line {n}: found character that cannot start any token"
        if not re.search(r"^services:", text, re.M):
            return "services must be a mapping"
        return None

    def run(self, command: str) -> CommandResult | None:
        """The answer to a known command, or None for anything else."""
        if command == docker.command():
            return CommandResult(self.ps(), "", 0)
        if command == spec.script("listening_ports"):
            return CommandResult(self.listening(), "", 0)
        if command.startswith("timeout 20 docker manifest inspect"):
            missing = any(w in command for w in ("doesnotexist", "nosuchimage"))
            return CommandResult("notfound\n" if missing else "found\n", "", 0)
        m = re.match(r"F=" + _QUOTED + r"; if \[ ! -e", command)
        if m:
            return self._read(_unquote(m.group(1)))
        m = re.match(r"F=" + _QUOTED + r"; D=", command)
        if m:
            return self._write(_unquote(m.group(1)), command)
        if re.match(r"D=" + _QUOTED + r"; T=\$\(mktemp", command) or command.startswith("T=$(mktemp -d)"):
            return self._validate(command)
        m = re.match(r"D=" + _QUOTED + r"; P=", command)
        if m:
            return self._create(_unquote(m.group(1)), command)
        return None

    def _read(self, path: str) -> CommandResult:
        text = self.files.get(path)
        if text is None:
            return CommandResult("##missing\n", "", 0)
        data = text.encode()
        sha = hashlib.sha256(data).hexdigest()
        return CommandResult(f"##meta\n{int(time.time())} 644 demo:demo\n##sha256\n{sha}\n##content\n"
                             f"{base64.b64encode(data).decode()}\n", "", 0)

    def _validate(self, command: str) -> CommandResult:
        m = _B64.search(command)
        text = base64.b64decode(m.group(1)).decode() if m else ""
        if '--env-file "$T"' in command:
            return CommandResult("", "", 0)
        problem = self._compose_problem(text)
        if problem:
            return CommandResult(f"validating compose.yaml: {problem}\n", "", 1)
        return CommandResult("", "", 0)

    def _write(self, path: str, command: str) -> CommandResult:
        m = _B64.search(command)
        text = base64.b64decode(m.group(1)).decode() if m else ""
        if not path.endswith("/.env"):
            problem = self._compose_problem(text)
            if problem:
                return CommandResult(f"##invalid\nvalidating compose.yaml: {problem}\n", "", 4)
        old = self.files.get(path)
        expected = re.search(r"([0-9a-f]{64})", command)
        if old is not None and expected and hashlib.sha256(old.encode()).hexdigest() != expected.group(1):
            return CommandResult("##changed\n", "", 3)
        self.files[path] = text
        if path.endswith("/compose.yaml"):
            self._relabel(path.rsplit("/", 2)[-2], text)
        return CommandResult(f"##saved\n{hashlib.sha256(text.encode()).hexdigest()}\n", "", 0)

    def _relabel(self, project: str, text: str) -> None:
        """A save of a running demo stack's compose file shows its labels at once (the real thing needs `up -d`)."""
        for b in self.boxes:
            if b.project == project and b.service:
                block = _service_block(text, b.service)
                b.labels = {k: v for k, v in re.findall(r"^\s*- (homepage\.[a-z]+)=(.*)$", block, re.M)}

    def _create(self, directory: str, command: str) -> CommandResult:
        if any(p.startswith(directory + "/") for p in self.files):
            return CommandResult("##exists\n", "", 3)
        blobs = [base64.b64decode(b).decode() for b in _B64.findall(command)]
        problem = self._compose_problem(blobs[0] if blobs else "")
        if problem:
            return CommandResult(f"##invalid\nvalidating compose.yaml: {problem}\n", "", 4)
        self.files[f"{directory}/compose.yaml"] = blobs[0]
        if len(blobs) > 1:
            self.files[f"{directory}/.env"] = blobs[1]
        return CommandResult("##created\n", "", 0)

    # --- streaming

    def stream(self, command: str) -> DemoStream:
        return DemoStream(self._lines(command))

    async def _lines(self, command: str) -> AsyncIterator[str]:
        m = re.match(r"docker logs -f --tail 100 ([0-9a-f]+)$", command)
        if m:
            async for chunk in self._logs(m.group(1)):
                yield chunk
            return
        inner = re.search(r"\( (.*) \); rk=\$\?", command, re.S)
        if inner is None:
            yield "\r\n##rackoon-exit:127\r\n"
            return
        code = 0
        async for chunk in self._act(inner.group(1)):
            if chunk.startswith("##exit:"):
                code = int(chunk[7:])
                continue
            yield chunk
        yield f"\r\n##rackoon-exit:{code}\r\n"

    async def _act(self, cmd: str) -> AsyncIterator[str]:
        m = re.match(r"docker (start|stop|restart) ([0-9a-f]+)$", cmd)
        if m:
            box = next((b for b in self.boxes if b.id == m.group(2)), None)
            await asyncio.sleep(0.8)
            if box is None:
                yield f"Error response from daemon: No such container: {m.group(2)}\r\n"
                yield "##exit:1"
                return
            box.state = "exited" if m.group(1) == "stop" else "running"
            box.exit_code = 0 if m.group(1) != "stop" else 143
            if box.state == "running":
                box.started = time.time()
            yield f"{box.id}\r\n"
            return
        m = re.match(r"docker rm -f( -v)? ([0-9a-f]+)$", cmd)
        if m:
            await asyncio.sleep(0.6)
            self.boxes = [b for b in self.boxes if b.id != m.group(2)]
            yield f"{m.group(2)}\r\n"
            return
        m = re.match(r"docker pull '([^']+)'$", cmd)
        if m:
            for line in (f"{m.group(1).split(':')[-1]}: Pulling from {m.group(1).split(':')[0]}",
                         "Digest: sha256:" + hashlib.sha256(m.group(1).encode()).hexdigest(),
                         f"Status: Image is up to date for {m.group(1)}"):
                await asyncio.sleep(0.4)
                yield line + "\r\n"
            return
        m = re.search(r"docker compose -p ([a-z0-9][a-z0-9_-]*) .*? (up -d|pull|restart|down)(.*?)( && cd /|$)", cmd)
        if m is None:
            yield "demo: not run\r\n"
            yield "##exit:1"
            return
        project, verb, rest = m.group(1), m.group(2), m.group(3)
        boxes = [b for b in self.boxes if b.project == project]
        if verb == "pull":
            for b in boxes:
                await asyncio.sleep(0.35)
                yield f"[+] Pulling {b.service} \x1b[32m✔\x1b[0m Pulled\r\n"
            return
        if verb == "restart":
            for b in boxes:
                await asyncio.sleep(0.5)
                b.state, b.started = "running", time.time()
                yield f"[+] Restarting 1/1\r\n \x1b[32m✔\x1b[0m Container {b.name}  Started\r\n"
            return
        if verb == "down":
            for b in boxes:
                await asyncio.sleep(0.4)
                yield f" \x1b[32m✔\x1b[0m Container {b.name}  Removed\r\n"
            self.boxes = [b for b in self.boxes if b.project != project]
            yield f" \x1b[32m✔\x1b[0m Network {project}_default  Removed\r\n"
            if "rm -rf" in cmd:
                directory = f"/opt/stacks/{project}"
                found = next((p.rsplit("/", 1)[0] for p in self.files if p.rsplit("/", 1)[0].endswith("/" + project)),
                             directory)
                self.files = {p: t for p, t in self.files.items() if not p.startswith(found + "/")}
            return
        # up -d, with --build / --force-recreate / one service
        folder = next((p.rsplit("/", 1)[0] for p in self.files if p.endswith(f"/{project}/compose.yaml")), None)
        text = self.files.get(f"{folder}/compose.yaml", "") if folder else ""
        if "--build" in rest:
            await asyncio.sleep(0.5)
            yield "[+] Building 3.2s (8/8) FINISHED\r\n"
        if not boxes and text:
            for service in compose_edit.services(text):
                block = _service_block(text, service)
                image = re.search(r"^\s*image:\s*['\"]?([^'\"\s]+)", block, re.M)
                ports = [(int(h), int(c)) for h, c in re.findall(r"(\d+):(\d+)['\"]?\s*$", block, re.M)]
                labels = {k: v for k, v in re.findall(r"^\s*- (homepage\.[a-z]+)=(.*)$", block, re.M)}
                box = Box(_id(f"{self.hostname}/{project}/{service}/{time.time()}"), f"{project}-{service}-1",
                          image.group(1) if image else "demo/app", project, service, ports, labels=labels,
                          cpu=0.3, mem_mib=40.0, started=time.time())
                self.boxes.append(box)
                await asyncio.sleep(0.5)
                yield f" \x1b[32m✔\x1b[0m Container {box.name}  Started\r\n"
            yield f" \x1b[32m✔\x1b[0m Network {project}_default  Created\r\n"
            return
        yield f"[+] Running {len(boxes)}/{len(boxes)}\r\n"
        for b in boxes:
            await asyncio.sleep(0.4)
            changed = "--force-recreate" in rest or b.state != "running"
            b.state = "running"
            if changed:
                b.started = time.time()
            yield f" \x1b[32m✔\x1b[0m Container {b.name}  {'Started' if changed else 'Running'}\r\n"

    async def _logs(self, cid: str) -> AsyncIterator[str]:
        box = next((b for b in self.boxes if b.id == cid), None)
        name = box.service if box and box.service else box.name if box else "app"
        messages = [("INFO", f"{name} ready to accept connections"), ("INFO", "GET /api/health 200 3ms"),
                    ("WARN", "slow request: GET /api/assets took 1.2s"), ("INFO", "GET / 200 12ms"),
                    ("ERROR", "upstream timed out (110: Connection timed out)") if name == "promtail"
                    else ("INFO", "background job finished in 0.4s")]
        rng = random.Random(cid)

        def stamp(offset: float) -> str:
            return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - offset)) + ".000Z"

        yield "".join(f"{stamp(600 - i * 6)} {lvl} {text}\r\n"
                      for i, (lvl, text) in enumerate(messages * 4))
        while True:
            await asyncio.sleep(rng.uniform(0.6, 2.0))
            lvl, text = rng.choice(messages)
            yield f"{stamp(0)} {lvl} {text}\r\n"


def _service_block(text: str, service: str) -> str:
    lines = text.split("\n")
    out: list[str] = []
    inside = False
    for line in lines:
        if re.match(rf"^  {re.escape(service)}:\s*$", line):
            inside = True
            continue
        if inside and re.match(r"^  \S", line):
            break
        if inside:
            out.append(line)
    return "\n".join(out)


class DemoStream:
    """`async with transport.stream(c) as s: async for chunk in s`, over a canned generator."""

    def __init__(self, chunks: AsyncIterator[str]) -> None:
        self.chunks = chunks

    async def __aenter__(self) -> DemoStream:
        return self

    async def __aexit__(self, exc_type: type[BaseException] | None, exc: BaseException | None,
                        tb: TracebackType | None) -> None:
        aclose = getattr(self.chunks, "aclose", None)
        if aclose is not None:
            await aclose()

    def __aiter__(self) -> AsyncIterator[str]:
        return self.chunks
