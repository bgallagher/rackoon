"""Searching and reordering the saved servers (`ServerList` in the Swift core), and when Read-only turns itself back
on (`AutoReadOnly` in the Kotlin core)."""

from __future__ import annotations

import enum
import unicodedata

from .models import Server


def _fold(text: str) -> str:
    """Lower case without accents (Swift's caseInsensitive + diacriticInsensitive)."""
    return "".join(c for c in unicodedata.normalize("NFD", text.casefold()) if not unicodedata.combining(c))


def filter_servers(servers: list[Server], query: str) -> list[Server]:
    """The servers whose name, host, user or ssh_config alias contains every word of `query`, in saved order."""
    words = [_fold(w) for w in query.split()]
    if not words:
        return list(servers)
    out = []
    for s in servers:
        fields = [_fold(f) for f in (s.name, s.host, s.user or "", s.ssh_config_alias or "")]
        if all(any(w in f for f in fields) for w in words):
            out.append(s)
    return out


def moving_onto(server_id: str, target: str, servers: list[Server]) -> list[Server]:
    """`server_id` moved into `target`'s place (dragging a row over another). Unchanged if either is missing."""
    ids = [s.id for s in servers]
    if server_id == target or server_id not in ids or target not in ids:
        return list(servers)
    out = list(servers)
    item = out.pop(ids.index(server_id))
    out.insert(ids.index(target), item)
    return out


def moving_by(server_id: str, delta: int, servers: list[Server]) -> list[Server]:
    """`server_id` moved `delta` places (negative is up), stopping at either end."""
    ids = [s.id for s in servers]
    if server_id not in ids:
        return list(servers)
    start = ids.index(server_id)
    to = min(max(start + delta, 0), len(servers) - 1)
    if to == start:
        return list(servers)
    out = list(servers)
    item = out.pop(start)
    out.insert(to, item)
    return out


class AutoReadOnly(enum.Enum):
    """When Read-only turns itself back on after the user switched it off."""

    NEVER = ("never", "Never", None)
    IDLE_5 = ("idle5", "After 5 minutes idle", 5)
    IDLE_15 = ("idle15", "After 15 minutes idle", 15)
    IDLE_60 = ("idle60", "After an hour idle", 60)

    def __init__(self, key: str, label: str, idle_minutes: int | None) -> None:
        self.key = key
        self.label = label
        self.idle_minutes = idle_minutes

    @classmethod
    def from_key(cls, key: str | None) -> AutoReadOnly:
        return next((m for m in cls if m.key == key), cls.IDLE_15)


def should_reenable(mode: AutoReadOnly, read_only: bool, last_touch: float, now: float, busy: bool) -> bool:
    """Changes are allowed, the mode is an idle one, nothing touched the app for long enough, and no action is
    running (an action in flight is never interrupted by this)."""
    if mode.idle_minutes is None or read_only or busy:
        return False
    return now - last_touch >= mode.idle_minutes * 60
