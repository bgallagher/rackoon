"""The light container check behind Alerts: the `docker_states` parser (spec/fixtures/docker_states)."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from . import spec
from .docker import is_container_id, is_permission_problem
from .jsonmodel import json, to_json
from .text import to_int


@dataclass(frozen=True)
class StateContainer:
    id: str
    name: str
    state: str
    """created, running, restarting, exited, paused, dead, removing."""
    status: str
    """`Exited (1) 3 hours ago`, `Up 2 days (healthy)`."""
    project: str
    href: str
    """The `homepage.href` label, for certificate checks."""

    @property
    def exit_code(self) -> int | None:
        open_at = self.status.find("Exited (")
        if open_at < 0:
            return None
        start = open_at + len("Exited (")
        close = self.status.find(")", start)
        return to_int(self.status[start:close]) if close >= 0 else None


@dataclass(frozen=True)
class DockerStatesReading:
    containers: list[StateContainer]
    problem: str | None = None
    """None, "notInstalled", "permissionDenied" or "other"."""
    problem_text: str | None = field(default=None, metadata=json(skip=True))

    def to_golden(self) -> dict[str, Any]:
        """Swift's Codable shape for the enum: `{"notInstalled": {}}`, `{"other": {"_0": text}}`."""
        out: dict[str, Any] = {"containers": to_json(self.containers)}
        if self.problem == "other":
            out["problem"] = {"other": {"_0": self.problem_text or ""}}
        elif self.problem is not None:
            out["problem"] = {self.problem: {}}
        return out


def command() -> str:
    return spec.script("docker_states")


def parse(output: str) -> DockerStatesReading:
    containers: list[StateContainer] = []
    other: list[str] = []
    for line in output.split("\n"):
        if not line.strip(" \t"):
            continue
        f = line.split("\t")
        if len(f) >= 6 and is_container_id(f[0]):
            containers.append(StateContainer(f[0], f[1], f[2], f[3], f[4], f[5]))
        else:
            other.append(line)
    if containers or not other:
        return DockerStatesReading(containers)
    text = "\n".join(other)
    lower = text.lower()
    if "not found" in lower or "no such file" in lower:
        return DockerStatesReading([], "notInstalled")
    if is_permission_problem(text):
        return DockerStatesReading([], "permissionDenied")
    return DockerStatesReading([], "other", text[:300])
