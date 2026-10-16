"""Listing a folder on the server (`files_list`, spec/fixtures/files_list): one GNU `find -printf` with NUL separators,
so any file name survives. Also the listening-ports check the Add Container form uses (`listening_ports`)."""

from __future__ import annotations

import enum
from dataclasses import dataclass, field

from . import shell, spec
from .jsonmodel import json
from .text import to_float, to_int

MAX_ENTRIES = 5000


class EntryKind(enum.Enum):
    FILE = "file"
    DIRECTORY = "directory"
    SYMLINK = "symlink"
    OTHER = "other"


@dataclass(frozen=True)
class FolderEntry:
    name: str
    kind: EntryKind
    link_target: str | None = field(metadata=json(null=True))
    """Where a symlink points (as written)."""
    links_to_directory: bool
    size: int
    modified: float
    """Unix seconds."""
    permissions: str
    owner: str

    @property
    def is_directory(self) -> bool:
        return self.kind is EntryKind.DIRECTORY or self.links_to_directory


@dataclass(frozen=True)
class RemoteListing:
    path: str
    """The folder's real path (symlinks resolved)."""
    entries: list[FolderEntry]
    truncated: bool


def list_command(directory: str) -> str | None:
    quoted = shell.quote_path(directory)
    return shell.fill(spec.script("files_list"), {"dir": quoted}) if quoted else None


def parse_listing(output: str) -> RemoteListing | None:
    """The folder's real path, then eight fields per entry: type, type after following links, size, modified,
    permissions, owner, name, link target."""
    fields = output.split("\0")
    if fields and fields[-1] == "":
        fields.pop()  # the output ends with a NUL
    if not fields or not fields[0].startswith("/"):
        return None
    path, rest = fields[0], fields[1:]
    entries: list[FolderEntry] = []
    truncated = False
    for i in range(0, len(rest) - len(rest) % 8, 8):
        f = rest[i:i + 8]
        if len(entries) >= MAX_ENTRIES:
            truncated = True
            break
        kind = {"f": EntryKind.FILE, "d": EntryKind.DIRECTORY, "l": EntryKind.SYMLINK}.get(f[0], EntryKind.OTHER)
        entries.append(FolderEntry(
            name=f[6], kind=kind, link_target=f[7] if kind is EntryKind.SYMLINK and f[7] else None,
            links_to_directory=kind is EntryKind.SYMLINK and f[1] == "d", size=to_int(f[2]) or 0,
            modified=to_float(f[3]) or 0.0, permissions=f[4], owner=f[5]))
    return RemoteListing(path, entries, truncated)


def parse_listening_ports(output: str) -> set[int]:
    """`ss -H -tln`: the local address is the fourth column and the port follows its last colon (`0.0.0.0:80`,
    `[::]:80`, `127.0.0.53%lo:53`)."""
    ports: set[int] = set()
    for line in output.split("\n"):
        columns = [c for c in line.replace("\t", " ").split(" ") if c]
        if len(columns) < 4:
            continue
        local = columns[3]
        colon = local.rfind(":")
        if colon < 0:
            continue
        port = to_int(local[colon + 1:], (-(2**31), 2**31 - 1))
        if port is not None:
            ports.add(port)
    return ports
