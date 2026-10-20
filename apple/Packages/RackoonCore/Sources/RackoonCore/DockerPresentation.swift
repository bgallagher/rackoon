import Foundation

// What the Docker screens show about stacks and containers, as pure rules shared by the phone apps (the Mac app keeps its
// own copies in its views). Mirrors `DockerPresentation.kt` in the Kotlin core.

/// Where a link works: `local` = no real domain (a bare name like "dockge", `.local`/`.lan`, a private IP), which only
/// resolves from inside your network or tailnet; `tailscale` = a `*.ts.net` name or 100.64.0.0/10 address; `publicWeb` = a
/// normal domain. Same rules as `LinkScope` in the Mac app.
public enum LinkScope: String, Sendable, CaseIterable {
    case local, tailscale, publicWeb

    public init(href: String) {
        guard let host = URL(string: href)?.host?.lowercased() else { self = .publicWeb; return }
        if host.hasSuffix(".ts.net") { self = .tailscale; return }
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        let parts = pieces.compactMap { Int($0) }
        if parts.count == 4, pieces.count == 4 {
            if parts[0] == 100, (64...127).contains(parts[1]) { self = .tailscale; return }
            let privateRange = parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
                || (parts[0] == 172 && (16...31).contains(parts[1]))
            self = privateRange ? .local : .publicWeb
            return
        }
        let localSuffixes = [".local", ".lan", ".home", ".internal", ".home.arpa", ".localdomain"]
        self = !host.contains(".") || localSuffixes.contains(where: host.hasSuffix) ? .local : .publicWeb
    }

    public var title: String { switch self { case .local: "Local"; case .tailscale: "Tailscale"; case .publicWeb: "Public" } }
    public var hint: String {
        switch self {
        case .local: "Names and addresses that only work from inside your network"
        case .tailscale: "Only reachable on your tailnet"
        case .publicWeb: "Reachable from anywhere"
        }
    }
}

extension Bookmark {
    /// The address as a short label: the host, plus a port and a path when there is one ("app.example.com/tv").
    public var shortAddress: String {
        guard let url = URL(string: href), let host = url.host else { return href }
        let path = url.path == "/" ? "" : url.path
        return host + (url.port.map { ":\($0)" } ?? "") + path
    }
}

extension DockerStack {
    /// The stack's bookmarks (Homepage labels), first container first.
    public var bookmarkLinks: [Bookmark] { containers.compactMap(\.bookmark) }

    /// The card's status line: unhealthy first, then not started, stopped, partly stopped; a healthy stack says nothing.
    public var status: StackStatus {
        if unhealthyCount > 0 { return StackStatus(text: "\(unhealthyCount) unhealthy", severity: .danger) }
        if containers.isEmpty { return StackStatus(text: "Not started", severity: .idle) }
        if runningCount == 0 { return StackStatus(text: "Stopped", severity: .idle) }
        if stoppedCount > 0 { return StackStatus(text: "\(stoppedCount) stopped", severity: .warning) }
        return StackStatus(text: "", severity: .ok)
    }
}

/// How serious a stack's status is, for the dot and the text colour.
public enum StackSeverity: Sendable, Equatable { case ok, warning, danger, idle }

public struct StackStatus: Sendable, Equatable {
    public var text: String
    public var severity: StackSeverity
    public init(text: String, severity: StackSeverity) {
        self.text = text
        self.severity = severity
    }
}

extension DockerSnapshot {
    /// The line under the page title: "9 stacks · 20 containers · 19 healthy, 1 unhealthy, 1 stopped". The three counts add
    /// up to the containers.
    public var summary: String {
        let stackCount = stacks.filter { !$0.isStandalone }.count
        let unhealthy = containers.filter(\.isUnhealthy).count
        let healthy = containers.filter { $0.isRunning && !$0.isUnhealthy }.count
        let stopped = containers.count - healthy - unhealthy
        var parts: [String] = []
        if stackCount > 0 { parts.append("\(stackCount) \(stackCount == 1 ? "stack" : "stacks")") }
        parts.append("\(containers.count) \(containers.count == 1 ? "container" : "containers")")
        var state: [String] = []
        if healthy > 0 { state.append("\(healthy) healthy") }
        if unhealthy > 0 { state.append("\(unhealthy) unhealthy") }
        if stopped > 0 { state.append("\(stopped) stopped") }
        if !state.isEmpty { parts.append(state.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// The one-letter tile that stands in for a site icon: a hue from the name, so a stack keeps its colour.
public enum LetterTile {
    public static func letter(_ name: String) -> String { name.first.map { String($0).uppercased() } ?? "?" }

    /// 0 until 360, the same for the same name (djb2 over unicode scalars, as on the Mac and Android).
    public static func hue(_ name: String) -> Int {
        let h = name.unicodeScalars.reduce(Int64(5381)) { $0 &* 33 &+ Int64($1.value) }
        let r = Int(h % 360)
        return r < 0 ? r + 360 : r
    }

    /// Which of `count` palette colours this name gets: stable for the same name, so a stack keeps its colour.
    public static func slot(_ name: String, count: Int) -> Int { hue(name) % count }
}

extension DockerContainer {
    /// A container's usage text on a card: "6% · 147 MB", or its state when it is not running.
    public func usageText(formatBytes: (Int64) -> String) -> String {
        guard isRunning else { return state }
        guard let cpu = cpuPercent, let mem = memoryUsedBytes else { return "—" }
        return "\(String(format: "%.0f", cpu))% · \(formatBytes(mem))"
    }

    /// The name log lines are tagged with: the compose service name, else the container name.
    public var logSource: String { service ?? name }
}

/// A container image split for display: the repository (which may be shortened in the middle) and the tag, never cut.
public struct ImageName: Sendable, Equatable {
    public var repository: String
    public var tag: String?
    public init(repository: String, tag: String?) {
        self.repository = repository
        self.tag = tag
    }

    public static func parse(_ image: String) -> ImageName {
        if let at = image.firstIndex(of: "@") {
            let digest = image[image.index(after: at)...]
            return ImageName(repository: String(image[..<at]), tag: "@" + digest.prefix(19))
        }
        // A colon before the last slash belongs to a registry port (localhost:5000/app), not to a tag.
        guard let colon = image.lastIndex(of: ":") else { return ImageName(repository: image, tag: nil) }
        if let slash = image.lastIndex(of: "/"), colon < slash { return ImageName(repository: image, tag: nil) }
        return ImageName(repository: String(image[..<colon]), tag: String(image[colon...]))
    }
}
