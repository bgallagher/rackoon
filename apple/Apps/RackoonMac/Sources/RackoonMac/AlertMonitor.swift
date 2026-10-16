import Foundation
import RackoonCore
import RackoonSSHSystem
import UserNotifications

/// Keeps the alerts of every saved server (`AlertBook`, Core) current while the app runs.
///
/// Every 15 s it reads what the app already has: each server's connection and Overview attention items (the selected
/// server's live poll, the others' once-a-minute poll), the services scan, and Unraid's array reading. Every 5 minutes it
/// also checks each answering server in the background: the services scan, a light container check (`docker_states`,
/// through sudo only while Docker is unlocked), Unraid's array, and every 6 hours the TLS certificates of the https
/// bookmarks found on its containers. Everything is read-only. The book is saved as alerts.json on this Mac.
@MainActor @Observable
final class AlertMonitor {
    static let shared = AlertMonitor(directory: Demo.isOn ? Demo.alertSettings : nil)

    private(set) var book: AlertBook
    /// Servers being checked right now (the Check Now spinner).
    private(set) var checking: Set<String> = []
    /// When each server was last checked in the background.
    private(set) var lastSweep: [String: Date] = [:]

    @ObservationIgnored private let file: URL
    @ObservationIgnored private var fleet: () -> [FleetRow] = { [] }
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var applied: [String: Date] = [:]          // "<server>|<source>" -> reading time applied
    @ObservationIgnored private var containerReadings: [String: (DockerStatesReading, Date)] = [:]
    @ObservationIgnored private var certificates: [String: ([CertificateCheck], Date)] = [:]
    @ObservationIgnored private var lastCertificateCheck: [String: Date] = [:]
    @ObservationIgnored private let notifier = AlertNotifier()

    static let tick: Duration = .seconds(15)
    static let sweepInterval: TimeInterval = 5 * 60
    static let certificateInterval: TimeInterval = 6 * 3600

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rackoon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("alerts.json")
        book = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(AlertBook.self, from: $0) } ?? AlertBook()
    }

    /// Starts watching. `fleet` gives every saved server's latest reading (`AppModel.fleetRows`).
    func start(fleet: @escaping () -> [FleetRow]) {
        self.fleet = fleet
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

    private func tickOnce() async {
        let rows = fleet()
        evaluate(rows)
        let now = Date()
        for row in rows where row.isOnline && !checking.contains(row.id) {
            if now.timeIntervalSince(lastSweep[row.id] ?? .distantPast) >= Self.sweepInterval {
                Task { await sweep(row) }
            }
        }
    }

    /// Checks one server now (the Alerts screen's Check Now), or every answering server.
    func checkNow(_ server: Server? = nil) {
        let rows = fleet().filter { $0.isOnline && (server == nil || $0.server.id == server?.id) }
        for row in rows where !checking.contains(row.id) {
            Task { await sweep(row, certificatesToo: true) }
        }
    }

    // MARK: reading what the app has

    private func evaluate(_ rows: [FleetRow]) {
        let before = book
        var raised: [ServerAlert] = []
        let now = Date()
        for row in rows {
            let id = row.server.id, name = row.server.name
            func apply(_ source: AlertSource, _ signals: [AlertSignal]) {
                raised += book.apply(server: id, serverName: name, source: source, signals: signals, at: now)
            }
            // The connection, once there is any reading at all.
            if row.blocked != nil || row.state.error != nil || (row.state.overview != nil && !row.state.isStale) {
                apply(.connection, AlertRules.connection(error: row.state.error, blocked: row.blocked))
            }
            if let o = row.state.overview, !row.state.isStale, row.state.error == nil {
                var signals = AlertRules.overview(o)
                // On a NAS the array reading replaces df's fill alerts (ZFS datasets all read about 1%).
                if ServerKind.detect(o.os) == .unraid { signals.removeAll { $0.category == .disk } }
                apply(.overview, signals)
            }
            let services = ServicesStore.shared.model(for: row.server)
            if let snapshot = services.snapshot, let at = services.updatedAt, isNew(id, .services, at) {
                let visibility = ServiceVisibilityStore.shared
                apply(.services, AlertRules.services(snapshot) { visibility.isVisible($0, server: id) })
            }
            if let (reading, at) = containerReadings[id], isNew(id, .containers, at) {
                apply(.containers, AlertRules.containers(reading))
            }
            if let o = row.state.overview, ServerKind.detect(o.os) == .unraid {
                let nas = NASStore.shared.model(for: row.server)
                if let snapshot = nas.snapshot, let at = nas.updatedAt, isNew(id, .storage, at) { apply(.storage, AlertRules.storage(snapshot)) }
            }
            if let (checks, at) = certificates[id], isNew(id, .certificates, at) {
                apply(.certificates, AlertRules.certificates(checks, now: now))
            }
        }
        if book != before { save() }
        notifier.notify(raised)
    }

    /// True once per reading: each one is applied once, so `lastSeen` means "a check saw it".
    private func isNew(_ server: String, _ source: AlertSource, _ at: Date) -> Bool {
        let key = "\(server)|\(source.rawValue)"
        guard (applied[key] ?? .distantPast) < at else { return false }
        applied[key] = at
        return true
    }

    // MARK: background checks

    private func sweep(_ row: FleetRow, certificatesToo: Bool = false) async {
        let server = row.server
        checking.insert(server.id)
        defer {
            checking.remove(server.id)
            lastSweep[server.id] = Date()
            evaluate(fleet())
        }
        await ServicesStore.shared.model(for: server).refresh()
        if let o = row.state.overview, ServerKind.detect(o.os) == .unraid {
            await NASStore.shared.model(for: server).refresh()
        }
        let docker = DockerStatesSession(transport: dockerTransport(for: server))
        guard let reading = await docker.read() else { return }
        containerReadings[server.id] = (reading, Date())
        let due = Date().timeIntervalSince(lastCertificateCheck[server.id] ?? .distantPast) >= Self.certificateInterval
        guard (due || certificatesToo), !Demo.isOn else { return }
        let targets = CertificateCheck.targets(reading.containers.map(\.href))
        lastCertificateCheck[server.id] = Date()
        var checks: [CertificateCheck] = []
        for url in targets { checks.append(await CertificateProbe.check(url)) }
        certificates[server.id] = (checks, Date())
    }

    /// The last background container reading of a server (search uses it when the Docker screen has none).
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
    }

    private func save() {
        if let data = try? JSONEncoder().encode(book) { try? data.write(to: file, options: .atomic) }
    }
}

// MARK: - Certificates

/// Reads a site's TLS certificate expiry from the Mac. Only the handshake happens: the connection is cancelled as soon as
/// the certificate is seen, so no page is requested. Untrusted (self-signed) certificates are read too, and never trusted.
enum CertificateProbe {
    static func check(_ url: String) async -> CertificateCheck {
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
            let date = CertificateProbe.notAfter(leaf)
            lock.withLock { stored = date }
            return (.cancelAuthenticationChallenge, nil)
        }
    }

    static func notAfter(_ certificate: SecCertificate) -> Date? {
        let keys = [kSecOIDX509V1ValidityNotAfter] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [CFString: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
              let number = entry[kSecPropertyKeyValue] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: number.doubleValue)
    }
}

// MARK: - Notifications

/// macOS notifications for new alerts (warnings and worse, never on a server's first look, never muted ones). Only in a
/// real .app bundle (UserNotifications needs one); `alertNotifications` in the defaults turns them off.
@MainActor
final class AlertNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "alertNotifications"
    private var asked = false

    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    func notify(_ alerts: [ServerAlert]) {
        guard !alerts.isEmpty, Self.isAvailable, Self.isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            if !asked {
                asked = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
            for alert in alerts.prefix(5) {
                let content = UNMutableNotificationContent()
                content.title = "\(alert.serverName): \(alert.title)"
                content.body = alert.detail ?? ""
                content.threadIdentifier = alert.serverID
                content.userInfo = ["server": alert.serverID]
                if alert.severity == .critical { content.sound = .default }
                try? await center.add(UNNotificationRequest(identifier: alert.id + "|\(alert.firstSeen.timeIntervalSince1970)",
                                                            content: content, trigger: nil))
            }
            if alerts.count > 5 {
                let content = UNMutableNotificationContent()
                content.title = "\(alerts.count - 5) more alerts"
                content.body = "Open Rackoon's Alerts to see them all."
                try? await center.add(UNNotificationRequest(identifier: "more-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .list, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let server = response.notification.request.content.userInfo["server"] as? String
        await MainActor.run {
            NotificationCenter.default.post(name: .rackoonShowAlerts, object: server)
        }
    }
}

extension Notification.Name {
    /// Open the Alerts (object: a server id, or nil for every server).
    static let rackoonShowAlerts = Notification.Name("rackoonShowAlerts")
}
