import Foundation

// Alerts: everything that needs the user, across every server, with a memory. The app feeds each server's readings in by
// source (its connection, the Overview's attention items, the services scan, a light container check, Unraid's array,
// certificate checks of its bookmarks); `AlertRules` turns a reading into signals and `AlertBook` keeps the alerts: when
// each was first and last seen, when it went away, whether the user has seen or muted it, and which ones are new enough to
// notify about. Pure, so the same rules can later run in a relay or on a phone.

public typealias AlertSeverity = AttentionItem.Severity

extension AttentionItem.Severity {
    /// Higher is worse, for sorting and for "did it get worse".
    public var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .critical: 2
        }
    }
}

/// Where an alert's reading comes from. A reading only resolves alerts of its own source, so a check that did not run
/// never clears another check's alerts.
public enum AlertSource: String, Sendable, Codable, CaseIterable {
    case connection, overview, services, containers, storage, certificates
}

/// What an alert is about, for grouping and filters.
public enum AlertCategory: String, Sendable, Codable, CaseIterable {
    case connection, disk, containers, services, updates, storage, certificates

    public var title: String {
        switch self {
        case .connection: "Connection"
        case .disk: "Disk"
        case .containers: "Containers"
        case .services: "Services"
        case .updates: "Updates"
        case .storage: "Storage"
        case .certificates: "Certificates"
        }
    }
}

/// Where to go to deal with an alert: a screen (`Screen` raw value in the app) and, when it helps, the thing on it.
public struct AlertFix: Sendable, Codable, Equatable, Hashable {
    public var screen: String
    /// A Docker stack id, a service id or a bookmark address.
    public var target: String?

    public init(_ screen: String, target: String? = nil) {
        self.screen = screen
        self.target = target
    }
}

/// One thing a reading found wrong, before the book gives it a history.
public struct AlertSignal: Sendable, Equatable {
    /// Stable within the server and source: `disk_high:/`, `service_failed:system/x.service`.
    public var key: String
    public var category: AlertCategory
    public var severity: AlertSeverity
    public var title: String
    public var detail: String?
    public var fix: AlertFix?

    public init(key: String, category: AlertCategory, severity: AlertSeverity, title: String, detail: String? = nil, fix: AlertFix? = nil) {
        self.key = key
        self.category = category
        self.severity = severity
        self.title = title
        self.detail = detail
        self.fix = fix
    }
}

public struct ServerAlert: Sendable, Codable, Equatable, Identifiable {
    /// `<server id>|<source>|<key>`.
    public var id: String
    public var serverID: String
    public var serverName: String
    public var source: AlertSource
    public var key: String
    public var category: AlertCategory
    public var severity: AlertSeverity
    public var title: String
    public var detail: String?
    public var fix: AlertFix?
    public var firstSeen: Date
    public var lastSeen: Date
    /// When the condition went away; nil while it is active.
    public var resolvedAt: Date?
    /// The user has seen it: it stays listed but stops counting in badges.
    public var acknowledged: Bool

    public var isActive: Bool { resolvedAt == nil }
}

// MARK: - The book

public struct AlertBook: Sendable, Codable, Equatable {
    /// Active alerts and resolved ones from the last `historyDays`.
    public private(set) var alerts: [ServerAlert] = []
    /// ServerAlert ids the user muted: never counted or notified, shown only under Muted.
    public private(set) var muted: Set<String> = []
    /// `<server id>|<source>` pairs that have had at least one reading, so the very first reading of a server (or of a
    /// new check) does not notify about everything it finds at once.
    public private(set) var baselined: Set<String> = []

    public static let historyDays = 7
    public static let historyLimit = 300

    public init() {}

    public static func id(server: String, source: AlertSource, key: String) -> String { "\(server)|\(source.rawValue)|\(key)" }

    /// Records one reading of `source` on a server. Returns the alerts worth a notification: new ones (warning or worse)
    /// and ones that just became critical, never on the source's first reading and never muted ones.
    @discardableResult
    public mutating func apply(server: String, serverName: String, source: AlertSource, signals: [AlertSignal], at now: Date) -> [ServerAlert] {
        let baselineKey = "\(server)|\(source.rawValue)"
        let firstReading = !baselined.contains(baselineKey)
        baselined.insert(baselineKey)
        var raised: [ServerAlert] = []
        var seen = Set<String>()
        for signal in signals {
            let id = Self.id(server: server, source: source, key: signal.key)
            guard seen.insert(id).inserted else { continue }
            if let i = alerts.firstIndex(where: { $0.id == id && $0.isActive }) {
                let worse = signal.severity == .critical && alerts[i].severity != .critical
                alerts[i].severity = signal.severity
                alerts[i].title = signal.title
                alerts[i].detail = signal.detail
                alerts[i].fix = signal.fix
                alerts[i].category = signal.category
                alerts[i].serverName = serverName
                alerts[i].lastSeen = now
                if worse {
                    alerts[i].acknowledged = false
                    if !firstReading, !muted.contains(id) { raised.append(alerts[i]) }
                }
            } else {
                let alert = ServerAlert(id: id, serverID: server, serverName: serverName, source: source, key: signal.key,
                                  category: signal.category, severity: signal.severity, title: signal.title, detail: signal.detail,
                                  fix: signal.fix, firstSeen: now, lastSeen: now, resolvedAt: nil, acknowledged: false)
                alerts.append(alert)
                if !firstReading, signal.severity != .info, !muted.contains(id) { raised.append(alert) }
            }
        }
        // Gone from this source's reading: resolved.
        for i in alerts.indices where alerts[i].serverID == server && alerts[i].source == source && alerts[i].isActive && !seen.contains(alerts[i].id) {
            alerts[i].resolvedAt = now
        }
        prune(now: now)
        return raised
    }

    /// Active alerts, worst first, then oldest first. `includeMuted` adds the muted ones.
    public func active(server: String? = nil, includeMuted: Bool = false) -> [ServerAlert] {
        alerts.filter { $0.isActive && (server == nil || $0.serverID == server) && (includeMuted || !muted.contains($0.id)) }
            .sorted { a, b in a.severity.rank != b.severity.rank ? a.severity.rank > b.severity.rank : a.firstSeen < b.firstSeen }
    }

    public func mutedAlerts(server: String? = nil) -> [ServerAlert] {
        alerts.filter { $0.isActive && muted.contains($0.id) && (server == nil || $0.serverID == server) }
            .sorted { $0.firstSeen > $1.firstSeen }
    }

    /// Resolved alerts, most recent first.
    public func history(server: String? = nil) -> [ServerAlert] {
        alerts.filter { !$0.isActive && (server == nil || $0.serverID == server) }
            .sorted { ($0.resolvedAt ?? .distantPast) > ($1.resolvedAt ?? .distantPast) }
    }

    /// What a badge counts: active warnings and critical ones the user has neither seen nor muted.
    public func unseenCount(server: String? = nil) -> Int {
        active(server: server).filter { !$0.acknowledged && $0.severity != .info }.count
    }

    public func worstUnseen(server: String? = nil) -> AlertSeverity? {
        active(server: server).filter { !$0.acknowledged && $0.severity != .info }.map(\.severity).max { $0.rank < $1.rank }
    }

    public mutating func acknowledge(_ id: String, _ seen: Bool = true) {
        for i in alerts.indices where alerts[i].id == id && alerts[i].isActive { alerts[i].acknowledged = seen }
    }

    public mutating func acknowledgeAll(server: String? = nil) {
        for i in alerts.indices where alerts[i].isActive && (server == nil || alerts[i].serverID == server) { alerts[i].acknowledged = true }
    }

    public mutating func mute(_ id: String, _ on: Bool = true) {
        if on { muted.insert(id) } else { muted.remove(id) }
    }

    public mutating func clearHistory(server: String? = nil) {
        alerts.removeAll { !$0.isActive && (server == nil || $0.serverID == server) }
    }

    /// A removed server's alerts, mutes and baselines go with it. Returns whether anything changed.
    @discardableResult
    public mutating func forget(serverID: String) -> Bool {
        let before = (alerts.count, muted.count, baselined.count)
        alerts.removeAll { $0.serverID == serverID }
        muted = muted.filter { !$0.hasPrefix(serverID + "|") }
        baselined = baselined.filter { !$0.hasPrefix(serverID + "|") }
        return before != (alerts.count, muted.count, baselined.count)
    }

    /// Resolved alerts older than `historyDays` go, and the history never grows past `historyLimit`.
    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(Self.historyDays) * 86400)
        alerts.removeAll { ($0.resolvedAt ?? .distantFuture) < cutoff }
        let resolved = alerts.filter { !$0.isActive }
        if resolved.count > Self.historyLimit {
            let drop = Set(resolved.sorted { ($0.resolvedAt ?? .distantPast) < ($1.resolvedAt ?? .distantPast) }
                .prefix(resolved.count - Self.historyLimit).map(\.id))
            alerts.removeAll { !$0.isActive && drop.contains($0.id) }
        }
    }
}

// MARK: - Rules: from readings to signals

public enum AlertRules {
    /// The server's connection: not answering, or blocked by its host key or a refused login.
    public static func connection(error: String?, blocked: String?) -> [AlertSignal] {
        if let blocked {
            let changed = blocked.lowercased().contains("changed")
            return [AlertSignal(key: changed ? "host_key_changed" : "host_key_unknown", category: .connection,
                                severity: changed ? .critical : .info,
                                title: changed ? "Host key changed" : "Host key not trusted yet",
                                detail: blocked, fix: AlertFix("overview"))]
        }
        if let error, !error.isEmpty {
            let explained = ConnectionFailure.explain(error)
            let refused = error.contains("Permission denied")
            return [AlertSignal(key: refused ? "login_refused" : "not_answering", category: .connection, severity: .critical,
                                title: refused ? "Login refused" : "Not answering",
                                detail: explained?.headline ?? error.split(separator: "\n").first.map(String.init), fix: AlertFix("overview"))]
        }
        return []
    }

    /// The Overview's needs-attention items (disk, unhealthy containers, security updates, reboot required).
    public static func overview(_ overview: Overview) -> [AlertSignal] {
        Attention.evaluate(overview).map { item in
            let category: AlertCategory = item.id.hasPrefix("disk") ? .disk : item.id.hasPrefix("container") ? .containers : .updates
            let title: String = switch item.id {
            case "security_updates": "Security updates available"
            case "reboot_required": "Reboot required"
            default: item.id.hasPrefix("disk_high") ? "Disk almost full" : "Container unhealthy"
            }
            return AlertSignal(key: item.id, category: category, severity: item.severity, title: title, detail: item.message,
                               fix: AlertFix(item.fix))
        }
    }

    /// Services the user watches (shown on the Services screen) that failed, crash-loop or are stopped although they
    /// start at boot.
    public static func services(_ snapshot: ServicesSnapshot, isWatched: (DiscoveredService) -> Bool) -> [AlertSignal] {
        snapshot.services.filter(isWatched).compactMap { s in
            let fix = AlertFix("services", target: s.id)
            switch s.status {
            case .failed:
                return AlertSignal(key: "service_failed:\(s.id)", category: .services, severity: .critical, title: "\(s.name) failed",
                                   detail: [s.unit, s.result.map { "result: \($0)" }].compactMap { $0 }.joined(separator: " · "), fix: fix)
            case .restarting:
                return AlertSignal(key: "service_crashing:\(s.id)", category: .services, severity: .critical, title: "\(s.name) keeps crashing",
                                   detail: "systemd has restarted \(s.unit ?? s.name) \(s.restarts) time\(s.restarts == 1 ? "" : "s").", fix: fix)
            case .stopped where s.enabledAtBoot == true:
                return AlertSignal(key: "service_stopped:\(s.id)", category: .services, severity: .warning, title: "\(s.name) is stopped",
                                   detail: "\(s.unit ?? s.name) starts at boot but is not running now.", fix: fix)
            default:
                return nil
            }
        }
    }

    /// Containers that are down: restarting over and over, dead, or exited with an error. Exit codes 0 (finished), 130,
    /// 137 and 143 (stopped by a signal, as `docker stop` does) are not problems, nor is a container never started.
    public static func containers(_ reading: DockerStatesReading) -> [AlertSignal] {
        switch reading.problem {
        case .notInstalled: return []
        case .permissionDenied:
            return [AlertSignal(key: "docker_needs_sudo", category: .containers, severity: .info, title: "Containers not checked",
                                detail: "Docker refuses this user, so background checks can't see containers. Unlock Docker with sudo on the Docker screen to look.",
                                fix: AlertFix("docker"))]
        case .other(let text):
            return [AlertSignal(key: "docker_unreadable", category: .containers, severity: .warning, title: "Docker did not answer",
                                detail: text, fix: AlertFix("docker"))]
        case nil: break
        }
        return reading.containers.compactMap { c in
            let stack = c.project.isEmpty ? "standalone/\(c.name)" : c.project
            let fix = AlertFix("docker", target: stack)
            switch c.state {
            case "restarting":
                return AlertSignal(key: "container_down:\(c.name)", category: .containers, severity: .critical,
                                   title: "\(c.name) keeps restarting", detail: c.status, fix: fix)
            case "dead":
                return AlertSignal(key: "container_down:\(c.name)", category: .containers, severity: .critical,
                                   title: "\(c.name) is dead", detail: "Docker could not stop or remove it cleanly.", fix: fix)
            case "exited":
                guard let code = c.exitCode, ![0, 130, 137, 143].contains(code) else { return nil }
                return AlertSignal(key: "container_down:\(c.name)", category: .containers, severity: .warning,
                                   title: "\(c.name) stopped with an error", detail: c.status, fix: fix)
            default:
                return nil
            }
        }
    }

    /// An Unraid server's array and disks (`UnraidAttention`).
    public static func storage(_ snapshot: UnraidSnapshot, sustainedCPU: Double? = nil) -> [AlertSignal] {
        UnraidAttention.evaluate(snapshot, sustainedCPU: sustainedCPU).map {
            AlertSignal(key: $0.id, category: .storage, severity: $0.severity, title: storageTitle($0.id),
                        detail: $0.message, fix: AlertFix("overview"))
        }
    }

    /// The headline for an Unraid item: what it is about, so a CPU temperature is never called a disk problem.
    static func storageTitle(_ id: String) -> String {
        if id == "cpu_hot" { return "CPU running hot" }
        if id.hasPrefix("disk_hot:") { return "Disk running hot" }
        if id.hasPrefix("zfs_health:") { return "Pool needs attention" }
        if id.hasPrefix("array") || id.hasPrefix("parity") { return "Array needs attention" }
        return "Disk needs attention"
    }

    /// Days before expiry at which a certificate warns, and becomes critical.
    public static let certificateWarningDays = 21.0
    public static let certificateCriticalDays = 7.0

    /// Bookmarked https sites whose certificate expires soon or has expired. Sites that could not be reached say nothing.
    public static func certificates(_ checks: [CertificateCheck], now: Date) -> [AlertSignal] {
        checks.compactMap { check in
            guard let expires = check.expires else { return nil }
            let days = expires.timeIntervalSince(now) / 86400
            let fix = AlertFix("bookmarks", target: check.url)
            if days <= 0 {
                return AlertSignal(key: "cert:\(check.host)", category: .certificates, severity: .critical,
                                   title: "Certificate expired: \(check.host)", detail: "It expired \(Self.days(-days)) ago.", fix: fix)
            }
            guard days <= certificateWarningDays else { return nil }
            return AlertSignal(key: "cert:\(check.host)", category: .certificates,
                               severity: days <= certificateCriticalDays ? .critical : .warning,
                               title: "Certificate expires soon: \(check.host)", detail: "It expires in \(Self.days(days)).", fix: fix)
        }
    }

    static func days(_ d: Double) -> String {
        let n = Int(d.rounded(.down))
        return n < 1 ? "less than a day" : "\(n) day\(n == 1 ? "" : "s")"
    }
}

/// When a site's TLS certificate expires, as the Mac saw it.
public struct CertificateCheck: Sendable, Equatable, Codable {
    public var url: String
    public var host: String
    /// nil when the site could not be reached or showed no certificate.
    public var expires: Date?
    public var checkedAt: Date

    public init(url: String, host: String, expires: Date?, checkedAt: Date) {
        self.url = url
        self.host = host
        self.expires = expires
        self.checkedAt = checkedAt
    }

    /// The https addresses worth checking among bookmark addresses: one per host and port.
    public static func targets(_ hrefs: [String]) -> [String] {
        var seen = Set<String>()
        return hrefs.compactMap { href in
            guard let c = URLComponents(string: href), c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty else { return nil }
            let key = "\(host.lowercased()):\(c.port ?? 443)"
            guard seen.insert(key).inserted else { return nil }
            return "https://\(host)\(c.port.map { ":\($0)" } ?? "")/"
        }
    }
}

// MARK: - The light container check (spec `docker_states`)

public struct DockerStatesReading: Sendable, Equatable, Codable {
    public struct Container: Sendable, Equatable, Codable {
        public var id: String
        public var name: String
        /// created, running, restarting, exited, paused, dead, removing.
        public var state: String
        /// "Exited (1) 3 hours ago", "Up 2 days (healthy)".
        public var status: String
        public var project: String
        /// The `homepage.href` label, for certificate checks.
        public var href: String

        /// The exit code an exited container reports in its status.
        public var exitCode: Int? {
            guard let open = status.range(of: "Exited ("), let close = status[open.upperBound...].firstIndex(of: ")") else { return nil }
            return Int(status[open.upperBound..<close])
        }
    }

    public enum Problem: Sendable, Equatable, Codable {
        case notInstalled, permissionDenied
        case other(String)
    }

    public var containers: [Container]
    public var problem: Problem?
}

public enum DockerStatesParser {
    public static func parse(_ output: String) -> DockerStatesReading {
        var containers: [DockerStatesReading.Container] = []
        var other: [String] = []
        for line in output.split(separator: "\n").map(String.init) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f.count >= 6, DockerSession.isContainerID(f[0]) {
                containers.append(.init(id: f[0], name: f[1], state: f[2], status: f[3], project: f[4], href: f[5]))
            } else {
                other.append(line)
            }
        }
        guard containers.isEmpty, !other.isEmpty else { return DockerStatesReading(containers: containers, problem: nil) }
        let text = other.joined(separator: "\n")
        let lower = text.lowercased()
        if lower.contains("not found") || lower.contains("no such file") { return DockerStatesReading(containers: [], problem: .notInstalled) }
        if DockerAccess.isPermissionProblem(text) { return DockerStatesReading(containers: [], problem: .permissionDenied) }
        return DockerStatesReading(containers: [], problem: .other(String(text.prefix(300))))
    }
}

public actor DockerStatesSession {
    public static let command = #"docker ps -a --no-trunc --format '{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Status}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "homepage.href"}}' 2>&1; true"#

    private let transport: SSHTransport
    public init(transport: SSHTransport) { self.transport = transport }

    /// One reading, or nil when ssh itself failed (the connection alert covers that).
    public func read() async -> DockerStatesReading? {
        guard let result = try? await transport.run(Self.command, timeout: 15), result.exitCode == 0 else { return nil }
        return DockerStatesParser.parse(result.stdout)
    }
}
