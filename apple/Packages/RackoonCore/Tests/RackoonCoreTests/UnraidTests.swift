import Foundation
import XCTest
@testable import RackoonCore

final class UnraidTests: XCTestCase {
    /// Every fixture in spec/fixtures/unraid must parse to its expected JSON. Error fixtures expect {"error": "..."}.
    /// Run with RACKOON_WRITE_GOLDEN=1 to write any missing expected file, then review it before committing.
    func testGoldenFixtures() throws {
        let dir = specDir.appendingPathComponent("fixtures/unraid")
        let outs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".out.txt") && !$0.lastPathComponent.hasPrefix("raw-") }
            .sorted { $0.path < $1.path }
        XCTAssertGreaterThanOrEqual(outs.count, 3)
        for out in outs {
            let expectedURL = URL(fileURLWithPath: out.path.replacingOccurrences(of: ".out.txt", with: ".expected.json"))
            let actual = parsedJSON(try String(contentsOf: out, encoding: .utf8))
            if !FileManager.default.fileExists(atPath: expectedURL.path),
               ProcessInfo.processInfo.environment["RACKOON_WRITE_GOLDEN"] != nil {
                let data = try JSONSerialization.data(withJSONObject: actual, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: expectedURL)
                XCTFail("wrote \(expectedURL.lastPathComponent): review it, then commit")
                continue
            }
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as? NSDictionary
            XCTAssertEqual(actual, expected, out.lastPathComponent)
        }
    }

    private func parsedJSON(_ text: String) -> NSDictionary {
        do {
            let snapshot = try UnraidParser.parse(text)
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! NSDictionary
        } catch UnraidParseError.notUnraid {
            return ["error": "notUnraid"]
        } catch {
            return ["error": "other", "message": "\(error)"]
        }
    }

    private func fixture(_ name: String) throws -> UnraidSnapshot {
        try UnraidParser.parse(String(contentsOf: specDir.appendingPathComponent("fixtures/unraid/\(name).out.txt"), encoding: .utf8))
    }

    func testCommandMatchesSpec() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        XCTAssertEqual(UnraidSession.command, commands.first { $0["id"] as? String == "unraid" }?["script"] as? String)
    }

    func testDetectsUnraidFromOSRelease() {
        XCTAssertEqual(ServerKind.detect(.init(id: "unraid-os", name: "Unraid OS", version: "7.3.3", prettyName: "Unraid OS 7.3 x86_64")), .unraid)
        XCTAssertEqual(ServerKind.detect(.init(id: "slackware", name: "Unraid", version: "6.11", prettyName: "Unraid 6.11")), .unraid)
        XCTAssertEqual(ServerKind.detect(.init(id: "ubuntu", name: "Ubuntu", version: "24.04", prettyName: "Ubuntu 24.04 LTS")), .server)
        XCTAssertEqual(ServerKind.unraid.hiddenScreens, ["updates"], "Unraid has no apt")
        XCTAssertTrue(ServerKind.server.hiddenScreens.isEmpty)
    }

    func testRealZFSArray() throws {
        let s = try fixture("unraid-7.3-zfs")
        XCTAssertEqual(s.version, "7.3.3")
        XCTAssertTrue(s.array.isStarted)
        XCTAssertNil(s.array.operation, "mdResync=0 means idle even though mdResyncAction keeps the last action")
        XCTAssertEqual(s.parityDisks.map(\.name), ["parity", "parity2"])
        XCTAssertEqual(s.dataDisks.map(\.name), ["disk1", "disk2", "disk3", "disk4"])
        XCTAssertEqual(s.dataDisks.first?.model, "ST12000VN0007-2GS116", "the serial is not shown")
        XCTAssertEqual(s.dataDisks.first?.filesystem?.type, "zfs")
        // disks.ini is in KiB: disk2 holds 8617119520 KiB of 11576279040.
        XCTAssertEqual(s.dataDisks[1].filesystem?.usedBytes, 8_617_119_520 * 1024)
        XCTAssertEqual(s.dataDisks[1].filesystem?.usePercent, 74)
        XCTAssertGreaterThan(s.arrayTotalBytes, 40_000_000_000_000)
        let pools = s.pools
        XCTAssertEqual(pools.map(\.name), ["cache"])
        XCTAssertEqual(pools.first?.devices.map(\.name), ["cache", "cache2"], "cache2 is a member, not a pool of its own")
        XCTAssertEqual(pools.first?.health, "ONLINE")
        XCTAssertEqual(s.flash?.filesystem?.mount, "/boot")
        XCTAssertEqual(s.cpuTemperature, 63, "Intel package temperature")
        XCTAssertEqual(s.spinningFans.count, 3)
        XCTAssertFalse(s.boardSensors.contains { $0.celsius < -40 }, "the -128 °C non-reading is dropped")
        XCTAssertEqual(s.boardSensors.filter { $0.name == "Memory" }.count, 1, "two DIMM sensors collapse into one row")
        XCTAssertEqual(s.shares.count, 17)
        XCTAssertEqual(s.parityChecks.count, 10)
        XCTAssertEqual(s.lastParityCheck?.label, "Parity check")
        XCTAssertEqual(s.parityChecks[3].label, "Rebuilding disk 3")
        XCTAssertFalse(s.parityChecks[2].completed, "exit -4 is a cancelled check")
        XCTAssertEqual(s.parityChecks[1].finished, "2025 Nov 8 14:10:41", "the log's double space before a one-digit day is folded")
        XCTAssertNotNil(s.parityChecks[1].finishedDate(utcOffsetSeconds: 0))
        XCTAssertEqual(UnraidAttention.evaluate(s), [], "a healthy array needs no attention")
    }

    func testRunningCheckDisabledDiskAndAttention() throws {
        let s = try fixture("synthetic-check-running-disabled")
        let op = try XCTUnwrap(s.array.operation)
        XCTAssertEqual(op.label, "Parity check")
        XCTAssertEqual(op.fraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(op.bytesPerSecond), 1_000_000 / 10 * 1024, accuracy: 1)
        XCTAssertNotNil(op.remainingSeconds)
        XCTAssertEqual(s.parityDisks.map(\.name), ["parity"], "an empty parity2 slot is not a disk")
        XCTAssertEqual(s.dataDisks.map(\.name), ["disk1", "disk2", "disk3"], "an empty disk4 slot is not a disk")
        XCTAssertNil(s.dataDisks[1].temperature, "spun down: no reading, never a wake-up")
        XCTAssertTrue(s.dataDisks[1].spunDown)
        XCTAssertEqual(s.pools.first?.filesystem?.profile, "raid1")
        XCTAssertNil(s.pools.first?.health, "not ZFS")
        XCTAssertEqual(s.cpuTemperature, 58.25, "AMD Tctl")
        XCTAssertEqual(s.spinningFans.map(\.label), ["fan1"])
        XCTAssertEqual(s.shares.first { $0.name == "appdata" }?.placement, "cache, then array")
        XCTAssertEqual(s.shares.first { $0.name == "isos" }?.placement, "array")

        let ids = Set(UnraidAttention.evaluate(s).map(\.id))
        XCTAssertTrue(ids.contains("array_disabled"))
        XCTAssertTrue(ids.contains("disk_status:disk3"))
        XCTAssertTrue(ids.contains("disk_errors:disk2"))
        XCTAssertTrue(ids.contains("disk_hot:disk1"), "47 °C is over a hard drive's 45 °C warning")
        XCTAssertTrue(ids.contains("disk_hot:cache2"), "72 °C is over an SSD's 70 °C limit")
        XCTAssertTrue(ids.contains("disk_full:disk1"), "95% full")
        XCTAssertTrue(ids.contains("parity_errors"))
        XCTAssertFalse(ids.contains { $0.contains("disk4") || $0.contains("parity2") }, "empty slots raise nothing")
        XCTAssertEqual(UnraidAttention.evaluate(s).first { $0.id == "disk_hot:cache2" }?.severity, .critical)
    }

    func testNotUnraid() {
        XCTAssertThrowsError(try fixture("synthetic-not-unraid")) { XCTAssertEqual($0 as? UnraidParseError, .notUnraid) }
    }

    func testDescribeActions() {
        XCTAssertEqual(UnraidSnapshot.describe("check P Q"), "Parity check")
        XCTAssertEqual(UnraidSnapshot.describe("recon P"), "Parity sync")
        XCTAssertEqual(UnraidSnapshot.describe("recon D5"), "Rebuilding disk 5")
        XCTAssertEqual(UnraidSnapshot.describe("clear"), "Clearing disk")
    }

    func testSessionKeepsLastSnapshotOnFailure() async throws {
        let good = try String(contentsOf: specDir.appendingPathComponent("fixtures/unraid/unraid-7.3-zfs.out.txt"), encoding: .utf8)
        let session = UnraidSession(transport: FakeTransport([
            .success(CommandResult(stdout: good)),
            .success(CommandResult(stdout: "", stderr: "Connection refused", exitCode: 255)),
        ]))
        var state = await session.refresh()
        XCTAssertEqual(state.snapshot?.dataDisks.count, 4)
        state = await session.refresh()
        XCTAssertEqual(state.snapshot?.dataDisks.count, 4, "old data stays visible")
        XCTAssertEqual(state.error, "Connection refused")
    }
}

/// Edge cases of the NAS page's rules, beyond what the golden fixtures pin down.
final class UnraidEdgeCaseTests: XCTestCase {
    private func fixture(_ name: String) throws -> UnraidSnapshot {
        try UnraidParser.parse(String(contentsOf: specDir.appendingPathComponent("fixtures/unraid/\(name).out.txt"), encoding: .utf8))
    }

    /// A minimal reading: a version, var.ini lines and disks.ini lines.
    private func reading(_ vars: [String], disks: String = "", temps: [String] = []) throws -> UnraidSnapshot {
        try UnraidParser.parse((["##unraid", "7.0.0", "##var"] + vars + ["##disks", disks, "##temps"] + temps).joined(separator: "\n"))
    }

    private let oneParityOneData = """
    ["parity"]
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
    type="Data"
    """

    private let dataOnly = """
    ["disk1"]
    name="disk1"
    device="sdc"
    id="M_S2"
    size="100"
    status="DISK_OK"
    type="Data"
    """

    // MARK: pools

    func testSeveralPoolsGroupByCountNotName() throws {
        let s = try fixture("synthetic-pools-unmountable")
        let pools = s.pools
        XCTAssertEqual(pools.map(\.name), ["cache", "fast", "vms"])
        XCTAssertEqual(pools.map { $0.devices.map(\.name) }, [["cache", "cache2"], ["fast"], ["vms"]],
                       "a one-device pool doesn't swallow the next pool's first device")
        XCTAssertEqual(pools.map(\.kind), ["BTRFS raid1", "XFS", "ZFS"])
        XCTAssertEqual(pools.map(\.health), [nil, nil, "DEGRADED"], "only ZFS pools report health")
        XCTAssertEqual(s.dataDisks.map(\.name), ["disk1", "disk2", "disk3"], "a missing disk still has its slot")
    }

    func testPoolKindWithoutProfile() throws {
        let s = try fixture("unraid-7.3-zfs")
        XCTAssertEqual(s.pools.first?.kind, "ZFS 2 devices", "no profile recorded: the device count says how it's built")
        XCTAssertEqual(try fixture("synthetic-check-running-disabled").pools.first?.kind, "BTRFS raid1")
    }

    // MARK: alerts

    /// Boost spikes (one reading at 95 °C between normal ones) must never alert; only heat that lasts does.
    func testCPUHeatMustLastBeforeItCounts() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var h = CPUHeatTracker()
        h.record(95, at: t0)
        XCTAssertNil(h.sustained, "one spike")
        h.record(62, at: t0.addingTimeInterval(15))
        XCTAssertNil(h.hotSince, "a cool reading starts over")
        for i in 0...12 { h.record(i == 6 ? 90 : 93, at: t0.addingTimeInterval(Double(60 + i * 15))) }
        XCTAssertEqual(h.sustained, 90, "every reading at 90 or above for three minutes; reports the lowest")
        h.record(87, at: t0.addingTimeInterval(400))
        XCTAssertEqual(h.sustained, 87, "once hot it stays hot down to 85 °C, so it does not flap")
        h.record(80, at: t0.addingTimeInterval(415))
        XCTAssertNil(h.sustained)
        // Background checks are five minutes apart: two hot readings in a row are enough.
        var sweep = CPUHeatTracker()
        sweep.record(92, at: t0)
        sweep.record(91, at: t0.addingTimeInterval(300))
        XCTAssertEqual(sweep.sustained, 91)
        sweep.record(nil, at: t0.addingTimeInterval(600))
        XCTAssertNil(sweep.sustained, "no reading, no claim")
    }

    func testCPUHeatIsNeverCalledADiskProblem() throws {
        let titles = AlertRules.storage(try fixture("synthetic-pools-unmountable"), sustainedCPU: 92)
        XCTAssertEqual(titles.first { $0.key == "cpu_hot" }?.title, "CPU running hot")
        XCTAssertEqual(titles.first { $0.key == "zfs_health:vms" }?.title, "Pool needs attention")
        XCTAssertEqual(titles.first { $0.key == "disk_status:disk2" }?.title, "Disk needs attention")
        XCTAssertEqual(AlertRules.storageTitle("disk_hot:cache2"), "Disk running hot")
    }

    func testUnmountableMissingInvalidAndDegradedZFS() throws {
        let items = UnraidAttention.evaluate(try fixture("synthetic-pools-unmountable"))
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        XCTAssertEqual(byID["array_missing"]?.severity, .critical)
        XCTAssertEqual(byID["array_invalid"]?.severity, .warning)
        XCTAssertEqual(byID["disk_status:disk2"]?.message, "disk2 is missing.")
        XCTAssertEqual(byID["disk_unmountable:disk3"]?.severity, .critical)
        XCTAssertEqual(byID["zfs_health:vms"]?.severity, .warning, "DEGRADED still works")
        XCTAssertEqual(byID["disk_full:fast"]?.severity, .warning, "pools are judged like array disks (92%)")
        XCTAssertNil(byID["cpu_hot"], "one hot reading alone is never an alert")
        let s = try fixture("synthetic-pools-unmountable")
        XCTAssertEqual(s.cpuTemperature, 91.5, "Tdie, not Tctl's offset 101 °C")
        let hot = UnraidAttention.evaluate(s, sustainedCPU: 91.5).first { $0.id == "cpu_hot" }
        XCTAssertEqual(hot?.message, "The CPU has stayed at 91 °C or hotter for over 3 minutes.")
        XCTAssertNil(byID["disk_hot:fast"], "44 °C is fine for an NVMe drive")
        XCTAssertTrue(items.allSatisfy { $0.fix.isEmpty }, "no screen link: the fix is on this page")
    }

    func testFaultedZFSIsCritical() throws {
        var s = try fixture("unraid-7.3-zfs")
        s.zfsPools[0].health = "FAULTED"
        XCTAssertEqual(UnraidAttention.evaluate(s).first { $0.id == "zfs_health:cache" }?.severity, .critical)
    }

    func testStoppedArray() throws {
        let s = try reading(["mdState=\"STOPPED\"", "fsState=\"Stopped\""], disks: oneParityOneData)
        XCTAssertEqual(s.condition, .stopped("STOPPED"))
        XCTAssertEqual(s.condition.title, "Stopped")
        XCTAssertEqual(s.condition.level, .critical)
        let items = UnraidAttention.evaluate(s)
        XCTAssertEqual(items.first?.id, "array_stopped")
        XCTAssertEqual(items.first?.message, "The array is stopped.")
        XCTAssertEqual(try reading(["mdState=\"NEW_ARRAY\""]).condition.title, "New Array")
        XCTAssertEqual(try reading([]).condition, .stopped(""), "no var.ini at all")
        XCTAssertEqual(UnraidAttention.evaluate(try reading([])).first?.message, "The array is not started.")
    }

    func testWarmAndHotDrivesAtTheLimits() throws {
        func drive(_ temp: Int, rotational: Bool) -> UnraidSnapshot.Device {
            .init(name: "disk1", device: "sdc", identity: "M_S", sizeBytes: 1, transport: "ata", rotational: rotational, spunDown: false,
                  status: "DISK_OK", temperature: temp, errors: 0, role: .data, filesystem: nil)
        }
        XCTAssertEqual(drive(44, rotational: true).temperatureLevel, .normal)
        XCTAssertEqual(drive(45, rotational: true).temperatureLevel, .warning)
        XCTAssertEqual(drive(55, rotational: true).temperatureLevel, .critical)
        XCTAssertEqual(drive(59, rotational: false).temperatureLevel, .normal)
        XCTAssertEqual(drive(60, rotational: false).temperatureLevel, .warning)
        XCTAssertEqual(drive(70, rotational: false).temperatureLevel, .critical)
    }

    // MARK: array status

    func testConditions() throws {
        XCTAssertEqual(try reading(["mdState=\"STARTED\""], disks: oneParityOneData).condition, .protected)
        let noParity = try reading(["mdState=\"STARTED\""], disks: dataOnly)
        XCTAssertEqual(noParity.condition, .unprotected, "no parity disk must never read as protected")
        XCTAssertEqual(noParity.condition.level, .warning)
        XCTAssertEqual(try reading(["mdState=\"STARTED\"", "mdNumDisabled=\"1\""], disks: oneParityOneData).condition, .degraded)
        XCTAssertEqual(try reading(["mdState=\"STARTED\"", "mdResync=\"100\"", "mdResyncPos=\"10\""], disks: oneParityOneData).condition,
                       .checking)
        XCTAssertEqual(try fixture("synthetic-check-running-disabled").condition, .degraded, "a disabled disk outranks a running check")
    }

    func testPausedOperationHasNoSpeedOrETA() throws {
        let s = try reading(["mdState=\"STARTED\"", "mdResync=\"1000\"", "mdResyncPos=\"500\"", "mdResyncDt=\"0\"", "mdResyncDb=\"0\"",
                             "mdResyncAction=\"recon P\"", "mdResyncSize=\"0\""])
        let op = try XCTUnwrap(s.array.operation)
        XCTAssertNil(op.bytesPerSecond)
        XCTAssertNil(op.remainingSeconds)
        XCTAssertEqual(op.sizeKiB, 1000, "no mdResyncSize: the size comes from mdResync")
        XCTAssertEqual(op.fraction, 0.5)
        XCTAssertEqual(op.label, "Parity sync")
    }

    func testFinishedOperationAndOverrun() {
        let op = UnraidSnapshot.Operation(action: "check P", positionKiB: 120, sizeKiB: 100, bytesPerSecond: 1024)
        XCTAssertEqual(op.fraction, 1, "never over 100%")
        XCTAssertEqual(op.remainingSeconds, 0)
        XCTAssertEqual(UnraidSnapshot.Operation(action: "", positionKiB: 1, sizeKiB: 0, bytesPerSecond: nil).fraction, 0)
    }

    // MARK: names and thresholds

    func testSlotTitles() {
        XCTAssertEqual(["parity", "parity2", "disk1", "disk12", "cache", "cache2", "fast", "nvme2pool", "flash", "pool10"]
            .map(UnraidSnapshot.slotTitle),
                       ["Parity", "Parity 2", "Disk 1", "Disk 12", "Cache", "Cache 2", "Fast", "Nvme2pool", "Flash", "Pool 10"])
    }

    func testThresholds() {
        XCTAssertEqual(UnraidSnapshot.fillLevel(0.85), .normal, "the Overview's rule: over 85%")
        XCTAssertEqual(UnraidSnapshot.fillLevel(0.86), .warning)
        XCTAssertEqual(UnraidSnapshot.fillLevel(0.95), .critical)
        XCTAssertEqual(UnraidSnapshot.cpuLevel(79.9), .normal)
        XCTAssertEqual(UnraidSnapshot.cpuLevel(80), .warning)
        XCTAssertEqual(UnraidSnapshot.cpuLevel(90), .critical)
    }

    func testSharePlacements() {
        func share(_ use: String, _ pool: String = "cache") -> String {
            UnraidSnapshot.Share(name: "s", comment: "", useCache: use, cachePool: pool, freeBytes: 0).placement
        }
        XCTAssertEqual(share("only", "vms"), "vms only")
        XCTAssertEqual(share("prefer"), "cache, then array")
        XCTAssertEqual(share("yes"), "cache, moved to array")
        XCTAssertEqual(share("no"), "array")
        XCTAssertEqual(share("only", ""), "cache only", "no pool named: Unraid's default pool")
    }

    // MARK: sensors

    func testCPUTemperaturePreference() throws {
        func cpu(_ temps: [String]) throws -> Double? { try reading([], temps: temps).cpuTemperature }
        XCTAssertEqual(try cpu(["coretemp|Core 0|70000", "coretemp|Package id 0|65000"]), 65, "Intel package over a core")
        XCTAssertEqual(try cpu(["k10temp|Tctl|80000", "k10temp|Tdie|70000"]), 70, "Tdie over Tctl, whatever the order")
        XCTAssertEqual(try cpu(["k10temp|Tctl|80000", "k10temp|Tccd1|60000"]), 80, "Tctl when there is no Tdie")
        XCTAssertEqual(try cpu(["cpu_thermal||48000"]), 48, "an ARM board's only reading")
        XCTAssertEqual(try cpu(["coretemp|Core 0|-128000", "coretemp|Core 1|50000"]), 50, "impossible readings are ignored")
        XCTAssertNil(try cpu(["nvme|Composite|40000", "acpitz||30000"]), "no CPU driver: no CPU temperature")
    }

    func testBoardSensorsAndFans() throws {
        let s = try fixture("synthetic-pools-unmountable")
        XCTAssertEqual(s.temperatures.count, 3, "an empty or non-numeric reading is dropped")
        XCTAssertEqual(s.boardSensors.map(\.name), ["SYSTIN"], "Nuvoton chips keep their own labels")
        XCTAssertEqual(s.spinningFans.map(\.label), ["CPU Fan"], "0 RPM is an unconnected header")
        let amd = try fixture("synthetic-check-running-disabled")
        XCTAssertFalse(amd.boardSensors.contains { $0.name == "Motherboard" }, "acpitz at -273 °C is not a reading")
    }

    // MARK: parity log

    func testParityLogDatesAndOldFormat() throws {
        let s = try fixture("synthetic-pools-unmountable")
        let old = try XCTUnwrap(s.lastParityCheck)
        XCTAssertEqual(old.action, "check P", "Unraid 6's five-field log has no action column")
        XCTAssertEqual(old.sizeKiB, 0)
        XCTAssertEqual(old.label, "Parity check")
        // The log is in the server's local time: 23:30 on Dec 31 at UTC+2 is 21:30 UTC.
        let date = try XCTUnwrap(old.finishedDate(utcOffsetSeconds: 7200))
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2024-12-31T21:30:00Z"))
        XCTAssertNil(UnraidParser.parityCheck("garbage"))
        XCTAssertNil(UnraidParser.parityCheck("2026 Jan 1 00:00:00|notanumber|0|0|0"))
        XCTAssertNil(UnraidSnapshot.ParityCheck(finished: "yesterday", durationSeconds: 1, bytesPerSecond: 0, exitCode: 0, errors: 0,
                                                action: "", sizeKiB: 0).finishedDate(utcOffsetSeconds: 0))
    }

    // MARK: attention on the Overview

    func testMergeReplacesDfOnUnraidOnly() throws {
        let base = [AttentionItem(id: "disk_high:/mnt/disk1", severity: .warning, message: "x", fix: "docker"),
                    AttentionItem(id: "reboot_required", severity: .warning, message: "y", fix: "updates")]
        let degraded = try fixture("synthetic-check-running-disabled")
        XCTAssertEqual(UnraidAttention.merge(base, kind: .server, snapshot: degraded), base, "a plain server is left alone")
        let merged = UnraidAttention.merge(base, kind: .unraid, snapshot: degraded)
        XCTAssertFalse(merged.contains { $0.id.hasPrefix("disk_high:") })
        XCTAssertEqual(merged.first?.id, "reboot_required", "other Overview items stay, first")
        XCTAssertTrue(merged.contains { $0.id == "array_disabled" })
        XCTAssertEqual(UnraidAttention.merge(base, kind: .unraid, snapshot: nil).map(\.id), ["reboot_required"],
                       "before the first NAS reading, nothing misleading is shown")
    }

    // MARK: parsing details

    func testIniSectionsWithAndWithoutQuotes() {
        let sections = UnraidParser.iniSections(["[\"disk1\"]", "name=\"disk1\"", "[cache]", "fsType=zfs", "stray", "name=\"cache\""])
        XCTAssertEqual(sections.map { $0["_section"] }, ["disk1", "cache"])
        XCTAssertEqual(sections[1]["fsType"], "zfs")
        XCTAssertEqual(UnraidParser.iniSections(["name=\"orphan\""]), [], "lines before any header belong to nothing")
    }

    func testDeviceModelAndEmptySlot() throws {
        let s = try fixture("synthetic-check-running-disabled")
        XCTAssertEqual(s.dataDisks.first?.model, "WDC WD80EFAX-68KNBN0", "underscores inside the model read as spaces")
        let disk4 = try XCTUnwrap(s.devices.first { $0.name == "disk4" })
        XCTAssertTrue(disk4.isEmptySlot)
        XCTAssertFalse(disk4.isHealthy)
        XCTAssertEqual(disk4.statusDescription, "not assigned")
        XCTAssertEqual(s.devices.first { $0.name == "disk3" }?.statusDescription, "disabled")
        XCTAssertEqual(UnraidAttention.evaluate(s).first { $0.id == "disk_status:disk3" }?.message, "disk3 is disabled.")
        XCTAssertEqual(s.flash?.model, "Samsung Flash Drive FIT")
    }
}
