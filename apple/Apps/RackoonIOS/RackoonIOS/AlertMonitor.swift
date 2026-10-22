import Foundation
import Observation
import RackoonCore
import Security

/// One server as the alerts see it: its latest reading and whether polling is blocked.
struct AlertRow {
    let server: Server
    let state: ServerState
    /// Why the server is not polled (the host key, a missing secret), or nil.
    let blocked: String?

    var isOnline: Bool { blocked == nil && state.error == nil && state.overview != nil && !state.isStale }
}

/// The alerts of every saved server (`AlertBook`, Core), kept while the app is open on the screen. An iPhone can't poll
/// in the background, so this is the Mac's `AlertMonitor` in the foreground only: every 15 s it reads what the polls
/// already have (connection and Overview attention items, the services scan), and every 5 minutes it checks each
/// answering server: the services scan, a light container check (`docker_states`, through sudo only while Docker is
/// unlocked) and, every 6 hours, the TLS certificates of the https bookmarks found on its containers. Everything is
/// read-only. No notifications (they need a push relay). The book is saved as alerts.json on this device.
@MainActor @Observable
final class AlertMonitor {
    private(set) var book: AlertBook
    /// Servers being checked right now (the Check Now spinner).
    private(set) var checking: Set<String> = []
    private(set) var lastSweep: [String: Date] = [:]
    /// False until the first look after launch, so the screen doesn't say "nothing needs you" before anything was read.
    private(set) var hasLooked = false

    struct Dependencies {
        var rows: @MainActor () -> [AlertRow]
        /// The server's services model (made if needed), or nil when it can't be read yet.
        var services: @MainActor (Server) -> ServicesModel?
        var isWatched: @MainActor (DiscoveredService, String) -> Bool
        /// The transport Docker is read with (through sudo while unlocked), or nil.
        var dockerTransport: @MainActor (Server) -> SSHTransport?
        var certificate: @Sendable (String) async -> CertificateCheck = CertificateProbe.check
        var now: @Sendable () -> Date = { Date() }
    }

    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let deps: Dependencies
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var applied: [String: Date] = [:]
    @ObservationIgnored private var containerReadings: [String: (DockerStatesReading, Date)] = [:]
    @ObservationIgnored private var certificates: [String: ([CertificateCheck], Date)] = [:]
    @ObservationIgnored private var lastCertificateCheck: [String: Date] = [:]
    /// Certificates are fetched from the real sites, so never in demo mode.
    @ObservationIgnored var checksCertificates = true

    static let tick: Duration = .seconds(15)
    static let sweepInterval: TimeInterval = 5 * 60
    static let certificateInterval: TimeInterval = 6 * 3600

    /// `file` nil keeps the book in memory only (demo mode, tests).
    init(file: URL?, dependencies: Dependencies) {
        self.file = file
        deps = dependencies
        book = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(AlertBook.self, from: $0) } ?? AlertBook()
    }

    /// Starts watching while the app is in the foreground.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            // Give the first polls a moment, so the first look is a full one.
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await self?.tickOnce()
                try? await Task.sleep(for: Self.tick)
            }
        }
    }

    /// Stops in the background (iOS suspends the app soon anyway).
    func stop() {
        loop?.cancel()
        loop = nil
    }

    func tickOnce() async {
        let rows = deps.rows()
        evaluate(rows)
        let now = deps.now()
        for row in rows where row.isOnline && !checking.contains(row.server.id) {
            if now.timeIntervalSince(lastSweep[row.server.id] ?? .distantPast) >= Self.sweepInterval {
                Task { await sweep(row) }
            }
        }
    }

    /// Checks one server now (Check Now), or every answering server.
    func checkNow(_ server: Server? = nil) {
        for row in deps.rows() where row.isOnline && (server == nil || row.server.id == server?.id) && !checking.contains(row.server.id) {
            Task { await sweep(row, certificatesToo: true) }
        }
    }

    // MARK: reading what the app has

    func evaluate(_ rows: [AlertRow]) {
        hasLooked = true
        let before = book
        let now = deps.now()
        for row in rows {
            let id = row.server.id, name = row.server.name
            func apply(_ source: AlertSource, _ signals: [AlertSignal]) {
                _ = book.apply(server: id, serverName: name, source: source, signals: signals, at: now)
            }
            // The connection, once there is any reading at all.
            if row.blocked != nil || row.state.error != nil || (row.state.overview != nil && !row.state.isStale) {
                apply(.connection, AlertRules.connection(error: row.state.error, blocked: row.blocked))
            }
            if let o = row.state.overview, !row.state.isStale, row.state.error == nil {
                apply(.overview, AlertRules.overview(o))
            }
            if row.isOnline, let services = deps.services(row.server), let snapshot = services.snapshot,
               let at = services.updatedAt, isNew(id, .services, at) {
                apply(.services, AlertRules.services(snapshot) { [deps] in deps.isWatched($0, id) })
            }
            if let (reading, at) = containerReadings[id], isNew(id, .containers, at) {
                apply(.containers, AlertRules.containers(reading))
            }
            if let (checks, at) = certificates[id], isNew(id, .certificates, at) {
                apply(.certificates, AlertRules.certificates(checks, now: now))
            }
        }
        if book != before { save() }
    }

    /// True once per reading: each one is applied once, so `lastSeen` means "a check saw it".
    private func isNew(_ server: String, _ source: AlertSource, _ at: Date) -> Bool {
        let key = "\(server)|\(source.rawValue)"
        guard (applied[key] ?? .distantPast) < at else { return false }
        applied[key] = at
        return true
    }

    // MARK: checks

    func sweep(_ row: AlertRow, certificatesToo: Bool = false) async {
        let server = row.server
        checking.insert(server.id)
        defer {
            checking.remove(server.id)
            lastSweep[server.id] = deps.now()
            evaluate(deps.rows())
        }
        await deps.services(server)?.refresh()
        guard let transport = deps.dockerTransport(server),
              let reading = await DockerStatesSession(transport: transport).read() else { return }
        containerReadings[server.id] = (reading, deps.now())
        let due = deps.now().timeIntervalSince(lastCertificateCheck[server.id] ?? .distantPast) >= Self.certificateInterval
        guard due || certificatesToo, checksCertificates else { return }
        let targets = CertificateCheck.targets(reading.containers.map(\.href))
        lastCertificateCheck[server.id] = deps.now()
        var checks: [CertificateCheck] = []
        for url in targets { checks.append(await deps.certificate(url)) }
        certificates[server.id] = (checks, deps.now())
    }

    /// The last container reading of a server (search uses it when no Docker screen has one).
    func containerReading(for serverID: String) -> DockerStatesReading? { containerReadings[serverID]?.0 }

    // MARK: what the screens do

    func acknowledge(_ alert: ServerAlert, _ seen: Bool = true) { book.acknowledge(alert.id, seen); save() }
    func acknowledgeAll(server: String? = nil) { book.acknowledgeAll(server: server); save() }
    func mute(_ alert: ServerAlert, _ on: Bool = true) { book.mute(alert.id, on); save() }
    func clearHistory(server: String? = nil) { book.clearHistory(server: server); save() }

    /// A removed server's alerts go with it.
    func forget(serverID: String) {
        if book.forget(serverID: serverID) { save() }
        for key in applied.keys where key.hasPrefix(serverID + "|") { applied[key] = nil }
        containerReadings[serverID] = nil
        certificates[serverID] = nil
        lastSweep[serverID] = nil
        lastCertificateCheck[serverID] = nil
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(book) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

// MARK: - Certificates

/// Reads a site's TLS certificate expiry from the phone. Only the handshake happens: the connection is cancelled as soon
/// as the certificate is seen, so no page is requested. Untrusted (self-signed) certificates are read too, and never
/// trusted. The expiry date can be read on iOS 18 and later; on iOS 17 the check reports no date (and raises nothing).
enum CertificateProbe {
    @Sendable static func check(_ url: String) async -> CertificateCheck {
        let host = URL(string: url)?.host ?? url
        guard let target = URL(string: url) else { return CertificateCheck(url: url, host: host, expires: nil, checkedAt: Date()) }
        let catcher = TrustCatcher()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: catcher, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: target)
        request.httpMethod = "HEAD"
        _ = try? await session.data(for: request)
        return CertificateCheck(url: url, host: host, expires: catcher.expires, checkedAt: Date())
    }

    private final class TrustCatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Date?
        var expires: Date? { lock.withLock { stored } }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
                return (.cancelAuthenticationChallenge, nil)
            }
            if #available(iOS 18.0, *) {
                let date = SecCertificateCopyNotValidAfterDate(leaf) as Date?
                lock.withLock { stored = date }
            }
            return (.cancelAuthenticationChallenge, nil)
        }
    }
}
