import Foundation
import Observation
import RackoonCore

/// One server's Commands library (as on the Mac, `CommandsModel` there): which command is selected, its parameters, each
/// command's last run and note, the confirmation for commands that change the server, the sudo password sheet for root
/// entries, and the custom commands typed this session. Read entries run at once; changes run their read-only dry run
/// first and then ask with the exact command. One command runs at a time and keeps running when another is selected.
/// The Services screen uses one of these as the runner of its actions.
@MainActor @Observable
final class CommandsModel {
    /// Either a library entry or the free-form box.
    enum Selection: Hashable { case custom, library(String) }

    var selection: Selection = .library("disk_usage")
    var params: [String: String] = [:]
    var customText = ""
    /// The last run of each command, so a command's page only ever shows its own output.
    private(set) var outputs: [Selection: ActionOutput] = [:]
    /// The command whose dry run is being fetched before its confirmation, if any.
    private(set) var previewingSelection: Selection?
    private var messages: [Selection: String] = [:]
    var pending: PendingAction?
    var sudoRequest: SudoRequest?
    /// Set when an interactive entry opened a terminal tab; the screen shows the terminal.
    var openedTerminal = false
    /// Custom commands run this session, in memory only (a typed command can hold a password or a token).
    private(set) var history = CommandHistory()

    let server: Server
    @ObservationIgnored private let session: CommandLibrarySession
    @ObservationIgnored private let safety: SafetyStore
    @ObservationIgnored private let vault: SudoVault
    @ObservationIgnored private let openTerminal: (_ title: String, _ command: String) -> String?
    @ObservationIgnored private let containerNames: () -> [String]
    @ObservationIgnored var sizeWait = 30

    init(server: Server, transport: SSHTransport, safety: SafetyStore, vault: SudoVault,
         openTerminal: @escaping (String, String) -> String? = { _, _ in "Terminals are not available here." },
         containerNames: @escaping () -> [String] = { [] }) {
        self.server = server
        self.safety = safety
        self.vault = vault
        self.openTerminal = openTerminal
        self.containerNames = containerNames
        session = CommandLibrarySession(transport: transport, policy: safety.policy)
    }

    // MARK: choosing

    var selected: LibraryCommand? {
        if case .library(let id) = selection { return CommandLibrary.all.first { $0.id == id } }
        return nil
    }

    func output(for selection: Selection) -> ActionOutput? { outputs[selection] }
    func message(for selection: Selection) -> String? { messages[selection] }
    func isPreviewing(_ selection: Selection) -> Bool { previewingSelection == selection }

    var output: ActionOutput? { outputs[selection] }
    var message: String? { messages[selection] }

    private var activeRun: (selection: Selection, output: ActionOutput)? {
        outputs.first { $0.value.isRunning }.map { ($0.key, $0.value) }
    }

    var knownContainers: [String] { containerNames() }
    var isRunning: Bool { activeRun != nil || previewingSelection != nil }

    private var busyReason: String {
        if let run = activeRun { return run.selection == selection ? "This command is running" : "\(run.output.title) is running" }
        return "Another command is getting ready"
    }

    /// Why running `command` is unavailable right now, or nil.
    func blockedReason(for command: LibraryCommand) -> String? {
        if isRunning { return busyReason }
        if command.isMutating && safety.readOnly { return "Read-only mode is on" }
        if command.interactive && safety.readOnly { return "Read-only is on, so terminals are off" }
        return CommandLibrary.paramsProblem(command, params: params)
    }

    var customBlockedReason: String? {
        if safety.readOnly { return "Read-only mode is on" }
        if isRunning { return busyReason }
        return session.customIntent(customText) == nil ? "Type a command" : nil
    }

    // MARK: running

    func run(_ command: LibraryCommand) {
        let key = Selection.library(command.id)
        messages[key] = nil
        if let why = blockedReason(for: command) { messages[key] = why; return }
        guard let script = command.fullScript(params: params) else { return }
        if command.interactive {
            if let problem = openTerminal(command.title, script) { messages[key] = problem } else { openedTerminal = true }
            return
        }
        let params = params
        let saved = command.root && vault.isRemembered(server)
        if !command.isMutating {
            if saved {
                // A root read with a saved password: Face ID is the approval.
                let nonce = SudoElevation.makeNonce()
                if let elevated = session.passwordIntent(for: command, params: params, nonce: nonce) {
                    unlockAndLaunch(elevated, entry: (command, params, nil), nonce: nonce)
                    return
                }
            }
            guard let intent = session.intent(for: command, params: params) else { return }
            launch(intent, title: command.title, confirm: false, entry: (command, params, nil))
            return
        }
        // A change: show what it would do (a read-only dry run), then ask.
        previewingSelection = key
        Task { [self] in
            let preview = await session.preview(for: command, params: params)
            previewingSelection = nil
            let shown = preview.isEmpty ? nil : preview
            let nonce = SudoElevation.makeNonce()
            if saved, let elevated = session.passwordIntent(for: command, params: params, preview: shown, nonce: nonce) {
                // Confirm the exact command that will run (the password variant), then unlock the saved password.
                pending = PendingAction(
                    title: "\(command.title)?",
                    message: ([command.summary, command.warning].compactMap { $0 } + [vault.useNote(server)]).joined(separator: " "),
                    serverName: server.name, command: elevated.command, destructive: true, preview: elevated.preview,
                    run: { [weak self] in self?.unlockAndLaunch(elevated, entry: (command, params, shown), nonce: nonce) })
                return
            }
            guard let intent = session.intent(for: command, params: params, preview: shown) else { return }
            pending = PendingAction(
                title: "\(command.title)?",
                message: [command.summary, command.warning].compactMap { $0 }.joined(separator: " "),
                serverName: server.name, command: intent.command, destructive: true, preview: intent.preview,
                run: { [weak self] in
                    self?.launch(intent, title: command.title, confirm: true, entry: (command, params, intent.preview))
                })
        }
    }

    /// Face ID (or the passcode), then `elevated` (built with `nonce`) runs with the saved password. Cancelled: nothing
    /// runs. Changed or unreadable: it was forgotten, and the password sheet opens.
    private func unlockAndLaunch(_ elevated: Intent, entry: LibraryEntry, nonce: String) {
        let server = server
        Task {
            switch await vault.unlock(server, reason: SudoVault.reason(server, doing: entry.command.title)) {
            case .success(let password):
                launch(elevated, title: entry.command.title, confirm: entry.command.isMutating, entry: entry,
                       sudo: SudoCredential(password: password, nonce: nonce), source: .saved)
            case .failure(.cancelled):
                messages[.library(entry.command.id)] = SudoSecretError.cancelled.errorDescription
            case .failure(let error):
                presentSudoSheet(entry, problem: error.sheetProblem)
            }
        }
    }

    /// Asks for the sudo password, then runs the entry's password variant with it (one nonce per attempt).
    private func presentSudoSheet(_ entry: LibraryEntry, problem: String?) {
        guard !(entry.command.isMutating && safety.readOnly) else { return }
        let nonce = SudoElevation.makeNonce()
        guard let elevated = session.passwordIntent(for: entry.command, params: entry.params, preview: entry.preview, nonce: nonce) else { return }
        sudoRequest = SudoRequest(
            title: "\(entry.command.title) with sudo", server: server, command: elevated.command, problem: problem,
            destructive: entry.command.isMutating, canRemember: vault.canRemember,
            submit: { [weak self] password, remember in
                self?.launch(elevated, title: entry.command.title, confirm: entry.command.isMutating, entry: entry,
                             sudo: SudoCredential(password: password, nonce: nonce), source: .typed(remember: remember))
            })
    }

    func runCustom() {
        messages[.custom] = nil
        guard customBlockedReason == nil, let intent = session.customIntent(customText) else { messages[.custom] = customBlockedReason; return }
        pending = PendingAction(
            title: "Run this command on \(server.name)?",
            message: "Rackoon can't tell what a typed command does, so it asks every time. It runs as the ssh user, with no input.",
            serverName: server.name, command: intent.command, destructive: false,
            run: { [weak self] in
                self?.history.remember(intent.command)
                self?.launch(intent, title: intent.command, confirm: true)
            })
    }

    func clearHistory() { history.clear() }

    /// `entry` is the library entry behind the intent (custom commands have none): when sudo refuses it for want of a
    /// password, the password variant of that entry is offered. With `sudo`, `intent` must be that variant built with the
    /// same nonce, and sudo's one prompt is answered.
    private func launch(_ intent: Intent, title: String, confirm: Bool, entry: LibraryEntry? = nil,
                        sudo: SudoCredential? = nil, source: SudoPasswordSource? = nil) {
        let key: Selection = entry.map { .library($0.command.id) } ?? .custom
        guard activeRun == nil else {
            messages[key] = "Another command is still running, so nothing was started. Try again when it has finished."
            return
        }
        messages[key] = nil
        let session = session
        let server = server
        let vault = vault
        let result = RunResult()
        outputs[key] = ActionOutput.launch(
            scope: "commands", title: title, intro: "\u{1B}[2m$ \(title)\u{1B}[0m\r\n", sizeWait: sizeWait,
            work: { cols, rows, onEvent in
                // The policy checks again here, so turning on Read-only after confirming still stops it.
                let confirmation = confirm ? (try? session.confirm(intent)) : nil
                result.set(await session.run(intent, confirmation: confirmation, cols: cols, rows: rows, sudo: sudo, onEvent: onEvent))
            },
            completion: { [weak self] in
                guard let run = result.value else { return }
                // Saving and forgetting must not depend on the screen still being open.
                if let sudo, run.sudo == .accepted, !run.sudoAsksEveryTime, source == .typed(remember: true) {
                    vault.remember(sudo.password, for: server)
                }
                if source == .saved, run.sudoRejected { vault.forget(server.id) }
                guard let self, let entry else { return }
                if let problem = run.sudoProblem { self.messages[key] = problem }
                guard run.needsSudoPassword, !self.isRunning else { return }
                if source == .saved {
                    self.presentSudoSheet(entry, problem: "The saved sudo password was not accepted, so it was forgotten.")
                } else {
                    self.presentSudoSheet(entry, problem: run.sudoRejected ? "The server did not accept that password." : nil)
                }
            })
    }

    func cancelOutput(_ selection: Selection) { outputs[selection]?.task?.cancel() }

    /// Stops whatever runs (the server was removed or its connection changed).
    func cancelEverything() {
        for output in outputs.values where output.isRunning { output.task?.cancel() }
    }

    func dismissOutput(_ selection: Selection) {
        guard outputs[selection]?.isRunning != true else { return }
        outputs[selection] = nil
    }

    /// A command's output as plain text, for Copy.
    func outputText(_ selection: Selection) -> String { ANSI.strip(outputs[selection]?.chunks.joined() ?? "") }
}

/// A library entry with the values it ran with (and the dry-run text the user saw, for mutating entries).
typealias LibraryEntry = (command: LibraryCommand, params: [String: String], preview: String?)

/// Carries a streamed run's result from the work closure to the completion.
private final class RunResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: StreamedRun?
    func set(_ run: StreamedRun?) { lock.withLock { stored = run } }
    var value: StreamedRun? { lock.withLock { stored } }
}
