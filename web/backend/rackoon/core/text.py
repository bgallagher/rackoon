"""Small text helpers that behave like the Swift and Kotlin ones, so parsers port line for line.

Python's own `int()` and `float()` accept spaces, underscores and words like "nan"; the other cores do not, so numbers
are read with the strict versions here.
"""

from __future__ import annotations

import math
import re

_INT = re.compile(r"[+-]?[0-9]+", re.ASCII)
_FLOAT = re.compile(r"[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?", re.ASCII)

INT32 = (-(2**31), 2**31 - 1)
INT64 = (-(2**63), 2**63 - 1)


def to_int(text: str | None, bounds: tuple[int, int] = INT64) -> int | None:
    """Digits with an optional sign and nothing else (Swift `Int(_:)`, Kotlin `toLongOrNull`); None if out of range."""
    if text is None or not _INT.fullmatch(text):
        return None
    value = int(text)
    return value if bounds[0] <= value <= bounds[1] else None


def to_int32(text: str | None) -> int | None:
    """Kotlin `toIntOrNull`."""
    return to_int(text, INT32)


def to_float(text: str | None) -> float | None:
    """A plain decimal number (Swift `Double(_:)` / Kotlin `toDoubleOrNull` for what servers print)."""
    if text is None or not _FLOAT.fullmatch(text):
        return None
    return float(text)


def round_half_up(value: float) -> int:
    """Swift `.rounded()` / Kotlin `roundToLong` for the positive values parsers see (Python rounds half to even)."""
    return int(math.floor(value + 0.5)) if value >= 0 else -int(math.floor(-value + 0.5))


def trim_blanks(text: str) -> str:
    """Spaces and tabs only, like Swift's `CharacterSet.whitespaces`."""
    return text.strip(" \t")


def split_spaces(text: str) -> list[str]:
    """Split on single spaces, dropping empty pieces (Swift `split(separator: " ")`)."""
    return [p for p in text.split(" ") if p]


def split_sections(output: str) -> dict[str, list[str]]:
    """`##name` sections of a batched script's output. A repeated header starts the section again; empty lines are
    dropped."""
    result: dict[str, list[str]] = {}
    current: str | None = None
    for line in output.split("\n"):
        if line.startswith("##"):
            current = line[2:]
            result[current] = []
        elif current is not None and line:
            result.setdefault(current, []).append(line)
    return result


def key_values(lines: list[str], separator: str = "=") -> dict[str, str]:
    """`KEY=value` lines; the value is trimmed and one pair of surrounding double quotes removed. Last one wins."""
    values: dict[str, str] = {}
    for line in lines:
        i = line.find(separator)
        if i < 0:
            continue
        value = trim_blanks(line[i + 1:])
        if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        values[line[:i]] = value
    return values
