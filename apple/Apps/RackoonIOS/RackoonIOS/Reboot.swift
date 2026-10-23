import Foundation
import Observation
import RackoonCore
import RackoonDemo
import SwiftUI

/// A reboot in progress for one server, as on the Mac (`RebootFlow` there): asks the server to reboot, then waits until it
/// answers with a new boot id. When the ssh user's sudo wants a password the flow pauses in `needsPassword` and the
/// Overview asks for it (or Face ID unlocks the saved one). Rackoon never decides a reboot is needed: it is offered where
/// the server's own reboot-required flag shows.
@MainActor @Observable
final class RebootFlow {
    enum Phase: Equatable {
        case requesting
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
    @ObservationIgnored private let vault: SudoVault
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var onBack: () -> Void = {}
    /// How often the boot id is read while waiting (tests make it short).
    @ObservationIgnored var interval: TimeInterval = 4

    init(server: Server, transport: SSHTransport, policy: ActionPolicy, vault: SudoVault) {
        self.server = server
        self.vault = vault
        session = RebootSession(transport: transport, policy: policy)
    }

    func start() {
        task = Task {
            do {
                try await session.reboot(confirmation: try session.confirm())
                await awaitReturn()
            } catch RebootError.noSudo {
                guard vault.isRemembered(server) else { phase = .needsPassword(problem: nil); return }
                await rebootWithSaved(fallback: { self.phase = .needsPassword(problem: $0) })
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    /// The confirm sheet showed the sudo command (a password is saved): unlock it and reboot with it.
    func startWithSavedPassword() {
        task = Task { await rebootWithSaved(fallback: { self.phase = .needsPassword(problem: $0) }) }
    }

    private func rebootWithSaved(fallback: (String?) -> Void) async {
        switch await vault.unlock(server, reason: SudoVault.reason(server, doing: "reboot")) {
        case .success(let password): reboot(with: password, source: .saved)
        case .failure(.cancelled): phase = .failed(SudoSecretError.cancelled.errorDescription ?? "Cancelled.")
        case .failure(.notRemembered): start()
        case .failure(let error): fallback(error.sheetProblem)
        }
    }

    /// The user typed the sudo password. It goes to the command's standard input only; it is saved (Keychain, see
    /// `SudoVault`) only if `remember` is on and the server accepted it.
    func submitPassword(_ password: String, remember: Bool) {
        guard case .needsPassword = phase else { return }
        reboot(with: password, source: .typed(remember: remember))
    }

    /// The user cancelled the password sheet: nothing was scheduled, the server keeps running.
    func giveUp() {
        guard case .needsPassword = phase else { return }
        phase = .failed("Not rebooted: no sudo password was given.")
    }

    private func reboot(with password: String, source: SudoPasswordSource) {
        phase = .requesting
        let server = server
        task = Task {
            do {
                try await session.reboot(sudoPassword: password, confirmation: try session.confirmSudo())
                if source == .typed(remember: true) { vault.remember(password, for: server) }
                await awaitReturn()
            } catch RebootError.badPassword {
                if source == .saved {
                    vault.forget(server.id)
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
        let interval = interval
        switch await session.waitForReturn(interval: interval) {
        case .back(let elapsed):
            phase = .back(after: elapsed)
            onBack()
        case .timedOut:
            phase = .timedOut
        }
    }

    func cancel() { task?.cancel() }
}

extension AppModel {
    /// The confirmation for rebooting `server`, or nil when it can't be offered now (Read-only, one already running, no
    /// connection). Confirming starts the flow; the Overview shows its progress.
    func rebootRequest(_ server: Server) -> PendingAction? {
        guard !safety.readOnly, reboots[server.id]?.isActive != true else { return nil }
        let transport: SSHTransport
        if isDemo { transport = DemoRebootTransport() } else if case .success(let t) = self.transport(for: server) { transport = t } else { return nil }
        let message = "The server restarts in a couple of seconds. Everything running on it stops and comes back with it. Rackoon waits and reconnects when it is up again."
        let saved = vault.isRemembered(server)
        return PendingAction(
            title: "Reboot \(server.name)?", message: saved ? message + " " + vault.useNote(server) : message, serverName: server.name,
            command: saved ? RebootSession.sudoRebootCommand : RebootSession.rebootCommand, destructive: true, confirmLabel: "Reboot",
            run: { [weak self] in
                guard let self else { return }
                let flow = RebootFlow(server: server, transport: transport, policy: self.safety.policy, vault: self.vault)
                flow.onBack = { [weak self] in Task { await self?.fleet.refresh(server.id) } }
                self.reboots[server.id] = flow
                if saved { flow.startWithSavedPassword() } else { flow.start() }
            })
    }

    func dismissReboot(_ server: Server) {
        reboots[server.id]?.cancel()
        reboots[server.id] = nil
    }
}

/// The reboot's progress on the Overview: asking, waiting for the password, rebooting (with a running time), back,
/// not back after 10 minutes, or failed.
struct RebootBanner: View {
    @Environment(AppModel.self) private var model
    let flow: RebootFlow

    var body: some View {
        let t = model.tokens
        let name = flow.server.name
        switch flow.phase {
        case .requesting:
            row(nil, t.accent, "Asking \(name) to reboot…", nil, dismissible: false)
        case .needsPassword:
            row("key.fill", t.accent, "\(name) needs a password for sudo", "Enter it in the sheet to reboot, or dismiss this to leave the server running.", dismissible: true)
        case .waiting(let since):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                row(nil, t.accent, "Rebooting \(name)…", "Waiting for it to come back · \(Present.duration(context.date.timeIntervalSince(since))) so far", dismissible: false)
            }
        case .back(let after):
            row("checkmark.circle.fill", t.ok, "\(name) is back", "It restarted and answered again after \(Present.duration(after)).", dismissible: true)
        case .timedOut:
            row("exclamationmark.triangle.fill", t.warn, "\(name) has not come back", "No answer after 10 minutes. Check the machine or the provider's console.", dismissible: true)
        case .failed(let message):
            row("xmark.octagon.fill", t.danger, "Could not reboot \(name)", message, dismissible: true)
        }
    }

    private func row(_ symbol: String?, _ tint: Color, _ title: String, _ detail: String?, dismissible: Bool) -> some View {
        let t = model.tokens
        return HStack(alignment: .top, spacing: 10) {
            if let symbol { Image(systemName: symbol).foregroundStyle(tint) } else { ProgressView() }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                if let detail { Text(detail).font(.caption).foregroundStyle(t.secondary) }
            }
            Spacer(minLength: 0)
            if dismissible {
                Button { model.dismissReboot(flow.server) } label: { Image(systemName: "xmark").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(t.muted).accessibilityLabel("Dismiss")
            }
        }
        .accessibilityIdentifier("rebootBanner")
    }
}
