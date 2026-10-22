import Foundation
import Observation
import RackoonCore

/// A change waiting for the user's yes: the confirmation sheet shows the exact command (and a diff when there is one).
struct PendingAction: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let serverName: String
    let command: String
    /// Interrupts something that runs: the button is red and a hardware keyboard's Return does not press it.
    let destructive: Bool
    var preview: String?
    var confirmLabel = "Run Command"
    let run: @MainActor () -> Void
}

/// One streamed action (a stack or container action): its output so far, its state, and the size of the terminal that shows
/// it. The same as `ActionOutput` on the Mac.
@MainActor @Observable
final class ActionOutput: Identifiable {
    enum Phase: Equatable { case starting, running, succeeded, failed(Int32?), cancelled }

    nonisolated let id = UUID()
    /// What the run belongs to: a stack's `DockerStack.id`. Screens show only their own.
    let scope: String
    let title: String
    private(set) var phase: Phase = .starting
    /// Everything received, in chunks. The terminal view feeds only the chunks it has not shown yet.
    private(set) var chunks: [String] = []
    private(set) var cols = 80
    private(set) var rows = 24
    @ObservationIgnored private var sized = false
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored private var sawFinish = false
    @ObservationIgnored private var exitCode: Int32?

    init(scope: String, title: String) {
        self.scope = scope
        self.title = title
    }

    var isRunning: Bool { phase == .starting || phase == .running }

    /// Starts a run. `work` is handed the terminal's real size (so the remote pty matches it) and a sink for events, and
    /// returns when the command has finished. Events cross to the main actor through a stream, which keeps them in order.
    static func launch(scope: String, title: String, intro: String? = nil, sizeWait: Int = 30,
                       work: @escaping @Sendable (_ cols: Int, _ rows: Int, _ onEvent: @escaping @Sendable (ActionStreamEvent) -> Void) async -> Void,
                       completion: @escaping @MainActor () -> Void) -> ActionOutput {
        let run = ActionOutput(scope: scope, title: title)
        if let intro { run.apply(.output(intro)) }
        let (events, continuation) = AsyncStream<ActionStreamEvent>.makeStream()
        let consumer = Task { @MainActor in
            for await event in events { run.apply(event) }
        }
        run.task = Task { @MainActor in
            await run.waitForTerminalSize(tries: sizeWait)
            await work(run.cols, run.rows, { continuation.yield($0) })
            continuation.finish()
            await consumer.value
            run.finish(cancelled: Task.isCancelled)
            completion()
        }
        return run
    }

    /// The terminal view tells us its real size, so the remote pty (and compose's cursor-moving progress) matches it.
    func reportSize(cols: Int, rows: Int) {
        guard cols > 10, rows > 2 else { return }
        self.cols = cols
        self.rows = rows
        sized = true
    }

    /// The Output tab has to be on screen before the size is known. Wait for it briefly, then use what we have.
    private func waitForTerminalSize(tries: Int) async {
        for _ in 0..<tries where !sized { try? await Task.sleep(nanoseconds: 50_000_000) }
        if sized { try? await Task.sleep(nanoseconds: 250_000_000) }   // the first report can come before layout settles
        phase = .running
    }

    func apply(_ event: ActionStreamEvent) {
        switch event {
        case .output(let text): chunks.append(text)
        case .finished(let code): sawFinish = true; exitCode = code
        }
    }

    private func finish(cancelled: Bool) {
        if cancelled { phase = .cancelled }
        else if sawFinish, exitCode == 0 { phase = .succeeded }
        else { phase = .failed(exitCode) }
    }
}

/// One server's Docker: the polled containers, the actions (each confirmed with its exact command and streamed into the
/// stack's Output), logs and the remembered stacks that Docker can't list. Polls every 10 s only while a Docker screen is
/// attached. The same behaviour as `DockerModel` on the Mac; the words and rules are Core's `ActionPrompts`.
@MainActor @Observable
final class DockerModel {
    private(set) var state = DockerState()
    private(set) var logs = LogsState()
    /// A change waiting for the user's yes (shown as a sheet by the screen that asked).
    var pending: PendingAction?
    /// An action is running (they can take minutes), e.g. "Pulling images for media…".
    private(set) var working: String?
    /// The most recent action and everything it printed, kept until dismissed or replaced by the next one.
    private(set) var output: ActionOutput?
    /// Stacks created from this app that have no containers yet, by id. `docker ps` can't see them, so they are remembered
    /// (for this run of the app) until their containers show up.
    private(set) var createdStacks: [String: DockerStack] = [:]
    /// Stacks being deleted right now, kept visible (their containers vanish before the run ends).
    private(set) var removing: [String: DockerStack] = [:]
    /// The id of the stack a delete just removed, so its page can close.
    private(set) var removedStack: String?
    private(set) var refreshing = false

    let serverID: String
    let serverName: String
    @ObservationIgnored let serverUser: String?
    @ObservationIgnored let transport: SSHTransport
    @ObservationIgnored let safety: SafetyStore
    @ObservationIgnored private let session: DockerSession
    @ObservationIgnored private let follower: LogFollower
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var attached = 0
    /// The compose/.env editor of each stack, so drafts survive leaving its page. Keyed by the stack and its files.
    @ObservationIgnored private var editors: [String: StackEditorModel] = [:]
    /// How long an action waits for its Output view to report a size (tests have none).
    @ObservationIgnored var sizeWait = 30

    init(server: Server, transport: SSHTransport, safety: SafetyStore, interval: TimeInterval = 10) {
        serverID = server.id
        serverName = server.name
        serverUser = server.user
        self.transport = transport
        self.safety = safety
        session = DockerSession(transport: transport, interval: interval, policy: safety.policy)
        follower = LogFollower(transport: transport)
        follower.onChange = { [weak self] in self?.logs = $0 }
    }

    // MARK: polling

    /// Screens that show Docker data attach while visible; polling runs while at least one is. Counted, because a new
    /// screen can appear before the old one disappears.
    func attach() {
        attached += 1
        guard listener == nil else { return }
        let session = session
        listener = Task { [weak self] in
            for await next in await session.updates() { self?.state = next }
        }
        Task { await session.start() }
    }

    func detach() {
        attached = max(0, attached - 1)
        guard attached == 0 else { return }
        follower.stop()
        listener?.cancel()
        listener = nil
        let session = session
        Task { await session.stop() }
    }

    /// The app went to the background, or the server's address changed: stop everything this model runs.
    func shutdown() {
        attached = 0
        follower.stop()
        for editor in editors.values { editor.close() }
        output?.task?.cancel()
        listener?.cancel()
        listener = nil
        let session = session
        Task { await session.stop() }
    }

    func refresh() async {
        refreshing = true
        await session.refresh()
        refreshing = false
    }

    // MARK: what is shown

    /// Every stack to show: the ones Docker reports, then created or deleting ones it no longer lists.
    var stacks: [DockerStack] {
        let reported = state.snapshot?.stacks ?? []
        let ids = Set(reported.map(\.id))
        let extra = createdStacks.merging(removing) { $1 }.values.filter { !ids.contains($0.id) }.sorted { $0.name < $1.name }
        return reported + extra
    }

    func stack(id: String) -> DockerStack? { stacks.first { $0.id == id } }

    var suggestedStackFolder: String { NewStackDefaults.parentDirectory(stacks: state.snapshot?.stacks ?? [], user: serverUser) }

    func adopt(_ stack: DockerStack) { createdStacks[stack.id] = stack }

    func isBusy(_ stack: DockerStack) -> Bool {
        state.busyStacks.contains(stack.name) || state.busyStacks.contains(stack.id) || stack.containers.contains { state.busy.contains($0.id) }
    }

    // MARK: why things are unavailable

    func composeBlockedReason(for stack: DockerStack) -> String? {
        ActionPrompts.blockedReason(stack, readOnly: safety.readOnly, otherActionRunning: working != nil)
    }

    func standaloneBlockedReason(for stack: DockerStack) -> String? {
        ActionPrompts.standaloneBlockedReason(stack, readOnly: safety.readOnly, otherActionRunning: working != nil)
    }

    func containerBlockedReason() -> String? {
        if safety.readOnly { return "Read-only mode is on" }
        if working != nil { return "Another action is running" }
        return nil
    }

    // MARK: asking

    /// Stop and restart ask first, showing the exact command. Start runs straight away (it cannot break anything).
    func request(_ action: DockerAction, on container: DockerContainer) {
        guard containerBlockedReason() == nil, let intent = action.intent(containerID: container.id) else { return }
        guard let prompt = ActionPrompts.container(action, container) else { perform(action, on: container); return }
        pending = PendingAction(title: prompt.title, message: prompt.message, serverName: serverName, command: intent.command,
                                destructive: prompt.destructive, run: { [weak self] in self?.perform(action, on: container) })
    }

    func request(_ action: ComposeAction, on stack: DockerStack) {
        guard composeBlockedReason(for: stack) == nil, let intent = action.intent(for: stack) else { return }
        let prompt = ActionPrompts.stack(action, stack)
        pending = PendingAction(title: prompt.title, message: prompt.message, serverName: serverName, command: intent.command,
                                destructive: prompt.destructive, run: { [weak self] in self?.run(action, on: stack, label: prompt.working) })
    }

    func requestRebuild(of container: DockerContainer, in stack: DockerStack) {
        guard composeBlockedReason(for: stack) == nil, let service = container.service,
              let intent = ComposeAction.rebuild.intent(for: stack, service: service) else { return }
        let prompt = ActionPrompts.rebuild(service: service, in: stack)
        pending = PendingAction(title: prompt.title, message: prompt.message, serverName: serverName, command: intent.command,
                                destructive: prompt.destructive,
                                run: { [weak self] in self?.run(.rebuild, on: stack, service: service, label: prompt.working) })
    }

    func requestPull(of stack: DockerStack) {
        guard standaloneBlockedReason(for: stack) == nil, let intent = StandaloneAction.pullImage.intent(for: stack),
              let prompt = ActionPrompts.pull(stack) else { return }
        pending = PendingAction(title: prompt.title, message: prompt.message, serverName: serverName, command: intent.command,
                                destructive: false, run: { [weak self] in self?.run(.pullImage, on: stack, label: prompt.working) })
    }

    // MARK: running

    /// Start, stop or restart one container, with its output in the stack's Output.
    func perform(_ action: DockerAction, on container: DockerContainer) {
        guard working == nil else { return }
        working = "\(action.rawValue.capitalized) \(container.name)…"
        let session = session
        output = ActionOutput.launch(
            scope: DockerStack.id(of: container), title: "docker \(action.rawValue) \(container.name)",
            intro: "\u{1B}[2m$ docker \(action.rawValue) \(container.name)\u{1B}[0m\r\n", sizeWait: sizeWait,
            work: { cols, rows, onEvent in
                let confirmation = try? session.confirm(action, containerID: container.id)
                await session.performStreaming(action, containerID: container.id, confirmation: confirmation,
                                               cols: cols, rows: rows, onEvent: onEvent)
            },
            completion: { [weak self] in self?.working = nil })
    }

    private func run(_ action: ComposeAction, on stack: DockerStack, service: String? = nil, label: String) {
        guard working == nil else { return }
        working = label
        let session = session
        output = ActionOutput.launch(
            scope: stack.id, title: "docker compose \(action.rawValue)" + (service.map { " \($0)" } ?? ""), sizeWait: sizeWait,
            work: { cols, rows, onEvent in
                let confirmation = try? session.confirm(action, stack: stack, service: service)
                await session.performStreaming(action, stack: stack, service: service, confirmation: confirmation,
                                               cols: cols, rows: rows, onEvent: onEvent)
            },
            completion: { [weak self] in self?.working = nil })
    }

    private func run(_ action: StandaloneAction, on stack: DockerStack, label: String, completion: ((Bool) -> Void)? = nil) {
        guard working == nil else { return }
        working = label
        let session = session
        let title = switch action {
        case .pullImage: "docker pull \(StandaloneAction.pullableImage(of: stack) ?? stack.name)"
        case .remove: "docker rm \(stack.name)"
        }
        output = ActionOutput.launch(
            scope: stack.id, title: title, sizeWait: sizeWait,
            work: { cols, rows, onEvent in
                let confirmation = try? session.confirm(action, stack: stack)
                await session.performStreaming(action, stack: stack, confirmation: confirmation, cols: cols, rows: rows, onEvent: onEvent)
            },
            completion: { [weak self] in
                guard let self else { return }
                self.working = nil
                completion?(self.output?.phase == .succeeded)
            })
    }

    /// Runs `up -d` without its own confirmation, for a flow the user already confirmed as a whole (Save and Redeploy, Create
    /// and start). The policy still applies: Read-only refuses it.
    func runDirect(_ action: ComposeAction, on stack: DockerStack) {
        guard composeBlockedReason(for: stack) == nil else { return }
        run(action, on: stack, label: ActionPrompts.stack(action, stack).working)
    }

    /// Deletes a compose stack after the sheet's confirmation. On success the stack is forgotten and its page closes; on
    /// failure or cancel it stays listed as "Not started" so its Output can be read and its files are not orphaned.
    func delete(_ stack: DockerStack, _ removal: StackRemoval) {
        guard working == nil else { return }
        working = "Deleting \(stack.name)…"
        removing[stack.id] = stack
        removedStack = nil
        let session = session
        output = ActionOutput.launch(
            scope: stack.id, title: "docker compose down", sizeWait: sizeWait,
            work: { cols, rows, onEvent in
                let confirmation = try? session.confirm(removal, stack: stack)
                await session.performStreaming(removal, stack: stack, confirmation: confirmation, cols: cols, rows: rows, onEvent: onEvent)
            },
            completion: { [weak self] in
                guard let self else { return }
                self.working = nil
                self.removing[stack.id] = nil
                if self.output?.phase == .succeeded {
                    self.createdStacks[stack.id] = nil
                    self.removedStack = stack.id
                } else {
                    var left = stack
                    left.containers = []
                    self.createdStacks[stack.id] = left
                }
            })
    }

    /// Deletes a standalone container after the sheet's confirmation.
    func delete(_ stack: DockerStack, volumes: Bool) {
        guard working == nil else { return }
        removing[stack.id] = stack
        removedStack = nil
        run(.remove(volumes: volumes), on: stack, label: "Deleting \(stack.name)…") { [weak self] succeeded in
            guard let self else { return }
            self.removing[stack.id] = nil
            if succeeded { self.removedStack = stack.id }
        }
    }

    /// Stops the running action (Ctrl-C reaches the command on the server).
    func cancelOutput() { output?.task?.cancel() }

    func dismissOutput() {
        guard output?.isRunning != true else { return }
        output = nil
    }

    /// The editor for a stack's files (made on first use; a stack whose files moved gets a new one).
    func editor(for stack: DockerStack) -> StackEditorModel {
        let key = stack.id + "|" + (stack.workingDir ?? "") + "|" + stack.configFiles.joined(separator: ",")
        if let editor = editors[key] { return editor }
        let editor = StackEditorModel(stack: stack, transport: transport, safety: safety, serverName: serverName)
        editors[key] = editor
        return editor
    }

    // MARK: logs

    /// Follows these containers' logs, merged (one `docker logs -f` each). Nothing if they are already followed.
    func followLogs(_ containers: [DockerContainer]) { follower.follow(containers) }

    /// Stops following: Ctrl-C reaches every remote `docker logs -f`.
    func stopLogs() { follower.stop() }
}

/// Every server's Docker model, made on first use and kept while the app runs (so an action's output survives leaving the
/// screen). A model is dropped when its server is removed or now connects elsewhere.
@MainActor @Observable
final class DockerStore {
    @ObservationIgnored private var models: [String: DockerModel] = [:]

    func model(for server: Server, make: () -> DockerModel) -> DockerModel {
        if let model = models[server.id] { return model }
        let model = make()
        models[server.id] = model
        return model
    }

    func existing(_ id: String) -> DockerModel? { models[id] }

    func forget(_ id: String) {
        models[id]?.shutdown()
        models[id] = nil
    }

    func forgetAll() {
        for id in Array(models.keys) { forget(id) }
    }

    func pauseAll() {
        for model in models.values { model.stopLogs() }
    }
}
