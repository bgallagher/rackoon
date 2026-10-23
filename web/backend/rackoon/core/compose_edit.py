"""Editing compose text as line edits only, so every other line, comment and label stays exactly as it was: reading
the `services:` block (`ComposeYaml`), setting and removing a service's labels (`ComposeLabels`, used for Homepage
bookmarks) and adding a new service (`ComposeInsert`). Ported from the Kotlin core."""

from __future__ import annotations

import re
from dataclasses import dataclass

from .docker import Bookmark

# --- the services block -------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Block:
    start: int
    end: int
    inline: bool


def trimmed(line: str) -> str:
    return line.strip(" \t")


def indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def is_content(line: str) -> bool:
    t = trimmed(line)
    return bool(t) and not t.startswith("#")


def services_block(lines: list[str]) -> Block | None:
    start = next((i for i, x in enumerate(lines) if x.startswith("services:")), -1)
    if start < 0:
        return None
    rest = lines[start][len("services:"):]
    if "#" in rest:
        rest = rest[:rest.index("#")]
    inline = bool(trimmed(rest))
    end = next((i for i in range(start + 1, len(lines)) if lines[i] and lines[i][0] not in " \t#"), len(lines))
    return Block(start, end, inline)


def child_indent(lines: list[str], block: Block) -> int | None:
    return next((indent(lines[i]) for i in range(block.start + 1, block.end) if is_content(lines[i])), None)


def service_names(lines: list[str], block: Block, step: int) -> list[str]:
    if step <= 0:
        return []
    out = []
    for i in range(block.start + 1, block.end):
        line = lines[i]
        if indent(line) != step:
            continue
        body = line[step:]
        colon = body.find(":")
        if colon < 0 or not body or body[0] in "#- ":
            continue
        out.append(body[:colon].strip("\"'"))
    return out


def services(text: str) -> list[str]:
    lines = text.replace("\r\n", "\n").split("\n")
    block = services_block(lines)
    step = child_indent(lines, block) if block else None
    return service_names(lines, block, step) if block and step is not None else []


# --- labels -------------------------------------------------------------------------------------------------------


class ComposeEditError(Exception):
    pass


@dataclass(frozen=True)
class LabelChange:
    key: str
    value: str | None
    """None removes the label."""


BOOKMARK_KEYS = ("homepage.group", "homepage.name", "homepage.icon", "homepage.href", "homepage.description")


def bookmark_changes(b: Bookmark) -> list[LabelChange]:
    """What to write for each label; empty optional fields are removed."""
    def clean(s: str | None) -> str | None:
        return s.strip() if s and s.strip() else None
    return [LabelChange("homepage.group", clean(b.group)), LabelChange("homepage.name", clean(b.name)),
            LabelChange("homepage.icon", clean(b.icon)), LabelChange("homepage.href", b.href.strip(" \t")),
            LabelChange("homepage.description", clean(b.description))]


def bookmark_removal() -> list[LabelChange]:
    return [LabelChange(k, None) for k in BOOKMARK_KEYS]


def normalized_address(text: str) -> str:
    """A bare address like `app.example.com` is read as https."""
    t = text.strip()
    return t if not t or "://" in t else f"https://{t}"


_NON_STRING = [re.compile(p, f) for p, f in (
    (r"^[-+]?(\d[\d_]*\.?[\d_]*|\.\d[\d_]*)([eE][-+]?\d+)?$", 0),
    (r"^[-+]?\.(inf|nan)$", re.IGNORECASE),
    (r"^[-+]?0[xob][0-9a-fA-F_]+$", re.IGNORECASE),
    (r"^\d{4}-\d{1,2}-\d{1,2}([Tt ].*)?$", 0),
    (r"^[-+]?\d[\d_]*(:[0-5]?\d)+(\.\d*)?$", 0),
)]
_SPECIAL_START = "-?:,[]{}#&*!|>'\"%@`"


def scalar(s: str) -> str:
    """A YAML scalar: plain when that is safe, double-quoted otherwise."""
    newline = any(c in "\n\r\u0085  " for c in s)
    needs = (not s or s != trimmed(s) or ": " in s or " #" in s or s.endswith(":") or '"' in s or "\\" in s or newline
             or (s[0] in _SPECIAL_START and not s.startswith("homepage."))
             or s.lower() in ("true", "false", "yes", "no", "y", "n", "on", "off", "null", "~")
             or any(p.search(s) for p in _NON_STRING))
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"' if needs else s


def _item(key: str, value: str, as_list: bool, at: int) -> str:
    v = value.replace("$", "$$")  # `$` starts a variable in compose files
    return " " * at + ("- " + scalar(f"{key}={v}") if as_list else f"{key}: " + scalar(v))


def _unquote(s: str) -> str:
    return s[1:-1] if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'" else s


def _label_key(line: str, as_list: bool) -> str | None:
    body = trimmed(line)
    if as_list:
        if not body.startswith("-"):
            return None
        body = _unquote(trimmed(body[1:]))
        eq = body.find("=")
        return body[:eq] if eq >= 0 else body
    colon = body.find(":")
    return _unquote(trimmed(body[:colon])) if colon >= 0 else None


def _is_service_header(line: str, name: str, step: int) -> bool:
    if indent(line) != step:
        return False
    t = trimmed(line)
    if not t.startswith(name):
        return False
    rest = t[len(name):]
    if not rest.startswith(":"):
        return False
    rest = rest[1:]
    if "#" in rest:
        rest = rest[:rest.index("#")]
    return not trimmed(rest)


def _last_content(lines: list[str], start: int, end: int) -> int | None:
    return next((i for i in range(end - 1, start - 1, -1) if is_content(lines[i])), None)


def defines_service(name: str, text: str) -> bool:
    return name in services(text)


def setting_labels(changes: list[LabelChange], name: str, text: str) -> str:
    crlf = "\r\n" in text
    if crlf and "\n" in text.replace("\r\n", ""):
        raise ComposeEditError("This file mixes Windows and Unix line endings, so labels can't be edited automatically. "
                               "Edit the file by hand.")
    result = _setting_lf(changes, name, text.replace("\r\n", "\n") if crlf else text)
    return result.replace("\n", "\r\n") if crlf else result


def _not_found(name: str) -> ComposeEditError:
    return ComposeEditError(f"This compose file has no service called {name}.")


def _insert_new(changes: list[LabelChange], lines: list[str], after: int, key_indent: int, unit: int) -> str:
    additions = [_item(c.key, c.value, True, key_indent + unit) for c in changes if c.value is not None]
    if additions:
        lines[after + 1:after + 1] = [" " * key_indent + "labels:"] + additions
    return "\n".join(lines)


def _setting_lf(changes: list[LabelChange], name: str, text: str) -> str:
    lines = text.split("\n")
    block = services_block(lines)
    if block is None:
        raise _not_found(name)
    if block.inline:
        raise ComposeEditError("This file writes services on one line, so labels can't be edited automatically. "
                               "Edit the file by hand.")
    step = child_indent(lines, block)
    if not step:
        raise _not_found(name)
    header = next((i for i in range(block.start + 1, block.end) if _is_service_header(lines[i], name, step)), None)
    if header is None:
        raise _not_found(name)
    end = next((i for i in range(header + 1, block.end) if is_content(lines[i]) and indent(lines[i]) <= step), block.end)
    key_indent = next((indent(lines[i]) for i in range(header + 1, end) if is_content(lines[i])), None)
    if key_indent is None:
        return _insert_new(changes, lines, header, step + 2, 2)  # an empty service
    if any(indent(lines[i]) == key_indent and trimmed(lines[i]).startswith("<<:") for i in range(header + 1, end)):
        raise ComposeEditError(f"{name} uses a YAML merge key (<<:), so its labels may come from somewhere else. "
                               "Edit the file by hand.")
    unit = max(1, key_indent - step)
    labels_line = next((i for i in range(header + 1, end)
                        if indent(lines[i]) == key_indent and trimmed(lines[i]).startswith("labels:")), None)
    if labels_line is None:
        last = _last_content(lines, header + 1, end)
        return _insert_new(changes, lines, last if last is not None else header, key_indent, unit)
    rest = trimmed(lines[labels_line])[len("labels:"):]
    if "#" in rest:
        rest = rest[:rest.index("#")]
    if trimmed(rest):
        raise ComposeEditError(f"The labels of {name} are written inline ({{...}} or [...]), so they can't be edited "
                               "automatically. Edit the file by hand.")
    block_end = end
    for i in range(labels_line + 1, end):
        if not is_content(lines[i]):
            continue
        d = indent(lines[i])
        if d < key_indent or (d == key_indent and not trimmed(lines[i]).startswith("-")):
            block_end = i
            break
    while block_end - 1 > labels_line and not is_content(lines[block_end - 1]):
        block_end -= 1
    items = [i for i in range(labels_line + 1, block_end) if is_content(lines[i])]
    as_list = (trimmed(lines[items[0]]).startswith("- ") or trimmed(lines[items[0]]) == "-") if items else True
    item_indent = indent(lines[items[0]]) if items else key_indent + unit
    for change in changes:
        existing = next((i for i in range(labels_line + 1, block_end) if is_content(lines[i])
                         and indent(lines[i]) == item_indent and _label_key(lines[i], as_list) == change.key), None)
        new_line = _item(change.key, change.value, as_list, item_indent) if change.value is not None else None
        if existing is not None and new_line is not None:
            lines[existing] = new_line
        elif existing is not None:
            del lines[existing]
            block_end -= 1
        elif new_line is not None:
            at = _last_content(lines, labels_line + 1, block_end)
            lines.insert((at if at is not None else labels_line) + 1, new_line)
            block_end += 1
    if not any(is_content(lines[i]) for i in range(labels_line + 1, block_end)):
        del lines[labels_line:block_end]  # nothing left under labels: drop the key too
    return "\n".join(lines)
