import Foundation
import Observation
import RackoonCore

/// One server's Security reading: the read-only `security` command, run when the screen opens (if the last reading is
/// older than `freshFor`) and on Check Now. No background polling. Kept per connection by `SecurityStore`, so switching
/// screens shows the last reading at once.
@MainActor @Observable
final class SecurityModel {
    private(set) var snapshot: SecuritySnapshot?
    private(set) var checkedAt: Date?
    private(set) var error: String?
    private(set) var loading = false

    /// The opt-in vulnerability lookup (S3): nil until it has run.
    private(set) var vulnerabilities: [VulnerabilityFinding]?
    private(set) var vulnerabilitiesCheckedAt: Date?
    private(set) var vulnerabilityError: String?
    private(set) var lookingUp = false
    /// False when the server is not a Debian or Ubuntu release OSV knows (testing, derivatives, Unraid).
    private(set) var lookupSupported = true

    /// A reading younger than this is shown as it is when the screen opens again.
    static let freshFor: TimeInterval = 5 * 60

    @ObservationIgnored private let transport: SSHTransport

    init(transport: SSHTransport) { self.transport = transport }

    /// Reads again unless a reading is fresh (or `force`).
    func load(force: Bool = false, now: Date = Date()) {
        guard !loading else { return }
        if !force, let checkedAt, now.timeIntervalSince(checkedAt) < Self.freshFor { return }
        // A reading made with sudo knows more; only Check Now replaces it, so its findings (and their alerts) do not
        // vanish just because a plain reading cannot see them.
        if !force, deep { return }
        // Busy from this moment, so the screen (and a caller waiting on it) never sees an idle gap before the read starts.
        loading = true
        Task { await read(using: transport, deep: false, started: true) }
    }

    /// The last reading was made as root through sudo (Check Deeper), so sshd's effective settings, every container and
    /// /etc/shadow were read. A later plain reading replaces it.
    private(set) var deep = false

    /// Reads now (the alert sweep awaits it). Does nothing while a read is running.
    func refresh() async { await read(using: transport, deep: false) }

    /// The same read-only checks as root, through a transport that runs them under sudo (docs/security-plan.md: only
    /// when the user asks, never on its own).
    func refreshDeeper(using sudo: SSHTransport) async { await read(using: sudo, deep: true) }

    private func read(using transport: SSHTransport, deep: Bool, started: Bool = false) async {
        if !started {
            guard !loading else { return }
            loading = true
        }
        defer { loading = false }
        do {
            snapshot = try await SecuritySession.read(transport)
            checkedAt = Date()
            error = nil
            self.deep = deep && snapshot?.isRoot == true
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Lists the installed packages and the pending updates (both read-only), then asks OSV.dev. Call only when the user
    /// turned the lookup on for this server (`VulnerabilityLookupSettings`).
    func lookUpVulnerabilities() async {
        guard !lookingUp else { return }
        lookingUp = true
        defer { lookingUp = false }
        do {
            let inventory = try await PackageInventory.read(transport)
            guard OSV.ecosystem(id: inventory.os.id, version: inventory.os.version) != nil else {
                lookupSupported = false
                vulnerabilities = nil
                vulnerabilityError = nil
                return
            }
            lookupSupported = true
            let updates = await UpdatesSession(transport: transport).refresh()
            let pending = (updates.snapshot?.packages ?? []).map { PendingPackage(name: $0.name, newVersion: $0.newVersion) }
            vulnerabilities = try await VulnerabilityLookup.run(inventory, pending: pending, client: OSVShared.client, cache: OSVShared.cache)
            vulnerabilitiesCheckedAt = Date()
            vulnerabilityError = nil
        } catch {
            vulnerabilityError = error.localizedDescription
        }
    }

    /// Forgets the last lookup (the user turned it off).
    func clearVulnerabilities() {
        vulnerabilities = nil
        vulnerabilitiesCheckedAt = nil
        vulnerabilityError = nil
    }

    /// The findings for the last reading, with what the Overview poll knows (security updates, reboot flag).
    func findings(_ context: SecurityContext) -> [SecurityFinding] {
        guard let snapshot else { return [] }
        return SecurityRules.evaluate(snapshot, context: context)
    }

    /// What the Overview already polls, for the update checks; nil fields when there is no reading yet.
    static func context(_ overview: Overview?) -> SecurityContext {
        SecurityContext(pendingSecurityUpdates: overview?.securityUpdates, rebootRequired: overview?.rebootRequired)
    }
}

/// One `SecurityModel` per connection (an edited address gets a new one).
@MainActor
final class SecurityStore {
    static let shared = SecurityStore()
    private var models: [String: SecurityModel] = [:]

    /// The model if one exists, without making one (the alert monitor only reads what is there).
    func existingModel(for server: Server) -> SecurityModel? { models[server.connectionKey] }

    func model(for server: Server) -> SecurityModel {
        if let model = models[server.connectionKey] { return model }
        let model = SecurityModel(transport: makeTransport(for: server))
        models[server.connectionKey] = model
        return model
    }
}
