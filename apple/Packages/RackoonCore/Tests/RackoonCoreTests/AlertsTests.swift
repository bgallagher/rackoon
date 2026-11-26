import Foundation
import XCTest
@testable import RackoonCore

final class AlertsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func later(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func disk(_ percent: Int, mount: String = "/") -> AlertSignal {
        AlertSignal(key: "disk_high:\(mount)", category: .disk, severity: percent >= 95 ? .critical : .warning,
                    title: "Disk almost full", detail: "\(mount) is \(percent)% full.", fix: AlertFix("docker"))
    }

    // MARK: the book

    func testFirstReadingIsABaselineThenNewAlertsNotify() {
        var book = AlertBook()
        let first = book.apply(server: "a", serverName: "lab", source: .overview, signals: [disk(90)], at: t0)
        XCTAssertTrue(first.isEmpty, "what is already wrong at the first look is listed, not notified")
        XCTAssertEqual(book.active().count, 1)
        let second = book.apply(server: "a", serverName: "lab", source: .overview, signals: [disk(90), disk(88, mount: "/data")], at: later(1))
        XCTAssertEqual(second.map(\.key), ["disk_high:/data"])
        XCTAssertEqual(book.active().count, 2)
        // Still there: last seen moves, nothing new to say.
        XCTAssertTrue(book.apply(server: "a", serverName: "lab", source: .overview, signals: [disk(90), disk(88, mount: "/data")], at: later(2)).isEmpty)
        XCTAssertEqual(book.active().first { $0.key == "disk_high:/" }?.lastSeen, later(2))
        XCTAssertEqual(book.active().first { $0.key == "disk_high:/" }?.firstSeen, t0)
    }

    func testSecurityFindingsAreListedAndCountedButNeverNotify() throws {
        let text = try String(contentsOf: specDir.appendingPathComponent("fixtures/security/synthetic-debian-exposed.out.txt"), encoding: .utf8)
        let findings = SecurityRules.evaluate(SecurityParser.parse(text), context: .init(pendingSecurityUpdates: 2, rebootRequired: true))
        let signals = AlertRules.security(findings)
        XCTAssertEqual(signals.first { $0.key == "ssh.root_login" }?.severity, .critical)
        XCTAssertEqual(signals.first { $0.key == "ssh.root_login" }?.title, "Root login with a password")
        XCTAssertEqual(signals.first { $0.key == "ssh.root_login" }?.fix, AlertFix("security", target: "ssh.root_login"))
        XCTAssertEqual(signals.first { $0.key == "exposure.sensitive_port:3306" }?.severity, .warning)
        XCTAssertNil(signals.first { $0.key == "docker.container:portainer" }, "info findings stay on the Security screen")
        XCTAssertNil(signals.first { $0.key == "updates.security_pending" }, "the Overview already alerts about updates")
        XCTAssertNil(signals.first { $0.key == "updates.reboot" })
        XCTAssertTrue(signals.allSatisfy { $0.category == .security })

        var book = AlertBook()
        XCTAssertTrue(book.apply(server: "a", serverName: "lab", source: .security, signals: [], at: t0).isEmpty)
        let raised = book.apply(server: "a", serverName: "lab", source: .security, signals: signals, at: later(60))
        XCTAssertTrue(raised.isEmpty, "never a notification, even after the first reading")
        XCTAssertEqual(book.unseenCount(server: "a"), signals.count, "but counted in the badge")
        XCTAssertFalse(AlertSource.security.notifies)
        XCTAssertTrue(AlertSource.overview.notifies)
    }

    func testGettingWorseNotifiesAndClearsTheSeenMark() {
        var book = AlertBook()
        book.apply(server: "a", serverName: "lab", source: .overview, signals: [disk(90)], at: t0)
        let id = AlertBook.id(server: "a", source: .overview, key: "disk_high:/")
        book.acknowledge(id)
        XCTAssertEqual(book.unseenCount(), 0)
        let raised = book.apply(server: "a", serverName: "lab", source: .overview, signals: [disk(97)], at: later(1))
        XCTAssertEqual(raised.map(\.severity), [.critical])
        XCTAssertEqual(book.unseenCount(), 1)
        XCTAssertEqual(book.worstUnseen(), .critical)
    }

    func testAReadingOnlyResolvesItsOwnSource() {
        var book = AlertBook()
        book.apply(server: "a", serverName: "lab", source: .overview, signals: [disk(90)], at: t0)
        book.apply(server: "a", serverName: "lab", source: .services,
                   signals: [AlertSignal(key: "service_failed:x", category: .services, severity: .critical, title: "x failed")], at: t0)
        book.apply(server: "a", serverName: "lab", source: .services, signals: [], at: later(5))
        XCTAssertEqual(book.active().map(\.key), ["disk_high:/"], "the services reading resolved its alert, not the disk one")
        XCTAssertEqual(book.history().map(\.key), ["service_failed:x"])
        XCTAssertEqual(book.history().first?.resolvedAt, later(5))
        // Another server's reading touches nothing here.
        book.apply(server: "b", serverName: "nuc", source: .overview, signals: [], at: later(6))
        XCTAssertEqual(book.active(server: "a").count, 1)
    }

    func testComingBackIsANewOccurrence() {
        var book = AlertBook()
        book.apply(server: "a", serverName: "lab", source: .overview, signals: [], at: t0)
        XCTAssertEqual(book.apply(server: "a", serverName: "lab", source: .overview, signals: [disk(90)], at: later(1)).count, 1)
        book.apply(server: "a", serverName: "lab", source: .overview, signals: [], at: later(2))
        let again = book.apply(server: "a", serverName: "lab", source: .overview, signals: [disk(91)], at: later(3))
        XCTAssertEqual(again.first?.firstSeen, later(3))
        XCTAssertEqual(book.history().count, 1)
        XCTAssertEqual(book.active().count, 1)
    }

    func testMutedAlertsAreNotCountedOrNotified() {
        var book = AlertBook()
        book.apply(server: "a", serverName: "lab", source: .overview, signals: [], at: t0)
        book.apply(server: "a", serverName: "lab", source: .overview, signals: [disk(90)], at: later(1))
        let id = AlertBook.id(server: "a", source: .overview, key: "disk_high:/")
        book.mute(id)
        XCTAssertEqual(book.unseenCount(), 0)
        XCTAssertTrue(book.active().isEmpty)
        XCTAssertEqual(book.mutedAlerts().map(\.id), [id])
        XCTAssertTrue(book.apply(server: "a", serverName: "lab", source: .overview, signals: [disk(97)], at: later(2)).isEmpty, "muted: not even when worse")
        book.mute(id, false)
        XCTAssertEqual(book.active().count, 1)
    }

    func testInfoAlertsAreListedButNeverCountedOrNotified() {
        var book = AlertBook()
        book.apply(server: "a", serverName: "lab", source: .containers, signals: [], at: t0)
        let info = AlertSignal(key: "docker_needs_sudo", category: .containers, severity: .info, title: "Containers not checked")
        XCTAssertTrue(book.apply(server: "a", serverName: "lab", source: .containers, signals: [info], at: later(1)).isEmpty)
        XCTAssertEqual(book.active().count, 1)
        XCTAssertEqual(book.unseenCount(), 0)
    }

    func testOrderingAcknowledgeAllForgetAndHistoryLimits() {
        var book = AlertBook()
        book.apply(server: "a", serverName: "lab", source: .overview, signals: [disk(90, mount: "/old")], at: t0)
        book.apply(server: "a", serverName: "lab", source: .overview, signals: [disk(90, mount: "/old"), disk(96)], at: later(1))
        XCTAssertEqual(book.active().map(\.key), ["disk_high:/", "disk_high:/old"], "critical first")
        book.acknowledgeAll(server: "a")
        XCTAssertEqual(book.unseenCount(server: "a"), 0)
        book.mute(AlertBook.id(server: "a", source: .overview, key: "disk_high:/"))
        XCTAssertTrue(book.forget(serverID: "a"))
        XCTAssertTrue(book.alerts.isEmpty)
        XCTAssertTrue(book.muted.isEmpty)
        XCTAssertFalse(book.forget(serverID: "a"))

        // Resolved alerts older than a week go; the history is capped.
        var long = AlertBook()
        long.apply(server: "a", serverName: "lab", source: .overview, signals: [disk(90)], at: t0)
        long.apply(server: "a", serverName: "lab", source: .overview, signals: [], at: later(1))
        XCTAssertEqual(long.history().count, 1)
        long.apply(server: "a", serverName: "lab", source: .overview, signals: [], at: t0.addingTimeInterval(8 * 86400))
        XCTAssertTrue(long.history().isEmpty)
        for i in 0..<(AlertBook.historyLimit + 20) {
            long.apply(server: "a", serverName: "lab", source: .overview, signals: [disk(90, mount: "/m\(i)")], at: later(Double(i * 2)))
            long.apply(server: "a", serverName: "lab", source: .overview, signals: [], at: later(Double(i * 2 + 1)))
        }
        XCTAssertEqual(long.history().count, AlertBook.historyLimit)
    }

    func testBookRoundTripsThroughJSON() throws {
        var book = AlertBook()
        book.apply(server: "a", serverName: "lab", source: .overview, signals: [disk(90)], at: t0)
        book.mute("a|overview|x")
        let copy = try JSONDecoder().decode(AlertBook.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(copy, book)
    }

    // MARK: rules

    func testConnectionRules() {
        XCTAssertTrue(AlertRules.connection(error: nil, blocked: nil).isEmpty)
        let down = AlertRules.connection(error: "ssh: connect to host 10.0.0.9 port 22: No route to host", blocked: nil)
        XCTAssertEqual(down.map(\.key), ["not_answering"])
        XCTAssertEqual(down.first?.severity, .critical)
        XCTAssertEqual(AlertRules.connection(error: "user@h: Permission denied (publickey).", blocked: nil).first?.key, "login_refused")
        XCTAssertEqual(AlertRules.connection(error: nil, blocked: "The host key changed since you trusted it.").first?.severity, .critical)
        XCTAssertEqual(AlertRules.connection(error: nil, blocked: "Waiting for you to trust its host key.").first?.severity, .info)
    }

    func testServiceRulesOnlyWatchShownServices() throws {
        let s = ServicesParser.parse(try String(contentsOf: specDir.appendingPathComponent("fixtures/services/synthetic-root-failed.out.txt"), encoding: .utf8))
        let all = AlertRules.services(s) { $0.visibleByDefault }
        XCTAssertEqual(Set(all.map(\.key)), ["service_failed:system/backup-sync.service", "service_crashing:system/cloudflared.service",
                                             "service_stopped:system/beszel-agent.service"])
        XCTAssertEqual(all.first { $0.key.hasPrefix("service_stopped") }?.severity, .warning)
        XCTAssertEqual(all.first { $0.key.hasPrefix("service_failed") }?.fix, AlertFix("services", target: "system/backup-sync.service"))
        XCTAssertEqual(AlertRules.services(s) { $0.id != "system/backup-sync.service" && $0.visibleByDefault }.count, 2, "hidden ones don't alert")
    }

    func testContainerRules() throws {
        func fixture(_ name: String) throws -> DockerStatesReading {
            DockerStatesParser.parse(try String(contentsOf: specDir.appendingPathComponent("fixtures/docker_states/\(name).out.txt"), encoding: .utf8))
        }
        let problems = AlertRules.containers(try fixture("synthetic-problems"))
        XCTAssertEqual(problems.map(\.key), ["container_down:immich_redis", "container_down:paperless-worker", "container_down:old-thing"])
        XCTAssertEqual(problems.map(\.severity), [.critical, .warning, .critical])
        XCTAssertEqual(problems.first?.fix, AlertFix("docker", target: "immich"))
        XCTAssertEqual(problems.last?.fix, AlertFix("docker", target: "standalone/old-thing"))
        XCTAssertTrue(AlertRules.containers(try fixture("unraid-healthy")).isEmpty)
        XCTAssertEqual(AlertRules.containers(try fixture("permission-denied")).map(\.severity), [.info])
        XCTAssertTrue(AlertRules.containers(try fixture("not-installed")).isEmpty)
    }

    func testOverviewAndStorageRules() throws {
        let o = try OverviewParser.parse(String(contentsOf: specDir.appendingPathComponent("fixtures/overview/synthetic-security-updates.out.txt"), encoding: .utf8))
        let signals = AlertRules.overview(o)
        XCTAssertEqual(signals.map(\.key), Attention.evaluate(o).map(\.id))
        XCTAssertTrue(signals.contains { $0.key == "security_updates" && $0.category == .updates })
        let nas = try UnraidParser.parse(String(contentsOf: specDir.appendingPathComponent("fixtures/unraid/synthetic-check-running-disabled.out.txt"), encoding: .utf8))
        let storage = AlertRules.storage(nas)
        XCTAssertFalse(storage.isEmpty)
        XCTAssertTrue(storage.allSatisfy { $0.category == .storage })
        XCTAssertTrue(storage.contains { $0.severity == .critical })
    }

    func testCertificateRulesAndTargets() {
        let checks = [
            CertificateCheck(url: "https://a.example.com/", host: "a.example.com", expires: t0.addingTimeInterval(-86400), checkedAt: t0),
            CertificateCheck(url: "https://b.example.com/", host: "b.example.com", expires: t0.addingTimeInterval(3 * 86400), checkedAt: t0),
            CertificateCheck(url: "https://c.example.com/", host: "c.example.com", expires: t0.addingTimeInterval(14 * 86400), checkedAt: t0),
            CertificateCheck(url: "https://d.example.com/", host: "d.example.com", expires: t0.addingTimeInterval(60 * 86400), checkedAt: t0),
            CertificateCheck(url: "https://e.example.com/", host: "e.example.com", expires: nil, checkedAt: t0),
        ]
        let signals = AlertRules.certificates(checks, now: t0)
        XCTAssertEqual(signals.map(\.key), ["cert:a.example.com", "cert:b.example.com", "cert:c.example.com"])
        XCTAssertEqual(signals.map(\.severity), [.critical, .critical, .warning])
        XCTAssertEqual(signals[2].detail, "It expires in 14 days.")
        XCTAssertEqual(CertificateCheck.targets(["https://a.example.com/x", "https://A.example.com/y", "http://b.example.com",
                                                 "https://a.example.com:8443/", "not a url"]),
                       ["https://a.example.com/", "https://a.example.com:8443/"])
    }

    // MARK: the container reader

    func testDockerStatesGoldenFixtures() throws {
        let dir = specDir.appendingPathComponent("fixtures/docker_states")
        let outs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".out.txt") }.sorted { $0.path < $1.path }
        XCTAssertEqual(outs.count, 4)
        for out in outs {
            let expectedURL = URL(fileURLWithPath: out.path.replacingOccurrences(of: ".out.txt", with: ".expected.json"))
            let reading = DockerStatesParser.parse(try String(contentsOf: out, encoding: .utf8))
            let actual = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reading)) as! NSDictionary
            if !FileManager.default.fileExists(atPath: expectedURL.path), ProcessInfo.processInfo.environment["RACKOON_WRITE_GOLDEN"] != nil {
                try JSONSerialization.data(withJSONObject: actual, options: [.prettyPrinted, .sortedKeys]).write(to: expectedURL)
                XCTFail("wrote \(expectedURL.lastPathComponent): review it, then commit")
                continue
            }
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as? NSDictionary
            XCTAssertEqual(actual, expected, out.lastPathComponent)
        }
    }

    func testDockerStatesDetails() throws {
        let r = DockerStatesParser.parse(try String(contentsOf: specDir.appendingPathComponent("fixtures/docker_states/synthetic-problems.out.txt"), encoding: .utf8))
        XCTAssertEqual(r.containers.count, 8)
        XCTAssertEqual(r.containers.first { $0.name == "paperless-worker" }?.exitCode, 1)
        XCTAssertEqual(r.containers.first { $0.name == "uptime-kuma" }?.exitCode, 137)
        XCTAssertNil(r.containers.first { $0.name == "immich_server" }?.exitCode)
        XCTAssertEqual(r.containers.first?.href, "https://photos.example.com")
        let real = DockerStatesParser.parse(try String(contentsOf: specDir.appendingPathComponent("fixtures/docker_states/unraid-healthy.out.txt"), encoding: .utf8))
        XCTAssertGreaterThan(real.containers.count, 40)
        XCTAssertNil(real.problem)
    }

    func testCommandMatchesSpec() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("commands.json"))
        let commands = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["commands"] as! [[String: Any]]
        XCTAssertEqual(DockerStatesSession.command, commands.first { $0["id"] as? String == "docker_states" }?["script"] as? String)
    }
}
