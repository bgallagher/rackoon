"""`UpdatesSnapshot` (spec/models.schema.json) and the `updates` command's parser (spec/fixtures/updates)."""

from __future__ import annotations

import re
from dataclasses import dataclass

from . import spec
from .text import split_sections, to_int


class UpdatesParseError(Exception):
    pass


class AptNotInstalled(UpdatesParseError):
    def __init__(self) -> None:
        super().__init__("apt is not installed on this server.")


class UpdatesMalformed(UpdatesParseError):
    def __init__(self, detail: str) -> None:
        super().__init__(f"Unexpected updates output: {detail}")


@dataclass(frozen=True)
class PendingUpdate:
    name: str
    suite: str
    new_version: str
    old_version: str | None
    architecture: str
    is_security: bool

    @property
    def id(self) -> str:
        return f"{self.name}:{self.architecture}"


@dataclass(frozen=True)
class UpdatesSnapshot:
    packages: list[PendingUpdate]
    held: list[str]
    refreshed_at: int | None
    reboot_required: bool

    @property
    def security_count(self) -> int:
        return sum(p.is_security for p in self.packages)


def command() -> str:
    return spec.script("updates")


_LINE = re.compile(r"^[ ]*(\S+)[ ]+(\S+)[ ]+(\S+)(?:[ ]+(\S.*))?$", re.ASCII)


def parse_line(line: str) -> PendingUpdate | None:
    """`name/suite[,suite] new-version arch [upgradable from: old-version]`; anything else ("Listing...", warnings)
    is skipped."""
    m = _LINE.match(line)
    if not m:
        return None
    first, version, arch, rest = m.group(1), m.group(2), m.group(3), m.group(4) or ""
    name, slash, suite = first.partition("/")
    if not slash or not name or not suite:
        return None
    old: str | None = None
    marker = "upgradable from: "
    at = rest.find(marker)
    if at >= 0:
        tail = rest[at + len(marker):]
        value = tail[:-1] if tail.endswith("]") else tail
        old = value or None
    is_security = any(s.endswith("-security") for s in suite.split(","))
    return PendingUpdate(name, suite, version, old, arch, is_security)


def parse(output: str) -> UpdatesSnapshot:
    sections = split_sections(output)
    status = sections.get("apt")
    if not status:
        raise UpdatesMalformed("no ##apt section")
    if status[0] == "missing":
        raise AptNotInstalled()
    packages = [p for p in (parse_line(line) for line in sections.get("upgradable", [])) if p is not None]
    refreshed = sections.get("refreshed")
    reboot = sections.get("reboot")
    return UpdatesSnapshot(packages, list(sections.get("held", [])), to_int(refreshed[0]) if refreshed else None,
                           reboot is not None and bool(reboot) and reboot[0] == "yes")
