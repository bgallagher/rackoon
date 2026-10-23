import Foundation
import Observation
import RackoonCore
import RackoonSSHEmbedded

/// Every server's latest reading, from Core's `ServerSession`s. A server is polled only while a screen watches it: every
/// 5 s while its Overview is open, once a minute while the dashboard shows it, and not at all in the background. Before
/// the first poll the cached snapshot is shown (marked stale); each good reading is saved as the new snapshot. A server
/// whose host key is not trusted, or whose saved key or password is missing, is never polled.
@MainActor @Observable
final class FleetModel {
    static let fastInterval: TimeInterval = 5
    static let slowInterval: TimeInterval = 60
    static let secondReadingDelay: TimeInterval = 3

    private(set) var states: [String: ServerState] = [:]
    private(set) var history: [String: HealthHistory] = [:]
    /// Why a server is not polled (host key or sign-in), when that is the case.
    private(set) var blocked: [String: String] = [:]

    struct Dependencies {
        /// The transport to poll with, or a reason it can't be made (no saved key).
        var transport: @MainActor (Server) -> Result<SSHTransport, BlockedReason>
        /// Whether the host key lets this server be polled.
        var gate: @MainActor (Server) -> Gate
        /// Reads the server's host key and compares it with the trusted one (for a server not checked yet this run, or
        /// one whose key turned out to have changed).
        var checkHostKey: @MainActor (Server) async -> Void = { _ in }
        var store: ServerStore
        var server: @MainActor (String) -> Server?
        var now: @Sendable () -> Date = { Date() }
    }

    struct BlockedReason: Error {
        let message: String
    }

    enum Gate: Equatable {
        case open
        /// Not checked yet this run: check it, then decide.
        case needsCheck
        case blocked(String)
    }

    @ObservationIgnored private let deps: Dependencies
    @ObservationIgnored private var sessions: [String: Running] = [:]
    @ObservationIgnored private var watchers: [String: (fast: Int, slow: Int)] = [:]
    @ObservationIgnored private var paused = false
    @ObservationIgnored private var snapshots: [String: ServerState] = [:]
    @ObservationIgnored private var checking: Set<String> = []

    private struct Running {
        let session: ServerSession
        let transport: SSHTransport
        let fast: Bool
        let listener: Task<Void, Never>
        var starter: Task<Void, Never>?
    }

    init(_ deps: Dependencies) { self.deps = deps }

    /// The latest reading, or the cached snapshot (stale) when nothing has been polled yet.
    func state(for id: String) -> ServerState {
        if let state = states[id] { return state }
        if let cached = snapshots[id] { return cached }
        var state = ServerState()
        if let cached = deps.store.loadSnapshot(serverID: id) {
            state.overview = cached.overview
            state.attention = Attention.evaluate(cached.overview)
            state.updatedAt = cached.savedAt
            state.isStale = true
        }
        snapshots[id] = state   // read from disk once, not on every redraw
        return state
    }

    // MARK: watching

    func attach(_ id: String, fast: Bool) {
        var w = watchers[id] ?? (0, 0)
        if fast { w.fast += 1 } else { w.slow += 1 }
        watchers[id] = w
        reconcile(id)
    }

    func detach(_ id: String, fast: Bool) {
        guard var w = watchers[id] else { return }
        if fast { w.fast = max(0, w.fast - 1) } else { w.slow = max(0, w.slow - 1) }
        watchers[id] = w.fast + w.slow == 0 ? nil : w
        reconcile(id)
    }

    /// Polls now (pull to refresh, Try Again). Starts from the host key and sign-in again if the server was blocked.
    func refresh(_ id: String) async {
        if sessions[id] == nil, let server = deps.server(id) {
            // Blocked by the host key (or never checked): read it again first, since Try Again means "look again".
            if deps.gate(server) != .open { await deps.checkHostKey(server) }
            reconcile(id)
        }
        await sessions[id]?.session.refresh()
    }

    /// The app went to the background: iOS suspends it soon, so stop polling now rather than leave half-open polls.
    func pause() {
        paused = true
        for id in Array(sessions.keys) { stop(id) }
    }

    func resume() {
        paused = false
        for id in watchers.keys { reconcile(id) }
    }

    /// The server's address or sign-in changed (or its key was just trusted): drop the old session and reading.
    func reset(_ id: String) {
        stop(id)
        states[id] = nil
        snapshots[id] = nil
        history[id] = nil
        blocked[id] = nil
        reconcile(id)
    }

    func forget(_ id: String) {
        stop(id)
        watchers[id] = nil
        states[id] = nil
        history[id] = nil
        blocked[id] = nil
        snapshots[id] = nil
        deps.store.deleteSnapshot(serverID: id)
    }

    // MARK: sessions

    private func reconcile(_ id: String) {
        let w = watchers[id] ?? (0, 0)
        let wanted: Bool? = paused || w.fast + w.slow == 0 ? nil : w.fast > 0
        guard let fast = wanted, let server = deps.server(id) else {
            stop(id)
            return
        }
        if let running = sessions[id], running.fast == fast { return }
        stop(id)
        switch deps.gate(server) {
        case .open:
            break
        case .blocked(let reason):
            blocked[id] = reason
            return
        case .needsCheck:
            blocked[id] = nil
            guard !checking.contains(id) else { return }
            checking.insert(id)
            Task {
                await deps.checkHostKey(server)
                checking.remove(id)
                // Decide again, unless the check could not change anything (it would only ask for another check).
                if deps.gate(server) != .needsCheck { reconcile(id) }
            }
            return
        }
        let transport: SSHTransport
        switch deps.transport(server) {
        case .success(let t): transport = t
        case .failure(let reason):
            blocked[id] = reason.message
            return
        }
        blocked[id] = nil
        let current = state(for: id)
        let cached = current.overview.map { (overview: $0, savedAt: current.updatedAt ?? deps.now()) }
        let store = deps.store
        let session = ServerSession(transport: transport, interval: fast ? Self.fastInterval : Self.slowInterval,
                                    cached: cached, onSnapshot: { overview in try? store.saveSnapshot(overview, serverID: id) })
        let now = deps.now
        let listener = Task { [weak self] in
            for await state in await session.updates() {
                guard let self else { return }
                self.receive(state, for: id, at: now())
            }
        }
        sessions[id] = Running(session: session, transport: transport, fast: fast, listener: listener)
        sessions[id]?.starter = Task {
            await session.start()
            // CPU use needs two readings. At a minute apart the dashboard would show none for a minute, so take the
            // second one a few seconds after the first.
            if !fast {
                try? await Task.sleep(nanoseconds: UInt64(Self.secondReadingDelay * 1_000_000_000))
                if !Task.isCancelled { await session.refresh() }
            }
        }
    }

    private func receive(_ state: ServerState, for id: String, at date: Date) {
        // The server presented another key than the trusted one: stop, and let the host-key check show it as blocked.
        if state.error == EmbeddedSSHError.hostKeyChangedDescription, let server = deps.server(id) {
            stop(id)
            states[id] = state
            Task {
                await deps.checkHostKey(server)
                reconcile(id)
            }
            return
        }
        // Keep a known CPU figure across a session swap (fast <-> slow), until the new session has two readings itself.
        var next = state
        if next.cpuPercent == nil, let old = states[id]?.cpuPercent, !next.isStale { next.cpuPercent = old }
        states[id] = next
        if let sample = HealthSample(state: next, at: date) {
            history[id, default: HealthHistory()].record(sample)
        }
    }

    private func stop(_ id: String) {
        guard let running = sessions.removeValue(forKey: id) else { return }
        running.listener.cancel()
        running.starter?.cancel()
        let session = running.session, transport = running.transport
        Task {
            await session.stop()
            await (transport as? EmbeddedSSHTransport)?.close()
        }
    }

    var watchedIDs: Set<String> { Set(watchers.keys) }
    var pollingIDs: Set<String> { Set(sessions.keys) }
    func isFast(_ id: String) -> Bool? { sessions[id]?.fast }
}
