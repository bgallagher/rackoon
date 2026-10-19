"""A line diff (longest common subsequence), as `LineDiff` in the Swift and Kotlin cores: changed lines in the editor,
and what a save would change in the confirmation sheet (the command itself carries the content encoded)."""

from __future__ import annotations

import enum
from dataclasses import dataclass


class Kind(enum.Enum):
    SAME = "same"
    ADDED = "added"
    REMOVED = "removed"


@dataclass(frozen=True)
class Line:
    kind: Kind
    text: str
    old_number: int | None
    new_number: int | None


def _split(text: str) -> list[str]:
    if not text:
        return []
    parts = text.split("\n")
    if parts[-1] == "":
        parts.pop()  # a trailing newline does not make an extra empty line
    return parts


def lines(old: str, new: str) -> list[Line]:
    a, b = _split(old), _split(new)
    prefix = 0
    while prefix < len(a) and prefix < len(b) and a[prefix] == b[prefix]:
        prefix += 1
    suffix = 0
    while suffix < len(a) - prefix and suffix < len(b) - prefix and a[len(a) - 1 - suffix] == b[len(b) - 1 - suffix]:
        suffix += 1
    am, bm = a[prefix:len(a) - suffix], b[prefix:len(b) - suffix]
    middle: list[tuple[Kind, str]] = []
    if len(am) * len(bm) > 4_000_000:
        # Too big for the table: one removal, then one addition. Correct, just not minimal.
        middle += [(Kind.REMOVED, x) for x in am] + [(Kind.ADDED, x) for x in bm]
    else:
        n, m = len(am), len(bm)
        dp = [[0] * (m + 1) for _ in range(n + 1)]
        for i in range(n - 1, -1, -1):
            for j in range(m - 1, -1, -1):
                dp[i][j] = dp[i + 1][j + 1] + 1 if am[i] == bm[j] else max(dp[i + 1][j], dp[i][j + 1])
        i = j = 0
        while i < n or j < m:
            if i < n and j < m and am[i] == bm[j]:
                middle.append((Kind.SAME, am[i]))
                i += 1
                j += 1
            elif i < n and (j == m or dp[i + 1][j] >= dp[i][j + 1]):  # on a tie the removal comes first
                middle.append((Kind.REMOVED, am[i]))
                i += 1
            else:
                middle.append((Kind.ADDED, bm[j]))
                j += 1
    out: list[Line] = []
    old_n = new_n = 0

    def same(text: str) -> None:
        nonlocal old_n, new_n
        old_n += 1
        new_n += 1
        out.append(Line(Kind.SAME, text, old_n, new_n))

    for k in range(prefix):
        same(a[k])
    for kind, text in middle:
        if kind is Kind.SAME:
            same(text)
        elif kind is Kind.REMOVED:
            old_n += 1
            out.append(Line(Kind.REMOVED, text, old_n, None))
        else:
            new_n += 1
            out.append(Line(Kind.ADDED, text, None, new_n))
    for k in range(len(a) - suffix, len(a)):
        same(a[k])
    return out


def changed_line_numbers(old: str, new: str) -> set[int]:
    return {x.new_number for x in lines(old, new) if x.kind is Kind.ADDED and x.new_number is not None}


def change_count(old: str, new: str) -> int:
    return sum(x.kind is not Kind.SAME for x in lines(old, new))


def preview(old: str, new: str, context: int = 2, max_lines: int = 120) -> str:
    """Changes only, with two lines of context, in a plain +/- form."""
    all_lines = lines(old, new)
    changed = [i for i, x in enumerate(all_lines) if x.kind is not Kind.SAME]
    if not changed:
        return "No changes."
    keep = sorted({k for c in changed for k in range(max(0, c - context), min(len(all_lines) - 1, c + context) + 1)})
    out: list[str] = []
    last = -2
    for k in keep:
        if k != last + 1 and last >= 0:
            out.append("…")
        x = all_lines[k]
        mark = {Kind.ADDED: "+", Kind.REMOVED: "-", Kind.SAME: " "}[x.kind]
        out.append(f"{mark} {x.text}")
        last = k
    if len(out) > max_lines:
        more = len(out) - max_lines
        out = out[:max_lines] + [f"… ({more} more lines)"]
    return "\n".join(out)
