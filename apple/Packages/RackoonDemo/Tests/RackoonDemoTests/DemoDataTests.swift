import Foundation
@testable import RackoonCore
@testable import RackoonDemo
import XCTest

/// Demo mode is only useful if it shows what a real server would: every canned answer goes through the real parsers here,
/// so a spec format change that the demo data does not follow fails a test instead of breaking screenshots.
final class DemoDataTests: XCTestCase {
    private let homelab = DemoFleet.servers[0]
    private let nuc = DemoFleet.servers[1]

    func testTheFleetHasTwoServersEachWithItsOwnTransport() {
        XCTAssertEqual(DemoFleet.servers.map(\.name), ["homelab", "garage-nuc"])
        XCTAssertEqual(Set(DemoFleet.servers.map(\.id)).count, 2)
    }

    func testOverviewParsesWithAttentionItems() async throws {
        let result = try await DemoFleet.transport(for: homelab).run(ServerSession.overviewCommand, timeout: 5)
        let overview = try OverviewParser.parse(result.stdout)
        XCTAssertEqual(overview.hostname, "homelab")
        XCTAssertTrue(overview.rebootRequired)
        XCTAssertEqual(overview.pendingUpdates, 5)
        XCTAssertEqual(overview.securityUpdates, 2)
        XCTAssertEqual(overview.tailscaleIP, "100.100.40.7")
        XCTAssertFalse(overview.unhealthyContainers.isEmpty)
        XCTAssertFalse(Attention.evaluate(overview).isEmpty, "the demo exists partly to show the attention strip")

        let small = try OverviewParser.parse(try await DemoFleet.transport(for: nuc).run(ServerSession.overviewCommand, timeout: 5).stdout)
        XCTAssertEqual(small.hostname, "garage-nuc")
        XCTAssertNil(small.tailscaleIP)
    }

    func testCPUMovesBetweenPolls() async throws {
        let transport = DemoTransport(profile: .homelab)
        let first = try OverviewParser.parse(try await transport.run(ServerSession.overviewCommand, timeout: 5).stdout)
        try await Task.sleep(nanoseconds: 50_000_000)
        let second = try OverviewParser.parse(try await transport.run(ServerSession.overviewCommand, timeout: 5).stdout)
        XCTAssertNotNil(second.cpuPercent(since: first))
    }

    func testDockerParsesIntoStacksWithBookmarksAndStandaloneContainers() async throws {
        let result = try await DemoFleet.transport(for: homelab).run(DockerSession.command, timeout: 5)
        let snapshot = try DockerParser.parse(result.stdout)
        XCTAssertGreaterThanOrEqual(snapshot.stacks.count, 12)
        XCTAssertTrue(snapshot.stacks.contains { $0.name == "immich" && $0.containers.count == 4 })
        XCTAssertTrue(snapshot.stacks.contains { $0.isStandalone })
        XCTAssertTrue(snapshot.stacks.contains { $0.hasBookmark })
        for stack in snapshot.stacks where !stack.isStandalone {
            XCTAssertNotNil(ComposeAction.up.command(for: stack), "\(stack.name) must resolve to a compose command")
        }
    }

    func testAStackFileOpensAndSavesThroughTheRealSession() async throws {
        let transport = DemoFleet.transport(for: homelab)
        let snapshot = try DockerParser.parse(try await transport.run(DockerSession.command, timeout: 5).stdout)
        let stack = try XCTUnwrap(snapshot.stacks.first { StackFiles.editable(for: $0) != nil })
        let session = StackFileSession(transport: transport, stack: stack)
        let file = try XCTUnwrap(session.files.first)
        guard case .file(let remote) = try await session.read(file) else { return XCTFail("the compose file reads") }
        let edit = FileEdit(file: file, original: remote.content, originalSHA: remote.sha256, content: remote.content + "# edited\n")
        // A save starts with F='...' like a read; it must get a save's answer, not the file again.
        guard case .saved = try await session.save(edit, confirmation: try session.confirm(edit)) else { return XCTFail("the save confirms") }
    }

    func testUpdatesParse() async throws {
        let result = try await DemoUpdatesTransport().run(UpdatesSession.command, timeout: 5)
        let snapshot = try UpdatesParser.parse(result.stdout)
        XCTAssertEqual(snapshot.packages.count, 5)
        XCTAssertEqual(snapshot.packages.filter(\.isSecurity).count, 2)
        XCTAssertTrue(snapshot.rebootRequired)
    }

    func testStreamsEndWithTheExitMarker() async throws {
        var text = ""
        for try await chunk in DemoUpdatesTransport().stream("apt-get -y upgrade") { text += chunk }
        var parser = StreamOutputParser()
        _ = parser.push(text)
        XCTAssertEqual(parser.finish().exitCode, 0)
    }

    func testTheFakeShellNeverRunsWhatIsTyped() {
        let script = DemoFleet.shellScript
        XCTAssertTrue(script.hasPrefix("#!/bin/bash"))
        XCTAssertFalse(script.contains("eval"), "the demo shell must only print canned text")
        XCTAssertTrue(script.contains("demo shell, so only a few commands are simulated"))
    }
}
