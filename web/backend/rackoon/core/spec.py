"""The language-neutral contract in `spec/`, read at runtime like the Kotlin core reads its resources.

There is no Python copy of any shell command: every script comes from `spec/commands.json`. The spec folder is
`$RACKOON_SPEC` when set (the Docker image puts it there), otherwise the repository's `spec/` above this package.
Reading these files is the core's only I/O; everything else in `rackoon.core` is pure.
"""

from __future__ import annotations

import json
import os
from functools import cache
from pathlib import Path
from typing import Any


class SpecError(Exception):
    """spec/ is missing, unreadable or does not have what was asked for."""


def spec_dir() -> Path:
    env = os.environ.get("RACKOON_SPEC")
    if env:
        return Path(env)
    for parent in Path(__file__).resolve().parents:
        candidate = parent / "spec" / "commands.json"
        if candidate.is_file():
            return candidate.parent
    raise SpecError("spec/ not found: set RACKOON_SPEC")


def themes_path() -> Path:
    """The shared themes.json. It lives with the Mac app's resources; the image copies it next to spec/."""
    env = os.environ.get("RACKOON_THEMES")
    if env:
        return Path(env)
    beside = spec_dir() / "themes.json"
    if beside.is_file():
        return beside
    repo = spec_dir().parent / "apple" / "Apps" / "RackoonMac" / "Resources" / "themes.json"
    if repo.is_file():
        return repo
    raise SpecError("themes.json not found: set RACKOON_THEMES")


@cache
def load_json(relative: str) -> Any:
    path = spec_dir() / relative
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as e:
        raise SpecError(f"cannot read spec/{relative}: {e}") from None


@cache
def _scripts() -> dict[str, str]:
    return {c["id"]: c["script"] for c in load_json("commands.json")["commands"]}


def script(command_id: str) -> str:
    """The exact shell script of a spec command."""
    try:
        return _scripts()[command_id]
    except KeyError:
        raise SpecError(f"no command {command_id!r} in spec/commands.json") from None


def command_ids() -> set[str]:
    return set(_scripts())
