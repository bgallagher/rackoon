import Foundation
import Observation
import RackoonCore

/// One server's discovered services (as on the Mac): the last reading, a poll every 30 s while a screen shows them, and
/// the actions' runner. Actions are Commands-library entries built by `ServiceActions`, so they share its confirmation,
/// Read-only check, sudo password sheet (and the password saved behind Face ID) and live output.
@MainActor @Observable
final class ServicesModel {
    private(set) var snapshot: ServicesSnapshot?
    private(set) var error: String?
    private(set) var updatedAt: Date?
    private(set) var loading = false
    /// Runs start/stop/restart/status/logs and keeps their output.
    let runner: CommandsModel

    @ObservationIgnored private let session: ServicesSession
    @ObservationIgnored private var attachments = 0
    @ObservationIgnored private var poller: Task<Void, Never>?
    static let interval: Duration = .seconds(30)

    init(server: Server, transport: SSHTransport, runner: CommandsModel) {
        session = ServicesSession(transport: transport)
        self.runner = runner
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        let result = await session.refresh()
        snapshot = result.snapshot
        error = result.error
        updatedAt = result.updatedAt
        loading = false
    }

    /// Screens attach while they show this server's services; the poll runs while any is attached.
    func attach() {
        attachments += 1
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func detach() {
        attachments = max(0, attachments - 1)
        guard attachments == 0 else { return }
        poller?.cancel()
        poller = nil
    }

    func stop() {
        attachments = 0
        poller?.cancel()
        poller = nil
        runner.cancelEverything()
    }

    // MARK: actions

    /// Starts `action` on `service`: reads run at once, changes ask first (with sudo when the server wants it).
    func run(_ action: ServiceAction, on service: DiscoveredService) {
        guard let command = ServiceActions.command(action, for: service) else { return }
        runner.selection = .library(command.id)
        runner.run(command)
    }

    /// Why an action can't run now, or nil.
    func blockedReason(_ action: ServiceAction, on service: DiscoveredService) -> String? {
        guard let command = ServiceActions.command(action, for: service) else {
            return service.kind == .process ? "Started by hand, not by systemd, so Rackoon can't control it" : "Unknown unit"
        }
        if !action.applies(to: service) { return action == .start ? "Already running" : "Not running" }
        return runner.blockedReason(for: command)
    }

    /// The output of the last action run on `service`, if any.
    func output(for service: DiscoveredService) -> (CommandsModel.Selection, ActionOutput)? {
        for action in ServiceAction.allCases {
            guard let id = ServiceActions.command(action, for: service)?.id else { continue }
            let key = CommandsModel.Selection.library(id)
            if key == runner.selection, let output = runner.output(for: key) { return (key, output) }
        }
        return nil
    }
}

/// Which services the user wants to see (`ServiceVisibility` in Core), saved as services/visibility.json on this device.
@MainActor @Observable
final class ServiceVisibilityStore {
    private(set) var rules: ServiceVisibility
    @ObservationIgnored private let file: URL?

    /// `directory` nil keeps the choices in memory only (tests).
    init(directory: URL?) {
        guard let directory else {
            file = nil
            rules = ServiceVisibility()
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("visibility.json")
        self.file = file
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Bool].self, from: $0) } ?? [:]
        rules = ServiceVisibility(saved)
    }

    func isVisible(_ service: DiscoveredService, server: String) -> Bool { rules.isVisible(service, server: server) }
    func choice(_ service: DiscoveredService, server: String) -> Bool? { rules.choice(service.id, server: server) }

    func set(_ visible: Bool?, _ service: DiscoveredService, server: String, everywhere: Bool = false) {
        rules.set(visible, service: service.id, server: server, everywhere: everywhere)
        save()
    }

    func forget(serverID: String) {
        if rules.forget(serverID: serverID) { save() }
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(rules.overrides) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
