import Foundation

public enum AddTarget: String, Sendable, Equatable { case newStack, existing }

/// The existing stack's files as read from the server when it was chosen.
public struct ExistingStackFiles: Sendable, Equatable {
    public var compose: RemoteFileState?
    public var env: RemoteFileState?
    public var error: String?
    public init(compose: RemoteFileState? = nil, env: RemoteFileState? = nil, error: String? = nil) {
        self.compose = compose
        self.env = env
        self.error = error
    }
}

public struct AddState: Sendable, Equatable {
    public var target: AddTarget = .newStack
    public var spec = ContainerSpec()
    public var stackName = ""
    public var folder: String
    public var existingName: String?
    /// New stacks only: the user pastes a whole compose.yaml (and optionally a .env) instead of filling in the form.
    public var paste = false
    public var pasteCompose = ""
    public var pasteEnv = ""
    public var existing: ExistingStackFiles?
    public var validation: ValidationResult?
    /// What `validation` belongs to, so a result for older text is never shown as current.
    public var validatedKey: String?
    public var checkError: String?
    public var imageStatus: ImageStatus?
    public var listening: Set<Int>?
    public var working = false
    public var notice: String?

    public init(folder: String) { self.folder = folder }
}

/// What a create or save will do, for the confirmation sheet.
public struct DeployRequest: Sendable {
    public enum Work: Sendable {
        case newStack(NewStackPlan)
        /// `.env` first, then compose.
        case existingStack([FileEdit])
    }
    public let work: Work
    public let stack: DockerStack
    public let start: Bool
    public let title: String
    public let message: String
    public let preview: String
}

public struct DeployResult: Sendable, Equatable {
    public let stack: DockerStack
    public let isNew: Bool
    public let start: Bool
}

/// The Add container page's rules: where the container goes (a new stack, or an existing one), the form or a pasted compose
/// file, the checks that run on the server (compose, image, ports, name), and what the create or save does. Pure of any
/// screen. The rules of `AddContainerModel` on the Mac without its two-way text editing (the preview is read-only; a pasted
/// file replaces the form), as in `AddContainerDraft` in the Kotlin core.
@MainActor
public final class AddContainerDraft {
    public private(set) var state: AddState { didSet { onChange?(state) } }
    /// Called after every change of `state`.
    public var onChange: ((AddState) -> Void)?

    private let transport: SSHTransport
    private let policy: ActionPolicy
    private let serverName: String
    private let stacks: () -> [DockerStack]
    private let containers: () -> [DockerContainer]
    private let stackBlockedReason: (DockerStack) -> String?
    private let debounce: TimeInterval
    private let newSession: NewStackSession
    private let checker: ContainerChecker
    private var fileSession: StackFileSession?
    private var checkTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var portsTask: Task<Void, Never>?
    private var generation = 0
    private var imageFor: String?
    private var portsFor: [Int]?

    public init(transport: SSHTransport, policy: ActionPolicy, serverName: String, folder: String,
                stacks: @escaping () -> [DockerStack], containers: @escaping () -> [DockerContainer],
                stackBlockedReason: @escaping (DockerStack) -> String? = { _ in nil }, debounce: TimeInterval = 0.6) {
        self.transport = transport
        self.policy = policy
        self.serverName = serverName
        self.stacks = stacks
        self.containers = containers
        self.stackBlockedReason = stackBlockedReason
        self.debounce = debounce
        state = AddState(folder: folder)
        newSession = NewStackSession(transport: transport, policy: policy)
        checker = ContainerChecker(transport: transport)
    }

    // MARK: choosing where it goes

    public var existingCandidates: [DockerStack] { stacks().filter { !$0.isStandalone && StackFiles.editable(for: $0) != nil } }
    private func existingStack(_ s: AddState) -> DockerStack? { s.existingName.flatMap { n in stacks().first { $0.name == n } } }

    private func change(_ block: (inout AddState) -> Void) {
        var s = state
        block(&s)
        state = s
    }

    public func setTarget(_ target: AddTarget) {
        guard state.target != target else { return }
        change { $0.target = target; $0.notice = nil }
        scheduleChecks()
    }
    public func setStackName(_ name: String) { change { $0.stackName = name; $0.notice = nil }; scheduleChecks() }
    public func setFolder(_ folder: String) { change { $0.folder = folder; $0.notice = nil }; scheduleChecks() }
    public func setSpec(_ spec: ContainerSpec) { change { $0.spec = spec; $0.notice = nil }; scheduleChecks() }
    public func setPaste(_ on: Bool) { change { $0.paste = on; $0.notice = nil }; scheduleChecks() }
    public func setPasteCompose(_ text: String) { change { $0.pasteCompose = text; $0.notice = nil }; scheduleChecks() }
    public func setPasteEnv(_ text: String) { change { $0.pasteEnv = text; $0.notice = nil }; scheduleChecks() }

    public func chooseExisting(_ name: String) {
        guard let stack = stacks().first(where: { $0.name == name }), let files = StackFiles.editable(for: stack) else { return }
        change { $0.existingName = name; $0.existing = ExistingStackFiles(); $0.notice = nil }
        let session = StackFileSession(transport: transport, policy: policy, stack: stack)
        fileSession = session
        scheduleChecks()
        Task {
            var loaded: ExistingStackFiles
            do {
                loaded = ExistingStackFiles(compose: try await session.read(files[0]), env: try await session.read(files[files.count - 1]))
            } catch {
                loaded = ExistingStackFiles(error: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
            guard state.existingName == name else { return }
            change { $0.existing = loaded }
            scheduleChecks()
        }
    }

    // MARK: the files

    private func pastedMode(_ s: AddState) -> Bool { s.paste && s.target == .newStack }
    private func originalCompose(_ s: AddState) -> String? { s.existing?.compose?.content }
    private func originalEnv(_ s: AddState) -> String { s.existing?.env?.content ?? "" }
    private func existingReady(_ s: AddState) -> Bool { s.existing != nil && s.existing?.error == nil && originalCompose(s) != nil }

    private func envProblemFree(_ spec: ContainerSpec) -> Bool {
        spec.activeEnv.allSatisfy { ContainerSpec.envProblem($0) == nil } && Set(spec.activeEnv.map(\.key)).count == spec.activeEnv.count
    }

    private func generatedCompose(_ s: AddState) -> String {
        switch s.target {
        case .newStack:
            if s.spec.name.isEmpty || s.spec.nameProblem != nil || s.spec.image.isEmpty || s.spec.imageProblem != nil {
                return "services:\n  # Enter a container name and an image\n"
            }
            return s.spec.composeText
        case .existing:
            guard let original = originalCompose(s) else { return "" }
            if s.spec.blockingProblem != nil { return original }
            return (try? ComposeInsert.adding(s.spec, to: original)) ?? original
        }
    }

    private func generatedEnv(_ s: AddState) -> String {
        switch s.target {
        case .newStack: envProblemFree(s.spec) ? s.spec.envText : ""
        case .existing: envProblemFree(s.spec) ? EnvMerge.merge(existing: originalEnv(s), adding: s.spec.activeEnv).text : originalEnv(s)
        }
    }

    public func composeText(_ s: AddState? = nil) -> String { let s = s ?? state; return pastedMode(s) ? s.pasteCompose : generatedCompose(s) }
    public func envText(_ s: AddState? = nil) -> String { let s = s ?? state; return pastedMode(s) ? s.pasteEnv : generatedEnv(s) }

    private func key(_ s: AddState) -> String {
        [s.target.rawValue, s.stackName, s.existingName ?? "", s.folder, composeText(s), envText(s)].joined(separator: "\u{0}")
    }

    public func plan(_ s: AddState? = nil) -> NewStackPlan {
        let s = s ?? state
        return NewStackPlan(name: s.stackName, parentDirectory: s.folder, compose: composeText(s), env: envText(s))
    }

    /// Why adding to the existing stack's file is impossible (inline `services:`, a duplicate name), or nil.
    public func insertProblem(_ s: AddState? = nil) -> String? {
        let s = s ?? state
        guard s.target == .existing, existingReady(s), s.spec.blockingProblem == nil, let original = originalCompose(s) else { return nil }
        do { _ = try ComposeInsert.adding(s.spec, to: original); return nil } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Lines to mark in the preview of the compose file or the .env.
    public func changedLines(env: Bool, _ s: AddState? = nil) -> Set<Int> {
        let s = s ?? state
        let now = env ? envText(s) : composeText(s)
        switch s.target {
        case .newStack:
            let n = now.components(separatedBy: "\n").count - (now.hasSuffix("\n") ? 1 : 0)
            return n > 0 ? Set(1...n) : []
        case .existing:
            return LineDiff.changedLineNumbers(old: env ? originalEnv(s) : (originalCompose(s) ?? ""), new: now)
        }
    }

    // MARK: checks

    private func composeSkipReason(_ s: AddState) -> String? {
        if !pastedMode(s), let problem = s.spec.blockingProblem { return problem }
        switch s.target {
        case .newStack:
            let p = plan(s)
            if pastedMode(s), s.pasteCompose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Paste a compose.yaml" }
            if let problem = p.nameProblem { return s.stackName.isEmpty ? "Enter a stack name" : problem }
            return p.folderProblem
        case .existing:
            if s.existingName == nil { return "Choose a stack" }
            if let error = s.existing?.error { return error }
            return existingReady(s) ? nil : "Reading the stack from \(serverName)…"
        }
    }

    private func scheduleChecks() {
        let s = state
        // Image and port lookups only rerun when what they look at changed.
        if !pastedMode(s), s.spec.image != imageFor {
            imageTask?.cancel()
            imageFor = s.spec.image
            change { $0.imageStatus = nil }
            let image = s.spec.image
            if s.spec.imageProblem == nil, !image.isEmpty {
                let checker = checker, delay = debounce
                imageTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                    guard !Task.isCancelled else { return }
                    let status = await checker.imageStatus(image)
                    if imageFor == image { change { $0.imageStatus = status } }
                }
            }
        }
        let ports = s.spec.activePorts.compactMap(\.hostPort)
        if portsTask == nil || ports != portsFor {
            portsTask?.cancel()
            portsFor = ports
            change { $0.listening = nil }
            let checker = checker
            portsTask = Task {
                let found = await checker.listeningPorts()
                guard !Task.isCancelled else { return }
                if portsFor == ports { change { $0.listening = found ?? [] } }
            }
        }
        checkTask?.cancel()
        generation += 1
        let mine = generation
        if composeSkipReason(s) != nil || !EnvSyntax.check(envText(s)).isEmpty {
            change { $0.validation = nil; $0.validatedKey = nil; $0.checkError = nil }
            return
        }
        let snapshotKey = key(s)
        let compose = composeText(s)
        let plan = plan(s)
        let stack = existingStack(s)
        let session = fileSession
        let target = s.target
        let added = Set(s.spec.activeEnv.map(\.key))
        let newSession = newSession, delay = debounce
        if state.validatedKey != snapshotKey { change { $0.validation = nil } }
        checkTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))   // wait for a pause in typing
            guard !Task.isCancelled else { return }
            var outcome: ValidationResult?
            var failure: String?
            do {
                switch target {
                case .newStack:
                    outcome = try await newSession.check(plan)
                case .existing:
                    guard let stack, let session, let file = StackFiles.editable(for: stack)?.first else { return }
                    let result = try await session.validate(file, content: compose)
                    // The new variables are not in the server's .env until we save, so compose warns about them; that is expected.
                    outcome = ValidationResult(issues: result.issues.filter { i in
                        !(i.severity == .warning && added.contains { i.message.contains("\"\($0)\"") })
                    })
                }
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            guard generation == mine else { return }
            change { $0.validation = outcome; $0.validatedKey = outcome == nil ? nil : snapshotKey; $0.checkError = failure }
        }
    }

    /// The variables compose says are not set that the `.env` does not define: added to the .env with one tap.
    public func missingVariables(_ s: AddState? = nil) -> [String] {
        let s = s ?? state
        guard s.validatedKey == key(s) else { return [] }
        let defined = Set(EnvSyntax.names(in: envText(s)))
        return (s.validation?.unsetVariables ?? []).filter { !defined.contains($0) }
    }

    /// Appends `NAME=` lines for the unset variables to the pasted .env (new stack, pasted mode).
    public func addMissingVariables() {
        let missing = missingVariables()
        guard !missing.isEmpty, pastedMode(state) else { return }
        var text = state.pasteEnv
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        setPasteEnv(text + missing.map { "\($0)=" }.joined(separator: "\n") + "\n")
    }

    /// The checklist: compose (one line when all is well), then image, ports, container name.
    public func rows(_ s: AddState? = nil) -> [EditorCheckRow] {
        let s = s ?? state
        var rows: [EditorCheckRow] = []
        if let skip = composeSkipReason(s) {
            rows.append(EditorCheckRow(id: "yaml", state: .skipped, title: "YAML syntax", detail: skip))
        } else if let envIssue = EnvSyntax.check(envText(s)).first {
            rows.append(EditorCheckRow(id: "env", state: .fail, title: ".env syntax", detail: EditorChecks.describe(envIssue)))
        } else {
            let k = key(s)
            rows += ContainerChecks.composeRow(
                EditorChecks.rows(isEnv: false, serverName: serverName, local: [], checkError: s.checkError, validation: s.validation,
                                  validatedText: s.validatedKey == k ? k : nil, text: k),
                serverName: serverName)
        }
        if let problem = insertProblem(s) { rows.append(EditorCheckRow(id: "insert", state: .fail, title: "Add to stack", detail: problem)) }
        if pastedMode(s) {
            rows.append(EditorCheckRow(id: "services", state: .skipped, title: "Pasted file",
                                       detail: "Image, port and name checks cover the form only. The server's compose check above covers the whole file."))
        } else {
            rows.append(ContainerChecks.imageRow(s.spec, status: s.imageStatus))
            rows += ContainerChecks.portRows(s.spec, listening: s.listening, containers: containers(), serverName: serverName)
            rows.append(ContainerChecks.nameRow(s.spec, stack: s.target == .newStack ? s.stackName : s.existingName, containers: containers()))
        }
        if s.target == .existing {
            let kept = EnvMerge.merge(existing: originalEnv(s), adding: s.spec.activeEnv).kept
            if !kept.isEmpty {
                rows.append(EditorCheckRow(id: "envkept", state: .warn, title: "Already in .env", detail: "\(kept.joined(separator: ", ")) keeps its current value"))
            }
        }
        return rows
    }

    // MARK: writing

    public func newStackNameProblem(_ s: AddState? = nil) -> String? {
        let s = s ?? state
        guard !s.stackName.isEmpty else { return nil }
        if let problem = plan(s).nameProblem { return problem }
        return stacks().contains { $0.name == s.stackName } ? "A stack named \(s.stackName) already exists" : nil
    }

    /// Why Create/Save is off, or nil when it can go ahead.
    public func deployBlockedReason(_ s: AddState? = nil) -> String? {
        let s = s ?? state
        if policy.isReadOnly { return "Read-only mode is on" }
        if s.working { return "Working…" }
        switch s.target {
        case .newStack:
            if s.stackName.isEmpty { return "Enter a stack name" }
            if let problem = newStackNameProblem(s) { return problem }
            if let problem = plan(s).folderProblem { return problem }
        case .existing:
            if s.existingName == nil { return "Choose a stack to add the container to" }
            if let error = s.existing?.error { return error }
            if !existingReady(s) { return "Reading the stack from \(serverName)…" }
        }
        if !pastedMode(s) {
            if let problem = s.spec.blockingProblem { return problem }
        } else if s.pasteCompose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Paste a compose.yaml"
        }
        if let problem = insertProblem(s) { return problem }
        if let issue = EnvSyntax.check(envText(s)).first { return "Fix .env: \(EditorChecks.describe(issue))" }
        let rows = rows(s)
        if let fail = rows.first(where: { $0.state == .fail }) { return "\(fail.title): \(fail.detail)" }
        if rows.contains(where: { $0.state == .running }) || s.validatedKey != key(s) { return s.checkError ?? "Waiting for the checks on \(serverName)" }
        if let stack = s.target == .newStack ? plan(s).stack : existingStack(s), let reason = stackBlockedReason(stack) { return reason }
        return nil
    }

    /// What a create or save would do, for the confirmation sheet, or nil when it can't go ahead.
    public func request(start: Bool) -> DeployRequest? {
        let s = state
        guard deployBlockedReason(s) == nil else { return nil }
        switch s.target {
        case .newStack:
            let plan = plan(s)
            guard let stack = plan.stack, let intent = newSession.intent(for: plan), let dir = plan.directory else { return nil }
            return DeployRequest(
                work: .newStack(plan), stack: stack, start: start,
                title: start ? "Create \(plan.name) and start it?" : "Create \(plan.name)?",
                message: "Creates \(dir) on \(serverName) with the files below. The server checks them first and removes everything it made if that fails."
                    + (start ? " Then the stack is started with docker compose up -d, which pulls any images it needs." : ""),
                preview: intent.preview ?? "")
        case .existing:
            guard let stack = existingStack(s), let session = fileSession, let files = StackFiles.editable(for: stack),
                  case .file(let composeFile) = s.existing?.compose else { return nil }
            let compose = FileEdit(file: files[0], original: composeFile.content, originalSHA: composeFile.sha256, content: composeText(s))
            var envFile: RemoteFile?
            if case .file(let f) = s.existing?.env { envFile = f }
            let env = envText(s) != originalEnv(s)
                ? FileEdit(file: files[files.count - 1], original: envFile?.content, originalSHA: envFile?.sha256, content: envText(s)) : nil
            guard let composeIntent = session.intent(for: compose) else { return nil }
            var preview = "compose.yaml\n" + (composeIntent.preview ?? "")
            if let env, let envIntent = session.intent(for: env) { preview += "\n\n.env\n" + (envIntent.preview ?? "") }
            return DeployRequest(
                work: .existingStack([env, compose].compactMap { $0 }), stack: stack, start: start,
                title: start ? "Add \(s.spec.name) to \(stack.name) and start it?" : "Add \(s.spec.name) to \(stack.name)?",
                message: "The server checks each file first, and nothing is written if that fails. The previous versions are kept as .rackoon.bak."
                    + (start ? " Then the stack is updated: the new container starts, and any container whose settings changed is recreated." : ""),
                preview: preview)
        }
    }

    /// Runs a confirmed request. `onDone` gets the result on success; failures become a notice on the page.
    public func perform(_ request: DeployRequest, onDone: @escaping @MainActor (DeployResult) -> Void) {
        guard !state.working else { return }
        change { $0.working = true; $0.notice = nil }
        let newSession = newSession, fileSession = fileSession, serverName = serverName
        Task {
            defer { change { $0.working = false } }
            do {
                switch request.work {
                case .newStack(let plan):
                    switch try await newSession.create(plan, confirmation: try newSession.confirm(plan)) {
                    case .created:
                        onDone(DeployResult(stack: request.stack, isNew: true, start: request.start))
                    case .exists:
                        change { $0.notice = "\(request.stack.workingDir ?? plan.name) already exists on \(serverName), so nothing was written. Choose another name or folder." }
                    case .invalid(let issues):
                        change { s in
                            s.validation = ValidationResult(issues: issues)
                            s.validatedKey = key(s)
                            s.notice = "\(serverName) refused the files, so nothing was created."
                        }
                    }
                case .existingStack(let edits):
                    guard let session = fileSession else { return }
                    // .env first: if the compose save is then refused, a spare variable is harmless; the other way round
                    // would leave a service that refers to a variable that was never written.
                    for edit in edits {
                        switch try await session.save(edit, confirmation: try session.confirm(edit)) {
                        case .saved:
                            continue
                        case .changedOnServer:
                            change { $0.notice = "\(edit.file.fileName) changed on \(serverName) after you opened this page, so it was not saved. Go back and add the container again." }
                            return
                        case .invalid(let issues):
                            change { s in
                                s.validation = ValidationResult(issues: issues)
                                s.validatedKey = key(s)
                                s.notice = "\(serverName) refused \(edit.file.fileName), so it was not saved."
                            }
                            return
                        }
                    }
                    onDone(DeployResult(stack: request.stack, isNew: false, start: request.start))
                }
            } catch {
                change { $0.notice = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            }
        }
    }

    public var isDirty: Bool {
        let s = state
        return !s.spec.name.isEmpty || !s.spec.image.isEmpty || !s.stackName.isEmpty || !s.pasteCompose.isEmpty || !s.pasteEnv.isEmpty
            || !s.spec.activePorts.isEmpty || !s.spec.activeVolumes.isEmpty || !s.spec.activeEnv.isEmpty
    }

    /// Starts the checks once the page opens (the port lookup runs straight away).
    public func start() { scheduleChecks() }

    public func close() {
        checkTask?.cancel()
        imageTask?.cancel()
        portsTask?.cancel()
    }
}
