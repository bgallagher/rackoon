"""The Unraid NAS page's rules and attention (the Swift core's UnraidTests and UnraidEdgeCaseTests beyond the golden
fixtures, which test_golden_fixtures already runs)."""

from __future__ import annotations

import dataclasses

from rackoon.core import spec, unraid, unraid_view as v
from rackoon.core.models import AttentionItem, Severity
from rackoon.core.unraid import Device, Operation, Role, Share, UnraidSnapshot

ONE_PARITY_ONE_DATA = """["parity"]
name="parity"
device="sdb"
id="M_S1"
size="100"
status="DISK_OK"
type="Parity"
["disk1"]
name="disk1"
device="sdc"
id="M_S2"
size="100"
status="DISK_OK"
type="Data\""""
DATA_ONLY = ONE_PARITY_ONE_DATA[ONE_PARITY_ONE_DATA.index('["disk1"]'):]


def fixture(name: str) -> UnraidSnapshot:
    return unraid.parse((spec.spec_dir() / "fixtures" / "unraid" / f"{name}.out.txt").read_text())


def reading(vars: list[str], disks: str = "", temps: list[str] | None = None) -> UnraidSnapshot:
    return unraid.parse("\n".join(["##unraid", "7.0.0", "##var", *vars, "##disks", disks, "##temps", *(temps or [])]))


def test_a_real_zfs_array() -> None:
    s = fixture("unraid-7.3-zfs")
    assert s.array.operation is None
    assert [d.name for d in v.parity_disks(s)] == ["parity", "parity2"]
    data = v.data_disks(s)
    assert [d.name for d in data] == ["disk1", "disk2", "disk3", "disk4"]
    assert v.model(data[0]) == "ST12000VN0007-2GS116", "the serial is not shown"
    assert v.array_bytes(s)[0] > 40_000_000_000_000
    pools = v.pools(s)
    assert [p.name for p in pools] == ["cache"] and [d.name for d in pools[0].devices] == ["cache", "cache2"]
    assert pools[0].health == "ONLINE" and pools[0].kind == "ZFS 2 devices"
    flash = v.flash(s)
    assert flash is not None and flash.filesystem is not None and flash.filesystem.mount == "/boot"
    assert v.cpu_temperature(s) == 63, "Intel package temperature"
    assert len(v.spinning_fans(s)) == 3
    assert not any(c < -40 for _, c in v.board_sensors(s))
    assert [n for n, _ in v.board_sensors(s)].count("Memory") == 1, "two DIMM sensors collapse into one row"
    last = v.last_parity_check(s)
    assert last is not None and v.describe(last.action) == "Parity check"
    assert v.describe(s.parity_checks[3].action) == "Rebuilding disk 3"
    assert v.evaluate(s) == [], "a healthy array needs no attention"


def test_a_running_check_a_disabled_disk_and_attention() -> None:
    s = fixture("synthetic-check-running-disabled")
    op = s.array.operation
    assert op is not None and v.describe(op.action) == "Parity check" and abs(op.fraction - 0.25) < 0.001
    assert v.remaining_seconds(op) is not None
    assert [d.name for d in v.parity_disks(s)] == ["parity"], "an empty parity2 slot is not a disk"
    assert [d.name for d in v.data_disks(s)] == ["disk1", "disk2", "disk3"]
    assert v.cpu_temperature(s) == 58.25, "AMD Tctl"
    assert {sh.name: v.placement(sh) for sh in s.shares}["appdata"] == "cache, then array"
    items = v.evaluate(s)
    ids = {i.id for i in items}
    assert {"array_disabled", "disk_status:disk3", "disk_errors:disk2", "disk_hot:disk1", "disk_hot:cache2",
            "disk_full:disk1", "parity_errors"} <= ids
    assert not any("disk4" in i or "parity2" in i for i in ids), "empty slots raise nothing"
    assert next(i for i in items if i.id == "disk_hot:cache2").severity is Severity.CRITICAL
    assert next(i for i in items if i.id == "disk_status:disk3").message == "disk3 is disabled."
    assert v.condition(s) == ("Degraded", v.CRITICAL), "a disabled disk outranks a running check"
    disk4 = next(d for d in s.devices if d.name == "disk4")
    assert v.is_empty_slot(disk4) and v.status_description(disk4) == "not assigned"


def test_several_pools_unmountable_missing_and_degraded_zfs() -> None:
    s = fixture("synthetic-pools-unmountable")
    pools = v.pools(s)
    assert [[d.name for d in p.devices] for p in pools] == [["cache", "cache2"], ["fast"], ["vms"]]
    assert [p.kind for p in pools] == ["BTRFS raid1", "XFS", "ZFS"]
    assert [p.health for p in pools] == [None, None, "DEGRADED"]
    by = {i.id: i for i in v.evaluate(s)}
    assert by["array_missing"].severity is Severity.CRITICAL and by["array_invalid"].severity is Severity.WARNING
    assert by["disk_status:disk2"].message == "disk2 is missing."
    assert by["disk_unmountable:disk3"].severity is Severity.CRITICAL
    assert by["zfs_health:vms"].severity is Severity.WARNING
    assert by["disk_full:fast"].severity is Severity.WARNING
    assert by["cpu_hot"].message == "The CPU is at 91 °C.", "Tdie, not Tctl"
    assert "disk_hot:fast" not in by
    assert [n for n, _ in v.board_sensors(s)] == ["SYSTIN"]


def test_conditions_and_a_stopped_array() -> None:
    stopped = reading(['mdState="STOPPED"', 'fsState="Stopped"'], ONE_PARITY_ONE_DATA)
    assert v.condition(stopped) == ("Stopped", v.CRITICAL)
    assert v.evaluate(stopped)[0].message == "The array is stopped."
    assert v.condition(reading(['mdState="NEW_ARRAY"']))[0] == "New Array"
    assert v.evaluate(reading([]))[0].message == "The array is not started."
    assert v.condition(reading(['mdState="STARTED"'], ONE_PARITY_ONE_DATA)) == ("Protected", v.NORMAL)
    assert v.condition(reading(['mdState="STARTED"'], DATA_ONLY)) == ("No parity", v.WARNING)
    assert v.condition(reading(['mdState="STARTED"', 'mdResync="100"', 'mdResyncPos="10"'], ONE_PARITY_ONE_DATA))[0] == \
        "Checking"


def test_drive_temperatures_at_the_limits_and_thresholds() -> None:
    def drive(t: int, rotational: bool) -> Device:
        return Device("disk1", "sdc", "M_S", 1, "ata", rotational, False, "DISK_OK", t, 0, Role.DATA, None)
    assert [v.temperature_level(drive(t, True)) for t in (44, 45, 55)] == [v.NORMAL, v.WARNING, v.CRITICAL]
    assert [v.temperature_level(drive(t, False)) for t in (59, 60, 70)] == [v.NORMAL, v.WARNING, v.CRITICAL]
    assert [v.fill_level(f) for f in (0.85, 0.86, 0.95)] == [v.NORMAL, v.WARNING, v.CRITICAL]
    assert [v.cpu_level(c) for c in (79.9, 80, 90)] == [v.NORMAL, v.WARNING, v.CRITICAL]


def test_names_operations_shares_and_cpu_preference() -> None:
    assert [v.slot_title(n) for n in ("parity", "parity2", "disk1", "disk12", "cache", "cache2", "fast", "nvme2pool",
                                      "flash", "pool10")] == \
        ["Parity", "Parity 2", "Disk 1", "Disk 12", "Cache", "Cache 2", "Fast", "Nvme2pool", "Flash", "Pool 10"]
    assert [v.describe(a) for a in ("check P Q", "recon P", "recon D5", "clear")] == \
        ["Parity check", "Parity sync", "Rebuilding disk 5", "Clearing disk"]
    op = Operation("check P", 120, 100, 1024)
    assert op.fraction == 1 and v.remaining_seconds(op) == 0
    assert v.remaining_seconds(Operation("", 1, 0, None)) is None
    assert v.placement(Share("s", "", "only", "", 0)) == "cache only"
    assert v.placement(Share("s", "", "yes", "cache", 0)) == "cache, moved to array"

    def cpu(temps: list[str]) -> float | None:
        return v.cpu_temperature(reading([], temps=temps))
    assert cpu(["coretemp|Core 0|70000", "coretemp|Package id 0|65000"]) == 65
    assert cpu(["k10temp|Tctl|80000", "k10temp|Tdie|70000"]) == 70
    assert cpu(["k10temp|Tctl|80000", "k10temp|Tccd1|60000"]) == 80
    assert cpu(["coretemp|Core 0|-128000", "coretemp|Core 1|50000"]) == 50
    assert cpu(["nvme|Composite|40000", "acpitz||30000"]) is None


def test_merge_replaces_df_items_on_unraid_only() -> None:
    base = [AttentionItem("disk_high:/mnt/disk1", Severity.WARNING, "x", "docker"),
            AttentionItem("reboot_required", Severity.WARNING, "y", "updates")]
    degraded = fixture("synthetic-check-running-disabled")
    assert v.merge(base, False, degraded) == base
    merged = v.merge(base, True, degraded)
    assert merged[0].id == "reboot_required" and not any(i.id.startswith("disk_high:") for i in merged)
    assert any(i.id == "array_disabled" for i in merged)
    assert [i.id for i in v.merge(base, True, None)] == ["reboot_required"]
    faulted = dataclasses.replace(fixture("unraid-7.3-zfs"),
                                  zfs_pools=[dataclasses.replace(fixture("unraid-7.3-zfs").zfs_pools[0], health="FAULTED")])
    assert next(i for i in v.evaluate(faulted) if i.id == "zfs_health:cache").severity is Severity.CRITICAL
