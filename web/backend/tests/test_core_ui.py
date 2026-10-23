"""What the screens are computed from: the WCAG-clamped palette (Kotlin's AppPaletteTests), attention, connection
failures explained, fleet history and totals, the server list and Read-only's auto re-enable."""

from __future__ import annotations

from dataclasses import replace

import pytest

from rackoon.core import attention, connection_failure, fleet, overview, palette, server_list, themes
from rackoon.core.models import AttentionItem, Server, Severity
from rackoon.core.themes import BLACK, RGB, WHITE

from .support import out

THEMES = themes.bundled()


def at_least(theme: str, name: str, c: RGB, against: RGB, floor: float) -> None:
    need = min(floor, against.best_possible_contrast)
    assert c.contrast_ratio(against) >= need - 0.01, f"{theme}: {name} {c.hex} on {against.hex}"


# --- palette ------------------------------------------------------------------------------------------------------


def test_mix_and_contrast() -> None:
    assert BLACK.mixed(WHITE, 0.5) == RGB(128, 128, 128)
    assert BLACK.mixed(WHITE, 0.0) == BLACK and BLACK.mixed(WHITE, 1.0) == WHITE
    assert BLACK.mixed(WHITE, 7.0) == WHITE, "amount is clamped"
    assert BLACK.contrast_ratio(WHITE) == pytest.approx(21.0, abs=0.001)
    assert RGB.from_hex("#777777").contrast_ratio(WHITE) == pytest.approx(4.48, abs=0.02)  # type: ignore[union-attr]


def test_ensuring_contrast_nudges_toward_the_readable_end() -> None:
    dark_bg, dim = RGB.from_hex("#101010"), RGB.from_hex("#303030")
    assert dark_bg and dim
    fixed = dim.ensuring_contrast(dark_bg, 4.5)
    assert fixed.contrast_ratio(dark_bg) >= 4.5 and fixed.luminance > dim.luminance
    light_bg, pale = RGB.from_hex("#F0F0F0"), RGB.from_hex("#C0C0C0")
    assert light_bg and pale
    darker = pale.ensuring_contrast(light_bg, 4.5)
    assert darker.contrast_ratio(light_bg) >= 4.5 and darker.luminance < pale.luminance
    fine = RGB(0xEE, 0xEE, 0xEE)
    assert fine.ensuring_contrast(dark_bg, 4.5) == fine


def test_black_or_white_always_clears_the_on_accent_floor() -> None:
    worst = min(RGB(r, g, b).best_possible_contrast for r in range(0, 256, 15) for g in range(0, 256, 15)
                for b in range(0, 256, 15))
    assert worst >= palette.ON_ACCENT


def test_every_bundled_theme_meets_the_contrast_floors() -> None:
    assert len(THEMES) == 45
    for t in THEMES:
        p = palette.derive(t)
        bg = p.background
        at_least(t.id, "textPrimary", p.text_primary, bg, palette.PRIMARY)
        at_least(t.id, "textSecondary", p.text_secondary, bg, palette.SECONDARY)
        at_least(t.id, "textMuted", p.text_muted, bg, palette.MUTED)
        at_least(t.id, "textMuted on card", p.text_muted, p.card, palette.MUTED - 0.7)
        at_least(t.id, "textDim", p.text_dim, bg, palette.MUTED)
        at_least(t.id, "accent", p.accent, bg, palette.ACCENT)
        for name, c in (("ok", p.ok), ("warn", p.warn), ("danger", p.danger), ("idle", p.idle)):
            at_least(t.id, name, c, bg, palette.STATUS)
        at_least(t.id, "accentText", p.accent_text, p.accent, palette.ON_ACCENT)
        at_least(t.id, "warnText", p.warn_text, p.warn_chip, palette.CHIP_TEXT)
        roles = [p.ok_role, p.warn_role, p.danger_role, p.info, p.scope_local, p.scope_tailscale, p.scope_public,
                 *p.series]
        for r in roles:
            at_least(t.id, "mark", r.mark, bg, palette.STATUS)
            at_least(t.id, "mark on card", r.mark, p.card, palette.STATUS)
            at_least(t.id, "label", r.label, bg, palette.LABEL)
            at_least(t.id, "label on card", r.label, p.card, palette.LABEL)
            at_least(t.id, "onFill", r.on_fill, r.fill, palette.LABEL)
        assert len(p.series) == 6 and len({r.mark for r in p.series}) == 6, f"{t.id}: series colours differ"
        for surface in (p.sidebar, p.card, p.selection, p.border):
            assert surface != bg
        assert p.border.contrast_ratio(bg) > 1.12 and p.selection.contrast_ratio(bg) > 1.08
        assert p.is_dark == t.is_dark
        assert palette.derive(t) == p, "deterministic"


def test_rackoon_dark_matches_the_design() -> None:
    p = palette.derive(next(t for t in THEMES if t.id == "rackoon-dark"))
    assert p.background.hex == "#15171C"
    assert 0 < p.sidebar.luminance - p.background.luminance < 0.02
    css = p.css()
    assert css["background"] == "#15171C" and set(css["okRole"]) == {"mark", "label", "fill", "onFill"}
    assert len(css["series"]) == 6 and css["isDark"] is True


# --- attention ----------------------------------------------------------------------------------------------------


def test_attention_from_the_rules() -> None:
    o = overview.parse(out("overview", "synthetic-security-updates"))
    items = attention.evaluate(o)
    assert any(i.id == "security_updates" and i.fix == "updates" for i in items)
    full = replace(o, disks=[overview.Disk("/dev/sda1", "/", 100, 96, 96), overview.Disk("/dev/sdb", "/data", 100, 90, 90),
                             overview.Disk("/dev/sdc", "/ok", 100, 85, 85)],
                   unhealthy_containers=["cloudflared"], security_updates=1, reboot_required=True)
    items = attention.evaluate(full)
    assert [(i.id, i.severity) for i in items] == [
        ("disk_high:/", Severity.CRITICAL), ("disk_high:/data", Severity.WARNING),
        ("container_unhealthy:cloudflared", Severity.WARNING), ("security_updates", Severity.WARNING),
        ("reboot_required", Severity.WARNING)]
    assert items[3].message == "1 security update is available."
    shown = attention.sorted_items(items)
    assert [i.id for i in shown][:2] == ["disk_high:/", "container_unhealthy:cloudflared"], "red first"
    assert [attention.short_message(i) for i in items] == ["/ is 96% full", "/data is 90% full", "cloudflared is unhealthy",
                                                            "1 security update", "Reboot required"]
    two = AttentionItem("security_updates", Severity.WARNING, "2 security updates are available.", "updates")
    assert attention.short_message(two) == "2 security updates"


# --- connection failures ------------------------------------------------------------------------------------------


def test_connection_failures_explained() -> None:
    explain = connection_failure.explain
    kinds = connection_failure.FailureKind
    cases = {
        "ssh: connect to host 10.0.0.1 port 22: Connection refused": kinds.UNREACHABLE,
        "ssh: Could not resolve hostname nas: Name or service not known": kinds.UNRESOLVED,
        "ssh: connect to host 10.0.0.1 port 22: Connection timed out": kinds.UNREACHABLE,
        "ssh: connect to host 10.0.0.1 port 22: No route to host": kinds.UNREACHABLE,
        "Connection closed by 10.0.0.1 port 22": kinds.UNREACHABLE,
        "Sign-in was refused: Permission denied for user rk": kinds.AUTH_REFUSED,
        "This server's host key is not trusted yet (SHA256:x).": kinds.HOST_KEY_UNKNOWN,
        "The host key changed since it was trusted. Connection blocked.": kinds.HOST_KEY_CHANGED,
    }
    for raw, kind in cases.items():
        f = explain(raw)
        assert f is not None and f.kind is kind, raw
    assert explain("something nobody has seen") is None
    key = explain("Permission denied", connection_failure.SignIn.KEY)
    tailscale = explain("Permission denied", connection_failure.SignIn.TAILSCALE)
    assert key and tailscale and "authorized_keys" in key.advice and "tailnet" in tailscale.advice


# --- fleet --------------------------------------------------------------------------------------------------------


def test_history_keeps_one_sample_a_minute_and_every_change() -> None:
    h = fleet.HealthHistory()
    h.record(fleet.HealthSample(0, True))
    h.record(fleet.HealthSample(10, True))
    assert len(h.samples) == 1, "a minute apart"
    h.record(fleet.HealthSample(12, False))
    h.record(fleet.HealthSample(14, True))
    assert [s.up for s in h.samples] == [True, False, True], "a short outage is never hidden"
    for i in range(100):
        h.record(fleet.HealthSample(100 + i * 60, True))
    assert len(h.samples) == fleet.CAPACITY
    assert h.uptime_fraction == 1.0 and h.down_count == 0
    assert fleet.HealthHistory().uptime_fraction is None


def test_sample_of_a_state() -> None:
    o = overview.parse(out("overview", "ubuntu-24.04"))
    assert fleet.HealthSample.of(fleet.ServerState(), 1) is None
    assert fleet.HealthSample.of(fleet.ServerState(overview=o, is_stale=True), 1) is None, "a cached snapshot is no check"
    down = fleet.HealthSample.of(fleet.ServerState(overview=o, error="refused"), 1)
    assert down is not None and not down.up
    up = fleet.HealthSample.of(fleet.ServerState(overview=o, cpu_percent=12.5), 1)
    assert up is not None and up.up and up.cpu_percent == 12.5 and up.disk_fraction == max(d.use_percent for d in o.disks) / 100


def test_fleet_totals_weigh_cpu_by_cores() -> None:
    o = overview.parse(out("overview", "ubuntu-24.04"))
    big = replace(o, cores=12, pending_updates=3, security_updates=1, reboot_required=True)
    states = [fleet.ServerState(overview=o, cpu_percent=10.0), fleet.ServerState(overview=big, cpu_percent=50.0),
              fleet.ServerState(overview=o, error="down"), fleet.ServerState()]
    t = fleet.FleetTotals.of(states)
    assert (t.servers, t.online) == (4, 2)
    expected = (10.0 * max(o.cores, 1) + 50.0 * 12) / (max(o.cores, 1) + 12)
    assert t.cpu_percent == pytest.approx(expected)
    assert t.memory_total == 3 * o.memory.total_bytes, "an offline server still counts its last numbers"
    assert (t.updates, t.security_updates, t.reboot_required) == (3 + 2 * o.pending_updates, 1 + 2 * o.security_updates, 1)


# --- server list and read-only ------------------------------------------------------------------------------------


def test_server_list_filter_and_move() -> None:
    servers = [Server("1", "Hetzner VPS", "203.0.113.7", user="root"), Server("2", "nas", "nas.lan", user="admin"),
               Server("3", "Café box", "cafe.lan", ssh_config_alias="cafe")]
    assert [s.id for s in server_list.filter_servers(servers, "")] == ["1", "2", "3"]
    assert [s.id for s in server_list.filter_servers(servers, "hetz root")] == ["1"]
    assert [s.id for s in server_list.filter_servers(servers, "cafe")] == ["3"], "accents ignored"
    assert server_list.filter_servers(servers, "hetzner admin") == []
    assert [s.id for s in server_list.moving_onto("3", "1", servers)] == ["3", "1", "2"]
    assert [s.id for s in server_list.moving_by("1", 5, servers)] == ["2", "3", "1"]
    assert [s.id for s in server_list.moving_by("1", -1, servers)] == ["1", "2", "3"]
    assert server_list.moving_onto("9", "1", servers) == servers


def test_read_only_turns_itself_back_on_when_idle() -> None:
    mode = server_list.AutoReadOnly.IDLE_15
    assert server_list.AutoReadOnly.from_key(None) is mode and server_list.AutoReadOnly.from_key("idle5").idle_minutes == 5
    assert not server_list.should_reenable(mode, False, 0, 14 * 60, False)
    assert server_list.should_reenable(mode, False, 0, 15 * 60, False)
    assert not server_list.should_reenable(mode, True, 0, 99 * 60, False), "already on"
    assert not server_list.should_reenable(mode, False, 0, 99 * 60, True), "never interrupts a running action"
    assert not server_list.should_reenable(server_list.AutoReadOnly.NEVER, False, 0, 1e9, False)
