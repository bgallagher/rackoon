"""`DockerSnapshot` (spec/models.schema.json), the `docker` command's parser (spec/fixtures/docker), stacks, bookmarks,
and the container and compose commands (spec/scenarios/compose-commands.json, docker-ids.json)."""

from __future__ import annotations

import enum
import json as jsonlib
import string
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urlsplit

from . import shell, spec
from .policy import Intent, Risk
from .jsonmodel import json
from .text import round_half_up, split_sections, to_float, to_int32, trim_blanks


class DockerParseError(Exception):
    pass


class NotInstalled(DockerParseError):
    def __init__(self) -> None:
        super().__init__("Docker is not installed on this server.")


class Daemon(DockerParseError):
    """Docker is installed but the command failed (daemon down, permission denied...). Carries docker's message."""

    def __init__(self, text: str) -> None:
        super().__init__(text)
        self.text = text


class DockerMalformed(DockerParseError):
    def __init__(self, detail: str) -> None:
        super().__init__(f"Unexpected docker output: {detail}")


# --- Bookmarks (Homepage label convention, gethomepage.dev) -------------------------------------------------------

BOOKMARK_LABELS = ("homepage.group", "homepage.name", "homepage.icon", "homepage.href", "homepage.description")
# What a URL may contain once spaces and controls are excluded (RFC 3986 reserved, unreserved and %).
_URL_CHARS = set(string.ascii_letters + string.digits + "-._~:/?#[]@!$&'()*+,;=%")


def is_valid_url(text: str) -> bool:
    """An http or https URL with a host and nothing that could break a label or open something else."""
    if len(text) > 2048 or any(c.isspace() or ord(c) < 32 for c in text):
        return False
    if any(c not in _URL_CHARS for c in text):
        return False
    try:
        parts = urlsplit(text)
        host = parts.hostname
    except ValueError:
        return False
    return parts.scheme.lower() in ("http", "https") and bool(host)


@dataclass(frozen=True)
class Bookmark:
    href: str
    name: str | None = None
    group: str | None = None
    icon: str | None = None
    description: str | None = None

    @staticmethod
    def from_labels(labels: Mapping[str, str]) -> Bookmark | None:
        raw = labels.get("homepage.href")
        href = trim_blanks(raw) if raw is not None else None
        if href is None or not is_valid_url(href):
            return None

        def value(key: str) -> str | None:
            v = labels.get(key)
            v = trim_blanks(v) if v is not None else None
            return v or None

        return Bookmark(href, value("homepage.name"), value("homepage.group"), value("homepage.icon"),
                        value("homepage.description"))


# --- Containers and stacks ----------------------------------------------------------------------------------------


@dataclass(frozen=True)
class PortMapping:
    host_port: int
    container_port: int
    proto: str


@dataclass(frozen=True)
class DockerContainer:
    id: str
    name: str
    image: str
    state: str
    health: str
    status: str
    ports: list[PortMapping]
    project: str | None = None
    service: str | None = None
    working_dir: str | None = None
    config_file: str | None = None
    config_files: list[str] = field(default_factory=list)
    cpu_percent: float | None = None
    memory_used_bytes: int | None = None
    memory_limit_bytes: int | None = None
    bookmark: Bookmark | None = None
    icon_url: str | None = field(default=None, metadata=json("iconURL"))

    @property
    def is_running(self) -> bool:
        return self.state in ("running", "restarting")

    @property
    def is_unhealthy(self) -> bool:
        return self.health == "unhealthy"


def standalone_id(container_name: str) -> str:
    return f"standalone/{container_name}"


@dataclass(frozen=True)
class DockerStack:
    name: str
    working_dir: str | None
    config_file: str | None
    config_files: list[str]
    containers: list[DockerContainer]
    is_standalone: bool = False

    @property
    def id(self) -> str:
        """A compose project's name, or `standalone/<container>`: `/` can't be in either, so they never clash."""
        return standalone_id(self.name) if self.is_standalone else self.name

    @property
    def kind_label(self) -> str:
        return "Standalone" if self.is_standalone else "Compose Stack"

    @property
    def config_file_name(self) -> str | None:
        return self.config_file.rsplit("/", 1)[-1] if self.config_file is not None else None

    @property
    def running_count(self) -> int:
        return sum(c.is_running for c in self.containers)

    @property
    def unhealthy_count(self) -> int:
        return sum(c.is_unhealthy for c in self.containers)

    @property
    def stopped_count(self) -> int:
        return len(self.containers) - self.running_count

    @property
    def has_bookmark(self) -> bool:
        return any(c.bookmark is not None for c in self.containers)


@dataclass(frozen=True)
class DockerSnapshot:
    containers: list[DockerContainer]

    @property
    def stacks(self) -> list[DockerStack]:
        """One stack per compose project, and one per container without a project (`docker run`), sorted by name
        ignoring case; on a tie the compose stack comes first."""
        by_project: dict[str, list[DockerContainer]] = {}
        standalone: list[DockerContainer] = []
        for c in self.containers:
            if c.project is not None:
                by_project.setdefault(c.project, []).append(c)
            else:
                standalone.append(c)
        stacks: list[DockerStack] = []
        for name, members in by_project.items():
            members = sorted(members, key=lambda c: c.service if c.service is not None else c.name)
            # All of a project's containers carry the same compose labels. If they disagree there is no single file
            # set to run against, so the stack gets none and compose actions are refused instead of guessing.
            layouts = {(c.working_dir, tuple(c.config_files or ([c.config_file] if c.config_file else [])))
                       for c in members if c.working_dir is not None}
            layout = next(iter(layouts)) if len(layouts) == 1 else None
            files = list(layout[1]) if layout else []
            stacks.append(DockerStack(name, layout[0] if layout else None, files[0] if files else None, files, members))
        stacks += [DockerStack(c.name, None, None, [], [c], is_standalone=True) for c in standalone]
        return sorted(stacks, key=lambda s: (s.name.lower(), s.is_standalone, s.name))


# --- Parsing ------------------------------------------------------------------------------------------------------


def health(field_value: str | None, status: str) -> str:
    """Newer Docker reports HealthStatus; older versions only put it in the status text."""
    if field_value:
        return field_value
    if "(unhealthy)" in status:
        return "unhealthy"
    if "(healthy)" in status:
        return "healthy"
    if "(health: starting)" in status:
        return "starting"
    return "none"


def parse_labels(text: str) -> dict[str, str]:
    """Comma-separated key=value pairs. A value may contain commas (several compose files), so a piece without `=`
    continues the previous value."""
    labels: dict[str, str] = {}
    last: str | None = None
    for piece in (p for p in text.split(",") if p):
        eq = piece.find("=")
        if eq >= 0:
            last = piece[:eq]
            labels[last] = piece[eq + 1:]
        elif last is not None:
            labels[last] = labels.get(last, "") + "," + piece
    return labels


def parse_ports(text: str) -> list[PortMapping]:
    """`127.0.0.1:8087->8080/tcp, [::]:8087->8080/tcp, 5432/tcp` -> published mappings only, de-duplicated."""
    result: list[PortMapping] = []
    for part in (trim_blanks(p) for p in text.split(",")):
        arrow = part.find("->")
        if arrow < 0:
            continue
        left, right = part[:arrow], part[arrow + 2:]
        host_parts = [p for p in left.split(":") if p]
        host_port = to_int32(host_parts[-1]) if host_parts else None  # ranges don't parse, so they are skipped
        rhs = [p for p in right.split("/") if p]
        if host_port is None or len(rhs) != 2:
            continue
        container_port = to_int32(rhs[0])
        if container_port is None:
            continue
        mapping = PortMapping(host_port, container_port, rhs[1])
        if mapping not in result:
            result.append(mapping)
    return result


def parse_percent(text: str) -> float | None:
    return to_float(text.strip("% "))


_UNITS = {"B": 1.0, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12,
          "KiB": 1024.0, "MiB": 1_048_576.0, "GiB": 1_073_741_824.0, "TiB": 1_099_511_627_776.0}


def parse_size(text: str) -> int | None:
    t = trim_blanks(text)
    i = next((k for k, ch in enumerate(t) if not (ch.isdigit() and ch.isascii() or ch == ".")), -1)
    if i < 0:
        return None
    number = to_float(t[:i])
    unit = _UNITS.get(t[i:])
    if number is None or unit is None:
        return None
    return round_half_up(number * unit)


def parse_mem_usage(text: str) -> tuple[int, int] | None:
    """`255.8MiB / 7.57GiB`."""
    parts = text.split(" / ")
    if len(parts) != 2:
        return None
    used, limit = parse_size(parts[0]), parse_size(parts[1])
    return (used, limit) if used is not None and limit is not None else None


def _str(row: dict[str, Any], key: str, required: bool = True) -> str | None:
    value = row.get(key)
    if value is None:
        if required:
            raise DockerMalformed(f"ps row: no {key}")
        return None
    if not isinstance(value, str):
        raise DockerMalformed(f"ps row: {key} is not text")
    return value


def parse(output: str) -> DockerSnapshot:
    sections = split_sections(output)
    status_lines = sections.get("docker")
    if not status_lines:
        raise DockerMalformed("no ##docker section")
    if status_lines[0] == "missing":
        raise NotInstalled()

    ps_lines = sections.get("ps", [])
    # Anything that is not a JSON row is docker's error text (daemon down, permission denied...).
    if any(not line.startswith("{") for line in ps_lines):
        raise Daemon("\n".join(ps_lines))

    stats: dict[str, tuple[float | None, int | None, int | None]] = {}
    for line in sections.get("stats", []):
        if not line.startswith("{"):
            continue
        try:
            row = jsonlib.loads(line)
            sid, cpu, mem = row["ID"], row["CPUPerc"], row["MemUsage"]
        except (ValueError, KeyError, TypeError):
            continue
        if not (isinstance(sid, str) and isinstance(cpu, str) and isinstance(mem, str)):
            continue
        usage = parse_mem_usage(mem)
        stats[sid] = (parse_percent(cpu), usage[0] if usage else None, usage[1] if usage else None)

    containers: list[DockerContainer] = []
    for line in ps_lines:
        try:
            row = jsonlib.loads(line)
        except ValueError as e:
            raise DockerMalformed(f"ps row: {e}") from None
        if not isinstance(row, dict):
            raise DockerMalformed("ps row: not an object")
        cid, names, image, state, status = (_str(row, k) or "" for k in ("ID", "Names", "Image", "State", "Status"))
        labels = parse_labels(_str(row, "Labels", required=False) or "")
        s = stats.get(cid)
        config_files = [f for f in labels.get("com.docker.compose.project.config_files", "").split(",") if f]
        icon = labels.get("net.unraid.docker.icon")
        icon = trim_blanks(icon) if icon is not None else None
        containers.append(DockerContainer(
            id=cid, name=names, image=image, state=state, health=health(_str(row, "HealthStatus", False), status),
            status=status, ports=parse_ports(_str(row, "Ports", False) or ""),
            project=labels.get("com.docker.compose.project"), service=labels.get("com.docker.compose.service"),
            working_dir=labels.get("com.docker.compose.project.working_dir"),
            config_file=config_files[0] if config_files else None, config_files=config_files,
            cpu_percent=s[0] if s else None, memory_used_bytes=s[1] if s else None,
            memory_limit_bytes=s[2] if s else None, bookmark=Bookmark.from_labels(labels),
            icon_url=icon if icon is not None and is_valid_url(icon) else None,
        ))
    return DockerSnapshot(containers)


def is_permission_problem(message: str) -> bool:
    m = message.lower()
    return "permission denied" in m and ("docker" in m or "/var/run/docker.sock" in m)


# --- Commands -----------------------------------------------------------------------------------------------------


def command() -> str:
    return spec.script("docker")


def is_container_id(value: str) -> bool:
    """Ids come from docker, but anything that is not 12 to 64 lowercase hex is refused before it reaches a shell."""
    return 12 <= len(value) <= 64 and all(c in "0123456789abcdef" for c in value)


def is_compose_project_name(name: str) -> bool:
    """Lowercase letters, digits, `-` and `_`, starting with a letter or digit."""
    if not name or not (name[0] in string.ascii_lowercase or name[0] in string.digits):
        return False
    return all(c in string.ascii_lowercase or c in string.digits or c in "-_" for c in name)


def is_service_name(name: str) -> bool:
    """Compose service names: letters, digits, `.`, `_`, `-`, starting with a letter or digit, at most 64."""
    if not name or len(name) > 64 or not (name[0] in string.ascii_letters or name[0] in string.digits):
        return False
    return all(c in string.ascii_letters or c in string.digits or c in "-_." for c in name)


class DockerAction(enum.Enum):
    START = "start"
    STOP = "stop"
    RESTART = "restart"

    def command(self, container_id: str) -> str | None:
        if not is_container_id(container_id):
            return None
        return shell.fill(spec.script(f"docker_{self.value}"), {"id": container_id})

    def intent(self, container_id: str) -> Intent | None:
        cmd = self.command(container_id)
        return Intent(f"{self.value.capitalize()} container {container_id}", cmd, Risk.MUTATE) if cmd else None


def logs_command(container_id: str) -> str | None:
    return shell.fill(spec.script("docker_logs"), {"id": container_id}) if is_container_id(container_id) else None


def shell_command(container_id: str) -> str | None:
    return shell.fill(spec.script("docker_shell"), {"id": container_id}) if is_container_id(container_id) else None


class ComposeAction(enum.Enum):
    """Whole-stack actions, run with `docker compose` from the stack's own compose files."""

    PULL = ("pull", "Pull images for", 900)
    UP = ("up", "Update", 600)
    RESTART = ("restart", "Restart", 600)
    REBUILD = ("rebuild", "Rebuild", 1800)  # building images from source can be slow
    RECREATE = ("recreate", "Recreate", 600)

    def __init__(self, raw: str, verb: str, timeout_seconds: int) -> None:
        self.raw = raw
        self.verb = verb
        self.timeout_seconds = timeout_seconds

    @classmethod
    def from_raw(cls, raw: str) -> ComposeAction | None:
        return next((a for a in cls if a.raw == raw), None)

    def command(self, stack: DockerStack, service: str | None = None) -> str | None:
        """The exact command, or None if the stack has no compose project/paths or any is unsafe to send. With
        `service`, only REBUILD has a command (that one service)."""
        if service is None:
            return _fill(spec.script(f"compose_{self.raw}"), stack, {})
        if self is not ComposeAction.REBUILD or not is_service_name(service) or \
                not any(c.service == service for c in stack.containers):
            return None
        return _fill(spec.script("compose_rebuild_service"), stack, {"service": service})

    def intent(self, stack: DockerStack, service: str | None = None) -> Intent | None:
        cmd = self.command(stack, service)
        if cmd is None:
            return None
        summary = f"{self.verb} service {service} of {stack.name}" if service else f"{self.verb} stack {stack.name}"
        return Intent(summary, cmd, Risk.MUTATE)


def _fill(template: str, stack: DockerStack, extra: Mapping[str, str]) -> str | None:
    paths = stack.config_files or ([stack.config_file] if stack.config_file else [])
    # A comma inside a real path was split by the label parser, leaving a relative piece quote_path refuses.
    files = [q for q in (shell.quote_path(p) for p in paths) if q is not None]
    directory = shell.quote_path(stack.working_dir) if stack.working_dir is not None else None
    if stack.is_standalone or not is_compose_project_name(stack.name) or directory is None or not paths \
            or len(files) != len(paths):
        return None
    values = {"dir": directory, "project": stack.name, "files": " ".join(f"-f {f}" for f in files), **extra}
    return shell.fill(template, values)
