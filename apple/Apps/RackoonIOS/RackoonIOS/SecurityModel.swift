import Foundation
import Observation
import RackoonCore
import RackoonDemo

/// One server's Security reading (as on the Mac): the read-only `security` command when the screen opens (if the last
/// reading is over 5 minutes old) and on Check Now, hourly from the alert sweep; Check Deeper runs it once through sudo,
/// and only Check Now replaces that deeper reading. The opt-in vulnerability lookup sends package names and versions to
/// OSV.dev from the phone, only when the user turned it on.
@MainActor @Observable
final class SecurityModel {
    private(set) var snapshot: SecuritySnapshot?
    private(set) var checkedAt: Date?
    private(set) var error: String?
    private(set) var loading = false
    private(set) var deep = false

    private(set) var vulnerabilities: [VulnerabilityFinding]?
    private(set) var vulnerabilitiesCheckedAt: Date?
    private(set) var vulnerabilityError: String?
    private(set) var lookingUp = false
    private(set) var lookupSupported = true

    static let freshFor: TimeInterval = 5 * 60

    @ObservationIgnored private let transport: SSHTransport
    @ObservationIgnored private let osv: OSVClient

    init(transport: SSHTransport, osv: OSVClient) {
        self.transport = transport
        self.osv = osv
    }

    func load(force: Bool = false, now: Date = Date()) {
        guard !loading else { return }
        if !force, let checkedAt, now.timeIntervalSince(checkedAt) < Self.freshFor { return }
        if !force, deep { return }
        // Busy from this moment, so the screen (and a caller waiting on it) never sees an idle gap before the read starts.
        loading = true
        Task { await read(using: transport, deep: false, started: true) }
    }

    func refresh() async { await read(using: transport, deep: false) }

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
            vulnerabilities = try await VulnerabilityLookup.run(inventory, pending: pending, client: osv, cache: OSVShared.cache)
            vulnerabilitiesCheckedAt = Date()
            vulnerabilityError = nil
        } catch {
            vulnerabilityError = error.localizedDescription
        }
    }

    func clearVulnerabilities() {
        vulnerabilities = nil
        vulnerabilitiesCheckedAt = nil
        vulnerabilityError = nil
    }

    func findings(_ context: SecurityContext) -> [SecurityFinding] {
        guard let snapshot else { return [] }
        return SecurityRules.evaluate(snapshot, context: context)
    }

    static func context(_ overview: Overview?) -> SecurityContext {
        SecurityContext(pendingSecurityUpdates: overview?.securityUpdates, rebootRequired: overview?.rebootRequired)
    }
}

/// Whether the vulnerability lookup may send a server's package list to OSV.dev: off until turned on for one server or
/// for all (defaults `osvLookupAll`, `osvLookupServers`, as on the Mac). In demo mode it starts off and is never saved,
/// so trying it there can never turn it on for the real servers.
@MainActor @Observable
final class VulnerabilityLookupSettings {
    static let allKey = "osvLookupAll"
    static let serversKey = "osvLookupServers"
    static let privacyNote = "Sends this server's package names and versions (nothing else: no host names or addresses) from this phone to OSV.dev, a vulnerability database run by Google. Answers are kept for a day."

    private(set) var all: Bool
    private(set) var servers: Set<String>
    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        all = defaults?.bool(forKey: Self.allKey) ?? false
        servers = Set(defaults?.stringArray(forKey: Self.serversKey) ?? [])
    }

    func isOn(_ id: String) -> Bool { all || servers.contains(id) }
    func set(_ on: Bool, server id: String) { if on { servers.insert(id) } else { servers.remove(id) }; save() }
    func setAll(_ on: Bool) { all = on; save() }
    func forget(serverID: String) { if servers.remove(serverID) != nil { save() } }

    private func save() {
        defaults?.set(all, forKey: Self.allKey)
        defaults?.set(servers.sorted(), forKey: Self.serversKey)
    }
}

/// OSV.dev over URLSession: no cookies, no credentials, normal certificate checks.
struct URLSessionOSVClient: OSVClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpAdditionalHeaders = ["User-Agent": "Rackoon"]
        return URLSession(configuration: config)
    }()

    func post(_ url: URL, body: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request)
    }

    func get(_ url: URL) async throws -> Data { try await send(URLRequest(url: url)) }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await Self.session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw OSVError.http(code) }
        return data
    }
}

enum OSVShared {
    static let cache = OSVCache()
}
