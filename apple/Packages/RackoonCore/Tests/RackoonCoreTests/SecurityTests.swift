import Foundation
import XCTest
@testable import RackoonCore

final class SecurityTests: XCTestCase {
    private func fixture(_ name: String) throws -> SecuritySnapshot {
        SecurityParser.parse(try String(contentsOf: specDir.appendingPathComponent("fixtures/security/\(name).out.txt"), encoding: .utf8))
    }

    private func finding(_ findings: [SecurityFinding], _ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> SecurityFinding {
        try XCTUnwrap(findings.first { $0.id == id }, "no \(id) in \(findings.map(\.id))", file: file, line: line)
    }

    /// Every fixture in spec/fixtures/security must parse to its expected JSON.
    /// Run with RACKOON_WRITE_GOLDEN=1 to write any missing expected file, then review it before committing.
    func testGoldenFixtures() throws {
        let dir = specDir.appendingPathComponent("fixtures/security")
        let outs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".out.txt") && !$0.lastPathComponent.hasPrefix("raw-") }
            .sorted { $0.path < $1.path }
        XCTAssertGreaterThanOrEqual(outs.count, 3)
        for out in outs {
            let expectedURL = URL(fileURLWithPath: out.path.replacingOccurrences(of: ".out.txt", with: ".expected.json"))
            let snapshot = SecurityParser.parse(try String(contentsOf: out, encoding: .utf8))
            let actual = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! NSDictionary
            if !FileManager.default.fileExists(atPath: expectedURL.path),
               ProcessInfo.processInfo.environment["RACKOON_WRITE_GOLDEN"] != nil {
                let data = try JSONSerialization.data(withJSONObject: actual, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: expectedURL)
                XCTFail("wrote \(expectedURL.lastPathComponent): review it, then commit")
                continue
            }
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as? NSDictionary
            XCTAssertEqual(actual, expected, out.lastPathComponent)
        }
    }

    func testCommandMatchesSpec() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        XCTAssertEqual(SecuritySession.command, commands.first { $0["id"] as? String == "security" }?["script"] as? String)
    }

    /// The checks' titles and advice are data in spec/security-checks.json, for every platform.
    /// RACKOON_WRITE_GOLDEN=1 rewrites it from Swift; review the diff.
    func testChecksMatchSpec() throws {
        let url = specDir.appendingPathComponent("security-checks.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if ProcessInfo.processInfo.environment["RACKOON_WRITE_GOLDEN"] != nil {
            struct Doc: Encodable {
                let about: String
                let groups: [[String: String]]
                let checks: [SecurityCheck]
            }
            let doc = Doc(about: "The Security screen's checks (docs/security-plan.md): id, group, title, why it matters and advice a person acts on themselves. Rackoon never changes the server. Each core's rules emit findings with these ids (plus ':<item>' for one finding per port or container); spec/scenarios/security-checks.json says which severity each fixture gives.",
                          groups: SecurityCheck.Group.allCases.map { ["id": $0.rawValue, "title": $0.title] },
                          checks: SecurityChecks.all)
            var data = try encoder.encode(doc)
            data.append(contentsOf: Array("\n".utf8))
            try data.write(to: url)
        }
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let ours = try JSONSerialization.jsonObject(with: encoder.encode(SecurityChecks.all)) as! NSArray
        XCTAssertEqual(ours, spec["checks"] as? NSArray)
        let groups = (spec["groups"] as! [[String: String]]).map { ($0["id"]!, $0["title"]!) }
        XCTAssertEqual(groups.map(\.0), SecurityCheck.Group.allCases.map(\.rawValue))
        XCTAssertEqual(groups.map(\.1), SecurityCheck.Group.allCases.map(\.title))
    }

    func testEveryFindingNamesACheckInTheCatalog() throws {
        for name in ["synthetic-ubuntu-hardened", "synthetic-ubuntu-default", "synthetic-debian-exposed"] {
            for f in SecurityRules.evaluate(try fixture(name), context: .init(pendingSecurityUpdates: 1, rebootRequired: true)) {
                XCTAssertNotNil(SecurityChecks.check(f.check), "\(name): \(f.check)")
                XCTAssertTrue(f.id == f.check || f.id.hasPrefix(f.check + ":"), f.id)
            }
        }
    }

    func testDropInsComeFirstWhereTheIncludeIs() throws {
        let s = try fixture("synthetic-ubuntu-hardened")
        XCTAssertEqual(s.sshd.source, .files)
        // The main file says X11Forwarding yes AFTER its Include; the drop-in's "no" was read first, so it wins.
        XCTAssertEqual(s.sshd.settings["x11forwarding"], "no")
        XCTAssertEqual(s.sshd.origin["x11forwarding"], "/etc/ssh/sshd_config.d/10-hardening.conf")
        XCTAssertEqual(s.sshd.settings["kbdinteractiveauthentication"], "no")
        XCTAssertEqual(s.sshd.uncertain, [])
    }

    func testAnUnreadableDropInMakesLaterValuesUncertain() throws {
        let s = try fixture("synthetic-ubuntu-default")
        XCTAssertEqual(s.sshd.unreadable, ["/etc/ssh/sshd_config.d/50-cloud-init.conf"])
        XCTAssertEqual(s.sshd.settings["permitrootlogin"], "no", "the commented-out line in the main file does not count")
        XCTAssertTrue(s.sshd.uncertain.contains("permitrootlogin"))
        XCTAssertTrue(s.sshd.uncertain.contains("passwordauthentication"))
        let findings = SecurityRules.evaluate(s)
        XCTAssertEqual(try finding(findings, "ssh.password_auth").severity, .unknown, "never a guess from sshd's default")
        XCTAssertTrue(try finding(findings, "ssh.root_login").evidence?.contains("50-cloud-init.conf") == true)
    }

    func testRootReadsTheEffectiveSettings() throws {
        let s = try fixture("synthetic-debian-exposed")
        XCTAssertTrue(s.isRoot)
        XCTAssertEqual(s.sshd.source, .effective)
        XCTAssertEqual(s.sshd.settings["port"], "2222")
        XCTAssertEqual(s.rootAccounts, ["root", "toor"])
    }

    func testListenerScopes() {
        XCTAssertEqual(SecurityParser.scope(of: "0.0.0.0"), .all)
        XCTAssertEqual(SecurityParser.scope(of: "*"), .all)
        XCTAssertEqual(SecurityParser.scope(of: "::"), .all)
        XCTAssertEqual(SecurityParser.scope(of: "127.0.0.53"), .loopback)
        XCTAssertEqual(SecurityParser.scope(of: "::1"), .loopback)
        XCTAssertEqual(SecurityParser.scope(of: "100.100.40.7"), .tailscale)
        XCTAssertEqual(SecurityParser.scope(of: "fd7a:115c:a1e0::1"), .tailscale)
        XCTAssertEqual(SecurityParser.scope(of: "192.168.1.20"), .lan)
        XCTAssertEqual(SecurityParser.scope(of: "172.20.0.1"), .lan)
        XCTAssertEqual(SecurityParser.scope(of: "fe80::1"), .lan)
        XCTAssertEqual(SecurityParser.scope(of: "203.0.113.24"), .public)
        XCTAssertEqual(SecurityParser.scope(of: "100.63.0.1"), .public, "just below Tailscale's range")
        XCTAssertTrue(SecurityParser.hostPort("127.0.0.53%lo:53")! == ("127.0.0.53", "53"))
        XCTAssertTrue(SecurityParser.hostPort("[::ffff:127.0.0.1]:631")! == ("127.0.0.1", "631"))
        XCTAssertTrue(SecurityParser.hostPort(":::8080")! == ("::", "8080"), "old Docker's IPv6 any address")
    }

    func testIncludeGlobs() {
        XCTAssertTrue(SecurityParser.globMatches("/etc/ssh/sshd_config.d/*.conf", "/etc/ssh/sshd_config.d/50-cloud-init.conf"))
        XCTAssertFalse(SecurityParser.globMatches("/etc/ssh/sshd_config.d/*.conf", "/etc/ssh/sshd_config.d/x/y.conf"))
        XCTAssertFalse(SecurityParser.globMatches("/etc/ssh/sshd_config.d/*.conf", "/etc/ssh/sshd_config.d/notes.txt"))
        XCTAssertTrue(SecurityParser.globMatches("/etc/ssh/sshd_config.d/1?-a.conf", "/etc/ssh/sshd_config.d/10-a.conf"))
    }

    func testDockerPublishedOnEveryInterfaceGetsPastUfw() throws {
        var s = try fixture("synthetic-ubuntu-hardened")
        s.docker.published.append(.init(container: "web", address: "0.0.0.0", port: "8443", proto: "tcp", scope: .all))
        let bypass = try finding(SecurityRules.evaluate(s), "exposure.docker_bypass")
        XCTAssertEqual(bypass.severity, .warning)
        XCTAssertEqual(bypass.evidence, "8443/tcp (web)")
    }

    func testCountsBySeverity() throws {
        let counts = SecurityRules.counts(SecurityRules.evaluate(try fixture("synthetic-debian-exposed")))
        XCTAssertEqual(counts[.critical], 4, "root login, a second UID 0 account, an empty password, Docker's API without TLS")
    }

    func testReadsThroughTheTransport() async throws {
        let text = try String(contentsOf: specDir.appendingPathComponent("fixtures/security/synthetic-ubuntu-hardened.out.txt"), encoding: .utf8)
        let transport = FakeTransport([.success(CommandResult(stdout: text))])
        let s = try await SecuritySession.read(transport)
        XCTAssertEqual(transport.commands, [SecuritySession.command])
        XCTAssertEqual(s.os.id, "ubuntu")
    }
}

final class SecurityExposureTests: XCTestCase {
    private func fixture(_ name: String) throws -> SecuritySnapshot {
        SecurityParser.parse(try String(contentsOf: specDir.appendingPathComponent("fixtures/security/\(name).out.txt"), encoding: .utf8))
    }

    func testIPv4AndIPv6OfOnePortAreOneRowAndTheWidestReachWins() throws {
        let ports = SecurityExposure.ports(try fixture("synthetic-debian-exposed"), ufwOn: false)
        let mysql = try XCTUnwrap(ports.first { $0.port == 3306 })
        XCTAssertEqual(mysql.addresses, ["0.0.0.0", "::"])
        XCTAssertEqual(mysql.containers, ["mariadb"])
        XCTAssertEqual(mysql.service, "MySQL/MariaDB")
        XCTAssertEqual(mysql.flags, ["database or cache"])
        XCTAssertEqual(ports.filter { $0.port == 3306 }.count, 1)
        XCTAssertEqual(try XCTUnwrap(ports.first { $0.port == 2375 }).flags, ["no TLS"])
        XCTAssertEqual(ports.first?.scope, .all, "widest reach first")
        XCTAssertEqual(ports.last?.port, 9000, "the LAN-only port comes after every exposed one")
    }

    func testDockerPortsPastUfwAreFlaggedOnlyWithUfwOn() throws {
        var s = try fixture("synthetic-ubuntu-hardened")
        s.listeners.append(.init(proto: "tcp", address: "0.0.0.0", port: 8443, scope: .all))
        s.docker.published.append(.init(container: "web", address: "0.0.0.0", port: "8443", proto: "tcp", scope: .all))
        XCTAssertEqual(SecurityExposure.ports(s, ufwOn: true).first { $0.port == 8443 }?.flags, ["past ufw"])
        XCTAssertEqual(SecurityExposure.ports(s, ufwOn: false).first { $0.port == 8443 }?.flags, [])
        let tailscaleOnly = try XCTUnwrap(SecurityExposure.ports(s, ufwOn: true).first { $0.port == 8080 })
        XCTAssertFalse(tailscaleOnly.isExposed)
        XCTAssertEqual(tailscaleOnly.containers, ["paperless"])
    }
}
