"""Models to JSON in the shape spec/models.schema.json and the golden files use: camelCase keys, unknown (None)
optionals left out, enums as their raw value. A field can name its key (`json("machineID")`) or keep an explicit
null (`json(null=True)`)."""

from __future__ import annotations

import dataclasses
import enum
from typing import Any


def json(name: str | None = None, *, null: bool = False, skip: bool = False) -> dict[str, Any]:
    """Field metadata: `field(metadata=json("bootID"))`."""
    return {"json": name, "null": null, "skip": skip}


def camel(name: str) -> str:
    head, *rest = name.split("_")
    return head + "".join(p[:1].upper() + p[1:] for p in rest)


def to_json(value: Any) -> Any:
    if dataclasses.is_dataclass(value) and not isinstance(value, type):
        out: dict[str, Any] = {}
        for f in dataclasses.fields(value):
            meta = f.metadata
            if meta.get("skip"):
                continue
            v = getattr(value, f.name)
            if v is None and not meta.get("null"):
                continue
            out[meta.get("json") or camel(f.name)] = to_json(v)
        return out
    if isinstance(value, enum.Enum):
        return value.value
    if isinstance(value, (list, tuple)):
        return [to_json(v) for v in value]
    if isinstance(value, dict):
        return {k: to_json(v) for k, v in value.items()}
    return value
