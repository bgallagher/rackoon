import Foundation
@testable import RackoonCore
import XCTest
@testable import RackoonDemo
@testable import RackoonMac

/// The demo's services data goes through the real parser, so the demo shows what a real server would.
final class DemoServicesTests: XCTestCase {
    func testHomelabDemoParsesIntoTheServicesTheScreenShows() throws {
        let s = ServicesParser.parse(DemoServices.output(for: .homelab))
        let shown = Dictionary(uniqueKeysWithValues: s.services.filter(\.visibleByDefault).map { ($0.id, $0) })
        XCTAssertEqual(shown["system/tailscaled.service"]?.name, "Tailscale")
        XCTAssertEqual(shown["system/pihole-FTL.service"]?.ports.map(\.port), [53, 8053])
        XCTAssertEqual(shown["system/backup-sync.service"]?.status, .failed)
        XCTAssertEqual(shown["system/cloudflared.service"]?.status, .restarting)
        XCTAssertEqual(shown["user/hermes-gateway.service"]?.ports.map(\.port), [38165])
        XCTAssertEqual(shown["process/paperclipai"]?.ports.map(\.port), [3100, 54329])
        XCTAssertEqual(shown["process/hermes"]?.name, "Hermes Agent")
        XCTAssertNil(shown["system/dbus.service"])
        XCTAssertNil(shown["user/pipewire.service"])
        XCTAssertNotNil(s.services.first { $0.id == "system/ssh.service" }, "hidden, not missing")
    }

    func testSmallDemoServer() {
        let s = ServicesParser.parse(DemoServices.output(for: .nuc))
        XCTAssertEqual(Set(s.services.filter(\.visibleByDefault).map(\.id)),
                       ["system/tailscaled.service", "system/docker.service", "system/beszel-agent.service"])
    }

    func testDemoAnswersStatusLogsAndActions() {
        XCTAssertNotNil(DemoServices.read("systemctl status --no-pager --lines=5 'tailscaled.service' 2>&1 | head -n 20; true"))
        XCTAssertNil(DemoServices.read("docker ps"))
        XCTAssertEqual(DemoServices.streamLines("x; $S systemctl restart 'tailscaled.service' && echo"), ["Now: active"])
        XCTAssertEqual(DemoServices.streamLines("systemctl --user stop 'hermes-gateway.service'"), ["Now: inactive"])
    }
}

@MainActor
final class ServiceVisibilityStoreTests: XCTestCase {
    func testChoicesAreSavedAndForgotten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svc-vis-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = ServicesParser.parse(DemoServices.output(for: .homelab))
        let ssh = try XCTUnwrap(s.services.first { $0.id == "system/ssh.service" })
        let store = ServiceVisibilityStore(directory: dir)
        XCTAssertFalse(store.isVisible(ssh, server: "a"))
        store.set(true, ssh, server: "a")
        XCTAssertTrue(ServiceVisibilityStore(directory: dir).isVisible(ssh, server: "a"), "saved to disk")
        store.forget(serverID: "a")
        XCTAssertFalse(ServiceVisibilityStore(directory: dir).isVisible(ssh, server: "a"))
    }
}

/// The demo answers the background container check in the format the alert rules read.
final class DemoAlertsTests: XCTestCase {
    func testDemoContainerCheckParses() async throws {
        let transport = DemoTransport(profile: .homelab)
        let read = await DockerStatesSession(transport: transport).read()
        let reading = try XCTUnwrap(read)
        XCTAssertNil(reading.problem)
        XCTAssertGreaterThan(reading.containers.count, 10)
        XCTAssertTrue(reading.containers.contains { $0.status.contains("unhealthy") })
        XCTAssertTrue(AlertRules.containers(reading).isEmpty, "the demo's containers are all up; the unhealthy one comes from the Overview")
    }
}
