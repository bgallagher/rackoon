import Foundation

/// Which Overview layout a server gets, decided from what the server says it is (`/etc/os-release`). A NAS shows its
/// array, pools and drive temperatures; a plain server shows `df`.
public enum ServerKind: String, Sendable, Codable, Equatable {
    case server
    case unraid

    public static func detect(_ os: Overview.OS) -> ServerKind {
        let id = os.id.lowercased(), name = os.name.lowercased()
        return id == "unraid-os" || id == "unraid" || name.hasPrefix("unraid") ? .unraid : .server
    }

    public var isNAS: Bool { self != .server }
    /// Screens that mean nothing on this kind of server (Unraid is Slackware-based and has no apt).
    public var hiddenScreens: Set<String> { self == .unraid ? ["updates"] : [] }
}

/// One reading of the `unraid` command: the array, every device, user shares, sensors and parity history. Everything comes
/// from files Unraid's own web UI (emhttp) keeps current, so reading it never spins a sleeping disk up.
public struct UnraidSnapshot: Sendable, Codable, Equatable {
    public struct ArrayStatus: Sendable, Codable, Equatable {
        /// `mdState`: STARTED, STOPPED, NEW_ARRAY, DISABLE_DISK, SWAP_DSBL, ...
        public var state: String
        /// `fsState`: Started, Stopped, Starting, Stopping, ...
        public var fsState: String
        public var numDisks: Int
        public var disabled: Int
        public var invalid: Int
        public var missing: Int
        public var shareCount: Int
        /// A parity check, sync, rebuild or clear in progress; nil when the array is idle.
        public var operation: Operation?
        /// The superblock's record of the last parity operation: Unix seconds of its start and end, errors and exit code.
        public var lastSyncStart: Int64?
        public var lastSyncEnd: Int64?
        public var lastSyncErrors: Int64?
        public var lastSyncExit: Int?

        public var isStarted: Bool { state == "STARTED" }
        public var hasProblem: Bool { disabled > 0 || invalid > 0 || missing > 0 }
    }

    /// A running parity operation, in KiB as `md` reports it.
    public struct Operation: Sendable, Codable, Equatable {
        /// "check P Q", "recon P", "recon D3", "clear".
        public var action: String
        public var positionKiB: Int64
        public var sizeKiB: Int64
        /// Bytes per second over the last sample; nil while paused or just started.
        public var bytesPerSecond: Double?

        public var fraction: Double { sizeKiB > 0 ? min(1, Double(positionKiB) / Double(sizeKiB)) : 0 }
        public var remainingSeconds: Double? {
            guard let rate = bytesPerSecond, rate > 0 else { return nil }
            return Double(max(0, sizeKiB - positionKiB)) * 1024 / rate
        }
        public var label: String { UnraidSnapshot.describe(action) }
    }

    public struct Filesystem: Sendable, Codable, Equatable {
        /// xfs, btrfs, zfs, vfat, ...
        public var type: String
        /// Mounted, Unmountable, ...
        public var status: String
        public var mount: String
        public var totalBytes: Int64
        public var usedBytes: Int64
        public var freeBytes: Int64
        /// Devices in the pool (1 for an array disk).
        public var devices: Int
        /// raid1, raidz, mirror... (empty for a single device).
        public var profile: String

        public var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
        public var usePercent: Int { Int((usedFraction * 100).rounded()) }
        public var isMounted: Bool { status == "Mounted" }
    }

    public enum Role: String, Sendable, Codable, Equatable {
        case parity, data, pool, flash, other
    }

    public struct Device: Sendable, Codable, Equatable, Identifiable {
        /// The slot: parity, parity2, disk1, cache, cache2, flash.
        public var name: String
        /// Kernel device (sdc, nvme0n1); empty for an empty slot.
        public var device: String
        /// Model and serial joined by `_`, as Unraid identifies the drive.
        public var identity: String
        public var sizeBytes: Int64
        /// ata, nvme, usb, ...
        public var transport: String
        public var rotational: Bool
        public var spunDown: Bool
        /// DISK_OK, DISK_NP (no device), DISK_DSBL, DISK_INVALID, DISK_WRONG, DISK_NEW, ...
        public var status: String
        /// °C; nil when spun down or not reported (`*`).
        public var temperature: Int?
        /// Read/write errors md counted since the array started.
        public var errors: Int64
        public var role: Role
        /// The filesystem on it: array disks and the first device of a pool carry one, the other pool members don't.
        public var filesystem: Filesystem?

        public var id: String { name }
        public var isEmptySlot: Bool { status == "DISK_NP" || (device.isEmpty && identity.isEmpty) }
        public var isHealthy: Bool { status == "DISK_OK" && errors == 0 }
        /// Unraid's status code in words: DISK_NP_MISSING -> "missing", DISK_DSBL -> "disabled".
        public var statusDescription: String {
            switch status {
            case "DISK_OK": "healthy"
            case "DISK_NP": "not assigned"
            case "DISK_NP_MISSING": "missing"
            case "DISK_NP_DSBL": "missing and disabled"
            case "DISK_DSBL": "disabled"
            case "DISK_DSBL_NEW": "new and disabled"
            case "DISK_INVALID": "invalid"
            case "DISK_WRONG": "the wrong disk"
            case "DISK_NEW": "new"
            default: status.replacingOccurrences(of: "DISK_", with: "").replacingOccurrences(of: "_", with: " ").lowercased()
            }
        }
        /// "ST12000VN0007-2GS116" from "ST12000VN0007-2GS116_ZJV16MMX": the serial is dropped.
        public var model: String {
            guard let underscore = identity.lastIndex(of: "_") else { return identity }
            return String(identity[..<underscore]).replacingOccurrences(of: "_", with: " ")
        }
        /// Unraid's own defaults: hard drives warn at 45 °C and are critical at 55 °C; solid state runs hotter.
        public var temperatureLimits: (warning: Int, critical: Int) { rotational ? (45, 55) : (60, 70) }
        public var temperatureLevel: Level {
            guard let t = temperature else { return .normal }
            let limits = temperatureLimits
            return t >= limits.critical ? .critical : t >= limits.warning ? .warning : .normal
        }
    }

    public enum Level: String, Sendable, Codable, Equatable { case normal, warning, critical }

    /// A cache (or other) pool: one or more devices, the first of which carries the filesystem.
    public struct Pool: Sendable, Equatable, Identifiable {
        public var name: String
        public var devices: [Device]
        public var filesystem: Filesystem?
        /// `zpool list` health (ONLINE, DEGRADED, ...) for a ZFS pool.
        public var health: String?
        public var id: String { name }
    }

    public struct Share: Sendable, Codable, Equatable, Identifiable {
        public var name: String
        public var comment: String
        /// yes, no, only, prefer (Unraid's "use cache" setting).
        public var useCache: String
        public var cachePool: String
        /// Free space on the disks the share may write to. (Unraid's own `used` is that disk set's usage, not the share's
        /// size, which Unraid only works out on request, so it is not read.)
        public var freeBytes: Int64
        public var id: String { name }

        /// Where new files go, in Unraid's own words.
        public var placement: String {
            let pool = cachePool.isEmpty ? "cache" : cachePool
            switch useCache {
            case "only": return "\(pool) only"
            case "prefer": return "\(pool), then array"
            case "yes": return "\(pool), moved to array"
            default: return "array"
            }
        }
    }

    public struct Sensor: Sendable, Codable, Equatable {
        /// hwmon driver name: coretemp, k10temp, nvme, it8613, acpitz...
        public var chip: String
        public var label: String
        /// °C for temperatures, RPM for fans.
        public var value: Double
    }

    public struct ZFSPool: Sendable, Codable, Equatable {
        public var name: String
        public var health: String
    }

    /// One line of /boot/config/parity-checks.log.
    public struct ParityCheck: Sendable, Codable, Equatable {
        /// When it finished, in the server's local time: "2026 Sep 29 12:38:31".
        public var finished: String
        public var durationSeconds: Int
        public var bytesPerSecond: Int64
        /// 0 = completed; anything else (usually -4) = cancelled or aborted.
        public var exitCode: Int
        public var errors: Int64
        public var action: String
        public var sizeKiB: Int64

        public var completed: Bool { exitCode == 0 }
        public var label: String { UnraidSnapshot.describe(action) }

        /// The finish time as a date, given the server's UTC offset (the log has local times with no zone).
        public func finishedDate(utcOffsetSeconds: Int) -> Date? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds)
            formatter.dateFormat = "yyyy MMM d HH:mm:ss"
            return formatter.date(from: finished)
        }
    }

    public var version: String
    public var cpuModel: String
    public var array: ArrayStatus
    /// In disks.ini order: parity, data disks, parity2, pools, flash.
    public var devices: [Device]
    public var shares: [Share]
    public var zfsPools: [ZFSPool]
    public var temperatures: [Sensor]
    public var fans: [Sensor]
    /// Oldest first, as in the log (the last ten).
    public var parityChecks: [ParityCheck]

    // MARK: derived

    public var parityDisks: [Device] { devices.filter { $0.role == .parity && !$0.isEmptySlot } }
    public var dataDisks: [Device] { devices.filter { $0.role == .data && !$0.isEmptySlot } }
    public var flash: Device? { devices.first { $0.role == .flash } }

    /// The data disks' filesystems added up: what the array can hold.
    public var arrayTotalBytes: Int64 { dataDisks.compactMap(\.filesystem?.totalBytes).reduce(0, +) }
    public var arrayUsedBytes: Int64 { dataDisks.compactMap(\.filesystem?.usedBytes).reduce(0, +) }
    public var arrayFreeBytes: Int64 { dataDisks.compactMap(\.filesystem?.freeBytes).reduce(0, +) }
    public var arrayUsedFraction: Double { arrayTotalBytes > 0 ? Double(arrayUsedBytes) / Double(arrayTotalBytes) : 0 }

    /// Pool devices grouped into pools. disks.ini lists a pool's first device with the filesystem and `devices="N"`,
    /// then its other members (cache2, cache3...) without one, so membership follows order and count, not names.
    public var pools: [Pool] {
        var out: [Pool] = []
        var remaining = 0
        for device in devices where device.role == .pool {
            if remaining > 0, var last = out.popLast() {
                last.devices.append(device)
                out.append(last)
                remaining -= 1
                continue
            }
            let health = zfsPools.first { $0.name == device.name }?.health
            out.append(Pool(name: device.name, devices: [device], filesystem: device.filesystem, health: health))
            remaining = max(0, (device.filesystem?.devices ?? 1) - 1)
        }
        return out
    }

    /// The CPU package temperature: Intel's coretemp package, else AMD's Tdie (the real die temperature), else Tctl (which
    /// many Ryzens report 10 °C high, for fan control), else the hottest reading of a CPU driver.
    public var cpuTemperature: Double? {
        let cpu = temperatures.filter { ["coretemp", "k10temp", "zenpower", "cpu_thermal"].contains($0.chip) && Self.plausible($0.value) }
        for label in ["Package id 0", "Tdie", "Tctl"] {
            if let reading = cpu.first(where: { $0.label == label }) { return reading.value }
        }
        return cpu.map(\.value).max()
    }

    /// Readable sensors other than the CPU and the drives (whose temperatures are shown with each drive).
    public var boardSensors: [(name: String, celsius: Double)] {
        var seen = Set<String>()
        var out: [(String, Double)] = []
        for sensor in temperatures where Self.plausible(sensor.value) {
            let name: String
            switch sensor.chip {
            case "coretemp", "k10temp", "zenpower", "cpu_thermal", "nvme", "drivetemp": continue
            case "acpitz": name = "Motherboard"
            case "spd5118", "jc42": name = "Memory"
            case let chip where chip.hasPrefix("eth") || chip.hasPrefix("en") || chip.contains("phy"):
                name = "Network \(chip)"
            case let chip where chip.hasPrefix("it8") || chip.hasPrefix("nct") || chip.hasPrefix("f71"):
                name = sensor.label.isEmpty ? "Board" : sensor.label
            default: name = sensor.label.isEmpty ? sensor.chip : "\(sensor.chip) \(sensor.label)"
            }
            // One reading per name: the hottest (two memory modules, a NIC's PHY and MAC).
            if let i = out.firstIndex(where: { $0.0 == name }) { out[i].1 = max(out[i].1, sensor.value) }
            else if seen.insert(name).inserted { out.append((name, sensor.value)) }
        }
        return out
    }

    /// Spinning fans (0 RPM means not connected on most boards).
    public var spinningFans: [Sensor] { fans.filter { $0.value > 0 } }

    public var lastParityCheck: ParityCheck? { parityChecks.last }

    static func plausible(_ celsius: Double) -> Bool { celsius > -40 && celsius < 150 }

    /// "check P Q" -> "Parity check", "recon D3" -> "Rebuilding disk 3".
    static func describe(_ action: String) -> String {
        let parts = action.split(separator: " ").map(String.init)
        switch parts.first {
        case "check": return "Parity check"
        case "recon":
            let targets = parts.dropFirst()
            if let disk = targets.first(where: { $0.hasPrefix("D") }) { return "Rebuilding disk \(disk.dropFirst())" }
            return "Parity sync"
        case "clear": return "Clearing disk"
        default: return action.isEmpty ? "Parity operation" : action
        }
    }
}

public enum UnraidParseError: Error, Equatable {
    /// No `##unraid` version: the server is not Unraid (or /etc/unraid-version is unreadable).
    case notUnraid
}

/// Pure parser for the `unraid` command. Ini files arrive as `[section]` lines followed by key="value" lines.
public enum UnraidParser {
    public static func parse(_ output: String) throws -> UnraidSnapshot {
        let sections = OverviewParser.splitSections(output)
        guard let version = sections["unraid"]?.first?.trimmingCharacters(in: .whitespaces), !version.isEmpty else {
            throw UnraidParseError.notUnraid
        }
        let v = OverviewParser.keyValues(sections["var"] ?? [])
        func int(_ key: String) -> Int { Int(v[key] ?? "") ?? 0 }
        func int64(_ key: String) -> Int64? { Int64(v[key] ?? "") }

        var operation: UnraidSnapshot.Operation?
        if let size = int64("mdResync"), size > 0 {
            let dt = Double(v["mdResyncDt"] ?? "") ?? 0, db = Double(v["mdResyncDb"] ?? "") ?? 0
            operation = UnraidSnapshot.Operation(
                action: v["mdResyncAction"] ?? "", positionKiB: int64("mdResyncPos") ?? 0,
                sizeKiB: int64("mdResyncSize").flatMap { $0 > 0 ? $0 : nil } ?? size,
                bytesPerSecond: dt > 0 && db > 0 ? db / dt * 1024 : nil)
        }
        let array = UnraidSnapshot.ArrayStatus(
            state: v["mdState"] ?? "", fsState: v["fsState"] ?? "",
            numDisks: int("mdNumDisks"), disabled: int("mdNumDisabled"), invalid: int("mdNumInvalid"), missing: int("mdNumMissing"),
            shareCount: int("shareCount"), operation: operation,
            lastSyncStart: int64("sbSynced").flatMap { $0 > 0 ? $0 : nil }, lastSyncEnd: int64("sbSynced2").flatMap { $0 > 0 ? $0 : nil },
            lastSyncErrors: int64("sbSyncErrs"), lastSyncExit: v["sbSyncExit"].flatMap { Int($0) })

        let devices = iniSections(sections["disks"] ?? []).map(device)
        let shares = iniSections(sections["shares"] ?? []).map { s in
            UnraidSnapshot.Share(
                name: s["name"] ?? "", comment: s["comment"] ?? "", useCache: s["useCache"] ?? "no",
                cachePool: s["cachePool"] ?? "", freeBytes: kib(s["free"]))
        }.filter { !$0.name.isEmpty }

        let zfs = (sections["zpool"] ?? []).compactMap { line -> UnraidSnapshot.ZFSPool? in
            let f = line.split(separator: "\t").map(String.init)
            return f.count >= 5 ? UnraidSnapshot.ZFSPool(name: f[0], health: f[4]) : nil
        }
        return UnraidSnapshot(
            version: version, cpuModel: sections["cpu"]?.first?.trimmingCharacters(in: .whitespaces) ?? "",
            array: array, devices: devices, shares: shares, zfsPools: zfs,
            temperatures: sensors(sections["temps"] ?? [], scale: 1000), fans: sensors(sections["fans"] ?? [], scale: 1),
            parityChecks: (sections["parity"] ?? []).compactMap(parityCheck))
    }

    /// `["disk1"]` / `[disk1]` headers, each followed by its key="value" lines. Keys keep their order of appearance.
    static func iniSections(_ lines: [String]) -> [[String: String]] {
        var out: [[String: String]] = []
        var current: [String: String]?
        var currentName = ""
        for line in lines {
            if line.hasPrefix("[") {
                if var c = current { c["_section"] = currentName; out.append(c) }
                currentName = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]\" "))
                current = [:]
            } else if current != nil {
                for (k, value) in OverviewParser.keyValues([line]) { current?[k] = value }
            }
        }
        if var c = current { c["_section"] = currentName; out.append(c) }
        return out
    }

    /// disks.ini sizes are 1 KiB blocks.
    static func kib(_ value: String?) -> Int64 { (Int64(value ?? "") ?? 0) * 1024 }

    static func device(_ s: [String: String]) -> UnraidSnapshot.Device {
        let role: UnraidSnapshot.Role = switch s["type"] ?? "" {
        case "Parity": .parity
        case "Data": .data
        case "Cache": .pool
        case "Flash": .flash
        default: .other
        }
        var filesystem: UnraidSnapshot.Filesystem?
        if let type = s["fsType"], !type.isEmpty, let mount = s["fsMountpoint"] {
            filesystem = UnraidSnapshot.Filesystem(
                type: type, status: s["fsStatus"] ?? "", mount: mount,
                totalBytes: kib(s["fsSize"]), usedBytes: kib(s["fsUsed"]), freeBytes: kib(s["fsFree"]),
                devices: Int(s["devices"] ?? "") ?? 1, profile: s["fsProfile"] ?? "")
        }
        return UnraidSnapshot.Device(
            name: s["name"] ?? s["_section"] ?? "", device: s["device"] ?? "", identity: s["id"] ?? "",
            sizeBytes: kib(s["size"]), transport: s["transport"] ?? "", rotational: s["rotational"] == "1",
            spunDown: s["spundown"] == "1", status: s["status"] ?? "",
            temperature: s["temp"].flatMap { Int($0) }, errors: Int64(s["numErrors"] ?? "") ?? 0,
            role: role, filesystem: filesystem)
    }

    /// "coretemp|Package id 0|63000" -> CPU package at 63 °C. Unreadable values are dropped.
    static func sensors(_ lines: [String], scale: Double) -> [UnraidSnapshot.Sensor] {
        lines.compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3, let raw = Double(f[2].trimmingCharacters(in: .whitespaces)) else { return nil }
            return UnraidSnapshot.Sensor(chip: f[0], label: f[1], value: raw / scale)
        }
    }

    /// "2026 Sep 29 12:38:31|228495|113790929|0|0|check P Q|25391267788". Older Unraid logs have five fields.
    static func parityCheck(_ line: String) -> UnraidSnapshot.ParityCheck? {
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 5, let duration = Int(f[1]) else { return nil }
        let date = f[0].split(separator: " ").joined(separator: " ")
        return UnraidSnapshot.ParityCheck(
            finished: date, durationSeconds: duration, bytesPerSecond: Int64(f[2]) ?? 0, exitCode: Int(f[3]) ?? 0,
            errors: Int64(f[4]) ?? 0, action: f.count > 5 ? f[5] : "check P", sizeKiB: f.count > 6 ? Int64(f[6]) ?? 0 : 0)
    }
}

/// What needs attention on an Unraid server, in the same shape as the Overview's attention strip. Pure.
public enum UnraidAttention {
    /// `sustainedCPU` is the CPU temperature only when it has STAYED hot (`CPUHeatTracker`); one reading alone never
    /// raises a CPU item, because modern CPUs jump to 90-100 °C for a moment whenever a core boosts.
    public static func evaluate(_ s: UnraidSnapshot, sustainedCPU: Double? = nil) -> [AttentionItem] {
        var items: [AttentionItem] = []
        func add(_ id: String, _ severity: AttentionItem.Severity, _ message: String) {
            items.append(AttentionItem(id: id, severity: severity, message: message, fix: ""))
        }
        if !s.array.isStarted {
            add("array_stopped", .critical, "The array is \(s.array.state.isEmpty ? "not started" : s.array.state.lowercased().replacingOccurrences(of: "_", with: " ")).")
        }
        if s.array.disabled > 0 { add("array_disabled", .critical, "\(s.array.disabled) disk(s) disabled: the array is running unprotected.") }
        if s.array.missing > 0 { add("array_missing", .critical, "\(s.array.missing) disk(s) missing from the array.") }
        if s.array.invalid > 0 { add("array_invalid", .warning, "\(s.array.invalid) disk(s) have invalid contents (parity is not in sync).") }
        for d in s.devices where !d.isEmptySlot && d.role != .flash {
            if d.status != "DISK_OK" {
                add("disk_status:\(d.name)", .critical, "\(d.name) is \(d.statusDescription).")
            } else if d.errors > 0 {
                add("disk_errors:\(d.name)", .warning, "\(d.name) has \(d.errors) read/write error(s).")
            }
            switch d.temperatureLevel {
            case .critical: add("disk_hot:\(d.name)", .critical, "\(d.name) is at \(d.temperature ?? 0) °C.")
            case .warning: add("disk_hot:\(d.name)", .warning, "\(d.name) is warm: \(d.temperature ?? 0) °C.")
            case .normal: break
            }
            if let fs = d.filesystem, fs.isMounted, fs.usePercent > Attention.diskThresholdPercent {
                add("disk_full:\(d.name)", fs.usePercent >= 95 ? .critical : .warning, "\(d.name) is \(fs.usePercent)% full.")
            } else if let fs = d.filesystem, !fs.isMounted, s.array.isStarted, !fs.status.isEmpty {
                add("disk_unmountable:\(d.name)", .critical, "\(d.name) is \(fs.status.lowercased()).")
            }
        }
        for pool in s.zfsPools where pool.health != "ONLINE" {
            add("zfs_health:\(pool.name)", pool.health == "DEGRADED" ? .warning : .critical, "ZFS pool \(pool.name) is \(pool.health).")
        }
        if let last = s.lastParityCheck, last.errors > 0 {
            add("parity_errors", .warning, "The last \(last.label.lowercased()) found \(last.errors) error(s).")
        }
        if let cpu = sustainedCPU {
            add("cpu_hot", .warning, "The CPU has stayed at \(Int(cpu)) °C or hotter for over \(Int(CPUHeatTracker.sustain / 60)) minutes.")
        }
        return items
    }
}

/// Reads an Unraid server's storage, sensors and parity history (`unraid` in spec/commands.json). Read-only, never polled
/// unless the Overview of an Unraid server is showing. A failed read keeps the last good snapshot beside the error.
public actor UnraidSession {
    public static let command = #"""
    echo '##unraid'; sed -n 's/^version="\(.*\)"$/\1/p' /etc/unraid-version 2>/dev/null; \#
    echo '##var'; grep -E '^(mdState|mdNumDisks|mdNumDisabled|mdNumInvalid|mdNumMissing|mdResync|mdResyncPos|mdResyncSize|mdResyncAction|mdResyncDt|mdResyncDb|sbSynced|sbSynced2|sbSyncErrs|sbSyncExit|fsState|shareCount)=' /var/local/emhttp/var.ini 2>/dev/null; \#
    echo '##disks'; grep -E '^\[|^(name|device|id|size|transport|rotational|spundown|status|temp|numErrors|type|fsType|fsStatus|fsMountpoint|fsSize|fsFree|fsUsed|devices|fsProfile)=' /var/local/emhttp/disks.ini 2>/dev/null; \#
    echo '##shares'; grep -E '^\[|^(name|comment|useCache|cachePool|free)=' /var/local/emhttp/shares.ini 2>/dev/null; \#
    echo '##zpool'; zpool list -H -o name,size,alloc,free,health 2>/dev/null; \#
    echo '##fans'; for h in /sys/class/hwmon/hwmon*; do n=$(cat "$h/name" 2>/dev/null); for f in "$h"/fan*_input; do [ -r "$f" ] && echo "$n|$(cat "${f%_input}_label" 2>/dev/null)|$(cat "$f" 2>/dev/null)"; done; done; \#
    echo '##cpu'; grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//'; \#
    echo '##parity'; tail -n 10 /boot/config/parity-checks.log 2>/dev/null; \#
    echo '##temps'; sleep 1; for h in /sys/class/hwmon/hwmon*; do n=; read -r n 2>/dev/null < "$h/name"; for t in "$h"/temp*_input; do [ -r "$t" ] || continue; l=; read -r l 2>/dev/null < "${t%_input}_label"; v=; read -r v 2>/dev/null < "$t"; echo "$n|$l|$v"; done; done; true
    """#

    private let transport: SSHTransport
    public private(set) var snapshot: UnraidSnapshot?
    public private(set) var error: String?
    public private(set) var updatedAt: Date?

    public init(transport: SSHTransport) { self.transport = transport }

    @discardableResult
    public func refresh() async -> (snapshot: UnraidSnapshot?, error: String?, updatedAt: Date?) {
        do {
            let result = try await transport.run(Self.command, timeout: 15)
            // The script ends in `true`, so a non-zero exit is ssh's own failure.
            guard result.exitCode == 0 else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw UnraidFailure(detail.isEmpty ? "ssh exited \(result.exitCode)" : detail)
            }
            snapshot = try UnraidParser.parse(result.stdout)
            error = nil
            updatedAt = Date()
        } catch UnraidParseError.notUnraid {
            error = "This server does not look like Unraid (no /etc/unraid-version)."
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        return (snapshot, error, updatedAt)
    }

    private struct UnraidFailure: Error, LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

// MARK: - What the NAS page shows (pure, so it is tested here rather than in the views)

extension UnraidSnapshot {
    /// The array's state in one word, for the Array status tile.
    public enum Condition: Equatable, Sendable {
        /// Not started: carries Unraid's own state word (STOPPED, NEW_ARRAY...).
        case stopped(String)
        /// Started with a disk disabled, missing or invalid: data is at risk.
        case degraded
        /// A parity check, sync, rebuild or clear is running.
        case checking
        /// Started, healthy, with parity.
        case protected
        /// Started and healthy, but no parity disk is assigned: a failed disk loses its data.
        case unprotected

        public var title: String {
            switch self {
            case .stopped(let state):
                state.isEmpty ? "Unknown" : state.replacingOccurrences(of: "_", with: " ").capitalized
            case .degraded: "Degraded"
            case .checking: "Checking"
            case .protected: "Protected"
            case .unprotected: "No parity"
            }
        }

        public var level: Level {
            switch self {
            case .stopped, .degraded: .critical
            case .unprotected: .warning
            case .checking, .protected: .normal
            }
        }
    }

    public var condition: Condition {
        if !array.isStarted { return .stopped(array.state) }
        if array.hasProblem { return .degraded }
        if array.operation != nil { return .checking }
        return parityDisks.isEmpty ? .unprotected : .protected
    }

    /// "Parity", "Parity 2", "Disk 1", "Cache 2", "Fast": how Unraid's own UI names the slots.
    public static func slotTitle(_ name: String) -> String {
        if name == "parity" { return "Parity" }
        if name.hasPrefix("parity"), let n = Int(name.dropFirst(6)) { return "Parity \(n)" }
        if name.hasPrefix("disk"), let n = Int(name.dropFirst(4)) { return "Disk \(n)" }
        // A numbered pool member: "cache2" -> "Cache 2".
        if let last = name.lastIndex(where: { !$0.isNumber }), name.index(after: last) < name.endIndex {
            let base = name[...last], n = name[name.index(after: last)...]
            return base.prefix(1).uppercased() + base.dropFirst() + " " + n
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// How full is too full, with the same thresholds as the Overview's disk alerts.
    public static func fillLevel(_ fraction: Double) -> Level {
        let percent = fraction * 100
        if percent >= 95 { return .critical }
        return percent > Double(Attention.diskThresholdPercent) ? .warning : .normal
    }

    /// CPU package temperature: warm from 80 °C, critical from 90 °C (where most desktop and NAS CPUs start to throttle).
    public static func cpuLevel(_ celsius: Double) -> Level {
        celsius >= 90 ? .critical : celsius >= 80 ? .warning : .normal
    }
}

extension UnraidSnapshot.Pool {
    /// "ZFS raid1", "BTRFS 2 devices", "XFS": the filesystem and how its devices are combined.
    public var kind: String? {
        guard let fs = filesystem else { return nil }
        let layout = fs.profile.isEmpty ? (devices.count > 1 ? "\(devices.count) devices" : nil) : fs.profile
        return [fs.type.uppercased(), layout].compactMap { $0 }.joined(separator: " ")
    }
}

extension UnraidAttention {
    /// The Overview's attention items for a server of this kind. On Unraid, `df`'s disk-full items are dropped (every ZFS
    /// dataset reads about 1%, and array disks are judged from emhttp's own numbers instead) and the NAS items added.
    public static func merge(_ base: [AttentionItem], kind: ServerKind, snapshot: UnraidSnapshot?, sustainedCPU: Double? = nil) -> [AttentionItem] {
        guard kind == .unraid else { return base }
        return base.filter { !$0.id.hasPrefix("disk_high:") } + (snapshot.map { evaluate($0, sustainedCPU: sustainedCPU) } ?? [])
    }
}

/// Whether a CPU has STAYED hot, from successive readings. A single reading says little: Intel and AMD CPUs boost a
/// core for a moment and the package temperature jumps to 90-100 °C, then falls back within a second, so alerting on
/// one reading flooded users with heat warnings the machine never had. Hot means every reading at or above `hot` for
/// at least `sustain`; once hot, it stays hot until a reading drops below `cool` (so a CPU hovering at the limit does
/// not flap). Pure: the times are passed in.
public struct CPUHeatTracker: Sendable, Equatable {
    public static let hot = 90.0
    public static let cool = 85.0
    public static let sustain: TimeInterval = 3 * 60

    public private(set) var hotSince: Date?
    public private(set) var lastAt: Date?
    /// The lowest reading since it became hot: what the CPU has stayed at or above.
    public private(set) var lowest: Double?

    public init() {}

    public mutating func record(_ celsius: Double?, at time: Date) {
        guard let c = celsius else { self = CPUHeatTracker(); return }
        let wasSustained = sustained != nil
        if c >= Self.hot || (wasSustained && c >= Self.cool) {
            hotSince = hotSince ?? time
            lowest = min(lowest ?? c, c)
            lastAt = time
        } else {
            self = CPUHeatTracker()
        }
    }

    /// The temperature the CPU has stayed at or above, once it has been hot for `sustain`; nil otherwise.
    public var sustained: Double? {
        guard let since = hotSince, let last = lastAt, last.timeIntervalSince(since) >= Self.sustain else { return nil }
        return lowest
    }
}
