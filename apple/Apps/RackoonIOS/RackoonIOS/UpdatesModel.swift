import Foundation
import Observation
import RackoonCore

/// One server's pending apt updates and the installs, as on the Mac (`UpdatesModel` there). Reads when the screen opens and
/// after every action; no polling. Every install asks first with its exact command and streams apt's own output. When sudo
/// wants a password the sheet asks for it (or Face ID unlocks the saved one) and the same action runs again with it.
@MainActor @Observable
final class UpdatesModel {
    private(set) var state = UpdatesState()
    private(set) var loading = false
    private(set) var working: String?
    private(set) var output: ActionOutput?
    var pending: PendingAction?
    var sudoRequest: SudoRequest?
    /// A note the session's state does not carry (a cancelled Face ID prompt).
    private(set) var notice: String?

    let server: Server
    @ObservationIgnored private let session: UpdatesSession
    @ObservationIgnored private let safety: SafetyStore
    @ObservationIgnored private let vault: SudoVault
    @ObservationIgnored var sizeWait = 30

    init(server: Server, transport: SSHTransport, safety: SafetyStore, vault: SudoVault) {
        self.server = server
        self.safety = safety
        self.vault = vault
        session = UpdatesSession(transport: transport, policy: safety.policy)
    }

    var packages: [PendingUpdate] { UpdatesPresentation.sorted(state.snapshot?.packages ?? []) }
    var securityNames: [String] { UpdatesPresentation.securityNames(packages) }

    func load() async {
        guard !loading, working == nil else { return }
        loading = true
        state = await session.refresh()
        loading = false
    }

    /// Why the actions are off, or nil.
    var blockedReason: String? {
        if safety.readOnly { return "Read-only mode is on" }
        if working != nil { return "Another action is running" }
        return nil
    }

    func request(_ action: AptAction) {
        guard blockedReason == nil, let intent = action.intent else { return }
        let prompt = UpdatesPresentation.prompt(action, packageCount: packages.count, securityCount: securityNames.count)
        // A saved sudo password: confirm the password variant itself (the exact command that runs), then unlock it.
        let nonce = SudoElevation.makeNonce()
        if vault.isRemembered(server), let elevated = action.passwordIntent(nonce: nonce) {
            pending = PendingAction(title: prompt.title, message: prompt.message + " " + vault.useNote(server), serverName: server.name,
                                    command: elevated.command, destructive: false, confirmLabel: "Run Command",
                                    run: { [weak self] in self?.runWithSavedPassword(action, prompt: prompt, nonce: nonce) })
            return
        }
        pending = PendingAction(title: prompt.title, message: prompt.message, serverName: server.name, command: intent.command,
                                destructive: false, run: { [weak self] in self?.run(action, prompt: prompt) })
    }

    private func runWithSavedPassword(_ action: AptAction, prompt: AptPrompt, nonce: String) {
        let server = server
        Task {
            switch await vault.unlock(server, reason: SudoVault.reason(server, doing: prompt.workingLabel)) {
            case .success(let password):
                run(action, prompt: prompt, sudo: SudoCredential(password: password, nonce: nonce), source: .saved)
            case .failure(.cancelled):
                notice = SudoSecretError.cancelled.errorDescription
            case .failure(let error):
                presentSudoSheet(action, prompt: prompt, problem: error.sheetProblem)
            }
        }
    }

    private func run(_ action: AptAction, prompt: AptPrompt, sudo: SudoCredential? = nil, source: SudoPasswordSource? = nil) {
        guard working == nil else { return }
        working = prompt.workingLabel
        notice = nil
        let session = session
        let server = server
        let vault = vault
        output = ActionOutput.launch(
            scope: "updates", title: prompt.outputTitle, sizeWait: sizeWait,
            work: { cols, rows, onEvent in
                // The policy that vetted the request vets it again here; a switch to Read-only in between wins.
                let confirmation = try? session.confirm(action, sudoNonce: sudo?.nonce)
                await session.performStreaming(action, confirmation: confirmation, cols: cols, rows: rows, sudo: sudo, onEvent: onEvent)
            },
            completion: { [weak self] in
                self?.working = nil
                Task { @MainActor in
                    // Saving and forgetting must not depend on the screen still being open.
                    let result = await session.state
                    if let sudo, result.sudoAccepted, source == .typed(remember: true) { vault.remember(sudo.password, for: server) }
                    if source == .saved, result.sudoPasswordNeeded { vault.forget(server.id) }
                    guard let self else { return }
                    self.state = result
                    guard result.sudoPasswordNeeded else { return }
                    self.presentSudoSheet(action, prompt: prompt,
                                          problem: source == .saved ? "The saved sudo password was not accepted, so it was forgotten."
                                                                    : (sudo == nil ? nil : result.actionError))
                }
            })
    }

    /// Asks for the sudo password, then runs the action with it. One nonce per attempt: the sheet shows the command with it,
    /// and the run uses the same one.
    private func presentSudoSheet(_ action: AptAction, prompt: AptPrompt, problem: String?) {
        let nonce = SudoElevation.makeNonce()
        guard !safety.readOnly, let intent = action.passwordIntent(nonce: nonce) else { return }
        sudoRequest = SudoRequest(
            title: action == .refresh ? "Refresh with sudo" : "Install with sudo", server: server, command: intent.command,
            problem: problem, actionLabel: action == .refresh ? "Refresh" : "Install", canRemember: vault.canRemember,
            submit: { [weak self] password, remember in
                self?.run(action, prompt: prompt, sudo: SudoCredential(password: password, nonce: nonce), source: .typed(remember: remember))
            })
    }

    func cancelOutput() { output?.task?.cancel() }

    func dismissOutput() {
        guard output?.isRunning != true else { return }
        output = nil
    }
}
