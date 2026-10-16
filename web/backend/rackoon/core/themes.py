"""The 45 shared terminal themes, read from themes.json at runtime and validated like `ThemeCatalog` in the Swift and
Kotlin cores. The palette derivation (W3) builds on `RGB`."""

from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass
from typing import Any

from . import spec
from .text import trim_blanks

DEFAULT_ID = "rackoon-dark"
LIGHT_DEFAULT_ID = "rackoon-light"
AUTOMATIC_ID = "automatic"

_SIX_HEX = re.compile(r"[0-9a-fA-F]{6}")


class ThemeCatalogError(Exception):
    def __init__(self, message: str) -> None:
        super().__init__(f"Invalid theme catalogue: {message}")


@dataclass(frozen=True)
class RGB:
    r: int
    g: int
    b: int

    @staticmethod
    def from_hex(text: str) -> RGB | None:
        """`#RRGGBB` or `RRGGBB`; anything else (3-digit shorthand too) is refused so a bad file fails loudly."""
        s = trim_blanks(text).removeprefix("#")
        if not _SIX_HEX.fullmatch(s):
            return None
        v = int(s, 16)
        return RGB((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)

    @property
    def hex(self) -> str:
        return f"#{self.r:02X}{self.g:02X}{self.b:02X}"

    @property
    def luminance(self) -> float:
        """WCAG relative luminance, 0 (black) to 1 (white)."""
        def lin(c: int) -> float:
            v = c / 255.0
            return v / 12.92 if v <= 0.03928 else float(((v + 0.055) / 1.055) ** 2.4)
        return 0.2126 * lin(self.r) + 0.7152 * lin(self.g) + 0.0722 * lin(self.b)

    def contrast_ratio(self, other: RGB) -> float:
        """WCAG contrast ratio, 1 (identical) to 21 (black on white)."""
        a, b = self.luminance, other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)

    def mixed(self, other: RGB, amount: float) -> RGB:
        """Linear blend: 0 gives `self`, 1 gives `other` (rounded half up, like Kotlin's Math.round)."""
        k = min(1.0, max(0.0, amount))

        def mix(a: int, b: int) -> int:
            return math.floor(a * (1 - k) + b * k + 0.5)
        return RGB(mix(self.r, other.r), mix(self.g, other.g), mix(self.b, other.b))

    @property
    def best_possible_contrast(self) -> float:
        """The best contrast any colour can have against this one (black or white, whichever is further)."""
        return max(self.contrast_ratio(BLACK), self.contrast_ratio(WHITE))

    def ensuring_contrast(self, background: RGB, minimum: float) -> RGB:
        """`self` if it already has `minimum` contrast on `background`; else the closest colour toward white or black
        that does, or the best that can be had."""
        if self.contrast_ratio(background) >= minimum:
            return self
        target = WHITE if background.contrast_ratio(WHITE) >= background.contrast_ratio(BLACK) else BLACK
        for step in range(1, 41):
            c = self.mixed(target, step / 40.0)
            if c.contrast_ratio(background) >= minimum:
                return c
        return target


BLACK = RGB(0, 0, 0)
WHITE = RGB(255, 255, 255)


@dataclass(frozen=True)
class TerminalTheme:
    id: str
    name: str
    family: str
    appearance: str
    """"dark" or "light"."""
    background: str
    foreground: str
    cursor: str | None
    selection: str | None
    ansi: list[str]
    """The 16 ANSI colours: 0-7 normal, 8-15 bright."""

    @property
    def is_dark(self) -> bool:
        return self.appearance == "dark"

    def rgb(self, field: str) -> RGB:
        """A colour of the theme; cursor and selection fall back to the foreground."""
        value = getattr(self, field)
        fallback = RGB(255, 255, 255) if field == "foreground" else RGB(0, 0, 0)
        if field in ("cursor", "selection") and value is None:
            return self.rgb("foreground")
        return RGB.from_hex(value) or fallback

    @property
    def ansi_rgb(self) -> list[RGB]:
        return [RGB.from_hex(c) or RGB(128, 128, 128) for c in self.ansi]


def _theme(raw: Any) -> TerminalTheme:
    if not isinstance(raw, dict):
        raise ThemeCatalogError("a theme is not an object")
    try:
        ansi = raw["ansi"]
        if not isinstance(ansi, list) or not all(isinstance(c, str) for c in ansi):
            raise ThemeCatalogError(f"{raw.get('id')}: ansi must be a list of strings")
        values = {k: raw[k] for k in ("id", "name", "family", "appearance", "background", "foreground")}
    except KeyError as e:
        raise ThemeCatalogError(f"not valid theme JSON: missing {e}") from None
    if not all(isinstance(v, str) for v in values.values()):
        raise ThemeCatalogError("not valid theme JSON: a field is not text")
    cursor, selection = raw.get("cursor"), raw.get("selection")
    return TerminalTheme(**values, cursor=cursor, selection=selection, ansi=ansi)


def load(text: str) -> list[TerminalTheme]:
    try:
        raw = json.loads(text)
    except ValueError as e:
        raise ThemeCatalogError(f"not valid theme JSON: {e}") from None
    if not isinstance(raw, list):
        raise ThemeCatalogError("not a list of themes")
    themes = [_theme(t) for t in raw]
    validate(themes)
    return themes


def validate(themes: list[TerminalTheme]) -> None:
    """Unique ids, valid hex everywhere, 16 ANSI colours, and an appearance that agrees with the background."""
    seen: set[str] = set()
    for t in themes:
        def bad(message: str, theme: TerminalTheme = t) -> ThemeCatalogError:
            return ThemeCatalogError(f"{theme.id}: {message}")
        if not t.id or t.id in seen:
            raise bad("missing or duplicate id")
        seen.add(t.id)
        if t.appearance not in ("dark", "light"):
            raise bad("appearance must be dark or light")
        bg = RGB.from_hex(t.background)
        if bg is None:
            raise bad("bad background")
        if RGB.from_hex(t.foreground) is None:
            raise bad("bad foreground")
        if t.cursor is not None and RGB.from_hex(t.cursor) is None:
            raise bad("bad cursor")
        if t.selection is not None and RGB.from_hex(t.selection) is None:
            raise bad("bad selection")
        if len(t.ansi) != 16:
            raise bad(f"needs exactly 16 ANSI colours, has {len(t.ansi)}")
        for i, c in enumerate(t.ansi):
            if RGB.from_hex(c) is None:
                raise bad(f"bad ANSI colour {i}: {c}")
        looks_dark = bg.luminance < 0.4
        if looks_dark != t.is_dark:
            raise bad(f"labelled {t.appearance} but the background is {'dark' if looks_dark else 'light'}")
    if DEFAULT_ID not in seen or LIGHT_DEFAULT_ID not in seen:
        raise ThemeCatalogError(f"{DEFAULT_ID} and {LIGHT_DEFAULT_ID} must both exist (Automatic needs them)")


def bundled() -> list[TerminalTheme]:
    try:
        text = spec.themes_path().read_text(encoding="utf-8")
    except OSError as e:
        raise ThemeCatalogError(f"themes.json is unreadable: {e}") from None
    return load(text)


def resolve(selection: str, system_is_dark: bool, themes: list[TerminalTheme]) -> TerminalTheme | None:
    """The theme in effect for a saved selection; `automatic` (and any unknown id) follows the system."""
    if selection != AUTOMATIC_ID:
        chosen = next((t for t in themes if t.id == selection), None)
        if chosen is not None:
            return chosen
    wanted = DEFAULT_ID if system_is_dark else LIGHT_DEFAULT_ID
    return (next((t for t in themes if t.id == wanted), None)
            or next((t for t in themes if t.id == DEFAULT_ID), None)
            or (themes[0] if themes else None))
