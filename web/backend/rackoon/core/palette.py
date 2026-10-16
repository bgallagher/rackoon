"""The app's chrome colours (surfaces, text, status colours) derived from a terminal theme, so one choice restyles
everything: `AppPalette.derive` in the Swift and Kotlin cores, ported line for line. Every text and status colour is
clamped to a minimum WCAG contrast, so no theme can make the app unreadable. The browser only receives the result as
CSS colours."""

from __future__ import annotations

from dataclasses import dataclass, fields
from typing import Any

from .themes import BLACK, RGB, WHITE, TerminalTheme

PRIMARY = 7.0
SECONDARY = 6.0
MUTED = 4.5
ACCENT = 3.0
STATUS = 3.0
ON_ACCENT = 4.5
CHIP_TEXT = 4.5
LABEL = 4.5
FILL_ALPHA = 0.18
SERIES_MIN_DISTANCE = 40


@dataclass(frozen=True)
class PaletteRole:
    """One colour as a family: `mark` (3:1) for dots, bars and icons, `label` (4.5:1) for words, `fill` a quiet tint
    over a card and `on_fill` reads on it."""

    mark: RGB
    label: RGB
    fill: RGB
    on_fill: RGB


@dataclass(frozen=True)
class AppPalette:
    background: RGB
    sidebar: RGB
    card: RGB
    selection: RGB
    border: RGB
    text_primary: RGB
    text_secondary: RGB
    text_muted: RGB
    accent: RGB
    accent_text: RGB
    ok: RGB
    warn: RGB
    danger: RGB
    idle: RGB
    warn_background: RGB
    warn_border: RGB
    warn_chip: RGB
    warn_text: RGB
    text_dim: RGB
    ok_role: PaletteRole
    warn_role: PaletteRole
    danger_role: PaletteRole
    info: PaletteRole
    scope_local: PaletteRole
    scope_tailscale: PaletteRole
    scope_public: PaletteRole
    series: list[PaletteRole]
    is_dark: bool

    def css(self) -> dict[str, Any]:
        """Hex strings by camelCase name (roles as objects), for the browser's CSS variables."""
        def value(v: Any) -> Any:
            if isinstance(v, RGB):
                return v.hex
            if isinstance(v, PaletteRole):
                return {"mark": v.mark.hex, "label": v.label.hex, "fill": v.fill.hex, "onFill": v.on_fill.hex}
            if isinstance(v, list):
                return [value(x) for x in v]
            return v

        def camel(name: str) -> str:
            head, *rest = name.split("_")
            return head + "".join(p[:1].upper() + p[1:] for p in rest)
        return {camel(f.name): value(getattr(self, f.name)) for f in fields(self)}


def derive(theme: TerminalTheme) -> AppPalette:
    bg = theme.rgb("background")
    fg = theme.rgb("foreground")
    ansi = theme.ansi_rgb
    dark = theme.is_dark

    # Surfaces: stepped from the background toward the foreground; on light themes cards go toward white.
    sidebar = bg.mixed(fg, 0.04 if dark else 0.05)
    card = bg.mixed(fg, 0.06) if dark else bg.mixed(WHITE, 0.65)
    if card.contrast_ratio(bg) < 1.02:  # a pure-white page can't get lighter: lift cards the other way
        card = bg.mixed(fg, 0.035)
    selection = bg.mixed(fg, 0.12 if dark else 0.10)
    border = bg.mixed(fg, 0.14 if dark else 0.16)

    text_primary = fg.ensuring_contrast(bg, PRIMARY)
    text_secondary = fg.mixed(bg, 0.15).ensuring_contrast(bg, SECONDARY)
    text_muted = fg.mixed(bg, 0.40).ensuring_contrast(bg, MUTED)

    def better(normal: int, bright: int) -> RGB:
        """Normal or bright variant, whichever reads better on this background (bright is often pale on light)."""
        a, b = ansi[normal], ansi[bright]
        return a if a.contrast_ratio(bg) >= b.contrast_ratio(bg) else b

    def pick(normal: int, bright: int) -> RGB:
        return better(normal, bright).ensuring_contrast(bg, STATUS)

    accent = better(4, 12).ensuring_contrast(bg, ACCENT)
    # Black or white, whichever reads better: for any colour the better one has at least sqrt(21) - 0.05 contrast.
    accent_text = BLACK if accent.contrast_ratio(BLACK) >= accent.contrast_ratio(WHITE) else WHITE
    warn = pick(3, 11)
    chip = bg.mixed(warn, 0.18)
    warn_text = text_primary.mixed(warn, 0.30).ensuring_contrast(chip, CHIP_TEXT)

    def role(base: RGB) -> PaletteRole:
        # Each pair is nudged against both the page and the card, so a role reads on either.
        mark = base.ensuring_contrast(card, STATUS).ensuring_contrast(bg, STATUS)
        label = base.ensuring_contrast(card, LABEL).ensuring_contrast(bg, LABEL)
        fill = card.mixed(mark, FILL_ALPHA)
        return PaletteRole(mark, label, fill, label.ensuring_contrast(fill, LABEL))

    red, green, yellow = better(1, 9), better(2, 10), better(3, 11)
    blue, magenta, cyan = better(4, 12), better(5, 13), better(6, 14)
    orange = red.mixed(yellow, 0.5)
    candidates = [
        cyan, orange, magenta,
        blue.mixed(magenta, 0.5).mixed(fg, 0.2),  # lavender
        green.mixed(cyan, 0.5),                   # teal
        blue.mixed(fg, 0.45),                     # grey-blue
    ]

    def far(a: RGB, b: RGB) -> bool:
        return abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) >= SERIES_MIN_DISTANCE

    # A colour too close to an earlier one (themes that reuse a hue) is nudged lighter or darker, keeping its hue.
    series: list[PaletteRole] = []
    for candidate in candidates:
        c = candidate
        r = role(c)
        tries = 0
        while tries < 10 and any(not far(s.mark, r.mark) for s in series):
            c = c.mixed(fg if tries % 2 == 0 else bg, 0.22)
            r = role(c)
            tries += 1
        series.append(r)

    return AppPalette(
        background=bg, sidebar=sidebar, card=card, selection=selection, border=border,
        text_primary=text_primary, text_secondary=text_secondary, text_muted=text_muted,
        accent=accent, accent_text=accent_text, ok=pick(2, 10), warn=warn, danger=pick(1, 9),
        idle=ansi[8].ensuring_contrast(bg, STATUS),
        warn_background=bg.mixed(warn, 0.10), warn_border=bg.mixed(warn, 0.30), warn_chip=chip, warn_text=warn_text,
        text_dim=fg.mixed(bg, 0.45).ensuring_contrast(card, MUTED).ensuring_contrast(bg, MUTED),
        ok_role=role(green), warn_role=role(yellow), danger_role=role(red),
        info=role(blue), scope_local=role(blue), scope_tailscale=role(magenta), scope_public=role(orange),
        series=series, is_dark=dark,
    )
