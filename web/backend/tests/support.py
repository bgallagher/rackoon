"""The language-neutral contract in spec/, read straight from the repository, and a structural JSON diff for golden
files (numbers by value, key order ignored), like `jsonDiff` in android/core's tests."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from rackoon.core.spec import spec_dir

SPEC = spec_dir()
PLATFORM = "web"


def load(relative: str) -> Any:
    return json.loads((SPEC / relative).read_text(encoding="utf-8"))


def fixtures(command_id: str, suffix: str = ".out.txt") -> list[str]:
    """Every `NAME.out.txt` in spec/fixtures/<id>/ (raw captures are git-ignored and skipped)."""
    folder = SPEC / "fixtures" / command_id
    return sorted(p.name.removesuffix(suffix) for p in folder.iterdir()
                  if p.name.endswith(suffix) and not p.name.startswith("raw-"))


def out(command_id: str, name: str) -> str:
    return (SPEC / "fixtures" / command_id / f"{name}.out.txt").read_text(encoding="utf-8")


def expected(command_id: str, name: str) -> Any:
    return load(f"fixtures/{command_id}/{name}.expected.json")


def done_features() -> set[str]:
    return {f["id"] for f in load("features.json")["features"] if f["platforms"][PLATFORM]["status"] == "done"}


def run_everything() -> bool:
    """`RACKOON_PARITY_ALL=1` runs scenarios and lab checks whose feature is not done on web yet, to check work ahead
    of the matrix. It never counts as proof: check-parity only reads the gated run."""
    return os.environ.get("RACKOON_PARITY_ALL") == "1"


def json_diff(want: Any, got: Any, path: str = "$") -> str | None:
    """The first difference, or None when equal. Numbers compare by value (1 equals 1.0); booleans are not numbers."""
    if isinstance(want, dict) and isinstance(got, dict):
        for k in sorted(set(want) | set(got)):
            if k not in got:
                return f"{path}.{k}: missing in actual (expected {want[k]!r})"
            if k not in want:
                return f"{path}.{k}: unexpected key in actual ({got[k]!r})"
            d = json_diff(want[k], got[k], f"{path}.{k}")
            if d:
                return d
        return None
    if isinstance(want, list) and isinstance(got, list):
        if len(want) != len(got):
            return f"{path}: expected {len(want)} items, got {len(got)}"
        for i, (w, g) in enumerate(zip(want, got)):
            d = json_diff(w, g, f"{path}[{i}]")
            if d:
                return d
        return None
    if isinstance(want, bool) or isinstance(got, bool):
        return None if type(want) is type(got) and want == got else f"{path}: expected {want!r}, got {got!r}"
    if isinstance(want, (int, float)) and isinstance(got, (int, float)):
        return None if float(want) == float(got) else f"{path}: expected {want!r}, got {got!r}"
    return None if type(want) is type(got) and want == got else f"{path}: expected {want!r}, got {got!r}"


def assert_json_equals(want: Any, got: Any, what: str) -> None:
    diff = json_diff(want, got)
    assert diff is None, f"{what}: {diff}"


def spec_path(*parts: str) -> Path:
    return SPEC.joinpath(*parts)
