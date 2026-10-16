"""The single user's settings, in <data>/preferences.json: the theme and the Read-only switch with its auto re-enable.

Read-only starts ON for a new install (a web app is reachable from more places than a Mac app), and by default turns
itself back on after 15 minutes without the user touching the app, never while an action runs (Android's rule).
The one `ActionPolicy` lives here, so every service is created with it and the switch reaches all of them.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from typing import Any

from rackoon.core import palette, themes
from rackoon.core.policy import ActionPolicy
from rackoon.core.server_list import AutoReadOnly, should_reenable

from .storage import DataStore, read_json, write_json


class Preferences:
    def __init__(self, store: DataStore, clock: Callable[[], float] = time.time) -> None:
        self.path = store.root / "preferences.json"
        self.clock = clock
        raw = read_json(self.path)
        self._raw: dict[str, Any] = raw if isinstance(raw, dict) else {}
        self.policy = ActionPolicy(read_only=self._raw.get("readOnly", True) is not False)
        self.last_touch = clock()
        self.themes = themes.bundled()
        self._palettes: dict[str, dict[str, Any]] = {}

    def _save(self) -> None:
        write_json(self.path, self._raw)

    # --- read-only

    @property
    def read_only(self) -> bool:
        return self.policy.is_read_only

    @property
    def auto(self) -> AutoReadOnly:
        return AutoReadOnly.from_key(self._raw.get("autoReadOnly"))

    def set_read_only(self, on: bool) -> None:
        self.policy.is_read_only = on
        self._raw["readOnly"] = on
        self.touch()
        self._save()

    def set_auto(self, key: str) -> None:
        self._raw["autoReadOnly"] = AutoReadOnly.from_key(key).key
        self._save()

    def touch(self) -> None:
        """The user did something; idle time starts again."""
        self.last_touch = self.clock()

    def check_idle(self, busy: bool) -> bool:
        """Turns Read-only back on if it is time to. Returns whether it did."""
        if should_reenable(self.auto, self.read_only, self.last_touch, self.clock(), busy):
            self.set_read_only(True)
            return True
        return False

    def safety_json(self) -> dict[str, Any]:
        return {"readOnly": self.read_only, "auto": self.auto.key,
                "options": [{"key": m.key, "label": m.label} for m in AutoReadOnly]}

    # --- appearance

    @property
    def theme_selection(self) -> str:
        value = self._raw.get("theme", themes.AUTOMATIC_ID)
        return value if isinstance(value, str) else themes.AUTOMATIC_ID

    def set_theme(self, selection: str) -> None:
        if selection != themes.AUTOMATIC_ID and not any(t.id == selection for t in self.themes):
            raise ValueError("no such theme")
        self._raw["theme"] = selection
        self._save()

    def _resolved(self, system_is_dark: bool) -> dict[str, Any]:
        theme = themes.resolve(self.theme_selection, system_is_dark, self.themes)
        assert theme is not None
        cached = self._palettes.get(theme.id)
        if cached is None:
            cached = self._palettes[theme.id] = {
                "themeId": theme.id, "palette": palette.derive(theme).css(),
                "terminal": {"background": theme.background, "foreground": theme.foreground,
                             "cursor": theme.rgb("cursor").hex, "selection": theme.rgb("selection").hex,
                             "ansi": theme.ansi},
            }
        return cached

    def appearance_json(self) -> dict[str, Any]:
        """Both resolutions, so the browser follows its own light/dark setting without asking again."""
        return {"selection": self.theme_selection,
                "themes": [{"id": t.id, "name": t.name, "family": t.family, "appearance": t.appearance}
                           for t in self.themes],
                "dark": self._resolved(True), "light": self._resolved(False)}
