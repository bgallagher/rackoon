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


# --- paths, transfers and changes (the Swift core's RemotePath, FileTransferCommands, FileOperationCommands) --------


def join(folder: str, name: str) -> str:
    return "/" + name if folder == "/" else folder + "/" + name


def parent(path: str) -> str | None:
    """`/` has no parent."""
    if path == "/" or not path.startswith("/"):
        return None
    parts = [p for p in path.split("/") if p][:-1]
    return "/" + "/".join(parts)


def crumbs(path: str) -> list[tuple[str, str]]:
    """`/opt/stacks` -> [("/", "/"), ("opt", "/opt"), ("stacks", "/opt/stacks")]."""
    out = [("/", "/")]
    current = ""
    for part in (p for p in path.split("/") if p):
        current += "/" + part
        out.append((part, current))
    return out


def home_command() -> str:
    return spec.script("files_home")


def error_of(exit_code: int, stderr: str, path: str) -> str:
    if exit_code == 3:
        return f"{path} doesn't exist (or isn't a folder)."
    if exit_code == 4:
        return f"You don't have permission to open {path}."
    return stderr.strip() or f"the server answered with status {exit_code}"


def valid_name(name: str) -> bool:
    """A name that can be one path component and one shell word."""
    return bool(name) and name not in (".", "..") and "/" not in name and shell.quote(name) is not None


MAX_UPLOAD_NAME_BYTES = 240  # the temporary name adds 14 bytes; file names are limited to 255


def upload_file_command(directory: str, new_name: str, size: int) -> str | None:
    """stdin goes to `.<name>.rackoon-part` beside the target and is moved into place only if exactly `size` bytes
    arrived: a cancelled or dropped upload looks like a normal end of input to `cat`."""
    if not valid_name(new_name) or len(new_name.encode()) > MAX_UPLOAD_NAME_BYTES or size < 0:
        return None
    dest = shell.quote_path(join(directory, new_name))
    tmp = shell.quote_path(join(directory, f".{new_name}.rackoon-part"))
    if dest is None or tmp is None:
        return None
    return shell.fill(spec.script("files_upload_file"), {"dest": dest, "tmp": tmp, "bytes": str(size)})


def upload_folder_command(directory: str, source_name: str, new_name: str, size: int) -> str | None:
    if not valid_name(source_name) or not valid_name(new_name) or size < 0:
        return None
    dest = shell.quote_path(join(directory, new_name))
    src = shell.quote(source_name)
    tmpdir = shell.quote_path(join(directory, ".rackoon-XXXXXX"))
    if dest is None or src is None or tmpdir is None:
        return None
    return shell.fill(spec.script("files_upload_folder"), {"tmpdir": tmpdir, "dest": dest, "src": src,
                                                           "bytes": str(size)})


def download_command(directory: str, name: str, is_folder: bool) -> str | None:
    """`cat` for a file; a folder's CONTENTS as a tar stream (links inside it stay links)."""
    path = shell.quote_path(join(directory, name)) if valid_name(name) else None
    if path is None:
        return None
    return shell.fill(spec.script("files_download_folder" if is_folder else "files_download_file"), {"path": path})


def delete_problem(path: str) -> str | None:
    """Why a folder can't be deleted from here, or None. Stricter than deleting a stack: nothing shallower than three
    levels, service data and a home folder's settings folders stay out of reach."""
    from .stack_actions import unsafe_folder_reason
    reason = unsafe_folder_reason(path)
    if reason:
        return reason
    parts = [p for p in path.split("/") if p]
    if len(parts) < 3:
        return f"{path} is too high up to delete from here. Use a terminal if you really mean it."
    if parts[0] == "var" and parts[1] in ("lib", "www", "mail", "spool", "backups") and (len(parts) < 4 or parts[1] == "lib"):
        return f"{path} holds service data. Use a terminal if you really mean it."
    if parts[0] in ("home", "Users") and len(parts) == 3 and parts[2].startswith("."):
        return f"{path} is a settings folder in a home folder"
    if parts[0] == "root" and len(parts) == 2:
        return f"{path} is a settings folder in a home folder"
    return None


@dataclass(frozen=True)
class FileOperation:
    """mkdir (`name`), rename (`name` -> `to`) or delete (`name`, `is_folder`), all inside `directory`."""

    kind: str
    directory: str
    name: str
    to: str | None = None
    is_folder: bool = False

    @property
    def summary(self) -> str:
        if self.kind == "mkdir":
            return f"Create folder {self.name} in {self.directory}"
        if self.kind == "rename":
            return f"Rename {self.name} to {self.to} in {self.directory}"
        return f"Delete {'folder' if self.is_folder else 'file'} {self.name} in {self.directory}"

    @property
    def command(self) -> str | None:
        if not valid_name(self.name):
            return None
        path = shell.quote_path(join(self.directory, self.name))
        if path is None:
            return None
        if self.kind == "mkdir":
            return shell.fill(spec.script("files_mkdir"), {"path": path})
        if self.kind == "rename":
            if self.to is None or not valid_name(self.to) or self.to == self.name:
                return None
            to = shell.quote_path(join(self.directory, self.to))
            return shell.fill(spec.script("files_rename"), {"from": path, "to": to}) if to else None
        if self.kind == "delete":
            if self.is_folder:
                if delete_problem(join(self.directory, self.name)) is not None:
                    return None
                return shell.fill(spec.script("files_delete_folder"), {"path": path})
            return shell.fill(spec.script("files_delete_file"), {"path": path})
        return None


def keep_both_name(name: str, taken: set[str]) -> str:
    """"report 2.pdf", "report 3.pdf"...: the first name not taken (the extension stays at the end)."""
    stem, dot, ext = name.rpartition(".")
    if not dot or not stem:
        stem, ext = name, ""
    n = 2
    while True:
        candidate = f"{stem} {n}" + (f".{ext}" if ext else "")
        if candidate not in taken:
            return candidate
        n += 1
