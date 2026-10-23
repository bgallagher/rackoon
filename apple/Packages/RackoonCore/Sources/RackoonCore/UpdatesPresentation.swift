import Foundation

/// What the confirm sheet and the Output panel say about one apt action (the Mac's `UpdatesModel.request` wording).
public struct AptPrompt: Sendable, Equatable {
    public var title: String
    public var message: String
    public var workingLabel: String
    public var outputTitle: String
}

/// Pure presentation rules of the Updates screen, shared by the phone apps and tested (the same as `UpdatesPresentation`
/// in the Kotlin core).
public enum UpdatesPresentation {
    /// Updates are read from apt's local cache, so lists older than this may be missing newer updates.
    public static let staleAfterSeconds: Int64 = 3 * 86_400

    public static func subtitle(_ s: UpdatesSnapshot) -> String {
        if s.packages.isEmpty { return "Everything is up to date" }
        let n = s.packages.count
        let base = "\(n) update\(n == 1 ? "" : "s") available"
        return s.securityCount > 0 ? "\(base), \(s.securityCount) security" : base
    }

    /// "3 days ago", "2 hours ago"… for a time `seconds` in the past.
    public static func relativeAge(_ seconds: Int64) -> String {
        let s = max(seconds, 0)
        func unit(_ n: Int64, _ name: String) -> String { "\(n) \(name)\(n == 1 ? "" : "s") ago" }
        if s < 60 { return "just now" }
        if s < 3600 { return unit(s / 60, "minute") }
        if s < 86_400 { return unit(s / 3600, "hour") }
        if s < 30 * 86_400 { return unit(s / 86_400, "day") }
        return unit(s / (30 * 86_400), "month")
    }

    public static func refreshedText(_ s: UpdatesSnapshot, now: Int64) -> String {
        s.refreshedAt.map { relativeAge(now - $0) } ?? "unknown"
    }

    /// A warning when the package lists are old, else nil.
    public static func staleness(_ s: UpdatesSnapshot, now: Int64) -> String? {
        guard let t = s.refreshedAt, now - t > staleAfterSeconds else { return nil }
        return "Package lists were refreshed \(relativeAge(now - t)). Refresh them to see newer updates."
    }

    /// Security updates first, then by name.
    public static func sorted(_ packages: [PendingUpdate]) -> [PendingUpdate] {
        packages.sorted { ($0.isSecurity ? 0 : 1, $0.name) < ($1.isSecurity ? 0 : 1, $1.name) }
    }

    public static func securityNames(_ packages: [PendingUpdate]) -> [String] { sorted(packages).filter(\.isSecurity).map(\.name) }

    /// "Install security updates" needs an explicit list, which is capped; beyond the cap use Install All.
    public static func canInstallSecurity(_ packages: [PendingUpdate]) -> Bool {
        let n = securityNames(packages).count
        return n > 0 && n <= AptAction.maxPackages
    }

    /// Why the Install Security Updates button is off, or nil when it can be used.
    public static func installSecurityHint(_ packages: [PendingUpdate], readOnly: Bool) -> String? {
        if readOnly { return "Read-only mode is on" }
        if securityNames(packages).isEmpty { return "No security updates" }
        if !canInstallSecurity(packages) { return "Too many to list one by one; use Install All" }
        return nil
    }

    public static func prompt(_ action: AptAction, packageCount: Int, securityCount: Int) -> AptPrompt {
        switch action {
        case .refresh:
            return AptPrompt(title: "Refresh package lists?", message: "Checks the repositories for new versions. Nothing is installed.",
                             workingLabel: "Refreshing package lists…", outputTitle: "apt-get update")
        case .upgradeAll:
            return AptPrompt(title: "Install all \(packageCount) updates?",
                             message: "Held packages stay as they are and existing config files are kept. Some updates may ask for a reboot afterwards.",
                             workingLabel: "Installing \(packageCount) updates…", outputTitle: "apt-get upgrade")
        case .upgrade(let names):
            return AptPrompt(
                title: "Install \(securityCount) security update\(securityCount == 1 ? "" : "s")?",
                message: "Only these packages are upgraded: \(names.prefix(6).joined(separator: ", "))\(names.count > 6 ? " and \(names.count - 6) more" : "").",
                workingLabel: "Installing security updates…",
                outputTitle: "apt-get install --only-upgrade (\(names.count) package\(names.count == 1 ? "" : "s"))")
        }
    }
}
