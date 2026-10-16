"""Reading a stack's compose or `.env` file on the server: the `file_read` parser (spec/fixtures/file_read)."""

from __future__ import annotations

import base64
import binascii
from dataclasses import dataclass

from .text import split_sections, to_int

# The content travels inside one remote command argument (base64), and Linux caps one argument at 128 KiB.
MAX_BYTES = 65_536


class StackFileError(Exception):
    pass


class NotText(StackFileError):
    def __init__(self) -> None:
        super().__init__("The file is not valid UTF-8 text.")


class FileMalformed(StackFileError):
    def __init__(self, detail: str) -> None:
        super().__init__(f"Unexpected output reading the file: {detail}")


@dataclass(frozen=True)
class RemoteFile:
    content: str
    sha256: str
    mode: str
    """Octal permissions as `stat` prints them, e.g. "644"."""
    owner: str
    """`owner:group`."""
    modified_at: int


@dataclass(frozen=True)
class Missing:
    pass


@dataclass(frozen=True)
class TooLarge:
    pass


RemoteFileState = RemoteFile | Missing | TooLarge


def parse_file_read(output: str) -> RemoteFileState:
    """`##missing`, `##toolarge`, or `##meta` (`mtime mode owner`), `##sha256` and `##content` (base64)."""
    sections = split_sections(output)
    if "missing" in sections:
        return Missing()
    if "toolarge" in sections:
        return TooLarge()
    meta_lines = sections.get("meta")
    meta = meta_lines[0].split(" ", 2) if meta_lines else []
    mtime = to_int(meta[0]) if len(meta) == 3 else None
    if mtime is None:
        raise FileMalformed("no ##meta")
    sha_lines = sections.get("sha256")
    sha = sha_lines[0] if sha_lines else ""
    if len(sha) != 64:
        raise FileMalformed("no ##sha256")
    # An empty file has an empty base64 line, which split_sections drops.
    content = sections.get("content")
    b64 = content[0] if content else ""
    try:
        data = base64.b64decode(b64, validate=True)
    except (binascii.Error, ValueError):
        raise FileMalformed("content is not base64") from None
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise NotText() from None
    return RemoteFile(text, sha, meta[1], meta[2], mtime)
