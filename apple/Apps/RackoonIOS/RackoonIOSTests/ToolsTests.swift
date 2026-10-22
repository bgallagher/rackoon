import Foundation
import RackoonCore
import RackoonDemo
@testable import RackoonIOS
import XCTest

// Stage I6: Commands, Services, Files, Alerts and Search, run against the demo servers (nothing is sent anywhere).

@MainActor
private func homelab(_ app: AppModel) throws -> Server {
    try XCTUnwrap(app.servers.servers.first { $0.id == "demo-homelab" })
}

@MainActor
final class CommandsModelTests: XCTestCase {
    private let sandbox = Sandbox()

    private func commands(_ app: AppModel) throws -> CommandsModel {
        let model = try app.commandsModel(for: try homelab(app)).get()
        model.sizeWait = 0
        return model
    }

    private func entry(_ id: String) throws -> LibraryCommand { try XCTUnwrap(CommandLibrary.all.first { $0.id == id }) }

    func testAReadCommandRunsAtOnceAndKeepsItsOwnOutput() async throws {
        let app = sandbox.app(demo: true)
        let model = try commands(app)
        XCTAssertTrue(try app.commandsModel(for: try homelab(app)).get() === model, "one model per server, kept")
        model.run(try entry("disk_usage"))
        XCTAssertNil(model.pending, "a read runs without asking")
        let output = try XCTUnwrap(model.output(for: .library("disk_usage")))
        try await waitUntil { !output.isRunning }
        XCTAssertEqual(output.phase, .succeeded)
        XCTAssertTrue(model.outputText(.library("disk_usage")).contains("Filesystem"))
        XCTAssertNil(model.output(for: .library("memory")), "another command shows only its own output")
    }

    func testAChangeShowsItsDryRunThenAsksWithTheExactCommand() async throws {
        let app = sandbox.app(demo: true)
        let model = try commands(app)
        let prune = try entry("docker_prune")
        model.run(prune)
        try await waitUntil { model.pending != nil }
        let pending = try XCTUnwrap(model.pending)
        XCTAssertTrue(pending.destructive)
        XCTAssertEqual(pending.command, prune.fullScript())
        XCTAssertNotNil(pending.preview, "the dry run's output is in the sheet")
        pending.run()
        let output = try XCTUnwrap(model.output(for: .library("docker_prune")))
        try await waitUntil { !output.isRunning }
        XCTAssertEqual(output.phase, .succeeded)
    }

    func testReadOnlyBlocksChangesAndTerminalsButNotReads() throws {
        let app = sandbox.app(demo: true)
        app.safety.setReadOnly(true)
        let model = try commands(app)
        XCTAssertEqual(model.blockedReason(for: try entry("docker_prune")), "Read-only mode is on")
        XCTAssertNotNil(model.blockedReason(for: try entry("live_top")))
        XCTAssertNil(model.blockedReason(for: try entry("disk_usage")))
        model.customText = "uptime"
        XCTAssertEqual(model.customBlockedReason, "Read-only mode is on")
        model.run(try entry("docker_prune"))
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.message(for: .library("docker_prune")), "Read-only mode is on")
    }

    func testAParameterMustBeValidBeforeAnythingRuns() throws {
        let app = sandbox.app(demo: true)
        let model = try commands(app)
        let logs = try entry("container_logs")
        model.run(logs)
        XCTAssertEqual(model.message(for: .library("container_logs")), "Enter a valid container")
        model.params["container"] = "web; rm -rf /"
        XCTAssertNotNil(model.blockedReason(for: logs))
        model.params["container"] = "jellyfin-jellyfin-1"
        XCTAssertNil(model.blockedReason(for: logs))
    }

    func testACustomCommandAlwaysAsksAndIsRememberedForTheSessionOnly() async throws {
        let app = sandbox.app(demo: true)
        let model = try commands(app)
        model.customText = "uptime"
        model.runCustom()
        let pending = try XCTUnwrap(model.pending)
        XCTAssertEqual(pending.command, "uptime")
        pending.run()
        XCTAssertEqual(model.history.items, ["uptime"])
        let output = try XCTUnwrap(model.output(for: .custom))
        try await waitUntil { !output.isRunning }
        model.clearHistory()
        XCTAssertEqual(model.history.items, [])
    }

    func testAnInteractiveCommandOpensATerminalTab() throws {
        let app = sandbox.app(demo: true)
        let model = try commands(app)
        model.run(try entry("live_top"))
        XCTAssertTrue(model.openedTerminal)
        XCTAssertEqual(app.terminals.tabs(for: "demo-homelab").count, 1)
    }
}

@MainActor
final class ServicesModelTests: XCTestCase {
    private let sandbox = Sandbox()

    func testTheScanFindsServicesAndActionsRunThroughTheRunner() async throws {
        let app = sandbox.app(demo: true)
        let model = try app.servicesModel(for: try homelab(app)).get()
        model.runner.sizeWait = 0
        await model.refresh()
        let snapshot = try XCTUnwrap(model.snapshot)
        let tunnel = try XCTUnwrap(snapshot.services.first { $0.unit == "cloudflared.service" })
        XCTAssertEqual(tunnel.status, .restarting)
        XCTAssertNil(model.blockedReason(.restart, on: tunnel))
        XCTAssertEqual(model.blockedReason(.start, on: tunnel), "Already running")

        model.run(.status, on: tunnel)
        let (_, output) = try XCTUnwrap(model.output(for: tunnel))
        try await waitUntil { !output.isRunning }
        XCTAssertEqual(output.phase, .succeeded)

        model.run(.restart, on: tunnel)
        try await waitUntil { model.runner.pending != nil }
        XCTAssertTrue(try XCTUnwrap(model.runner.pending).command.contains("systemctl restart 'cloudflared.service'"))

        if let process = snapshot.services.first(where: { $0.kind == .process }) {
            XCTAssertEqual(model.blockedReason(.restart, on: process), "Started by hand, not by systemd, so Rackoon can't control it")
        }
    }

    func testShowAndHideChoicesAreSavedOnThisDevice() throws {
        let dir = sandbox.directory.appendingPathComponent("services", isDirectory: true)
        let store = ServiceVisibilityStore(directory: dir)
        let fields: [String: Any] = ["id": "system/dbus.service", "kind": "system", "name": "dbus", "detail": "", "status": "running",
                                     "subState": "running", "restarts": 0, "ports": [], "isPlumbing": true, "visibleByDefault": false]
        let dbus = try JSONDecoder().decode(DiscoveredService.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertFalse(store.isVisible(dbus, server: "s1"))
        store.set(true, dbus, server: "s1")
        XCTAssertTrue(ServiceVisibilityStore(directory: dir).isVisible(dbus, server: "s1"), "read back from visibility.json")
        store.forget(serverID: "s1")
        XCTAssertFalse(ServiceVisibilityStore(directory: dir).isVisible(dbus, server: "s1"))
    }
}

@MainActor
final class FilesModelTests: XCTestCase {
    private let sandbox = Sandbox()

    private func files(_ app: AppModel) async throws -> FilesModel {
        let model = try app.filesModel(for: try homelab(app)).get()
        try? FileManager.default.removeItem(at: model.downloads)
        await model.start()
        return model
    }

    func testItStartsInTheHomeFolderWithFoldersFirst() async throws {
        let model = try await files(sandbox.app(demo: true))
        XCTAssertEqual(model.path, "/home/demo")
        XCTAssertEqual(model.rows(showHidden: false).map(\.name), ["backups", "docker-cleanup.sh", "notes.txt"])
        XCTAssertTrue(model.rows(showHidden: true).contains { $0.name == ".bashrc" })
        XCTAssertEqual(model.parent, "/home")
        await model.open("/opt/stacks")
        XCTAssertEqual(model.path, "/opt/stacks")
    }

    func testADownloadLandsInDownloadsAndNeverReplacesAFileThere() async throws {
        let model = try await files(sandbox.app(demo: true))
        let notes = try XCTUnwrap(model.rows(showHidden: false).first { $0.name == "notes.txt" })
        model.download(notes)
        model.download(notes)
        try await waitUntil(10) { model.transfers.count == 2 && model.transfers.allSatisfy(\.isFinished) }
        XCTAssertEqual(model.transfers.map(\.state), [.done, .done])
        let names = try FileManager.default.contentsOfDirectory(atPath: model.downloads.path).sorted()
        XCTAssertEqual(names, ["notes copy.txt", "notes.txt"])
        model.clearFinished()
        XCTAssertTrue(model.transfers.isEmpty)
    }

    func testAnUploadAsksWithItsCommandAndAClashAsksFirst() async throws {
        let model = try await files(sandbox.app(demo: true))
        let local = sandbox.directory.appendingPathComponent("up", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let fresh = local.appendingPathComponent("photo.jpg")
        try Data(repeating: 7, count: 2048).write(to: fresh)
        model.upload(urls: [fresh])
        try await waitUntil { model.pending != nil }
        let pending = try XCTUnwrap(model.pending)
        XCTAssertTrue(pending.command.contains("-ne 2048"), "the server checks the exact length")
        XCTAssertTrue(pending.command.contains(".photo.jpg.rackoon-part"))
        model.pending = nil
        pending.run()
        try await waitUntil(10) { model.transfers.first?.isFinished == true }
        XCTAssertEqual(model.transfers.first?.state, .done)

        let clash = local.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: clash)
        model.upload(urls: [clash])
        let conflict = try XCTUnwrap(model.conflict)
        XCTAssertEqual(conflict.names, ["notes.txt"])
        model.conflict = nil
        conflict.resolve(.keepBoth)
        try await waitUntil { model.pending != nil }
        XCTAssertTrue(try XCTUnwrap(model.pending?.preview).contains("as notes copy.txt"))
    }

    func testChangesAskFirstAndReadOnlyBlocksThem() async throws {
        let app = sandbox.app(demo: true)
        let model = try await files(app)
        model.newFolder()
        let prompt = try XCTUnwrap(model.namePrompt)
        XCTAssertEqual(prompt.problem(" "), "Enter a name")
        XCTAssertEqual(prompt.problem("notes.txt"), "That name is already taken")
        XCTAssertTrue(try XCTUnwrap(prompt.command("new")).contains("mkdir -- '/home/demo/new'"))
        let backups = try XCTUnwrap(model.rows(showHidden: false).first { $0.name == "backups" })
        model.delete([backups])
        let delete = try XCTUnwrap(model.deletePrompt)
        XCTAssertTrue(delete.plan.hasFolder, "a folder needs the typed word")
        XCTAssertTrue(delete.plan.problems.isEmpty)

        model.namePrompt = nil
        model.deletePrompt = nil
        app.safety.setReadOnly(true)
        model.newFolder()
        model.delete([backups])
        model.upload(urls: [sandbox.directory])
        XCTAssertNil(model.namePrompt)
        XCTAssertNil(model.deletePrompt)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.notice, "Read-only mode is on")
    }
}

@MainActor
final class AlertMonitorTests: XCTestCase {
    private let sandbox = Sandbox()

    func testAServerThatDoesNotAnswerRaisesACriticalAlert() throws {
        var state = ServerState()
        state.error = "ssh: connect to host box.lan port 22: Connection refused"
        let server = Server(id: "s1", name: "box", host: "box.lan")
        let monitor = AlertMonitor(file: nil, dependencies: .init(
            rows: { [AlertRow(server: server, state: state, blocked: nil)] }, services: { _ in nil }, isWatched: { _, _ in true },
            dockerTransport: { _ in nil }))
        XCTAssertFalse(monitor.hasLooked)
        monitor.evaluate([AlertRow(server: server, state: state, blocked: nil)])
        XCTAssertTrue(monitor.hasLooked)
        let alert = try XCTUnwrap(monitor.book.active(server: "s1").first)
        XCTAssertEqual(alert.key, "not_answering")
        XCTAssertEqual(alert.severity, .critical)
        monitor.evaluate([AlertRow(server: server, state: ServerState(), blocked: "The host key changed since it was trusted.")])
        XCTAssertEqual(monitor.book.active(server: "s1").map(\.key), ["host_key_changed"])
    }

    func testACheckRaisesWatchedServicesOnlyAndTheBookIsSaved() async throws {
        let app = sandbox.app(demo: true)
        let server = try homelab(app)
        app.fleet.attach(server.id, fast: false)
        await app.fleet.refresh(server.id)
        try await waitUntil { app.alertRows.first { $0.server.id == server.id }?.isOnline == true }
        let row = try XCTUnwrap(app.alertRows.first { $0.server.id == server.id })
        await app.alerts.sweep(row)
        let keys = Set(app.alerts.book.active(server: server.id).map(\.key))
        XCTAssertTrue(keys.contains("service_crashing:system/cloudflared.service"), "\(keys)")
        XCTAssertTrue(keys.contains("security_updates"))
        XCTAssertNotNil(app.alerts.containerReading(for: server.id))

        // Hidden services are not watched: the next reading resolves its alert.
        let tunnel = try XCTUnwrap(app.existingServicesModel(server.id)?.snapshot?.services.first { $0.unit == "cloudflared.service" })
        app.visibility.set(false, tunnel, server: server.id)
        try await Task.sleep(nanoseconds: 20_000_000)
        await app.alerts.sweep(row)
        XCTAssertFalse(app.alerts.book.active(server: server.id).contains { $0.key == "service_crashing:system/cloudflared.service" })
        app.fleet.detach(server.id, fast: false)

        // Seen and muted survive a restart of the app (alerts.json).
        let file = sandbox.directory.appendingPathComponent("alerts.json")
        let deps = AlertMonitor.Dependencies(rows: { [] }, services: { _ in nil }, isWatched: { _, _ in true }, dockerTransport: { _ in nil })
        var down = ServerState()
        down.error = "Connection timed out"
        let saved = AlertMonitor(file: file, dependencies: deps)
        saved.evaluate([AlertRow(server: server, state: down, blocked: nil)])
        let alert = try XCTUnwrap(saved.book.active(server: server.id).first)
        saved.acknowledge(alert)
        XCTAssertEqual(AlertMonitor(file: file, dependencies: deps).book.unseenCount(server: server.id), 0)
        saved.forget(serverID: server.id)
        XCTAssertTrue(AlertMonitor(file: file, dependencies: deps).book.alerts.isEmpty)
    }
}

@MainActor
final class SearchIndexTests: XCTestCase {
    private let sandbox = Sandbox()

    func testSearchFindsServersCommandsAndWhatTheChecksRead() async throws {
        let app = sandbox.app(demo: true)
        let server = try homelab(app)
        app.fleet.attach(server.id, fast: false)
        await app.fleet.refresh(server.id)
        let before = Search.run("jellyfin", in: SearchIndex.items(app))
        XCTAssertFalse(before.sections.contains { $0.group == .docker }, "nothing is fetched for a search")
        await app.alerts.sweep(try XCTUnwrap(app.alertRows.first { $0.server.id == server.id }))
        let items = SearchIndex.items(app)
        XCTAssertEqual(Search.run("homelab", in: items).sections.first?.group, .servers)
        XCTAssertTrue(Search.run("jellyfin", in: items).sections.contains { $0.group == .docker })
        XCTAssertTrue(Search.run("cloudflared", in: items).sections.contains { $0.group == .services })
        XCTAssertTrue(Search.run("disk usage", in: items).sections.contains { $0.group == .commands })
        XCTAssertTrue(Search.run("security updates", in: items).sections.contains { $0.group == .alerts })
        app.fleet.detach(server.id, fast: false)
    }
}
