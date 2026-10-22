import Foundation
import RackoonCore
@testable import RackoonIOS
import UIKit
import XCTest

/// The iOS Docker model against the demo server (the shared `DemoTransport`, nothing is sent anywhere): what it shows, that
/// every change asks first with the exact command, that runs stream into the stack's Output, and that Read-only refuses.
@MainActor
final class DockerModelTests: XCTestCase {
    private func demoDocker(_ sandbox: Sandbox) throws -> (AppModel, DockerModel) {
        let app = sandbox.app(demo: true)
        guard case .success(let docker) = app.dockerModel(for: app.servers.servers[0]) else { throw XCTSkip("no demo docker") }
        docker.sizeWait = 0   // no Output view reports a size in a test
        return (app, docker)
    }

    private func loaded(_ docker: DockerModel) async throws -> DockerSnapshot {
        docker.attach()
        try await waitUntil { docker.state.snapshot != nil }
        return try XCTUnwrap(docker.state.snapshot)
    }

    func testTheDemoServerListsItsStacksAndTheModelIsKeptPerServer() async throws {
        let sandbox = Sandbox()
        let (app, docker) = try demoDocker(sandbox)
        let snapshot = try await loaded(docker)
        XCTAssertFalse(docker.stacks.isEmpty)
        XCTAssertTrue(snapshot.summary.contains("containers"))
        guard case .success(let again) = app.dockerModel(for: app.servers.servers[0]) else { return XCTFail() }
        XCTAssertTrue(again === docker, "one model per server, so a run's output survives leaving the screen")
        docker.detach()
    }

    func testStopAsksFirstWithTheExactCommandAndStreamsIntoTheStacksOutput() async throws {
        let sandbox = Sandbox()
        let (_, docker) = try demoDocker(sandbox)
        _ = try await loaded(docker)
        let container = try XCTUnwrap(docker.stacks.flatMap(\.containers).first { $0.isRunning && $0.project != nil })
        docker.request(.stop, on: container)
        let pending = try XCTUnwrap(docker.pending)
        XCTAssertEqual(pending.command, "docker stop \(container.id)")
        XCTAssertTrue(pending.destructive, "stopping interrupts the container: red button, not Return")
        XCTAssertNil(docker.output, "nothing runs before the yes")
        pending.run()
        let output = try XCTUnwrap(docker.output)
        XCTAssertEqual(output.scope, DockerStack.id(of: container))
        try await waitUntil { !output.isRunning }
        XCTAssertEqual(output.phase, .succeeded)
        XCTAssertNil(docker.working)
        docker.detach()
    }

    func testStartRunsWithoutAsking() async throws {
        let sandbox = Sandbox()
        let (_, docker) = try demoDocker(sandbox)
        _ = try await loaded(docker)
        let container = try XCTUnwrap(docker.stacks.flatMap(\.containers).first)
        docker.request(.start, on: container)
        XCTAssertNil(docker.pending)
        XCTAssertNotNil(docker.output)
        try await waitUntil { docker.working == nil }
        docker.detach()
    }

    func testAStackActionShowsItsComposeCommand() async throws {
        let sandbox = Sandbox()
        let (_, docker) = try demoDocker(sandbox)
        _ = try await loaded(docker)
        let stack = try XCTUnwrap(docker.stacks.first { !$0.isStandalone && ComposeAction.up.command(for: $0) != nil })
        docker.request(.recreate, on: stack)
        let pending = try XCTUnwrap(docker.pending)
        XCTAssertEqual(pending.command, ComposeAction.recreate.command(for: stack))
        XCTAssertTrue(pending.destructive)
        XCTAssertEqual(pending.title, ActionPrompts.stack(.recreate, stack).title)
        docker.detach()
    }

    func testReadOnlyRefusesEveryChange() async throws {
        let sandbox = Sandbox()
        let (app, docker) = try demoDocker(sandbox)
        _ = try await loaded(docker)
        app.safety.setReadOnly(true)
        let stack = try XCTUnwrap(docker.stacks.first { !$0.isStandalone && !$0.containers.isEmpty })
        let container = try XCTUnwrap(stack.containers.first)
        docker.request(.restart, on: container)
        docker.request(.start, on: container)
        docker.request(.up, on: stack)
        docker.runDirect(.up, on: stack)
        XCTAssertNil(docker.pending)
        XCTAssertNil(docker.output, "nothing ran")
        XCTAssertEqual(docker.composeBlockedReason(for: stack), "Read-only mode is on")
        XCTAssertEqual(docker.containerBlockedReason(), "Read-only mode is on")
        docker.detach()
    }

    func testADeletedStackIsForgottenAndItsPageIsToldToClose() async throws {
        let sandbox = Sandbox()
        let (_, docker) = try demoDocker(sandbox)
        _ = try await loaded(docker)
        let stack = try XCTUnwrap(docker.stacks.first { !$0.isStandalone && StackRemoval().command(for: $0) != nil })
        docker.delete(stack, StackRemoval())
        XCTAssertNotNil(docker.stack(id: stack.id), "kept on screen while the delete runs")
        try await waitUntil { docker.working == nil }
        XCTAssertEqual(docker.output?.phase, .succeeded)
        XCTAssertEqual(docker.removedStack, stack.id)
        docker.detach()
    }

    func testAStackCreatedHereIsShownUntilDockerListsIt() async throws {
        let sandbox = Sandbox()
        let (_, docker) = try demoDocker(sandbox)
        _ = try await loaded(docker)
        let plan = NewStackPlan(name: "fresh", parentDirectory: "/opt/stacks", compose: "services:\n  a:\n    image: nginx\n")
        let stack = try XCTUnwrap(plan.stack)
        docker.adopt(stack)
        XCTAssertEqual(docker.stack(id: "fresh")?.status.text, "Not started")
        docker.detach()
    }

    func testAnUntrustedServerHasNoDockerAndAnEditDropsTheModel() throws {
        let sandbox = Sandbox()
        let app = sandbox.app()
        var draft = ServersModel.Draft()
        draft.host = "box"
        app.servers.add(draft)
        guard case .failure(let reason) = app.dockerModel(for: app.servers.servers[0]) else { return XCTFail("refused") }
        XCTAssertEqual(reason.message, "Trust the server's host key on its Overview first.")

        let demo = sandbox.app(demo: true)
        let server = demo.servers.servers[0]
        guard case .success = demo.dockerModel(for: server) else { return XCTFail() }
        XCTAssertNotNil(demo.docker.existing(server.id))
        var moved = ServersModel.Draft(server)
        moved.host = "elsewhere.demo"
        XCTAssertNil(demo.update(id: server.id, with: moved))
        XCTAssertNil(demo.docker.existing(server.id), "the model belonged to the old address")
    }
}

@MainActor
final class DockerScreenModelTests: XCTestCase {
    func testTheEditorModelFollowsCoresEditor() async throws {
        let sandbox = Sandbox()
        let app = sandbox.app(demo: true)
        guard case .success(let docker) = app.dockerModel(for: app.servers.servers[0]) else { return XCTFail() }
        docker.attach()
        try await waitUntil { docker.state.snapshot != nil }
        let stack = try XCTUnwrap(docker.stacks.first { StackFiles.editable(for: $0) != nil })
        let editor = docker.editor(for: stack)
        XCTAssertTrue(editor === docker.editor(for: stack), "drafts survive leaving the stack's page")
        let file = try XCTUnwrap(editor.editor.files.first)
        editor.editor.open(file)
        try await waitUntil { editor.draft(file).original != nil }
        editor.editor.setText(file, editor.draft(file).text + "# note\n")
        XCTAssertTrue(editor.isDirty(file))
        try await waitUntil(5) { editor.editor.canSave(file) }
        XCTAssertNil(editor.editor.saveBlockedReason(file))
        docker.detach()
    }

    func testTheAddContainerModelFollowsCoresDraft() async throws {
        let sandbox = Sandbox()
        let app = sandbox.app(demo: true)
        guard case .success(let docker) = app.dockerModel(for: app.servers.servers[0]) else { return XCTFail() }
        docker.attach()
        try await waitUntil { docker.state.snapshot != nil }
        let add = AddContainerModel(docker: docker, safety: app.safety)
        XCTAssertEqual(add.state.folder, docker.suggestedStackFolder)
        add.draft.setStackName("kuma")
        add.draft.setSpec(ContainerSpec(name: "uptime-kuma", image: "louislam/uptime-kuma:1"))
        XCTAssertEqual(add.state.stackName, "kuma")
        try await waitUntil(5) { add.draft.deployBlockedReason() == nil }
        XCTAssertEqual(add.draft.request(start: true)?.title, "Create kuma and start it?")
        add.draft.close()
        docker.detach()
    }
}

@MainActor
final class IconStoreTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rackoon-icons-\(UUID().uuidString)", isDirectory: true)
    }

    /// A one-container compose stack, made the way the app gets one: from `docker ps` output.
    private func stack(_ name: String) -> DockerStack {
        let ps = #"{"HealthStatus":"none","ID":"abcdef012345","Image":"\#(name):1","Labels":"com.docker.compose.project=\#(name),com.docker.compose.service=app","Names":"\#(name)-app-1","Ports":"","State":"running","Status":"Up"}"#
        return (try? DockerParser.parse("##docker\nok\n##ps\n\(ps)\n##stats\n"))?.stacks.first
            ?? { XCTFail("parsed"); fatalError() }()
    }

    func testAChoiceIsKeptOnThisDeviceAndGoesWithItsServer() {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppIconStore(directory: dir, network: false)
        store.choose("grafana", for: stack("monitoring"), server: "s1")
        store.choose("", for: stack("other"), server: "s1")
        XCTAssertEqual(store.stackIcon(stack("monitoring"), server: "s1"), "grafana")
        XCTAssertTrue(store.prefersLetter(stack("other"), server: "s1"))
        let reopened = AppIconStore(directory: dir, network: false)
        XCTAssertEqual(reopened.stackIcon(stack("monitoring"), server: "s1"), "grafana", "saved in choices.json")
        reopened.forget(serverID: "s1")
        XCTAssertNil(AppIconStore(directory: dir, network: false).stackIcon(stack("monitoring"), server: "s1"))
    }

    func testAPickedImageIsRedrawnAndCanBeDeleted() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AppIconStore(directory: dir, network: false)
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let imported = await store.importImage(picture)
        let id = try XCTUnwrap(imported)
        XCTAssertTrue(id.hasPrefix("custom:"))
        XCTAssertEqual(store.customIcons, [id])
        let image = try XCTUnwrap(store.image(id))
        XCTAssertEqual(image.size.width * image.scale, 256, "redrawn as a 256 px square")
        store.choose(id, for: stack("mine"), server: "s1")
        store.deleteCustom(id)
        XCTAssertTrue(store.customIcons.isEmpty)
        XCTAssertNil(store.stackIcon(stack("mine"), server: "s1"), "a choice that used it goes back to automatic")
        let refused = await store.importImage(Data("not an image".utf8))
        XCTAssertNil(refused)
    }

    func testFaviconsAreRedrawnSquareAndNothingIsFetchedWithoutTheNetwork() {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let wide = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 16)).pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 16))
        }
        let png = FaviconStore.renderPNG(wide, side: 128)
        let image = UIImage(data: png ?? Data())
        XCTAssertEqual(image?.size, CGSize(width: 128, height: 128))
        let store = FaviconStore(directory: dir, network: false)
        store.ensure(["http://grafana.local:3000"])
        XCTAssertTrue(store.fetching.isEmpty)
        XCTAssertNil(store.image(for: "http://grafana.local:3000"))
    }
}
