"""Models to JSON in the shape spec/models.schema.json and the golden files use: camelCase keys, unknown (None)
optionals left out, enums as their raw value. A field can name its key (`json("machineID")`) or keep an explicit
null (`json(null=True)`)."""

from __future__ import annotations

import dataclasses
import enum
import types
import typing
from typing import Any, TypeVar


def json(name: str | None = None, *, null: bool = False, skip: bool = False) -> dict[str, Any]:
    """Field metadata: `field(metadata=json("bootID"))`."""
    return {"json": name, "null": null, "skip": skip}


def camel(name: str) -> str:
    head, *rest = name.split("_")
    return head + "".join(p[:1].upper() + p[1:] for p in rest)


class DecodeError(ValueError):
    pass


T = TypeVar("T")


def from_json(cls: type[T], data: Any, path: str = "$") -> T:
    """The inverse of `to_json` for the model dataclasses: reads camelCase keys, a missing or null optional becomes
    None (or its default), unknown keys are ignored. Raises DecodeError naming the bad path."""
    value = _decode(cls, data, path)
    return value  # type: ignore[no-any-return]


def _decode(tp: Any, data: Any, path: str) -> Any:
    origin = typing.get_origin(tp)
    if origin in (typing.Union, types.UnionType):
        args = [a for a in typing.get_args(tp) if a is not type(None)]
        if data is None:
            if len(args) != len(typing.get_args(tp)):
                return None
            raise DecodeError(f"{path}: null")
        return _decode(args[0], data, path) if len(args) == 1 else data
    if origin is list:
        if not isinstance(data, list):
            raise DecodeError(f"{path}: expected a list")
        (item,) = typing.get_args(tp)
        return [_decode(item, v, f"{path}[{i}]") for i, v in enumerate(data)]
    if origin is dict:
        if not isinstance(data, dict):
            raise DecodeError(f"{path}: expected an object")
        _, item = typing.get_args(tp)
        return {k: _decode(item, v, f"{path}.{k}") for k, v in data.items()}
    if isinstance(tp, type) and dataclasses.is_dataclass(tp):
        if not isinstance(data, dict):
            raise DecodeError(f"{path}: expected an object")
        hints = typing.get_type_hints(tp)
        kwargs: dict[str, Any] = {}
        for f in dataclasses.fields(tp):
            if f.metadata.get("skip") or not f.init:
                continue
            key = f.metadata.get("json") or camel(f.name)
            if key in data and not (data[key] is None and _has_default(f)):
                kwargs[f.name] = _decode(hints[f.name], data[key], f"{path}.{key}")
            elif not _has_default(f):
                if _is_optional(hints[f.name]):
                    kwargs[f.name] = None
                else:
                    raise DecodeError(f"{path}.{key}: missing")
        return tp(**kwargs)
    if isinstance(tp, type) and issubclass(tp, enum.Enum):
        try:
            return tp(data)
        except ValueError:
            raise DecodeError(f"{path}: {data!r} is not a {tp.__name__}") from None
    if tp is float:
        if isinstance(data, bool) or not isinstance(data, (int, float)):
            raise DecodeError(f"{path}: expected a number")
        return float(data)
    if tp is int:
        if isinstance(data, bool) or not isinstance(data, int):
            raise DecodeError(f"{path}: expected an integer")
        return data
    if tp in (str, bool):
        if type(data) is not tp:
            raise DecodeError(f"{path}: expected {tp.__name__}")
        return data
    if tp is Any:
        return data
    raise DecodeError(f"{path}: cannot decode {tp!r}")


def _has_default(f: dataclasses.Field[Any]) -> bool:
    return f.default is not dataclasses.MISSING or f.default_factory is not dataclasses.MISSING


def _is_optional(tp: Any) -> bool:
    return typing.get_origin(tp) in (typing.Union, types.UnionType) and type(None) in typing.get_args(tp)


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
