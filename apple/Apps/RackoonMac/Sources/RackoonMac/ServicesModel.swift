import Foundation
import RackoonCore

/// One server's discovered services: the last reading, a poll that runs while a screen shows them, and the actions'
/// runner. Actions are Commands-tab entries built by `ServiceActions`, so they share its confirmation, Read-only check,
/// sudo password sheet (and saved password) and live output.
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
    /// A scan takes well under a second; services change rarely, so a slow poll is plenty while one is open.
    static let interval: Duration = .seconds(30)

    init(server: Server) {
        session = ServicesSession(transport: makeTransport(for: server))
        runner = CommandsModel(server: server)
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

    func refresh() { Task { await refresh() } }

    /// Screens attach while they show this server's services and detach when they go; the poll runs while any is attached.
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

    /// Stops polling whoever is attached (the server was removed or its connection changed).
    func stop() {
        attachments = 0
        poller?.cancel()
        poller = nil
    }

    // MARK: actions

    /// Starts `action` on `service`: reads run at once, changes ask first (with sudo when the server wants it).
    func run(_ action: ServiceAction, on service: DiscoveredService) {
        guard let command = ServiceActions.command(action, for: service) else { return }
        runner.select(.library(command.id))
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
}

/// One `ServicesModel` per server connection, shared by the Services screen and the Dashboard, so a reading and a running
/// action survive switching screens. A changed connection (Edit Connection) gets a new model.
@MainActor
final class ServicesStore {
    static let shared = ServicesStore()
    private var models: [String: ServicesModel] = [:]

    /// The server's model if one was made, without making one.
    func existingModel(for server: Server) -> ServicesModel? { models[server.connectionKey] }

    func model(for server: Server) -> ServicesModel {
        if let model = models[server.connectionKey] { return model }
        let model = ServicesModel(server: server)
        models[server.connectionKey] = model
        return model
    }

    /// A removed or edited server: stop its poll and drop its models.
    func forget(serverID: String) {
        for key in models.keys where key.hasPrefix(serverID + "|") {
            models[key]?.stop()
            models[key] = nil
        }
    }
}

/// Which services the user wants to see (`ServiceVisibility` in Core), saved as services/visibility.json on this Mac only.
@MainActor @Observable
final class ServiceVisibilityStore {
    static let shared = ServiceVisibilityStore(directory: Demo.isOn ? Demo.serviceSettings : nil)

    private(set) var rules: ServiceVisibility
    @ObservationIgnored private let file: URL

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rackoon/services", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("visibility.json")
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Bool].self, from: $0) } ?? [:]
        rules = ServiceVisibility(saved)
    }

    func isVisible(_ service: DiscoveredService, server: String) -> Bool { rules.isVisible(service, server: server) }
    func isChosen(_ service: DiscoveredService, server: String) -> Bool { rules.isChosen(service, server: server) }
    func choice(_ service: DiscoveredService, server: String) -> Bool? { rules.choice(service.id, server: server) }

    func set(_ visible: Bool?, _ service: DiscoveredService, server: String, everywhere: Bool = false) {
        rules.set(visible, service: service.id, server: server, everywhere: everywhere)
        save()
    }

    func forget(serverID: String) {
        if rules.forget(serverID: serverID) { save() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules.overrides) { try? data.write(to: file, options: .atomic) }
    }
}
