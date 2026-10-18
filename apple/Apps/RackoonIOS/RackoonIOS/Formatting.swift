import Foundation
import RackoonCore
import SwiftUI

/// Small, testable presentation rules shared by the Overview and the dashboard.
enum Present {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// "27d 9h", "3h 12m", "45m".
    static func uptime(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// The server's own clock now: its reading at the poll plus the time since, shown in its own zone.
    static func serverClock(_ overview: Overview, polledAt: Date, now: Date) -> String {
        let seconds = TimeInterval(overview.serverTime) + now.timeIntervalSince(polledAt)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: overview.utcOffsetSeconds)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let offset = overview.utcOffsetSeconds
        let sign = offset < 0 ? "-" : "+"
        let utc = String(format: "UTC%@%02d:%02d", sign, abs(offset) / 3600, (abs(offset) % 3600) / 60)
        let zone = overview.timeZoneName.isEmpty ? utc : "\(overview.timeZoneName), \(utc)"
        return "\(f.string(from: Date(timeIntervalSince1970: seconds))) (\(zone))"
    }

    /// What the reading is: live, cached from an earlier run, or not there yet.
    static func freshness(_ state: ServerState, now: Date) -> String {
        guard let at = state.updatedAt else { return "Not read yet" }
        let ago = max(0, now.timeIntervalSince(at))
        let when = ago < 10 ? "just now" : ago < 60 ? "\(Int(ago))s ago" : ago < 3600 ? "\(Int(ago / 60))m ago" : ago < 86400 * 2 ? "\(Int(ago / 3600))h ago" : "\(Int(ago / 86400))d ago"
        if state.isStale { return "Saved reading from \(when)" }
        if ago < 10 { return "Live" }
        return "Updated \(when)"
    }

    /// The fullest disk, which is the one a dashboard tile shows.
    static func fullestDisk(_ overview: Overview) -> Overview.Disk? { overview.disks.max { $0.usePercent < $1.usePercent } }
}

/// Answering (green), not answering (red), or unknown / not read live (grey).
enum Liveness: Equatable {
    case up, down, unknown

    init(_ state: ServerState) {
        if state.error != nil { self = .down } else if state.overview != nil, !state.isStale { self = .up } else { self = .unknown }
    }
}

extension AttentionItem.Severity {
    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }
}
