import AppKit
import RackoonCore
import RackoonDemo
import RackoonSSHSystem
import Observation

/// One server on the dashboard: its latest reading and recent history.
struct FleetRow: Identifiable {
    let server: Server
    let state: ServerState
    /// Why it is not polled (host key not trusted yet, or changed), if it isn't.
    let blocked: String?
    let history: HealthHistory
    var id: String { server.id }

    var isOnline: Bool { blocked == nil && state.error == nil && state.overview != nil && !state.isStale }
}

enum ConnectionPhase: Equatable {
    case idle
    case checkingHostKey
    case needsTrust(HostKeyOffer)
    /// Host key changed: connecting is blocked until the user fixes known_hosts themselves.
    case blocked(String)
    case polling

    /// Why the server is not being polled, for the dashboard.
    var blockedReason: String? {
        switch self {
        case .needsTrust: "Waiting for you to trust its host key."
        case .blocked(let message): message
        default: nil
        }
    }
}

/// A reboot in progress for one server: asks the server to reboot, then waits until it answers with a new boot id.
/// When the ssh user's sudo wants a password, the flow pauses in `needsPassword` and the Overview asks for it.
@MainActor @Observable
final class RebootFlow {
    enum Phase: Equatable {
        case requesting
        /// `sudo -n` was refused: waiting for the user to type the sudo password (or give up). `problem` is why the
        /// last attempt failed, when there was one.
        case needsPassword(problem: String?)
        case waiting(since: Date)
        case back(after: TimeInterval)
        case timedOut
        case failed(String)
    }

    let server: Server
    private(set) var phase: Phase = .requesting
    var isActive: Bool {
        switch phase { case .requesting, .needsPassword, .waiting: true; default: false }
    }
    @ObservationIgnored private let session: RebootSession
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var onBack: () -> Void = {}

    init(server: Server) {
        self.server = server
        // RACKOON_DEMO_REBOOT=1 swift run RackoonMac: pretend to reboot (nothing is sent to the server) and come back
        // after about 15 seconds, so the waiting banner can be seen without taking a real server down.
        let transport: SSHTransport = ProcessInfo.processInfo.environment["RACKOON_DEMO_REBOOT"] != nil || Demo.isOn
            ? DemoRebootTransport() : makeTransport(for: server)
        session = RebootSession(transport: transport, policy: SafetyStore.shared.policy)
    }

    func start() {
        task = Task {
            do {
                try await session.reboot(confirmation: try session.confirm())
                await awaitReturn()
            } catch RebootError.noSudo {
                guard SudoVault.shared.isRemembered(server) else { phase = .needsPassword(problem: nil); return }
                switch await SudoVault.shared.unlock(server, reason: SudoVault.reason(server, doing: "reboot")) {
                case .success(let password): reboot(with: password, source: .saved)
                case .failure(.cancelled): phase = .failed(SudoSecretError.cancelled.errorDescription ?? "Cancelled.")
                case .failure(let error): phase = .needsPassword(problem: error.sheetProblem)
                }
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    /// Reboot with the saved sudo password (the confirm sheet showed the sudo command). If it can't be unlocked, fall
    /// back to asking; if it was forgotten in the meantime, start the plain way.
    func startWithSavedPassword() {
        let server = server
        task = Task {
            switch await SudoVault.shared.unlock(server, reason: SudoVault.reason(server, doing: "reboot")) {
            case .success(let password): reboot(with: password, source: .saved)
            case .failure(.cancelled): phase = .failed(SudoSecretError.cancelled.errorDescription ?? "Cancelled.")
            case .failure(.notRemembered): start()
            case .failure(let error): phase = .needsPassword(problem: error.sheetProblem)
            }
        }
    }

    /// The user typed the sudo password. It goes to the command's standard input; it is saved (sealed, see
    /// `SudoVault`) only if `remember` is on and the server accepted it.
    func submitPassword(_ password: String, remember: Bool) {
        guard case .needsPassword = phase else { return }
        reboot(with: password, source: .typed(remember: remember))
    }

    private func reboot(with password: String, source: SudoPasswordSource) {
        phase = .requesting
        let server = server
        task = Task {
            do {
                try await session.reboot(sudoPassword: password, confirmation: try session.confirmSudo())
                if source == .typed(remember: true) { await SudoVault.shared.remember(password, for: server) }
                await awaitReturn()
            } catch RebootError.badPassword {
                if source == .saved {
                    SudoVault.shared.forget(server.id)
                    phase = .needsPassword(problem: "The saved sudo password was not accepted, so it was forgotten.")
                } else {
                    phase = .needsPassword(problem: RebootError.badPassword.errorDescription)
                }
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    private func awaitReturn() async {
        phase = .waiting(since: Date())
        switch await session.waitForReturn() {
        case .back(let elapsed):
            phase = .back(after: elapsed)
            onBack()
        case .timedOut:
            phase = .timedOut
        }
    }

    func cancel() { task?.cancel() }
}

/// Saved servers, the selected server, and the live session for it.
/// The selected server is polled every few seconds; `fleet` polls the others once a minute for their status lights.
@MainActor @Observable
final class AppModel {
    private(set) var servers: [Server]
    private(set) var selectedID: String?
    private(set) var phase: ConnectionPhase = .idle
    private(set) var state = ServerState()
    /// Reboots started from this app, by server id (kept after they finish so the result can be read and dismissed).
    private(set) var reboots: [String: RebootFlow] = [:]
    /// A reboot waiting for the user's yes (shown as a sheet by the Overview screen).
    var pending: PendingAction?
    /// What a verbose ssh attempt found after the server refused the login (which keys were offered, what it accepts),
    /// for the Overview's explanation. Nil until a login fails; cleared when a poll succeeds or the server changes.
    private(set) var authAttempt: SSHAttempt?

    /// Slow polls of every server that is not selected.
    let fleet: FleetMonitor
    private let store: ServerStore
    private let verifier = HostKeyVerifier()
    private var session: ServerSession?
    private var listener: Task<Void, Never>?
    private var connecting: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    var selected: Server? { servers.first { $0.id == selectedID } }

    init(store: ServerStore = Demo.isOn ? Demo.store() : .defaultStore()) {
        self.store = store
        fleet = FleetMonitor(store: store)
        servers = store.loadServers()
        let last = UserDefaults.standard.string(forKey: "selectedServerID")
        selectedID = servers.contains { $0.id == last } ? last : servers.first?.id
    }

    func start() {
        // Registered here, not in init: `@State private var model = AppModel()` runs init on every parent
        // re-evaluation and discards all but the first instance, which would leak an observer each time.
        if wakeObserver == nil {
            // After sleep the SSH connection is usually dead: poll straight away instead of waiting for the next tick.
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                    self?.fleet.refreshAll()
                }
            }
        }
        SudoVault.shared.load(servers)   // which servers have a saved sudo password (never prompts)
        if let selected { connect(selected) }
        fleet.sync(servers: servers, selectedID: selectedID)
    }

    func select(_ server: Server) {
        guard server.id != selectedID else { return }
        // The server being left keeps its light: hand its latest reading to the slow poll.
        if let old = selectedID { fleet.seed(old, with: state) }
        selectedID = server.id
        if !Demo.isOn { UserDefaults.standard.set(server.id, forKey: "selectedServerID") }
        connect(server)
        fleet.sync(servers: servers, selectedID: selectedID)
    }

    func add(_ server: Server) {
        servers.append(server)
        persist()
        select(server)
        if selectedID == server.id, phase == .idle { connect(server) }
        fleet.sync(servers: servers, selectedID: selectedID)
    }

    /// Saves a new order for the servers (the server menu's drag and Move Up/Down). Only the order may differ.
    func reorder(_ newOrder: [Server]) {
        guard newOrder.count == servers.count, Set(newOrder.map(\.id)) == Set(servers.map(\.id)),
              newOrder.map(\.id) != servers.map(\.id) else { return }
        servers = newOrder
        persist()
    }

    /// Every saved server's latest reading, in saved order, for the dashboard: the selected one's live state, the others'
    /// once-a-minute ones, and each server's history.
    var fleetRows: [FleetRow] {
        servers.map { server in
            if server.id == selectedID {
                return FleetRow(server: server, state: state, blocked: phase.blockedReason, history: fleet.histories[server.id] ?? HealthHistory())
            }
            let entry = fleet.entries[server.id]
            return FleetRow(server: server, state: entry?.state ?? ServerState(), blocked: entry?.blocked,
                            history: fleet.histories[server.id] ?? HealthHistory())
        }
    }

    /// The status light of a server that is not selected (the selected one's comes from `phase` and `state`).
    func backgroundEntry(_ id: String) -> FleetEntry? { fleet.entries[id] }

    /// Saves an edited server. Returns true when its connection details changed (host, user, port, key file or the ssh
    /// config link), in which case the caller drops what it holds for the old address (terminal tabs, Docker models) and
    /// the selected server reconnects. A rename alone changes nothing live.
    @discardableResult
    func update(_ server: Server) -> Bool {
        guard let i = servers.firstIndex(where: { $0.id == server.id }) else { return false }
        let before = servers[i]
        servers[i] = server
        persist()
        guard !before.connectsLike(server) else { return false }
        // A saved sudo password belongs to the connection it was accepted on; so does unlocked Docker access.
        SudoVault.shared.forget(server.id)
        DockerElevation.shared.lock(server.id)
        // A snapshot taken from another address would be painted as this server's past: drop it.
        if before.host != server.host { store.deleteSnapshot(serverID: server.id) }
        fleet.reset(server.id)
        if server.id == selectedID { connect(server) }   // drops the old session and starts from the host-key check
        fleet.sync(servers: servers, selectedID: selectedID)
        return true
    }

    func remove(_ server: Server) {
        servers.removeAll { $0.id == server.id }
        SudoVault.shared.forget(server.id)
        DockerElevation.shared.lock(server.id)
        store.deleteSnapshot(serverID: server.id)
        persist()
        if selectedID == server.id {
            disconnect()
            selectedID = servers.first?.id
            state = ServerState()
            phase = .idle
            if let next = selected { connect(next) }
        }
        fleet.reset(server.id)
        fleet.sync(servers: servers, selectedID: selectedID)
    }

    /// `then` runs once the user has confirmed and the reboot has started (the Updates screen uses it to move to the
    /// Overview, which is where the waiting and reconnect progress is shown).
    func requestReboot(_ server: Server, then: (() -> Void)? = nil) {
        guard !SafetyStore.shared.readOnly, reboots[server.id]?.isActive != true else { return }
        if SudoVault.shared.isRemembered(server) {
            // A saved sudo password: confirm the sudo command that will actually run, then unlock it.
            pending = PendingAction(
                title: "Reboot \(server.name)?",
                message: "The server restarts in a couple of seconds. Everything running on it stops and comes back with it. Rackoon waits and reconnects when it is up again. " + SudoVault.useNote(server),
                serverName: server.name, command: RebootSession.sudoRebootCommand, destructive: true,
                run: { [weak self] in
                    guard let self else { return }
                    let flow = RebootFlow(server: server)
                    flow.onBack = { [weak self] in self?.refresh() }
                    self.reboots[server.id] = flow
                    flow.startWithSavedPassword()
                    then?()
                })
            return
        }
        pending = PendingAction(
            title: "Reboot \(server.name)?",
            message: "The server restarts in a couple of seconds. Everything running on it stops and comes back with it. Rackoon waits and reconnects when it is up again.",
            serverName: server.name, command: RebootSession.rebootCommand, destructive: true,
            run: { [weak self] in
                guard let self else { return }
                let flow = RebootFlow(server: server)
                flow.onBack = { [weak self] in self?.refresh() }   // poll straight away instead of waiting for the next tick
                self.reboots[server.id] = flow
                flow.start()
                then?()
            })
    }

    func dismissReboot(_ server: Server) {
        reboots[server.id]?.cancel()
        reboots[server.id] = nil
    }

    /// True while a manual refresh is running (the Overview's Refresh button shows it).
    private(set) var refreshing = false

    func refresh() {
        guard !refreshing else { return }
        guard let session else {
            // Nothing is polling (the host key was blocked, or the trust sheet was declined): start over from the check.
            if let selected { connect(selected) }
            return
        }
        refreshing = true
        let server = selected
        Task {
            await session.refresh()
            // Still refused after a manual retry: look again at which keys ssh offers, in case the user changed them.
            if let server, !Demo.isOn, let error = await session.state.error, ConnectionFailure.isAuthRefused(error) {
                authAttempt = await AuthProbe.attempt(server)
            }
            try? await Task.sleep(for: .milliseconds(500))   // long enough to be seen when the answer is instant
            refreshing = false
        }
    }

    /// The user confirmed the fingerprint shown in the trust sheet.
    func trustPending() {
        guard case .needsTrust(let offer) = phase, let server = selected else { return }
        do {
            try verifier.trust(offer)
            connect(server)
        } catch {
            state.error = "Could not save the host key: \(error.localizedDescription)"
            phase = .idle
        }
    }

    func declineTrust() {
        guard case .needsTrust = phase else { return }
        state.error = "Not connected: the host key was not trusted."
        phase = .idle
    }

    // MARK: - Connecting

    private func connect(_ server: Server) {
        disconnect()
        // Paint the last known data straight away, marked stale until the first poll lands.
        state = ServerState()
        authAttempt = nil
        if let cached = store.loadSnapshot(serverID: server.id) {
            state.overview = cached.overview
            state.attention = Attention.evaluate(cached.overview)
            state.updatedAt = cached.savedAt
            state.isStale = true
        }
        phase = .checkingHostKey
        connecting = Task { [weak self] in
            guard let self else { return }
            let status: HostKeyStatus = Demo.isOn ? .trusted : await verifier.check(server)
            if Task.isCancelled { return }
            switch status {
            case .trusted:
                fleet.noteTrusted(server.id)
                startSession(for: server)
            case .failed(let message):
                // Unreachable right now: keep polling so it recovers when the network returns.
                state.error = message
                startSession(for: server)
            case .authFailed(let message):
                // The host key is fine but the login was refused. Keep polling (it recovers once the key is sorted out)
                // and find out, verbosely, which keys ssh offered, so the Overview can say what to do.
                state.error = message
                startSession(for: server)
                let attempt = await AuthProbe.attempt(server)
                if !Task.isCancelled { authAttempt = attempt }
            case .unknown(let offer):
                phase = .needsTrust(offer)
            case .changed(let message):
                state.error = message
                phase = .blocked(message)
            }
        }
    }

    private func startSession(for server: Server) {
        let store = store, id = server.id
        let cached = state.overview.flatMap { o in state.updatedAt.map { (overview: o, savedAt: $0) } }
        let session = ServerSession(
            transport: makeTransport(for: server),
            cached: cached,
            onSnapshot: { overview in try? store.saveSnapshot(overview, serverID: id) })
        self.session = session
        phase = .polling
        listener = Task { [weak self] in
            for await next in await session.updates() {
                self?.state = next
                self?.fleet.record(id, next)
                if next.error == nil { self?.authAttempt = nil }   // logged in: the diagnosis is history
            }
        }
        Task { await session.start() }
    }

    private func disconnect() {
        connecting?.cancel(); connecting = nil
        listener?.cancel(); listener = nil
        if let session { Task { await session.stop() } }
        session = nil
    }

    private func persist() {
        try? store.saveServers(servers)
    }
}
