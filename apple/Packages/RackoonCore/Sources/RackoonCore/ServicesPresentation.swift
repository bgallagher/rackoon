import Foundation

// How the Services screen shows a discovered service: the status chips, the order, the labels and the one-line facts.
// The Mac app has its own copies in its views; the iPhone app uses these.

/// The status chips above the list.
public enum ServiceStatusFilter: String, Sendable, CaseIterable {
    case running, attention, stopped

    public var title: String {
        switch self {
        case .running: "Running"
        case .attention: "Needs attention"
        case .stopped: "Stopped"
        }
    }

    public func includes(_ s: DiscoveredService) -> Bool {
        switch self {
        case .running: s.status == .running || s.status == .starting
        case .attention: s.isProblem
        case .stopped: s.status == .stopped || s.status == .stopping
        }
    }
}

public enum ServicesPresentation {
    public static func kindLabel(_ kind: DiscoveredService.Kind) -> String {
        switch kind {
        case .system: "System service"
        case .user: "User service"
        case .process: "Started by hand"
        }
    }

    /// The status as words, and its tone ("ok", "warn", "danger", "idle", as `SearchItem.tone`).
    public static func status(_ s: DiscoveredService) -> (text: String, tone: String) {
        switch s.status {
        case .running: ("Running", "ok")
        case .starting: ("Starting", "warn")
        case .restarting: ("Crash loop", "danger")
        case .stopping: ("Stopping", "warn")
        case .stopped: ("Stopped", "idle")
        case .failed: ("Failed" + (s.result.map { " (\($0))" } ?? ""), "danger")
        }
    }

    /// One line on how it is doing: how long it has run, memory, boot setting, restarts.
    public static func facts(_ s: DiscoveredService, uptime: (Double) -> String, bytes: (Int64) -> String) -> [String] {
        var out: [String] = []
        if let up = s.activeSeconds { out.append("Up \(uptime(up))") }
        if let mem = s.memoryBytes, mem > 0 { out.append(bytes(mem)) }
        if let boot = s.enabledAtBoot { out.append(boot ? "Starts at boot" : "Not at boot") }
        if s.restarts > 0 { out.append("\(s.restarts) restart\(s.restarts == 1 ? "" : "s")") }
        return out
    }

    /// Problems first, then running, then the rest; by name within each.
    public static func sorted(_ list: [DiscoveredService]) -> [DiscoveredService] {
        func rank(_ s: DiscoveredService) -> Int { s.isProblem ? 0 : (s.isRunning ? 1 : 2) }
        return list.sorted { (rank($0), $0.name.lowercased()) < (rank($1), $1.name.lowercased()) }
    }

    /// The unit, or for a process the program it runs.
    public static func identity(_ s: DiscoveredService) -> String {
        if let unit = s.unit { return unit }
        return s.detail.isEmpty ? s.name : s.detail
    }

    /// The description, when it says more than the name (a unit's description often only repeats it).
    public static func description(_ s: DiscoveredService) -> String? {
        guard s.kind != .process, !s.detail.isEmpty else { return nil }
        let d = s.detail.lowercased()
        return [s.name.lowercased(), (s.unit ?? "").lowercased(), ServicesParser.displayBase(s.unit)].contains(d) ? nil : s.detail
    }

    /// "4 shown · 12 hidden · 1 needs attention".
    public static func subtitle(_ snapshot: ServicesSnapshot, isVisible: (DiscoveredService) -> Bool) -> String {
        let shown = snapshot.services.filter(isVisible)
        var parts = ["\(shown.count) shown", "\(snapshot.services.count - shown.count) hidden"]
        let problems = shown.filter(\.isProblem).count
        if problems > 0 { parts.append("\(problems) need\(problems == 1 ? "s" : "") attention") }
        return parts.joined(separator: " · ")
    }

    /// A port as a link to open, when it looks like a web page and can be reached from here.
    public static func link(_ port: ServicePort, webHost: String?) -> URL? {
        guard port.isLikelyWeb, let host = port.linkHost(preferred: webHost) else { return nil }
        return URL(string: "http://\(host):\(port.port)")
    }

    /// The actions a service's menu offers, in order: changes first (only those that apply), then the reads.
    /// A process started by hand has none.
    public static func actions(for s: DiscoveredService) -> [ServiceAction] {
        guard s.kind != .process else { return [] }
        return [ServiceAction.restart, .stop, .start].filter { $0.applies(to: s) } + [.status, .logs]
    }
}

// MARK: - Files

public enum RemoteFileNames {
    /// "report.pdf" -> "report copy.pdf" -> "report copy 2.pdf", skipping names in `taken`. A leading dot is part of the
    /// name, not an extension (".env" -> ".env copy").
    public static func copyName(_ name: String, avoiding taken: Set<String>) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let hasExt = !ext.isEmpty && !(ns.lastPathComponent.hasPrefix(".") && ns.deletingPathExtension == "")
        let stem = hasExt ? ns.deletingPathExtension : name
        for n in 1... {
            let candidate = (n == 1 ? "\(stem) copy" : "\(stem) copy \(n)") + (hasExt ? ".\(ext)" : "")
            if !taken.contains(candidate) { return candidate }
        }
        return name
    }

    /// Why a typed name can't be used for a new folder or a rename, or nil.
    public static func problem(_ name: String, taken: Set<String>) -> String? {
        let t = name.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "Enter a name" }
        if !FileTransferCommands.validName(t) { return "That name has a character that can't be used (a slash, or a line break)" }
        if taken.contains(t) { return "That name is already taken" }
        return nil
    }
}

/// What deleting some items of a server folder would run, or why it can't.
public struct DeletePlan: Sendable, Equatable {
    public var operations: [FileOperation]
    public var commands: [String]
    /// Non-empty: nothing is deleted.
    public var problems: [String]
    public var hasFolder: Bool

    /// `items` are names with whether each is a real folder (a link to a folder is deleted as a link, never followed).
    public init(directory: String, items: [(name: String, isFolder: Bool)]) {
        operations = items.map { FileOperation.delete(in: directory, name: $0.name, isFolder: $0.isFolder) }
        commands = []
        problems = []
        hasFolder = items.contains { $0.isFolder }
        for (item, op) in zip(items, operations) {
            if let command = FileOperationCommands.command(for: op) {
                commands.append(command)
            } else if item.isFolder {
                problems.append(FileOperationCommands.deleteProblem(folder: RemotePath.join(directory, item.name)) ?? "“\(item.name)” can't be deleted from here.")
            } else {
                problems.append("“\(item.name)” can't be deleted from here.")
            }
        }
    }

    /// The word to type before a folder is deleted.
    public static let confirmWord = "delete"
}

// MARK: - Commands

extension CommandLibrary {
    /// Library entries matching `query` (title, summary or id), in their groups; empty groups are left out.
    public static func visibleGroups(matching query: String) -> [(name: String, commands: [LibraryCommand])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return groups.compactMap { group in
            let items = commands(in: group).filter {
                q.isEmpty || $0.title.lowercased().contains(q) || $0.summary.lowercased().contains(q) || $0.id.contains(q)
            }
            return items.isEmpty ? nil : (group, items)
        }
    }

    /// Why an entry can't run with these values, or nil.
    public static func paramsProblem(_ command: LibraryCommand, params: [String: String]) -> String? {
        guard !command.params.isEmpty, command.fullScript(params: params) == nil else { return nil }
        return "Enter a valid \(command.params.map { $0.label.lowercased() }.joined(separator: " and "))"
    }
}

/// The custom commands typed this session, newest first. Kept in memory only, never on disk: a typed command can hold a
/// password or a token.
public struct CommandHistory: Sendable, Equatable {
    public static let limit = 20
    public private(set) var items: [String] = []

    public init() {}

    public mutating func remember(_ command: String) {
        items.removeAll { $0 == command }
        items.insert(command, at: 0)
        items = Array(items.prefix(Self.limit))
    }

    public mutating func clear() { items = [] }
}
