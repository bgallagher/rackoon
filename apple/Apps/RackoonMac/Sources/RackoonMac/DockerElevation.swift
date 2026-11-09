import Foundation
import Observation
import RackoonCore
import RackoonSSHSystem

/// Docker through sudo, for servers where the ssh user may not use Docker directly. Nothing on the server changes: once
/// the user unlocks it (the sudo password, or a saved one after Touch ID / Apple Watch / login password), every Docker
/// command for that server runs as `sudo … sh -c '<command>'` (`SudoTransport`) until the chosen time ends (15 minutes by
/// default, up to "until Rackoon quits", `lasting`) or the user locks it. The password is held in memory only for that
/// time, never written anywhere. Changes to the server still go through the confirm sheet either way.
@MainActor @Observable
final class DockerElevation {
    static let shared = DockerElevation()
    /// Like sudo's own default grace period.
    static let window: TimeInterval = ElevationWindow.defaultLength
    static let lastingKey = "dockerUnlockMinutes"

    /// How long an unlock lasts, chosen by the user (Docker notice, Dashboard); 15 minutes unless they pick otherwise.
    var lasting: ElevationWindow.Lasting = ElevationWindow.Lasting(rawValue: UserDefaults.standard.object(forKey: DockerElevation.lastingKey) as? Int ?? -1) ?? .standard {
        didSet { UserDefaults.standard.set(lasting.rawValue, forKey: Self.lastingKey) }
    }

    /// The rules (who is unlocked, until when, why locked) live in Core's `ElevationWindow`, which is tested.
    private var state = ElevationWindow(length: DockerElevation.window)
    @ObservationIgnored private var timers: [String: Task<Void, Never>] = [:]

    var lockReason: [String: String] { state.lockReasons }

    func isUnlocked(_ server: Server) -> Bool { state.active(server.id, at: Date()) != nil }
    func unlockedUntil(_ server: Server) -> Date? { state.active(server.id, at: Date())?.until }
    func key(_ server: Server) -> String { "\(server.connectionKey)|\(state.generation(server.id))" }

    /// The transport for anything Docker on this server: through sudo while unlocked, plain otherwise.
    func transport(for server: Server) -> SSHTransport {
        let base = makeTransport(for: server)
        guard !Demo.isOn, let unlock = state.active(server.id, at: Date()) else { return base }
        let id = server.id
        return SudoTransport(base: base, password: unlock.password, validUntil: unlock.until, onRejected: {
            Task { @MainActor in DockerElevation.shared.lock(id, reason: SudoTransportError.rejected.errorDescription) }
        })
    }

    func unlock(_ server: Server, password: String) {
        let lasting = lasting
        state.unlock(server.id, password: password, now: Date(), lasting: lasting)
        let id = server.id
        timers[id]?.cancel()
        timers[id] = nil
        guard let seconds = lasting.seconds else { return }   // until Rackoon quits (or Lock)
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.lock(id, reason: "Docker access through sudo ended after \(lasting.title). Unlock it again to continue.")
        }
    }

    /// Unlocks every one of `servers` that has a saved sudo password, with ONE Touch ID / Apple Watch / login password
    /// approval. Each password is checked on its server first (`check`); one the server rejects is forgotten. Returns
    /// the servers it could not unlock with why, so the caller can ask for those passwords one by one.
    func unlockAll(_ servers: [Server]) async -> [(server: Server, problem: String?)] {
        let vault = SudoVault.shared
        let saved = servers.filter { vault.isRemembered($0) && !isUnlocked($0) }
        var failed: [(Server, String?)] = servers.filter { !vault.isRemembered($0) && !isUnlocked($0) }.map { ($0, nil) }
        guard !saved.isEmpty else { return failed }
        let names = saved.map(\.name).joined(separator: ", ")
        let opened = await vault.unlockMany(saved, reason: "use the saved sudo passwords for Docker on \(names)")
        await withTaskGroup(of: (Server, String?, String?).self) { group in
            for server in saved {
                switch opened[server.id] {
                case .success(let password)?:
                    group.addTask { (server, password, await DockerElevation.check(password, on: server)) }
                case .failure(let error)?:
                    if error != .cancelled { failed.append((server, error.sheetProblem)) }
                case nil:
                    failed.append((server, nil))
                }
            }
            for await (server, password, problem) in group {
                if let problem {
                    if problem == Self.rejected { vault.forget(server.id) }
                    failed.append((server, problem == Self.rejected ? "The saved sudo password was not accepted, so it was forgotten." : problem))
                } else if let password {
                    unlock(server, password: password)
                }
            }
        }
        return failed
    }

    /// Locks every server unlocked now.
    func lockAll(_ servers: [Server]) { for server in servers where isUnlocked(server) { lock(server.id) } }

    static let rejected = "The server did not accept that password."

    func lock(_ serverID: String, reason: String? = nil) {
        timers[serverID]?.cancel()
        timers[serverID] = nil
        state.lock(serverID, reason: reason)
    }

    /// Checks the password with a harmless `sudo -S -v` on its own connection before unlocking. nil when accepted,
    /// otherwise why not.
    static func check(_ password: String, on server: Server) async -> String? {
        let transport = OpenSSHTransport(server: server)
        guard let result = try? await transport.run("sudo -S -p '' -v", input: password + "\n", timeout: 20) else {
            return "Could not reach the server to check the password."
        }
        if result.exitCode == 0 { return nil }
        let said = result.stdout + "\n" + result.stderr
        return SudoElevation.isAuthFailure(said) ? rejected : SudoElevation.explainRefusal(said)
    }
}

/// Where Docker-related models get their connection.
@MainActor func dockerTransport(for server: Server) -> SSHTransport { DockerElevation.shared.transport(for: server) }

import SwiftUI

/// Docker's access notice, for the Docker and Bookmarks screens: when the ssh user may not use Docker, offer to unlock it
/// with the sudo password; while unlocked, say until when and offer Lock. Any other Docker error is a plain error banner.
struct DockerAccessNotice: View {
    let server: Server
    let error: String?
    /// One line without the duration menu, for the Dashboard's server rows (whose banner holds the menu).
    var compact = false
    @State private var request: SudoRequest?
    @State private var working = false
    private let elevation = DockerElevation.shared

    var body: some View {
        Group {
            if let until = elevation.unlockedUntil(server) {
                NoticeRow(icon: "lock.open.fill", tint: Theme.accent,
                          message: until == .distantFuture ? "Docker is running through sudo until Rackoon quits."
                            : "Docker is running through sudo until \(until.formatted(date: .omitted, time: .shortened)).",
                          detail: "Nothing on the server was changed. The password is kept in memory only until then.",
                          action: AttentionAction(title: "Lock", help: "Stop using sudo for Docker now", run: { elevation.lock(server.id) }))
                    .noticeSurface(.info)
            } else if let error, DockerAccess.isPermissionProblem(error) {
                HStack(spacing: 12) {
                NoticeRow(icon: "lock.fill", tint: Theme.warn,
                          message: "\(server.user ?? "This user") can't use Docker on \(server.name) without sudo.",
                          detail: elevation.lockReason[server.id]
                            ?? "Unlock to run Docker commands through sudo (\(elevation.lasting == .untilQuit ? "until Rackoon quits" : "for \(elevation.lasting.title)")). Nothing on the server is changed.",
                          action: AttentionAction(title: working ? "Unlocking…" : "Unlock with sudo…", enabled: !working, run: start))
                    if !compact { UnlockLastingMenu() }
                }
                .noticeSurface(.warn)
            } else if let error {
                ErrorBanner(message: error)
            }
        }
        .sudoPassword($request)
    }

    /// A saved password: Touch ID / Apple Watch / login password. Otherwise the password sheet.
    private func start() {
        let server = server
        guard SudoVault.shared.isRemembered(server) else { ask(problem: nil); return }
        working = true
        Task {
            defer { working = false }
            switch await SudoVault.shared.unlock(server, reason: SudoVault.reason(server, doing: "use Docker")) {
            case .success(let password):
                if let problem = await DockerElevation.check(password, on: server) {
                    if problem == DockerElevation.rejected { SudoVault.shared.forget(server.id) }
                    ask(problem: problem == DockerElevation.rejected ? "The saved sudo password was not accepted, so it was forgotten." : problem)
                } else {
                    elevation.unlock(server, password: password)
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
            title: "Use Docker on \(server.name) with sudo", server: server,
            command: "sudo -S -p '' sh -c '<each Docker command>'",
            problem: problem, actionLabel: "Unlock", canRemember: SudoVault.shared.canRemember,
            submit: { password, remember in
                working = true
                Task {
                    defer { working = false }
                    if let problem = await DockerElevation.check(password, on: server) {
                        ask(problem: problem)
                        return
                    }
                    elevation.unlock(server, password: password)
                    if remember { await SudoVault.shared.remember(password, for: server) }
                }
            })
    }
}

/// How long Docker stays unlocked through sudo: 15 minutes (like sudo itself), 1 hour, 8 hours or until Rackoon quits.
/// Applies to the next unlock.
struct UnlockLastingMenu: View {
    @Bindable private var elevation = DockerElevation.shared

    var body: some View {
        Picker("Keep unlocked", selection: $elevation.lasting) {
            ForEach(ElevationWindow.Lasting.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .font(.system(size: 12))
        .help("How long Docker stays unlocked after you unlock it. The password is kept in Rackoon's memory only for that long; Lock ends it at once.")
        .handCursor()
    }
}
