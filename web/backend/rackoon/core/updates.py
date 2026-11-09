"""`UpdatesSnapshot` (spec/models.schema.json) and the `updates` command's parser (spec/fixtures/updates)."""

from __future__ import annotations

import re
from dataclasses import dataclass, field

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
    # Upgrades apt would install now; held, phased and kept-back packages are in `waiting` instead.
    packages: list[PendingUpdate]
    held: list[str]
    refreshed_at: int | None
    reboot_required: bool
    # Upgradable but not installed by apt yet: held, deferred by Ubuntu's phased rollout, or kept back (needs a removal).
    waiting: list[PendingUpdate] = field(default_factory=list)
    # Names apt defers for its phased rollout.
    phased: list[str] = field(default_factory=list)

    def waiting_reason(self, p: PendingUpdate) -> str:
        """"held", "phased" or "kept_back"."""
        if p.name in self.held:
            return "held"
        if p.name in self.phased:
            return "phased"
        return "kept_back"

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
    upgradable = [p for p in (parse_line(line) for line in sections.get("upgradable", [])) if p is not None]
    held = list(sections.get("held", []))
    phased, kept = parse_deferred(sections.get("deferred", []))
    waiting_names = set(held) | set(phased) | set(kept)
    refreshed = sections.get("refreshed")
    reboot = sections.get("reboot")
    return UpdatesSnapshot([p for p in upgradable if p.name not in waiting_names], held,
                           to_int(refreshed[0]) if refreshed else None,
                           reboot is not None and bool(reboot) and reboot[0] == "yes",
                           [p for p in upgradable if p.name in waiting_names], phased)


def parse_deferred(lines: list[str]) -> tuple[list[str], list[str]]:
    """`phased <name>` / `kept <name>` lines from a simulated `apt-get upgrade --with-new-pkgs` (`:arch` dropped).
    Unique, in order."""
    phased: list[str] = []
    kept: list[str] = []
    for line in lines:
        f = line.split()
        if len(f) != 2:
            continue
        name = f[1].split(":")[0]
        if not name:
            continue
        target = phased if f[0] == "phased" else kept if f[0] == "kept" else None
        if target is not None and name not in target:
            target.append(name)
    return phased, kept
