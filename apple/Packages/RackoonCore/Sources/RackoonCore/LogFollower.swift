import Foundation

/// One log line and the container (its compose service name) it came from.
public struct LogEntry: Sendable, Equatable, Identifiable {
    public let id: Int
    public let source: String
    public let line: String
    /// Only explicit markers count (see `LogLineParser`); nil when the line says nothing about its level.
    public let level: LogLevel?

    public init(id: Int, source: String, line: String) {
        self.id = id
        self.source = source
        self.line = line
        level = LogLineParser.level(of: line)
    }

    /// What a log row shows: the time, the level and the message with those two taken out of it.
    public var parts: LogParts { LogParts(line: line, level: level) }
}

public struct LogParts: Sendable, Equatable {
    public var time: String?
    public var level: LogLevel?
    public var message: String

    public init(time: String?, level: LogLevel?, message: String) {
        self.time = time
        self.level = level
        self.message = message
    }

    private static let leadingLevel = try! NSRegularExpression(
        pattern: #"^(\[(error|err|fatal|panic|critical|warn|warning|info|debug|trace)\]|(error|err|fatal|panic|critical|warn|warning|info|debug|trace):?|level=["']?[A-Za-z]+["']?)\s+"#,
        options: .caseInsensitive)

    init(line: String, level: LogLevel?) {
        let tsLength = LogLineParser.timestampLength(in: line)
        let time = tsLength > 0 ? String(line.prefix(tsLength)).trimmingCharacters(in: .whitespaces) : nil
        var rest = String(String(line.dropFirst(tsLength)).drop(while: { $0 == " " || $0 == "\t" }))
        // The level is shown on its own, so drop it from the start of the message (it stays in the middle of one).
        if level != nil, let m = Self.leadingLevel.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
           let r = Range(m.range, in: rest) {
            rest = String(rest[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        self.init(time: time, level: level, message: rest)
    }
}

public struct LogsState: Sendable, Equatable {
    /// Merged across the followed containers in arrival order, capped. Updated in batches so a chatty container cannot flood the UI.
    public var entries: [LogEntry] = []
    /// Lines received since following began (not capped), for "N new lines" while scrolled away.
    public var received = 0
    public var containers: [DockerContainer] = []
    public var live = false
    public var error: String?
    public init() {}
}

/// Follows the logs of a stack's containers at once, merged. Each container gets its own `docker logs -f` through
/// `transport.stream` (its own pty connection; cancelling sends Ctrl-C, so nothing is left running on the server). The same
/// rules as `DockerModel.showLogs` on the Mac and `LogFollower` in the Kotlin core.
@MainActor
public final class LogFollower {
    public private(set) var state = LogsState() { didSet { onChange?(state) } }
    /// Called after every change of `state`.
    public var onChange: ((LogsState) -> Void)?

    private let transport: SSHTransport
    private let maxEntries: Int
    private let flushDelay: TimeInterval
    private var pending: [LogEntry] = []
    private var nextID = 0
    private var flushScheduled = false
    private var generation = 0
    private var task: Task<Void, Never>?

    public init(transport: SSHTransport, maxEntries: Int = 2000, flushDelay: TimeInterval = 0.1) {
        self.transport = transport
        self.maxEntries = maxEntries
        self.flushDelay = flushDelay
    }

    /// Starts following these containers. Does nothing if exactly these are already being followed; otherwise restarts.
    public func follow(_ containers: [DockerContainer]) {
        guard !containers.isEmpty else { return }
        if containers.map(\.id) == state.containers.map(\.id), state.live { return }
        stop()
        generation += 1
        let gen = generation
        var next = LogsState()
        next.containers = containers
        next.live = true
        state = next
        let commands = containers.compactMap { c in DockerSession.logsCommand(id: c.id).map { (c, $0) } }
        task = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for (container, command) in commands {
                    group.addTask { await self?.followOne(container, command: command, generation: gen) }
                }
            }
            guard let self, self.generation == gen else { return }
            self.flush(gen)
            self.state.live = false
        }
    }

    private func followOne(_ container: DockerContainer, command: String, generation gen: Int) async {
        var buffer = LogBuffer()
        var seen = 0
        do {
            for try await chunk in transport.stream(command) {
                guard generation == gen else { return }
                buffer.append(chunk)
                let fresh = buffer.totalAppended - seen
                seen = buffer.totalAppended
                for line in buffer.lines.suffix(fresh) {
                    pending.append(LogEntry(id: nextID, source: container.logSource, line: line))
                    nextID += 1
                }
                scheduleFlush(gen)
            }
        } catch {
            guard generation == gen, !Task.isCancelled else { return }
            state.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func scheduleFlush(_ gen: Int) {
        guard !flushScheduled else { return }
        flushScheduled = true
        let delay = flushDelay
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            self?.flush(gen)
        }
    }

    private func flush(_ gen: Int) {
        flushScheduled = false
        guard generation == gen, !pending.isEmpty else { return }
        var next = state
        next.entries.append(contentsOf: pending)
        next.received += pending.count
        if next.entries.count > maxEntries { next.entries.removeFirst(next.entries.count - maxEntries) }
        pending = []
        state = next
    }

    /// Stops following (Ctrl-C reaches every remote `docker logs -f`) and clears what was collected.
    public func stop() {
        generation += 1
        pending = []
        flushScheduled = false
        task?.cancel()
        task = nil
        if state != LogsState() { state = LogsState() }
    }
}

/// Filtering for the log view: which container, which level, which text. Pure, so it is tested without a screen.
public enum LogView {
    /// A line with no recognised level counts as Info, so the level chips always add up to All.
    static func chipLevel(_ e: LogEntry) -> LogLevel { e.level ?? .info }

    public static func filtered(_ entries: [LogEntry], focus: String? = nil, level: LogLevel? = nil, search: String = "") -> [LogEntry] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        return entries.filter { e in
            (focus == nil || e.source == focus) && (level == nil || chipLevel(e) == level)
                && (needle.isEmpty || e.line.range(of: needle, options: .caseInsensitive) != nil)
        }
    }

    /// Counts for the level chips, from the lines of the focused container (before the level and search filters). The
    /// `nil` key is All.
    public static func counts(_ entries: [LogEntry], focus: String? = nil) -> [LogLevel?: Int] {
        let scoped = focus == nil ? entries : entries.filter { $0.source == focus }
        var counts: [LogLevel?: Int] = [nil: scoped.count]
        for e in scoped { counts[chipLevel(e), default: 0] += 1 }
        return counts
    }

    /// What Copy puts on the clipboard: the visible lines, tagged with their container when several are mixed.
    public static func text(_ entries: [LogEntry], showSource: Bool) -> String {
        entries.map { showSource ? "\($0.source) | \($0.line)" : $0.line }.joined(separator: "\n")
    }
}
