import Foundation
import Observation
import RackoonCore
import RackoonSSHEmbedded

/// Where a tab's output goes: the SwiftTerm view in the app, a recorder in tests.
@MainActor
protocol TerminalDisplay: AnyObject {
    func feed(_ bytes: ArraySlice<UInt8>)
}

/// One terminal tab: a shell on a pty, opened at the emulator's measured size, its output passed through the shared
/// `TerminalOutputFilter` (highlighting in-process; iOS has no pty relay) and reconnected by Core's `ReconnectPolicy`
/// when the connection drops. The tab outlives screens: it ends only when closed, or when its server is removed or edited.
@MainActor @Observable
final class TerminalTab: Identifiable {
    enum Phase: Equatable {
        /// Opened, waiting for the view to report its size (the pty must start at that size).
        case waitingForSize
        case connecting
        case live
        /// The connection dropped; the next attempt starts at `at`.
        case reconnecting(attempt: Int, of: Int, at: Date)
        /// Over: the shell exited, the user stopped reconnecting, or retries ran out.
        case ended(String)
    }

    let id = UUID()
    let serverID: String
    var title: String
    private(set) var phase: Phase = .waitingForSize

    @ObservationIgnored private let opener: any TerminalOpening
    @ObservationIgnored private let command: String?
    @ObservationIgnored private var filter = TerminalOutputFilter()
    @ObservationIgnored private var policy = ReconnectPolicy()
    @ObservationIgnored private var shell: (any TerminalShell)?
    @ObservationIgnored private var size: (cols: Int, rows: Int)?
    @ObservationIgnored private var session: Task<Void, Never>?
    @ObservationIgnored private var input: AsyncStream<[UInt8]>.Continuation?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var closed = false
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Lines shown before the tab connects, kept so a view attached later still shows them.
    @ObservationIgnored private var pending: [UInt8] = []
    @ObservationIgnored weak var display: (any TerminalDisplay)? {
        didSet {
            guard let display, !pending.isEmpty else { return }
            display.feed(pending[...])
            pending = []
        }
    }

    init(serverID: String, title: String, opener: any TerminalOpening, command: String? = nil, highlight: Bool,
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.serverID = serverID
        self.title = title
        self.opener = opener
        self.command = command
        self.sleep = sleep
        self.now = now
        filter.isEnabled = highlight
    }

    var isLive: Bool { phase == .live }

    // MARK: from the view

    /// The emulator's grid size. The first one opens the session; later ones resize the pty (after a short pause, because
    /// layout reports several sizes while it settles).
    func setSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        let first = size == nil
        size = (cols, rows)
        if first, phase == .waitingForSize {
            connect()
            return
        }
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self, let shell = self.shell, let size = self.size else { return }
            await shell.resize(cols: size.cols, rows: size.rows)
        }
    }

    /// Keystrokes from the view. They go through one queue per session, written in order by one task: a task per
    /// keystroke reorders them (typing "docker" arrived as "docerk").
    func send(_ bytes: [UInt8]) {
        guard shell != nil, phase == .live else { return }
        input?.yield(bytes)
    }

    func setHighlight(_ on: Bool) { filter.isEnabled = on }

    // MARK: reconnect controls

    /// Reconnect Now (from the countdown or after the session ended): a fresh start with a fresh retry budget.
    func reconnectNow() {
        guard !closed else { return }
        policy.reset()
        session?.cancel()
        if let shell { Task { await shell.close() } }
        shell = nil
        connect()
    }

    /// Stop trying; the scrollback stays.
    func cancelReconnect() {
        guard case .reconnecting = phase else { return }
        session?.cancel()
        phase = .ended("Reconnecting stopped.")
    }

    func close() {
        closed = true
        session?.cancel()
        resizeTask?.cancel()
        if let shell { Task { await shell.close() } }
        shell = nil
    }

    // MARK: the session

    private func connect() {
        guard let size, !closed else { return }
        phase = .connecting
        session = Task { [weak self] in await self?.run(cols: size.cols, rows: size.rows) }
    }

    private func run(cols: Int, rows: Int) async {
        let started = now()
        let opened: any TerminalShell
        do {
            opened = try await opener.openTerminal(cols: cols, rows: rows, command: command)
        } catch {
            guard !Task.isCancelled, !closed else { return }
            // Only a network failure is worth retrying; a refused sign-in or a host-key problem needs the user.
            if Self.isNetworkFailure(error) {
                await ended(.connectionLost, after: 0, note: error.localizedDescription)
            } else {
                show("\r\n\u{1B}[2m\(error.localizedDescription)\u{1B}[0m\r\n")
                phase = .ended(error.localizedDescription)
            }
            return
        }
        guard !Task.isCancelled, !closed else {
            await opened.close()
            return
        }
        shell = opened
        let (keys, keySink) = AsyncStream.makeStream(of: [UInt8].self)
        input = keySink
        let writer = Task { for await bytes in keys { await opened.write(bytes) } }
        defer {
            keySink.finish()
            writer.cancel()
        }
        phase = .live
        // Catch up with a size that changed while connecting.
        if let size, size.cols != cols || size.rows != rows { await opened.resize(cols: size.cols, rows: size.rows) }
        for await chunk in opened.output {
            show(filter.process(chunk))
        }
        let rest = filter.finish()
        if !rest.isEmpty { show(rest) }
        let end = await opened.awaitEnd()
        guard !Task.isCancelled, !closed else { return }   // replaced by Reconnect Now, or closed
        shell = nil
        await ended(end, after: now().timeIntervalSince(started), note: nil)
    }

    private func ended(_ end: SessionEnd, after connected: TimeInterval, note: String?) async {
        switch policy.onEnded(end, connectedFor: connected) {
        case .retry(let delay, let attempt, let of):
            show("\r\n\u{1B}[2m[\(note ?? "Connection lost"). Reconnecting in \(Int(delay)) s (attempt \(attempt) of \(of)).]\u{1B}[0m\r\n")
            phase = .reconnecting(attempt: attempt, of: of, at: now().addingTimeInterval(delay))
            do { try await sleep(delay) } catch { return }   // cancelled: Reconnect Now or Cancel took over
            guard !Task.isCancelled, !closed else { return }
            connect()
        case .giveUp:
            switch end {
            case .remoteExit(let code):
                show("\r\n\u{1B}[2m[Session ended\(code == 0 ? "" : " (exit \(code))").]\u{1B}[0m\r\n")
                phase = .ended(code == 0 ? "Session ended." : "Session ended (exit \(code)).")
            case .connectionLost:
                phase = .ended("Connection lost. Reconnect to try again.")
            case .closedByUser:
                break
            }
        }
    }

    private func show(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        if let display { display.feed(bytes[...]) } else { pending += bytes }
    }

    private func show(_ text: String) { show(Array(text.utf8)) }

    nonisolated static func isNetworkFailure(_ error: Error) -> Bool {
        switch error as? EmbeddedSSHError {
        case .unreachable, .connectionLost, .timeout: true
        default: false
        }
    }
}

/// Every server's terminal tabs. Owned by the app model, so tabs survive moving between screens and servers.
@MainActor @Observable
final class TerminalStore {
    private(set) var tabs: [String: [TerminalTab]] = [:]
    var selected: [String: UUID] = [:]

    func tabs(for serverID: String) -> [TerminalTab] { tabs[serverID] ?? [] }

    func selectedTab(for serverID: String) -> TerminalTab? {
        let list = tabs(for: serverID)
        return list.first { $0.id == selected[serverID] } ?? list.last
    }

    @discardableResult
    func newTab(for serverID: String, opener: any TerminalOpening, command: String? = nil, title: String? = nil,
                highlight: Bool) -> TerminalTab {
        let n = tabs(for: serverID).count + 1
        let tab = TerminalTab(serverID: serverID, title: title ?? (n == 1 ? "Shell" : "Shell \(n)"), opener: opener,
                              command: command, highlight: highlight)
        tabs[serverID, default: []].append(tab)
        selected[serverID] = tab.id
        return tab
    }

    func close(_ tab: TerminalTab) {
        tab.close()
        tabs[tab.serverID]?.removeAll { $0.id == tab.id }
        if selected[tab.serverID] == tab.id { selected[tab.serverID] = tabs[tab.serverID]?.last?.id }
    }

    /// The server was removed or now points somewhere else: its sessions belong to the old address.
    func closeAll(for serverID: String) {
        for tab in tabs(for: serverID) { tab.close() }
        tabs[serverID] = nil
        selected[serverID] = nil
    }

    func closeEverything() {
        for id in Array(tabs.keys) { closeAll(for: id) }
    }

    func setHighlight(_ on: Bool) {
        for list in tabs.values { for tab in list { tab.setHighlight(on) } }
    }

    var count: Int { tabs.values.reduce(0) { $0 + $1.count } }
}
