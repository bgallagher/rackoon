import Foundation
import XCTest
import RackoonCore
import RackoonDemo
@testable import RackoonMac

/// Counts what it is asked to run and answers with the demo homelab's Security output.
private final class CountingTransport: SSHTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var runs: Int { lock.withLock { count } }

    func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        lock.withLock { count += 1 }
        return try await DemoFleet.transport(for: DemoFleet.servers[0]).run(command, timeout: timeout)
    }

    func stream(_ command: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
}

@MainActor
final class SecurityModelTests: XCTestCase {
    private func findings(_ server: Server, context: SecurityContext = .init()) async throws -> [String: SecurityFinding.Severity] {
        let text = try await DemoFleet.transport(for: server).run(SecuritySession.command, timeout: 5).stdout
        return Dictionary(uniqueKeysWithValues: SecurityRules.evaluate(SecurityParser.parse(text), context: context).map { ($0.id, $0.severity) })
    }

    func testDemoHomelabIsMostlyHardened() async throws {
        let homelab = try XCTUnwrap(DemoFleet.servers.first { $0.name == "homelab" })
        let f = try await findings(homelab, context: .init(pendingSecurityUpdates: 2, rebootRequired: true))
        XCTAssertNil(f.values.first { $0 == .critical }, "\(f)")
        XCTAssertEqual(f["ssh.password_auth"], .pass)
        XCTAssertEqual(f["exposure.firewall"], .pass)
        XCTAssertEqual(f["exposure.docker_bypass"], .warning, "traefik and jellyfin publish on every interface past ufw")
        XCTAssertEqual(f["docker.container:traefik"], .info, "a reverse proxy needs the socket by design")
        XCTAssertEqual(f["updates.security_pending"], .warning)
    }

    func testDemoNucHasNoFirewall() async throws {
        let nuc = try XCTUnwrap(DemoFleet.servers.first { $0.name != "homelab" })
        let f = try await findings(nuc)
        XCTAssertEqual(f["exposure.firewall"], .warning)
        XCTAssertEqual(f["exposure.sensitive_port:6379"], .warning)
        XCTAssertEqual(f["updates.automatic"], .info)
    }

    func testAFreshReadingIsNotReadAgainUntilCheckNow() async throws {
        let transport = CountingTransport()
        let model = SecurityModel(transport: transport)
        model.load()
        try await waitUntil { !model.loading }
        XCTAssertNotNil(model.snapshot)
        XCTAssertEqual(transport.runs, 1)
        model.load()
        XCTAssertEqual(transport.runs, 1, "a reading younger than five minutes is kept")
        model.load(now: Date().addingTimeInterval(SecurityModel.freshFor + 1))
        try await waitUntil { !model.loading }
        XCTAssertEqual(transport.runs, 2)
        model.load(force: true)
        try await waitUntil { !model.loading }
        XCTAssertEqual(transport.runs, 3, "Check Now always reads")
    }

    func testContextComesFromTheOverview() {
        XCTAssertEqual(SecurityModel.context(nil), SecurityContext())
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
}
