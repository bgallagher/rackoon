"""Container logs: joining streamed chunks into lines, and each line's level and timestamp from explicit markers only
(`LogBuffer`, `LogLineParser`, `LogParts` in the Kotlin core). A message that merely mentions "error" is not red."""

from __future__ import annotations

import enum
import re
from dataclasses import dataclass


class LogBuffer:
    """Joins partial lines, normalises \\r\\n, drops ssh's own "Connection to … closed." and caps memory."""

    def __init__(self, max_lines: int = 2000) -> None:
        self.max_lines = max_lines
        self.lines: list[str] = []
        self.total_appended = 0
        self._partial = ""

    def append(self, chunk: str) -> list[str]:
        """Adds a chunk; returns the complete lines it finished."""
        text = self._partial + chunk.replace("\r\n", "\n").replace("\r", "\n")
        pieces = text.split("\n")
        self._partial = pieces.pop()
        kept = [p for p in pieces if not (p.startswith("Connection to ") and p.endswith(" closed."))]
        self.lines += kept
        self.total_appended += len(kept)
        if len(self.lines) > self.max_lines:
            del self.lines[: len(self.lines) - self.max_lines]
        return kept

    @property
    def text(self) -> str:
        return "\n".join(self.lines + ([self._partial] if self._partial else []))


class LogLevel(enum.Enum):
    ERROR = "error"
    WARN = "warn"
    INFO = "info"
    DEBUG = "debug"


_KEYED = re.compile(r"""\blevel["']?\s*[=:]\s*["']?([A-Za-z]+)""", re.IGNORECASE)
_BRACKETED = re.compile(r"\[(error|err|fatal|panic|critical|warn|warning|info|debug|trace)]", re.IGNORECASE)
_SHOUTING = re.compile(r"\b(ERROR|ERR|FATAL|PANIC|CRITICAL|WARN|WARNING|INFO|DEBUG|TRACE)\b")
_TIMESTAMP = re.compile(r"^\s*(\d{4}[-/]\d{2}[-/]\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?|\d{2}:\d{2}:\d{2}(\.\d+)?)")
_LEADING_LEVEL = re.compile(r"""^(\[(error|err|fatal|panic|critical|warn|warning|info|debug|trace)]|(error|err|fatal|panic|critical|warn|warning|info|debug|trace):?|level=["']?[A-Za-z]+["']?)\s+""",
                            re.IGNORECASE)


def _map(word: str) -> LogLevel | None:
    w = word.lower()
    if w in ("error", "err", "fatal", "panic", "critical"):
        return LogLevel.ERROR
    if w in ("warn", "warning"):
        return LogLevel.WARN
    if w == "info":
        return LogLevel.INFO
    if w in ("debug", "trace"):
        return LogLevel.DEBUG
    return None


def level(line: str) -> LogLevel | None:
    for pattern in (_KEYED, _BRACKETED, _SHOUTING):
        m = pattern.search(line)
        if m:
            found = _map(m.group(1))
            if found:
                return found
    return None


def timestamp_length(line: str) -> int:
    m = _TIMESTAMP.match(line)
    return m.end() if m else 0


@dataclass(frozen=True)
class LogParts:
    time: str | None
    level: LogLevel | None
    message: str


def parts(line: str) -> LogParts:
    """The time, the level and the message with those two taken out of its start."""
    lvl = level(line)
    n = timestamp_length(line)
    time = line[:n].strip() if n else None
    rest = line[n:].lstrip()
    if lvl is not None:
        m = _LEADING_LEVEL.match(rest)
        if m:
            rest = rest[m.end():].lstrip()
    return LogParts(time, lvl, rest)
