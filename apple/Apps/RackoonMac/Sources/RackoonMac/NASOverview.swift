import Foundation
import Observation
import RackoonCore
import SwiftUI

/// Bridges `UnraidSession` to SwiftUI for one server. Reads while an Unraid server's Overview is showing (every 15 s:
/// emhttp refreshes its files about that often), and keeps the last reading so coming back shows it at once.
@MainActor @Observable
final class NASModel {
    private(set) var snapshot: UnraidSnapshot?
    private(set) var error: String?
    private(set) var updatedAt: Date?
    private(set) var loading = false
    /// The CPU temperature over successive readings (the Overview's 15 s poll and the 5-minute background check), so
    /// only heat that lasts raises "CPU running hot"; a boost spike in one reading does not.
    private(set) var heat = CPUHeatTracker()
    @ObservationIgnored private let session: UnraidSession

    /// The temperature the CPU has stayed at or above for minutes, or nil.
    var sustainedCPU: Double? { heat.sustained }

    init(server: Server) { session = UnraidSession(transport: makeTransport(for: server)) }
    init(transport: SSHTransport) { session = UnraidSession(transport: transport) }

    func refresh() async {
        guard !loading else { return }
        loading = true
        let result = await session.refresh()
        if result.error == nil, let fresh = result.snapshot, result.updatedAt != updatedAt {
            heat.record(fresh.cpuTemperature, at: result.updatedAt ?? Date())
        }
        snapshot = result.snapshot
        error = result.error
        updatedAt = result.updatedAt
        loading = false
    }

    /// Reads now and then every 15 s until the calling task is cancelled (the Overview went away).
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(15))
        }
    }
}

/// One `NASModel` per server connection, so a reading survives switching screens and servers. A changed connection
/// (Edit Connection) gets a new model, since the old one holds the old address.
@MainActor
final class NASStore {
    static let shared = NASStore()
    private var models: [String: NASModel] = [:]
    /// How a model is made; tests pass a fake transport.
    private let make: (Server) -> NASModel

    init(make: @escaping (Server) -> NASModel = { NASModel(server: $0) }) { self.make = make }

    func model(for server: Server) -> NASModel {
        if let model = models[server.connectionKey] { return model }
        let model = make(server)
        models[server.connectionKey] = model
        return model
    }
}

/// The Overview of an Unraid server: what a NAS owner looks at first. Health tiles (CPU and its temperature, memory,
/// array and pool capacity, uptime), a running parity operation, every array device with its temperature and fill, the
/// pools, sensors and fans, parity history and the user shares.
struct NASSections: View {
    let o: Overview
    let cpu: Double?
    let nas: NASModel
    let polledAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let s = nas.snapshot {
                tiles(s)
                if let op = s.array.operation { ParityProgress(op: op) }
                ArrayDevicesCard(s: s)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                    PoolsCard(s: s)
                    SensorsCard(s: s, cores: o.cores)
                    ParityHistoryCard(s: s, utcOffset: o.utcOffsetSeconds)
                    SharesCard(s: s)
                }
            } else if let error = nas.error {
                NoticeRow(icon: "exclamationmark.triangle.fill", tint: Theme.warn,
                          message: "Could not read the array: \(error)")
                    .noticeSurface(.warn)
                basicTiles
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the array…") }
                    .foregroundStyle(Theme.textMuted)
                basicTiles
            }
            SystemInfoCard(o: o, polledAt: polledAt, cpuModel: nas.snapshot?.cpuModel)
        }
    }

    private var basicTiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
            cpuTile(temperature: nil)
            memoryTile
        }
    }

    private func tiles(_ s: UnraidSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
            cpuTile(temperature: s.cpuTemperature)
            memoryTile
            let used = s.arrayUsedFraction
            StatCard(title: "Array", trailing: Format.storage(s.arrayTotalBytes),
                     value: Format.percent(used * 100), unit: "used", valueTint: fillTint(used),
                     detail: "\(Format.storage(s.arrayFreeBytes)) free · \(s.dataDisks.count) data, \(s.parityDisks.count) parity",
                     fraction: used, tint: fillTint(used) ?? Theme.accent)
            ForEach(s.pools) { pool in
                let fs = pool.filesystem
                let used = fs?.usedFraction ?? 0
                StatCard(title: "Pool \(pool.name)", trailing: fs.map { Format.storage($0.totalBytes) } ?? "",
                         value: Format.percent(used * 100), unit: "used", valueTint: fillTint(used),
                         detail: [fs.map { "\(Format.storage($0.freeBytes)) free" }, pool.kind, pool.health]
                            .compactMap { $0 }.joined(separator: " · "),
                         fraction: used, tint: fillTint(used) ?? Theme.accent)
            }
            ArrayStateTile(s: s, utcOffset: o.utcOffsetSeconds)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let elapsed = max(0, polledAt.map { context.date.timeIntervalSince($0) } ?? 0)
                StatCard(title: "Uptime", trailing: "Unraid \(s.version)",
                         value: Format.uptime(o.uptimeSeconds + elapsed),
                         detail: "since \(Date(timeIntervalSinceNow: -(o.uptimeSeconds + elapsed)).formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }

    private func cpuTile(temperature: Double?) -> some View {
        StatCard(title: "CPU", trailing: temperature.map(Format.celsius) ?? "\(o.cores) cores",
                 trailingTint: temperature.map(cpuTint),
                 value: cpu.map { Format.percent($0) } ?? "—",
                 valueTint: cpu == nil ? Theme.textMuted : nil,
                 detail: "\(o.cores) cores · load \(Format.load(o.load1)) · \(Format.load(o.load5)) · \(Format.load(o.load15))",
                 fraction: (cpu ?? 0) / 100)
    }

    private var memoryTile: some View {
        StatCard(title: "Memory", trailing: Format.bytes(o.memory.totalBytes),
                 value: Format.bytes(o.memory.usedBytes), unit: "used",
                 detail: "\(Format.bytes(o.memory.availableBytes)) available",
                 fraction: o.memory.usedFraction)
    }
}

/// Fill colour (`UnraidSnapshot.fillLevel`). Nil means "normal" (the caller's own colour).
@MainActor private func fillTint(_ fraction: Double) -> Color? {
    let level = UnraidSnapshot.fillLevel(fraction)
    return level == .normal ? nil : levelTint(level)
}

@MainActor private func cpuTint(_ celsius: Double) -> Color { levelTint(UnraidSnapshot.cpuLevel(celsius)) }

@MainActor private func levelTint(_ level: UnraidSnapshot.Level) -> Color {
    switch level {
    case .normal: Theme.ok
    case .warning: Theme.warn
    case .critical: Theme.danger
    }
}

private func slotTitle(_ name: String) -> String { UnraidSnapshot.slotTitle(name) }

/// Started/stopped, protection and the last parity check, in one tile.
private struct ArrayStateTile: View {
    let s: UnraidSnapshot
    let utcOffset: Int

    var body: some View {
        let condition = s.condition
        let tint = condition == .checking ? Theme.accent : (condition.level == .normal ? Theme.ok : levelTint(condition.level))
        StatCard(title: "Array status", trailing: "\(s.parityDisks.count) parity",
                 value: condition.title, valueTint: tint, detail: detail)
    }

    private var detail: String {
        let a = s.array
        if a.disabled > 0 { return "\(a.disabled) disk(s) disabled, running on parity" }
        if a.missing > 0 { return "\(a.missing) disk(s) missing" }
        if let op = a.operation { return "\(op.label) \(Format.percent(op.fraction * 100))" }
        if s.parityDisks.isEmpty { return "No parity disk: a failed disk loses its data" }
        guard let last = s.lastParityCheck else { return "No parity check recorded" }
        let result = last.completed ? (last.errors == 0 ? "0 errors" : "\(last.errors) errors") : "cancelled"
        let when = last.finishedDate(utcOffsetSeconds: utcOffset)?.formatted(.relative(presentation: .named)) ?? last.finished
        return "Last check \(when) · \(result)"
    }
}

/// A parity check, sync or rebuild in progress: how far, how fast, how long to go.
private struct ParityProgress: View {
    let op: UnraidSnapshot.Operation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(op.label, systemImage: "arrow.triangle.2.circlepath").fontWeight(.semibold)
                Spacer()
                Text(Format.percent(op.fraction * 100)).monospacedDigit().fontWeight(.semibold)
            }
            FillBar(fraction: op.fraction, tint: Theme.accent, height: 8)
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
        }
        .noticeSurface(.info)
    }

    private var detail: String {
        var parts = ["\(Format.storage(op.positionKiB * 1024)) of \(Format.storage(op.sizeKiB * 1024))"]
        if let rate = op.bytesPerSecond { parts.append("\(Format.storage(Int64(rate)))/s") } else { parts.append("paused or starting") }
        if let left = op.remainingSeconds { parts.append("about \(Format.uptime(left)) left") }
        return parts.joined(separator: " · ")
    }
}

/// A thin fill bar (no label: the caller writes the value beside it).
private struct FillBar: View {
    let fraction: Double
    var tint: Color = Theme.accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule().fill(tint).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
    }
}

/// Section heading inside a card, with an optional muted note on the right.
private struct CardHeader: View {
    let title: String
    var note: String = ""
    var symbol: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let symbol { Image(systemName: symbol).foregroundStyle(Theme.textMuted) }
            Text(title).fontWeight(.semibold)
            Spacer()
            Text(note).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
        }
    }
}

/// Parity and data disks, one row each: status, slot, drive, size, temperature, fill and errors.
private struct ArrayDevicesCard: View {
    let s: UnraidSnapshot

    var body: some View {
        let types = Set(s.dataDisks.compactMap { $0.filesystem?.type.uppercased() }).sorted().joined(separator: ", ")
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Array devices",
                       note: "\(s.dataDisks.count) data · \(s.parityDisks.count) parity\(types.isEmpty ? "" : " · \(types)")",
                       symbol: "externaldrive.fill")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                ForEach(s.parityDisks + s.dataDisks) { d in
                    DeviceRow(d: d)
                    if d.id != s.dataDisks.last?.id { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

/// One drive: status dot, slot and model, size, temperature, then its filesystem's fill (or its role for parity).
private struct DeviceRow: View {
    let d: UnraidSnapshot.Device
    var showFill = true

    var body: some View {
        GridRow(alignment: .center) {
            Circle().fill(dot).frame(width: 8, height: 8).help(d.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(slotTitle(d.name)).fontWeight(.medium)
                Text([d.device, d.model].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
            }
            .frame(minWidth: 150, alignment: .leading)
            Text(Format.storage(d.sizeBytes)).monospacedDigit().foregroundStyle(Theme.textSecondary)
                .gridColumnAlignment(.trailing)
            temperature.gridColumnAlignment(.trailing)
            if showFill { fill }
            errors
        }
        .font(.system(size: 13))
    }

    private var dot: Color {
        if d.status != "DISK_OK" { return Theme.danger }
        if d.errors > 0 { return Theme.warn }
        return d.spunDown ? Theme.idle : Theme.ok
    }

    @ViewBuilder private var temperature: some View {
        if let t = d.temperature {
            Label(Format.celsius(Double(t)), systemImage: "thermometer.medium")
                .foregroundStyle(levelTint(d.temperatureLevel)).monospacedDigit()
                .help("Warns at \(d.temperatureLimits.warning) °C, critical at \(d.temperatureLimits.critical) °C")
        } else if d.spunDown {
            Label("Standby", systemImage: "moon.zzz").foregroundStyle(Theme.textMuted)
                .help("Spun down. Rackoon reads Unraid's own record, so it never wakes the drive.")
        } else {
            Text("—").foregroundStyle(Theme.textMuted)
        }
    }

    @ViewBuilder private var fill: some View {
        if let fs = d.filesystem {
            HStack(spacing: 10) {
                FillBar(fraction: fs.usedFraction, tint: fillTint(fs.usedFraction) ?? Theme.accent).frame(minWidth: 90, maxWidth: .infinity)
                Text("\(fs.usePercent)%").monospacedDigit().frame(width: 38, alignment: .trailing)
                Text("\(Format.storage(fs.freeBytes)) free").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                    .monospacedDigit().frame(minWidth: 84, alignment: .leading)
            }
            .help("\(fs.type.uppercased()) · \(Format.storage(fs.usedBytes)) used of \(Format.storage(fs.totalBytes)) · \(fs.mount)")
        } else {
            Text(d.role == .parity ? "Parity protection" : "Pool member")
                .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
        }
    }

    @ViewBuilder private var errors: some View {
        if d.errors > 0 {
            Text("\(d.errors) errors").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warn)
        } else {
            Text("No errors").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
        }
    }
}

/// Cache and other pools with their members, then the boot flash drive.
private struct PoolsCard: View {
    let s: UnraidSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "Pools & boot", note: s.pools.isEmpty ? "no pools" : "\(s.pools.count) pool\(s.pools.count == 1 ? "" : "s")",
                       symbol: "memorychip")
            ForEach(s.pools) { pool in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(slotTitle(pool.name)).fontWeight(.semibold)
                        if let kind = pool.kind {
                            Text(kind).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                        }
                        if let health = pool.health {
                            Badge(text: health, color: health == "ONLINE" ? Theme.ok : Theme.danger)
                        }
                        Spacer()
                        if let fs = pool.filesystem {
                            Text("\(Format.storage(fs.usedBytes)) of \(Format.storage(fs.totalBytes))")
                                .font(.system(size: 12)).foregroundStyle(Theme.textMuted).monospacedDigit()
                        }
                    }
                    if let fs = pool.filesystem { FillBar(fraction: fs.usedFraction, tint: fillTint(fs.usedFraction) ?? Theme.accent) }
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                        ForEach(pool.devices) { DeviceRow(d: $0, showFill: false) }
                    }
                }
            }
            if let flash = s.flash {
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "mediastick").foregroundStyle(Theme.textMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Boot flash").fontWeight(.medium)
                        Text([flash.device, flash.model].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                    Spacer()
                    if let fs = flash.filesystem {
                        Text("\(Format.storage(fs.usedBytes)) of \(Format.storage(fs.totalBytes))")
                            .font(.system(size: 12)).foregroundStyle(Theme.textMuted).monospacedDigit()
                    }
                    Circle().fill(flash.status == "DISK_OK" ? Theme.ok : Theme.danger).frame(width: 8, height: 8)
                }
                .font(.system(size: 13))
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

/// CPU temperature, the other board sensors and the fans.
private struct SensorsCard: View {
    let s: UnraidSnapshot
    let cores: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Temperatures & fans", symbol: "thermometer.medium")
            if let cpu = s.cpuTemperature {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CPU").fontWeight(.medium)
                        if !s.cpuModel.isEmpty {
                            Text(s.cpuModel).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(Format.celsius(cpu)).font(.system(size: 24, weight: .bold)).monospacedDigit().foregroundStyle(cpuTint(cpu))
                }
            }
            let drives = (s.parityDisks + s.dataDisks + s.pools.flatMap(\.devices)).compactMap(\.temperature)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                if let hottest = drives.max() {
                    row("Drives", value: "\(Format.celsius(Double(drives.min() ?? hottest))) – \(Format.celsius(Double(hottest)))",
                        note: "\(drives.count) reporting")
                }
                ForEach(Array(s.boardSensors.enumerated()), id: \.offset) { _, sensor in
                    row(sensor.name, value: Format.celsius(sensor.celsius))
                }
                ForEach(Array(s.spinningFans.enumerated()), id: \.offset) { i, fan in
                    row(fan.label.isEmpty || fan.label.hasPrefix("fan") ? "Fan \(i + 1)" : fan.label,
                        value: "\(Int(fan.value)) RPM", symbol: "fanblades")
                }
            }
            .font(.system(size: 13))
            if s.cpuTemperature == nil, s.boardSensors.isEmpty, s.spinningFans.isEmpty {
                Text("This server reports no temperature or fan sensors.").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func row(_ name: String, value: String, note: String = "", symbol: String? = nil) -> some View {
        GridRow {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Theme.textMuted) }
                Text(name).foregroundStyle(Theme.textSecondary)
            }
            Text(note).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            Text(value).monospacedDigit().gridColumnAlignment(.trailing).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// The last parity checks from Unraid's log, newest first.
private struct ParityHistoryCard: View {
    let s: UnraidSnapshot
    let utcOffset: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Parity checks", note: lastNote, symbol: "checkmark.shield")
            if s.parityChecks.isEmpty {
                Text(s.parityDisks.isEmpty ? "No parity disk is assigned." : "No parity check has been recorded yet.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                    ForEach(Array(s.parityChecks.suffix(6).reversed().enumerated()), id: \.offset) { _, check in
                        GridRow {
                            Image(systemName: check.completed ? (check.errors == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill") : "xmark.circle")
                                .foregroundStyle(check.completed ? (check.errors == 0 ? Theme.ok : Theme.warn) : Theme.textMuted)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(date(check))
                                Text(check.label + (check.completed ? "" : " · cancelled"))
                                    .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                            }
                            Text(Format.uptime(Double(check.durationSeconds))).foregroundStyle(Theme.textSecondary)
                                .gridColumnAlignment(.trailing)
                            Text(check.bytesPerSecond > 0 ? "\(Format.storage(check.bytesPerSecond))/s" : "—")
                                .foregroundStyle(Theme.textSecondary).gridColumnAlignment(.trailing)
                            Text(check.errors == 0 ? "0 errors" : "\(check.errors) errors")
                                .foregroundStyle(check.errors == 0 ? Theme.textMuted : Theme.warn).gridColumnAlignment(.trailing)
                        }
                        .font(.system(size: 12)).monospacedDigit()
                    }
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private var lastNote: String {
        guard let last = s.parityChecks.last(where: \.completed), let date = last.finishedDate(utcOffsetSeconds: utcOffset) else { return "" }
        return "last completed \(date.formatted(.relative(presentation: .named)))"
    }

    private func date(_ check: UnraidSnapshot.ParityCheck) -> String {
        check.finishedDate(utcOffsetSeconds: utcOffset)?.formatted(date: .abbreviated, time: .shortened) ?? check.finished
    }
}

/// User shares: where new files land and how much each holds.
private struct SharesCard: View {
    let s: UnraidSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Shares", note: "\(s.shares.count) user share\(s.shares.count == 1 ? "" : "s")", symbol: "folder.fill")
            if s.shares.isEmpty {
                Text("No user shares.").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                    ForEach(s.shares.sorted { $0.name.lowercased() < $1.name.lowercased() }) { share in
                        GridRow {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(share.name).fontWeight(.medium).lineLimit(1)
                                if !share.comment.isEmpty {
                                    Text(share.comment).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
                                }
                            }
                            Text(share.placement).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                                .help("Unraid's \"use cache\" setting: where new files are written")
                            Text("\(Format.storage(share.freeBytes)) free").monospacedDigit().foregroundStyle(Theme.textSecondary)
                                .gridColumnAlignment(.trailing)
                                .help("Free space where this share's files can go")
                        }
                        .font(.system(size: 12))
                    }
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).card()
    }
}
