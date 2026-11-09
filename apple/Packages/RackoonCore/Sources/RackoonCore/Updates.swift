import Foundation

/// Mirrors `UpdatesSnapshot` in spec/models.schema.json: one parsed reading of the `updates` command.
public struct PendingUpdate: Sendable, Codable, Equatable, Identifiable {
    public var name: String
    /// apt's suite list, e.g. "noble-updates,noble-security".
    public var suite: String
    public var newVersion: String
    public var oldVersion: String?
    public var architecture: String
    public var isSecurity: Bool

    public var id: String { name + ":" + architecture }
}

public struct UpdatesSnapshot: Sendable, Codable, Equatable {
    /// Upgrades apt would install now. Held, phased and kept-back packages are in `waiting` instead, so a server
    /// that has everything apt will give it reads as up to date.
    public var packages: [PendingUpdate]
    /// Upgradable, but apt is not installing them yet: held, deferred by Ubuntu's phased rollout, or kept back because
    /// they need a removal (which Rackoon never does). See `waitingReason(_:)`.
    public var waiting: [PendingUpdate]
    /// Names apt defers for its phased rollout.
    public var phased: [String]
    /// Packages pinned with `apt-mark hold`; apt will not upgrade them.
    public var held: [String]
    /// Unix time the package lists were last refreshed, when the server says.
    public var refreshedAt: Int64?
    public var rebootRequired: Bool

    public init(packages: [PendingUpdate], waiting: [PendingUpdate] = [], phased: [String] = [], held: [String],
                refreshedAt: Int64?, rebootRequired: Bool) {
        self.packages = packages
        self.waiting = waiting
        self.phased = phased
        self.held = held
        self.refreshedAt = refreshedAt
        self.rebootRequired = rebootRequired
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        packages = try c.decode([PendingUpdate].self, forKey: .packages)
        waiting = try c.decodeIfPresent([PendingUpdate].self, forKey: .waiting) ?? []
        phased = try c.decodeIfPresent([String].self, forKey: .phased) ?? []
        held = try c.decode([String].self, forKey: .held)
        refreshedAt = try c.decodeIfPresent(Int64.self, forKey: .refreshedAt)
        rebootRequired = try c.decode(Bool.self, forKey: .rebootRequired)
    }

    public var securityCount: Int { packages.filter(\.isSecurity).count }

    public enum WaitingReason: Sendable, Equatable {
        case held, phased, keptBack

        /// One line for the Updates screen.
        public var explanation: String {
            switch self {
            case .held: "Held with apt-mark hold, so apt leaves it alone."
            case .phased: "Ubuntu is rolling this update out gradually (a phased update); apt installs it when this server's turn comes."
            case .keptBack: "Kept back: it needs a package removed, which only a full upgrade (apt full-upgrade) does. Rackoon never removes packages."
            }
        }

        public var label: String {
            switch self {
            case .held: "Held"
            case .phased: "Phased rollout"
            case .keptBack: "Kept back"
            }
        }
    }

    /// Why a package in `waiting` is waiting.
    public func waitingReason(_ p: PendingUpdate) -> WaitingReason {
        if held.contains(p.name) { return .held }
        if phased.contains(p.name) { return .phased }
        return .keptBack
    }
}

public enum UpdatesParseError: Error, Equatable {
    case notInstalled
    case malformed(String)
}
