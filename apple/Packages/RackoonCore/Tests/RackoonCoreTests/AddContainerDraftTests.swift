import Foundation
@testable import RackoonCore
import XCTest

@MainActor
final class AddContainerDraftTests: XCTestCase {
    private func container(_ service: String, _ project: String, ports: [DockerContainer.PortMapping] = []) -> DockerContainer {
        DockerContainer(id: "abcdef0123" + String(service.prefix(2)).map { String(format: "%x", Int($0.asciiValue ?? 0) % 16) }.joined(),
                        name: "\(project)-\(service)-1", image: "x", state: "running", health: "none", status: "Up", ports: ports,
                        project: project, service: service, workingDir: "/opt/stacks/\(project)",
                        configFile: "/opt/stacks/\(project)/compose.yaml", configFiles: ["/opt/stacks/\(project)/compose.yaml"])
    }

    private func mediaStack() -> DockerStack {
        DockerStack(name: "media", workingDir: "/opt/stacks/media", configFile: "/opt/stacks/media/compose.yaml",
                    configFiles: ["/opt/stacks/media/compose.yaml"],
                    containers: [container("web", "media", ports: [.init(hostPort: 8080, containerPort: 80, proto: "tcp")])], isStandalone: false)
    }

    private func setup(_ server: FakeStackServer = FakeStackServer(), readOnly: Bool = false) -> (AddContainerDraft, FakeStackServer) {
        let policy = ActionPolicy(readOnly: readOnly)
        let stacks = [mediaStack()]
        let draft = AddContainerDraft(transport: server, policy: policy, serverName: "hetzner", folder: "/opt/stacks",
                                      stacks: { stacks }, containers: { stacks.flatMap(\.containers) }, debounce: 0.02)
        return (draft, server)
    }

    private let kuma = ContainerSpec(name: "uptime-kuma", image: "louislam/uptime-kuma:1", ports: [PortRow(host: "3001", container: "3001")],
                                     volumes: [VolumeRow(source: "./data", target: "/app/data")], env: [EnvRow(key: "TZ", value: "Europe/Dublin")])

    /// Waits until the compose check, the image lookup and the port lookup have all answered for the current state.
    private func checksDone(_ d: AddContainerDraft) async {
        await waitFor("the checks") {
            let rows = d.rows()
            return !rows.contains { $0.state == .running } && (d.state.validatedKey != nil || d.state.checkError != nil
                || rows.first?.state == .skipped || rows.first?.state == .fail)
        }
    }

    func testANewStackFromTheFormPassesAllChecksAndCanBeCreatedAndStarted() async throws {
        let (d, server) = setup()
        d.start()
        d.setStackName("kuma")
        d.setSpec(kuma)
        await checksDone(d)
        XCTAssertEqual(d.rows().map(\.title), ["YAML syntax", "Image", "Port 3001", "Container name"])
        XCTAssertTrue(d.rows().allSatisfy { $0.state == .pass }, "\(d.rows())")
        XCTAssertNil(d.deployBlockedReason())
        let request = try XCTUnwrap(d.request(start: true))
        guard case .newStack = request.work else { return XCTFail() }
        XCTAssertEqual(request.title, "Create kuma and start it?")
        XCTAssertTrue(request.preview.contains("Create folder /opt/stacks/kuma"))
        XCTAssertTrue(request.preview.contains(".env"))
        var result: DeployResult?
        d.perform(request) { result = $0 }
        await waitFor { result != nil }
        XCTAssertEqual(result, DeployResult(stack: request.stack, isNew: true, start: true))
        XCTAssertEqual(server.created.count, 1)
        await waitFor { !d.state.working }
        d.close()
    }

    func testProblemsBlockTheButtonWithAReason() async {
        let (d, _) = setup()
        d.start()
        XCTAssertEqual(d.deployBlockedReason(), "Enter a stack name")
        d.setStackName("media")
        XCTAssertEqual(d.deployBlockedReason(), "A stack named media already exists")
        d.setStackName("kuma")
        XCTAssertEqual(d.deployBlockedReason(), "Enter a container name")
        var taken = kuma
        taken.ports = [PortRow(host: "8080", container: "80")]
        d.setSpec(taken)
        await checksDone(d)
        let port = d.rows().first { $0.id == "port8080" }
        XCTAssertEqual(port?.state, .fail)
        XCTAssertEqual(port?.detail, "By web in media. Try 8081.")
        XCTAssertTrue(d.deployBlockedReason()?.hasPrefix("Port 8080 is already in use") == true, d.deployBlockedReason() ?? "")
        d.close()
    }

    func testAMissingImageBlocks() async {
        let server = FakeStackServer()
        server.imageFound = false
        let (d, _) = setup(server)
        d.start(); d.setStackName("kuma"); d.setSpec(kuma)
        await waitFor { d.state.imageStatus != nil }
        await checksDone(d)
        XCTAssertEqual(d.rows().first { $0.id == "image" }?.state, .fail)
        XCTAssertTrue(d.deployBlockedReason()?.hasPrefix("Image:") == true, d.deployBlockedReason() ?? "")
        d.close()
    }

    func testAServerThatRejectsTheComposeBlocksAndShowsWhy() async {
        let server = FakeStackServer()
        server.rejectWith = "yaml: line 4: mapping values are not allowed here"
        let (d, _) = setup(server)
        d.start(); d.setStackName("kuma"); d.setSpec(kuma)
        await checksDone(d)
        let first = d.rows().first
        XCTAssertEqual(first?.state, .fail)
        XCTAssertTrue(first?.detail.contains("Line 4") == true, first?.detail ?? "")
        XCTAssertNotNil(d.deployBlockedReason())
        d.close()
    }

    func testReadOnlyBlocksEverything() async {
        let (d, _) = setup(readOnly: true)
        d.start(); d.setStackName("kuma"); d.setSpec(kuma)
        await checksDone(d)
        XCTAssertEqual(d.deployBlockedReason(), "Read-only mode is on")
        XCTAssertNil(d.request(start: false))
        d.close()
    }

    func testPastingAComposeFileReplacesTheFormAndIsCheckedByTheServer() async throws {
        let (d, _) = setup()
        d.start(); d.setStackName("hello"); d.setPaste(true)
        let compose = "services:\n  hello:\n    image: nginxdemos/hello\n    ports:\n      - \"${TS_IP}:8081:80\"\n"
        d.setPasteCompose(compose)
        d.setPasteEnv("TS_IP=100.64.0.1\n")
        await checksDone(d)
        XCTAssertEqual(d.rows().map(\.title), ["YAML syntax", "Pasted file"])
        XCTAssertNil(d.deployBlockedReason())
        let request = try XCTUnwrap(d.request(start: false))
        guard case .newStack(let plan) = request.work else { return XCTFail() }
        XCTAssertEqual(plan.compose, compose)
        XCTAssertEqual(plan.env, "TS_IP=100.64.0.1\n")
        // A bad .env is caught locally, before any server round trip.
        d.setPasteEnv("BAD LINE\n")
        XCTAssertTrue(d.deployBlockedReason()?.hasPrefix("Fix .env") == true, d.deployBlockedReason() ?? "")
        d.close()
    }

    func testUnsetVariablesInAPastedFileCanBeAddedToTheEnvWithOneTap() async {
        let server = FakeStackServer()
        server.warnWith = #"time="t" level=warning msg="The \"DB_PASSWORD\" variable is not set. Defaulting to a blank string.""#
        let (d, _) = setup(server)
        d.start(); d.setStackName("x"); d.setPaste(true)
        d.setPasteCompose("services:\n  a:\n    image: x\n    environment:\n      K: ${DB_PASSWORD}\n")
        await waitFor { !d.missingVariables().isEmpty }
        XCTAssertEqual(d.missingVariables(), ["DB_PASSWORD"])
        d.addMissingVariables()
        XCTAssertEqual(d.state.pasteEnv, "DB_PASSWORD=\n")
        XCTAssertEqual(d.missingVariables(), [], "once the .env defines it, it is no longer missing")
        d.close()
    }

    func testAddingToAnExistingStackInsertsTheServiceAndMergesTheEnv() async throws {
        let server = FakeStackServer()
        server.envText = "TZ=UTC\n"
        let (d, _) = setup(server)
        d.start()
        d.setTarget(.existing)
        d.chooseExisting("media")
        d.setSpec(kuma)
        await waitFor { d.state.existing?.compose != nil }
        await checksDone(d)
        let composeNow = d.composeText()
        XCTAssertTrue(composeNow.hasPrefix("services:\n  web:\n    image: nginx\n  uptime-kuma:\n"), composeNow)
        XCTAssertEqual(d.envText(), "TZ=UTC\n", "TZ is already there: its value is kept")
        XCTAssertTrue(d.rows().contains { $0.id == "envkept" && $0.detail.contains("TZ") })
        XCTAssertNil(d.deployBlockedReason())
        let request = try XCTUnwrap(d.request(start: false))
        guard case .existingStack(let edits) = request.work else { return XCTFail() }
        XCTAssertEqual(edits.map(\.file.fileName), ["compose.yaml"], "no env edit when nothing new is added")
        var result: DeployResult?
        d.perform(request) { result = $0 }
        await waitFor { result != nil }
        XCTAssertEqual(result?.isNew, false)
        XCTAssertTrue(server.composeText.contains("uptime-kuma:"))
        d.close()
    }

    func testANewEnvVariableIsWrittenFirstAndThenTheCompose() async throws {
        let server = FakeStackServer()
        server.envText = "OTHER=1\n"
        let (d, _) = setup(server)
        d.start(); d.setTarget(.existing); d.chooseExisting("media"); d.setSpec(kuma)
        await waitFor { d.state.existing?.compose != nil }
        await checksDone(d)
        let request = try XCTUnwrap(d.request(start: true))
        guard case .existingStack(let edits) = request.work else { return XCTFail() }
        XCTAssertEqual(edits.map(\.file.fileName), [".env", "compose.yaml"])
        XCTAssertTrue(request.preview.contains(".env"))
        var done = false
        d.perform(request) { _ in done = true }
        await waitFor { done }
        XCTAssertEqual(server.envText, "OTHER=1\nTZ=Europe/Dublin\n")
        d.close()
    }

    func testAnInlineServicesBlockOrADuplicateNameIsRefusedWithTheReason() async {
        let server = FakeStackServer(compose: "services: {}\n")
        let (d, _) = setup(server)
        d.start(); d.setTarget(.existing); d.chooseExisting("media"); d.setSpec(kuma)
        await waitFor { d.state.existing?.compose != nil }
        XCTAssertTrue(d.deployBlockedReason()?.contains("one line") == true, d.deployBlockedReason() ?? "")
        XCTAssertEqual(d.rows().first { $0.id == "insert" }?.state, .fail)
        server.composeText = "services:\n  uptime-kuma:\n    image: a\n"
        d.chooseExisting("media")
        await waitFor { d.state.existing?.compose?.content == server.composeText }
        XCTAssertTrue(d.deployBlockedReason()?.contains("already has a service called uptime-kuma") == true, d.deployBlockedReason() ?? "")
        d.close()
    }

    func testAFileChangedOnTheServerInBetweenIsNotOverwritten() async throws {
        let server = FakeStackServer()
        let (d, _) = setup(server)
        var spec = kuma
        spec.env = [EnvRow()]
        d.start(); d.setTarget(.existing); d.chooseExisting("media"); d.setSpec(spec)
        await waitFor { d.state.existing?.compose != nil }
        await checksDone(d)
        let request = try XCTUnwrap(d.request(start: false))
        server.changeUnderneath = true
        var done = false
        d.perform(request) { _ in done = true }
        await waitFor { d.state.notice != nil }
        XCTAssertFalse(done)
        XCTAssertTrue(d.state.notice?.contains("changed on hetzner") == true)
        XCTAssertEqual(server.composeText, "services:\n  web:\n    image: nginx\n")
        d.close()
    }

    func testCreatingOverAnExistingFolderReportsIt() async throws {
        let server = FakeStackServer()
        server.exists = true
        let (d, _) = setup(server)
        d.start(); d.setStackName("kuma"); d.setSpec(kuma)
        await checksDone(d)
        d.perform(try XCTUnwrap(d.request(start: false))) { _ in XCTFail("must not finish") }
        await waitFor { d.state.notice != nil }
        XCTAssertTrue(d.state.notice?.contains("already exists") == true)
        d.close()
    }
}
