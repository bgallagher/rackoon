import Foundation

// Search across everything the app knows: servers, Docker stacks and containers, discovered services, bookmarks, the
// Commands library and alerts. Pure: the app builds `SearchItem`s from what its models already hold (nothing is fetched
// for a search) and `Search.run` ranks and groups them.

public enum SearchGroup: String, Sendable, CaseIterable, Codable {
    case servers, docker, services, bookmarks, commands, alerts

    public var title: String {
        switch self {
        case .servers: "Servers"
        case .docker: "Docker"
        case .services: "Services"
        case .bookmarks: "Bookmarks"
        case .commands: "Commands"
        case .alerts: "Alerts"
        }
    }
}

/// Where a result leads.
public enum SearchTarget: Sendable, Equatable, Hashable {
    case server(String)
    /// A Docker stack (`DockerStack.id`) on a server.
    case stack(server: String, stack: String)
    case service(server: String, service: String)
    case bookmark(server: String, href: String)
    /// A Commands-library entry (opened on the selected server).
    case command(String)
    case alert(server: String, alert: String)
}

public struct SearchItem: Sendable, Equatable, Identifiable {
    public var group: SearchGroup
    public var id: String
    public var title: String
    /// One line saying what it is and where: "Compose stack · 3 of 3 running".
    public var subtitle: String
    /// The server it lives on (none for commands).
    public var serverName: String?
    /// Other words it is found by (image, unit, ports, command text...), not shown.
    public var keywords: [String]
    public var target: SearchTarget
    /// A status colour hint for the row: nil, or "ok", "warn", "danger", "idle".
    public var tone: String?
    /// A web address the row can open directly (bookmarks, a stack's web page).
    public var link: String?

    public init(group: SearchGroup, id: String, title: String, subtitle: String, serverName: String? = nil, keywords: [String] = [],
                target: SearchTarget, tone: String? = nil, link: String? = nil) {
        self.group = group
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.serverName = serverName
        self.keywords = keywords
        self.target = target
        self.tone = tone
        self.link = link
    }
}

public struct SearchResults: Sendable, Equatable {
    public struct Section: Sendable, Equatable {
        public var group: SearchGroup
        /// Best first.
        public var items: [SearchItem]
    }

    /// In `SearchGroup` order, empty groups left out.
    public var sections: [Section]
    public var count: Int { sections.reduce(0) { $0 + $1.items.count } }
}

public enum Search {
    public static let minimumLength = 2

    /// Whether `query` is long enough to search for (two letters or more, ignoring spaces).
    public static func isSearchable(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumLength
    }

    /// Every word of the query must be found, ignoring case and accents: anywhere in the title, or at the start of a word
    /// of the subtitle, server or keywords (so "pi" finds Pi-hole, not every "pipe" in a description).
    /// Ranking: a title that is the query, then one that starts with it, then a title word that starts with it, then a
    /// match anywhere in the title, then elsewhere.
    public static func run(_ query: String, in items: [SearchItem]) -> SearchResults {
        guard isSearchable(query) else { return SearchResults(sections: []) }
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let words = q.split(separator: " ").map(String.init)
        var scored: [(SearchItem, Int)] = []
        for item in items {
            let title = fold(item.title)
            let rest = fold(([item.subtitle, item.serverName ?? ""] + item.keywords).joined(separator: " "))
            let restWords = rest.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            // Addresses and paths ("100.64", "/admin") are matched as written.
            func inRest(_ w: String) -> Bool { restWords.contains { $0.hasPrefix(w) } || (w.contains { !$0.isLetter && !$0.isNumber } && rest.contains(w)) }
            guard words.allSatisfy({ title.contains($0) || inRest($0) }) else { continue }
            var score = 0
            if title == q { score += 1000 }
            if title.hasPrefix(q) { score += 500 }
            let titleWords = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            for w in words {
                if titleWords.contains(where: { $0.hasPrefix(w) }) { score += 100 }
                else if title.contains(w) { score += 50 }
                else if restWords.contains(where: { $0.hasPrefix(w) }) { score += 20 }
                else { score += 5 }
            }
            // Shorter titles are closer matches; problems first among equals.
            score -= min(title.count, 60) / 6
            if item.tone == "danger" { score += 3 }
            scored.append((item, score))
        }
        let sections = SearchGroup.allCases.compactMap { group -> SearchResults.Section? in
            let items = scored.filter { $0.0.group == group }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending }
                .map(\.0)
            return items.isEmpty ? nil : SearchResults.Section(group: group, items: items)
        }
        return SearchResults(sections: sections)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }
}

// MARK: - Building the items

public enum SearchItems {
    public static func server(_ server: Server, summary: String, online: Bool?, os: String?, addresses: [String]) -> SearchItem {
        SearchItem(group: .servers, id: "server|\(server.id)", title: server.name,
                   subtitle: ([server.user.map { "\($0)@\(server.host)" } ?? server.host] + [os, summary].compactMap { $0 }).joined(separator: " · "),
                   keywords: [server.host, server.sshConfigAlias ?? ""] + addresses,
                   target: .server(server.id), tone: online.map { $0 ? "ok" : "danger" })
    }

    /// A server's stacks and their containers, from a full Docker reading.
    public static func docker(_ stacks: [DockerStack], server: Server) -> [SearchItem] {
        var out: [SearchItem] = []
        for stack in stacks {
            let running = stack.runningCount, total = stack.containers.count
            let state = total == 0 ? "not started" : "\(running) of \(total) running"
            let tone = stack.unhealthyCount > 0 ? "danger" : (total > 0 && running == 0 ? "idle" : (running < total ? "warn" : "ok"))
            out.append(SearchItem(group: .docker, id: "stack|\(server.id)|\(stack.id)", title: stack.name,
                                  subtitle: "\(stack.kindLabel) · \(state)", serverName: server.name,
                                  keywords: stack.containers.flatMap { [$0.name, $0.service ?? "", $0.image] },
                                  target: .stack(server: server.id, stack: stack.id), tone: tone))
            guard !stack.isStandalone else { continue }   // a standalone stack is its one container
            for c in stack.containers {
                out.append(SearchItem(group: .docker, id: "container|\(server.id)|\(c.id)", title: c.service ?? c.name,
                                      subtitle: "Container in \(stack.name) · \(c.image) · \(c.isUnhealthy ? "unhealthy" : c.state)",
                                      serverName: server.name, keywords: [c.name, c.image] + c.ports.map { String($0.hostPort) },
                                      target: .stack(server: server.id, stack: stack.id),
                                      tone: c.isUnhealthy ? "danger" : (c.isRunning ? "ok" : "idle")))
            }
        }
        return out
    }

    /// A server's containers from the light background check (no stats or images): used when its Docker screen has not
    /// been read.
    public static func docker(_ reading: DockerStatesReading, server: Server) -> [SearchItem] {
        var out: [SearchItem] = []
        var projects: [String: [DockerStatesReading.Container]] = [:]
        for c in reading.containers where !c.project.isEmpty { projects[c.project, default: []].append(c) }
        for (project, containers) in projects.sorted(by: { $0.key < $1.key }) {
            let running = containers.filter { $0.state == "running" }.count
            out.append(SearchItem(group: .docker, id: "stack|\(server.id)|\(project)", title: project,
                                  subtitle: "Compose Stack · \(running) of \(containers.count) running", serverName: server.name,
                                  keywords: containers.map(\.name), target: .stack(server: server.id, stack: project),
                                  tone: running == containers.count ? "ok" : (running == 0 ? "idle" : "warn")))
        }
        for c in reading.containers {
            let stack = c.project.isEmpty ? DockerStack.standaloneID(c.name) : c.project
            out.append(SearchItem(group: .docker, id: "container|\(server.id)|\(c.id)", title: c.name,
                                  subtitle: (c.project.isEmpty ? "Standalone container" : "Container in \(c.project)") + " · \(c.status)",
                                  serverName: server.name, target: .stack(server: server.id, stack: stack),
                                  tone: c.status.contains("unhealthy") ? "danger" : (c.state == "running" ? "ok" : "idle")))
        }
        return out
    }

    /// The services a server shows (hidden ones are left out, like on its Services screen).
    public static func services(_ snapshot: ServicesSnapshot, server: Server, isShown: (DiscoveredService) -> Bool) -> [SearchItem] {
        snapshot.services.filter(isShown).map { s in
            let state: String = switch s.status {
            case .running: "running"
            case .starting: "starting"
            case .restarting: "crash loop"
            case .stopping: "stopping"
            case .stopped: "stopped"
            case .failed: "failed"
            }
            let kind = s.kind == .process ? "Started by hand" : (s.kind == .user ? "User service" : "System service")
            return SearchItem(group: .services, id: "service|\(server.id)|\(s.id)", title: s.name,
                              subtitle: "\(kind) · \(state)" + (s.unit.map { " · \($0)" } ?? ""), serverName: server.name,
                              keywords: [s.detail, s.product ?? ""] + s.ports.map { String($0.port) },
                              target: .service(server: server.id, service: s.id),
                              tone: s.isProblem ? "danger" : (s.isRunning ? "ok" : "idle"))
        }
    }

    /// Bookmarks (Homepage labels) with the service that carries them.
    public static func bookmarks(_ items: [(bookmark: Bookmark, service: String)], server: Server) -> [SearchItem] {
        var seen = Set<String>()
        return items.compactMap { item in
            guard seen.insert(item.bookmark.href).inserted else { return nil }
            let b = item.bookmark
            return SearchItem(group: .bookmarks, id: "bookmark|\(server.id)|\(b.href)", title: b.title(fallback: item.service),
                              subtitle: ([b.href] + [b.group].compactMap { $0 }).joined(separator: " · "), serverName: server.name,
                              keywords: [item.service, b.description ?? ""], target: .bookmark(server: server.id, href: b.href),
                              link: b.href)
        }
    }

    public static func commands(_ commands: [LibraryCommand]) -> [SearchItem] {
        commands.map { c in
            SearchItem(group: .commands, id: "command|\(c.id)", title: c.title,
                       subtitle: "\(c.group) · \(c.isMutating ? "changes the server, asks first" : "read-only")" + (c.root ? " · sudo" : ""),
                       keywords: [c.summary, c.id.replacingOccurrences(of: "_", with: " ")], target: .command(c.id))
        }
    }

    public static func alerts(_ alerts: [ServerAlert]) -> [SearchItem] {
        alerts.map { a in
            SearchItem(group: .alerts, id: "alert|\(a.id)", title: a.title,
                       subtitle: "\(a.severity.rawValue.capitalized) · \(a.category.title)" + (a.detail.map { " · \($0)" } ?? ""),
                       serverName: a.serverName, keywords: [a.key], target: .alert(server: a.serverID, alert: a.id),
                       tone: a.severity == .critical ? "danger" : (a.severity == .warning ? "warn" : nil))
        }
    }
}
