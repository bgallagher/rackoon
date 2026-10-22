import Foundation
import Observation
import RackoonCore
import SwiftUI

/// Docker through sudo, for servers where the ssh user may not use Docker directly (the Mac's `DockerElevation`). Nothing
/// on the server changes: once unlocked (the sudo password, or the saved one after Face ID), every Docker command for that
/// server runs as `sudo … sh -c '<command>'` (`SudoTransport`) until the window ends or the user locks it. The password is
/// held in memory only for that window. Rackoon never suggests joining the docker group, which is root-equivalent.
@MainActor @Observable
final class DockerElevation {
    static let window: TimeInterval = ElevationWindow.defaultLength
    /// The rules (who is unlocked, until when, why locked) are Core's `ElevationWindow`, which is tested.
    private var state = ElevationWindow(length: DockerElevation.window)
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]
    /// Called when a server is unlocked or locked, so its Docker model is rebuilt on the right transport.
    @ObservationIgnored var changed: (String) -> Void = { _ in }

    var lockReason: [String: String] { state.lockReasons }

    func isUnlocked(_ id: String) -> Bool { state.active(id, at: Date()) != nil }
    func unlockedUntil(_ id: String) -> Date? { state.active(id, at: Date())?.until }
    /// Changes whenever the server is unlocked or locked; a Docker model made under another key is stale.
    func key(_ id: String) -> String { "\(isUnlocked(id))|\(state.generation(id))" }

    /// The transport for anything Docker on this server: through sudo while unlocked, `base` otherwise.
    func transport(for id: String, base: SSHTransport) -> SSHTransport {
        guard let unlock = state.active(id, at: Date()) else { return base }
        return SudoTransport(base: base, password: unlock.password, validUntil: unlock.until, onRejected: { [weak self] in
            Task { @MainActor in self?.lock(id, reason: SudoTransportError.rejected.errorDescription) }
        })
    }

    func unlock(_ id: String, password: String) {
        state.unlock(id, password: password, now: Date())
        timers[id]?.cancel()
        timers[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.window * 1e9))
            guard !Task.isCancelled else { return }
            self?.lock(id, reason: "Docker access through sudo ended after \(Int(Self.window / 60)) minutes. Unlock it again to continue.")
        }
        changed(id)
    }

    func lock(_ id: String, reason: String? = nil) {
        timers[id]?.cancel()
        timers[id] = nil
        let was = isUnlocked(id)
        state.lock(id, reason: reason)
        if was { changed(id) }
    }

    /// Checks the password with a harmless `sudo -S -v` on its own connection before unlocking. nil when accepted.
    static func check(_ password: String, on transport: SSHTransport) async -> String? {
        guard let result = try? await transport.run("sudo -S -p '' -v", input: password + "\n", timeout: 20) else {
            return "Could not reach the server to check the password."
        }
        if result.exitCode == 0 { return nil }
        let said = result.stdout + "\n" + result.stderr
        return SudoElevation.isAuthFailure(said) ? rejected : SudoElevation.explainRefusal(said)
    }

    static let rejected = "The server did not accept that password."
}

/// Docker's access notice, for the Docker and Bookmarks screens: when the ssh user may not use Docker, offer to unlock it
/// with the sudo password; while unlocked, say until when and offer Lock. Any other error is shown as it is.
struct DockerAccessNotice: View {
    @Environment(AppModel.self) private var model
    let server: Server
    let error: String?
    @State private var request: SudoRequest?
    @State private var working = false

    var body: some View {
        let t = model.tokens
        let elevation = model.elevation
        Group {
            if let until = elevation.unlockedUntil(server.id) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.open.fill").foregroundStyle(t.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Docker is running through sudo until \(until.formatted(date: .omitted, time: .shortened)).").font(.subheadline)
                        Text("Nothing on the server was changed. The password is kept in memory only until then.").font(.caption).foregroundStyle(t.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Lock") { elevation.lock(server.id) }.buttonStyle(.bordered)
                }
            } else if let error, DockerAccess.isPermissionProblem(error) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(server.user ?? "This user") can't use Docker on \(server.name) without sudo.", systemImage: "lock.fill")
                        .foregroundStyle(t.warn).font(.subheadline.weight(.medium))
                    Text(elevation.lockReason[server.id]
                         ?? "Unlock to run Docker commands through sudo for \(Int(DockerElevation.window / 60)) minutes. Nothing on the server is changed.")
                        .font(.caption).foregroundStyle(t.secondary)
                    Button(working ? "Unlocking…" : "Unlock with sudo…", action: start)
                        .buttonStyle(.borderedProminent)
                        .disabled(working || model.safety.readOnly)
                        .accessibilityIdentifier("unlockDocker")
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(t.warn).font(.subheadline)
            }
        }
        .sudoPassword($request)
    }

    /// A saved password: Face ID. Otherwise the password sheet.
    private func start() {
        let server = server
        let vault = model.vault
        guard vault.isRemembered(server) else { ask(problem: nil); return }
        working = true
        Task {
            defer { working = false }
            switch await vault.unlock(server, reason: SudoVault.reason(server, doing: "use Docker")) {
            case .success(let password):
                guard case .success(let transport) = model.transport(for: server) else { return }
                if let problem = await DockerElevation.check(password, on: transport) {
                    if problem == DockerElevation.rejected { vault.forget(server.id) }
                    ask(problem: problem == DockerElevation.rejected ? "The saved sudo password was not accepted, so it was forgotten." : problem)
                } else {
                    model.elevation.unlock(server.id, password: password)
                }
            case .failure(.cancelled):
                break
            case .failure(let error):
                ask(problem: error.sheetProblem)
            }
        }
    }

    private func ask(problem: String?) {
        let server = server
        request = SudoRequest(
            title: "Use Docker with sudo", server: server, command: "sudo -S -p '' sh -c '<each Docker command>'",
            problem: problem, actionLabel: "Unlock", canRemember: model.vault.canRemember,
            submit: { password, remember in
                working = true
                Task {
                    defer { working = false }
                    guard case .success(let transport) = model.transport(for: server) else { return }
                    if let problem = await DockerElevation.check(password, on: transport) {
                        ask(problem: problem)
                        return
                    }
                    model.elevation.unlock(server.id, password: password)
                    if remember { model.vault.remember(password, for: server) }
                }
            })
    }
}
