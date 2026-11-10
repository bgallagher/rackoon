import Foundation

/// Which servers have Docker unlocked through sudo, until when, and why one was locked. Pure (the clock is passed in),
/// so the rules are tested; the app's `DockerElevation` adds the timer and SwiftUI observation.
public struct ElevationWindow: Sendable {
    public struct Unlock: Sendable, Equatable {
        public let password: String
        public let until: Date
        /// Kept until the app quits (or the user locks it) rather than for a fixed time.
        public var lastsUntilQuit: Bool { until == .distantFuture }
    }

    /// How long an unlock lasts, as offered to the user. The raw value is minutes; 0 means until the app quits.
    public enum Lasting: Int, Sendable, CaseIterable, Identifiable {
        case fifteenMinutes = 15
        case oneHour = 60
        case eightHours = 480
        case untilQuit = 0

        public static let standard = Lasting.fifteenMinutes
        public var id: Int { rawValue }

        /// Seconds, or nil for until the app quits.
        public var seconds: TimeInterval? { self == .untilQuit ? nil : TimeInterval(rawValue * 60) }

        public var title: String {
            switch self {
            case .fifteenMinutes: "15 minutes"
            case .oneHour: "1 hour"
            case .eightHours: "8 hours"
            case .untilQuit: "Until Rackoon quits"
            }
        }
    }

    /// Like sudo's own default grace period.
    public static let defaultLength: TimeInterval = 15 * 60

    public let length: TimeInterval
    private var unlocks: [String: Unlock] = [:]
    private var generations: [String: Int] = [:]
    public private(set) var lockReasons: [String: String] = [:]

    public init(length: TimeInterval = ElevationWindow.defaultLength) { self.length = length }

    /// Unlocks `serverID` from `now` for `length`, or for `lasting` when given. Replaces an earlier unlock and clears the
    /// last lock reason.
    public mutating func unlock(_ serverID: String, password: String, now: Date, lasting: Lasting? = nil) {
        let until: Date
        switch lasting {
        case nil: until = now.addingTimeInterval(length)
        case .untilQuit?: until = .distantFuture
        case let other?: until = now.addingTimeInterval(other.seconds ?? length)
        }
        unlocks[serverID] = Unlock(password: password, until: until)
        lockReasons[serverID] = nil
        generations[serverID, default: 0] += 1
    }

    /// Locks now. Does nothing (not even a new generation) if it was not unlocked.
    public mutating func lock(_ serverID: String, reason: String? = nil) {
        guard unlocks.removeValue(forKey: serverID) != nil else { return }
        lockReasons[serverID] = reason
        generations[serverID, default: 0] += 1
    }

    /// The unlock that is still valid at `now`, if any. An expired one is never returned.
    public func active(_ serverID: String, at now: Date) -> Unlock? {
        guard let unlock = unlocks[serverID], unlock.until > now else { return nil }
        return unlock
    }

    /// Changes whenever the server's access changes: views and models holding a connection are keyed by it.
    public func generation(_ serverID: String) -> Int { generations[serverID] ?? 0 }
}

extension Attention {
    /// The notice that a Reboot… button belongs on (the server's own reboot-required flag).
    public static let rebootRequiredID = "reboot_required"

    public static func offersReboot(_ item: AttentionItem) -> Bool { item.id == rebootRequiredID }
}
