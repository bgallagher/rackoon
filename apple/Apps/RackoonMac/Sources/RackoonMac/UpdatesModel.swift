import Foundation
import RackoonCore
import RackoonDemo
import RackoonSSHSystem
import Observation

/// Bridges UpdatesSession to SwiftUI. Reads when the screen opens and after every action; there is no background polling.
@MainActor @Observable
final class UpdatesModel {
    private(set) var state = UpdatesState()
    private(set) var loading = false
    /// An apt action is running (they take minutes, so the screen shows progress instead of freezing buttons silently).
    private(set) var working: String?
    /// The latest install or refresh and what apt printed, kept until closed or replaced.
    private(set) var output: ActionOutput?
    /// A change waiting for the user's yes (shown as a sheet).
    var pending: PendingAction?
    /// sudo wanted a password for the last action: asks for it, then runs the same action again with it.
    var sudoRequest: SudoRequest?
    /// A short note about the last attempt that the session's state does not carry (a cancelled Touch ID prompt).
    private(set) var notice: String?

    @ObservationIgnored private let session: UpdatesSession
    @ObservationIgnored private let serverName: String
    @ObservationIgnored private let server: Server

    init(server: Server) {
        self.server = server
        serverName = server.name
        // RACKOON_DEMO_UPDATES=1 swift run RackoonMac: pretend the server has pending updates (nothing is sent to it),
        // so the screen can be seen and worked on when the real server is fully up to date.
        let transport: SSHTransport = ProcessInfo.processInfo.environment["RACKOON_DEMO_UPDATES"] != nil
            ? DemoUpdatesTransport() : makeTransport(for: server)
        session = UpdatesSession(transport: transport, policy: SafetyStore.shared.policy)
    }

    var packages: [PendingUpdate] {
        (state.snapshot?.packages ?? []).sorted { ($0.isSecurity ? 0 : 1, $0.name) < ($1.isSecurity ? 0 : 1, $1.name) }
    }
    var securityNames: [String] { packages.filter(\.isSecurity).map(\.name) }
    /// "Install security updates" needs an explicit list, which is capped; beyond the cap use Install all.
    var canInstallSecurity: Bool { !securityNames.isEmpty && securityNames.count <= AptAction.maxPackages }

    func load() {
        guard !loading, working == nil else { return }
        loading = true
        Task {
            state = await session.refresh()
            loading = false
        }
    }

    func request(_ action: AptAction) {
        guard !SafetyStore.shared.readOnly, working == nil, let intent = action.intent else { return }
        let all = packages.count, security = securityNames.count
        let (title, message, label): (String, String, String) = switch action {
        case .refresh:
            ("Refresh package lists?", "Checks the repositories for new versions. Nothing is installed.", "Refreshing package lists…")
        case .upgradeAll:
            ("Install all \(all) updates?",
             "Held packages stay as they are and existing config files are kept. Some updates may ask for a reboot afterwards.",
             "Installing \(all) updates…")
        case .upgrade(let names):
            ("Install \(security) security update\(security == 1 ? "" : "s")?",
             "Only these packages are upgraded: \(names.prefix(6).joined(separator: ", "))\(names.count > 6 ? " and \(names.count - 6) more" : "").",
             "Installing security updates…")
        }
        // A saved sudo password: confirm the password variant itself (the exact command that runs), then unlock it.
        let nonce = SudoElevation.makeNonce()
        if SudoVault.shared.isRemembered(server), let elevated = action.passwordIntent(nonce: nonce) {
            pending = PendingAction(title: title, message: message + " " + SudoVault.useNote(server), serverName: serverName,
                                    command: elevated.command, destructive: false,
                                    run: { [weak self] in self?.runWithSavedPassword(action, label: label, nonce: nonce) })
            return
        }
        pending = PendingAction(title: title, message: message, serverName: serverName, command: intent.command,
                                destructive: false, run: { [weak self] in self?.run(action, label: label) })
    }

    /// Touch ID, the Apple Watch or the login password, then the confirmed password variant runs. If the saved password
    /// can't be used (cancelled: nothing runs; changed or unreadable: it was forgotten), say so or ask for it instead.
    private func runWithSavedPassword(_ action: AptAction, label: String, nonce: String) {
        let server = server
        Task {
            switch await SudoVault.shared.unlock(server, reason: SudoVault.reason(server, doing: label)) {
            case .success(let password):
                run(action, label: label, sudo: SudoCredential(password: password, nonce: nonce), source: .saved)
            case .failure(.cancelled):
                notice = SudoSecretError.cancelled.errorDescription
            case .failure(let error):
                // Forgotten or unusable in the meantime: ask for it rather than dropping the confirmed action.
                presentSudoSheet(action, label: label, problem: error.sheetProblem)
            }
        }
    }

    /// Runs the action with live output: apt's own progress in a terminal on the page, then the list is re-read.
    /// With `sudo`, the password variant with that nonce runs and sudo's one prompt is answered over the pty.
    private func run(_ action: AptAction, label: String, sudo: SudoCredential? = nil, source: SudoPasswordSource? = nil) {
        guard working == nil else { return }
        working = label
        notice = nil
        let session = session
        let server = server
        let title: String
        switch action {
        case .refresh: title = "apt-get update"
        case .upgradeAll: title = "apt-get upgrade"
        case .upgrade(let names): title = "apt-get install --only-upgrade (\(names.count) package\(names.count == 1 ? "" : "s"))"
        }
        output = ActionOutput.launch(
            scope: "updates", title: title,
            work: { cols, rows, onEvent in
                // The same policy that vetted the request vets it again here; a switch to read-only in between wins.
                let confirmation = try? session.confirm(action, sudoNonce: sudo?.nonce)
                await session.performStreaming(action, confirmation: confirmation, cols: cols, rows: rows,
                                               sudo: sudo, onEvent: onEvent)
            },
            completion: { [weak self] in
                self?.working = nil
                Task { @MainActor in
                    // Saving and forgetting must not depend on the screen still being open.
                    let result = await session.state
                    if let sudo, result.sudoAccepted, source == .typed(remember: true) {
                        await SudoVault.shared.remember(sudo.password, for: server)
                    }
                    // The server no longer takes the saved password: forget it at once and never retry it.
                    if source == .saved, result.sudoPasswordNeeded { SudoVault.shared.forget(server.id) }
                    guard let self else { return }
                    self.state = result
                    guard result.sudoPasswordNeeded else { return }
                    self.presentSudoSheet(action, label: label,
                                          problem: source == .saved ? "The saved sudo password was not accepted, so it was forgotten."
                                                                    : (sudo == nil ? nil : result.actionError))
                }
            })
    }

    /// Asks for the sudo password, then runs the action with it. One nonce per attempt: the sheet shows the command
    /// with it, and the run must use the same one.
    private func presentSudoSheet(_ action: AptAction, label: String, problem: String?) {
        let nonce = SudoElevation.makeNonce()
        guard !SafetyStore.shared.readOnly, let intent = action.passwordIntent(nonce: nonce) else { return }
        sudoRequest = SudoRequest(
            title: intent.summary.replacingOccurrences(of: " (with sudo password)", with: "") + " with sudo",
            server: server, command: intent.command,
            problem: problem, actionLabel: action == .refresh ? "Refresh" : "Install",
            canRemember: SudoVault.shared.canRemember,
            submit: { [weak self] password, remember in
                self?.run(action, label: label, sudo: SudoCredential(password: password, nonce: nonce), source: .typed(remember: remember))
            })
    }

    func cancelOutput() { output?.task?.cancel() }

    func dismissOutput() {
        guard output?.isRunning != true else { return }
        output = nil
    }
}
