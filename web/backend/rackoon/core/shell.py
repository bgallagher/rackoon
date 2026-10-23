"""Quoting for values that reach a server's shell, and one-pass templates (spec/scenarios/shell-quote.json,
template-fill.json)."""

from __future__ import annotations

from collections.abc import Mapping


def quote(value: str) -> str | None:
    """Single-quotes the value so the shell reads one literal word; embedded quotes become `'\\''`. None for what no
    shell word can carry safely: empty, NUL, newline or carriage return."""
    if not value or "\0" in value or "\n" in value or "\r" in value:
        return None
    return "'" + value.replace("'", "'\\''") + "'"


def quote_path(path: str) -> str | None:
    """An absolute path, quoted. Relative paths are refused, so a command never depends on the login directory."""
    return quote(path) if path.startswith("/") else None


def fill(template: str, values: Mapping[str, str]) -> str:
    """Fills `{name}` placeholders in ONE pass: inserted values are never scanned again, so a value containing
    `{other}` cannot be substituted a second time. Unknown placeholders stay as written."""
    out: list[str] = []
    i = 0
    n = len(template)
    while i < n:
        if template[i] == "{":
            close = template.find("}", i)
            if close >= 0:
                value = values.get(template[i + 1:close])
                if value is not None:
                    out.append(value)
                    i = close + 1
                    continue
        out.append(template[i])
        i += 1
    return "".join(out)
