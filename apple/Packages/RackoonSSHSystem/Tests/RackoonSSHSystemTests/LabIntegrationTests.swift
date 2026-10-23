import Foundation
@testable import RackoonCore
import XCTest
@testable import RackoonSSHSystem

/// The checks in spec/integration/checks.json, run with the real OpenSSHTransport against the integration lab
/// (test/lab; `tools/lab up`, then `eval "$(tools/lab env)"`). Skipped when the lab is not configured. Like the shared
/// scenarios, a check runs only while its feature is done for the Mac in spec/features.json. ssh is given `-F /dev/null`
/// and the lab's own known_hosts, so nothing in ~/.ssh is read or written.
final class LabIntegrationTests: XCTestCase {
    private static let platform = "mac"
    private static let specDir: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("spec")
    }()

    private struct Lab {
        let host: String
        let port: Int
        let user: String
        let sudoUser: String
        let sudoPassword: String
        let key: String
        let knownHosts: String
    }

    private static func json(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: specDir.appendingPathComponent(name))) as! [String: Any]
    }

    private static var checks: [String: Any] { (try? json("integration/checks.json")) ?? [:] }
    private static var labFacts: [String: Any] { checks["lab"] as? [String: Any] ?? [:] }

    /// Check ids whose feature is done on the Mac.
    private static func applicableChecks() throws -> [String] {
        let features = try json("features.json")["features"] as! [[String: Any]]
        let done = Set(features.compactMap { f -> String? in
            let entry = (f["platforms"] as! [String: Any])[platform] as! [String: Any]
            return entry["status"] as? String == "done" ? f["id"] as? String : nil
        })
        let list = try json("integration/checks.json")["checks"] as! [[String: Any]]
        return list.filter { done.contains($0["feature"] as! String) }.map { $0["id"] as! String }
    }

    override class func setUp() {
        super.setUp()
        // Linux does not ignore SIGPIPE: a write to ssh's stdin after ssh exited (a refused connection) would kill the
        // whole test process instead of failing the one check.
        signal(SIGPIPE, SIG_IGN)
    }

    private static let implemented: Set<String> = [
        "overview_parses", "updates_parse", "docker_parses", "stream_exit_status", "logs_cancel_leaves_nothing",
        "hostkey_mismatch_blocked", "stdin_exact_bytes", "sudo_password_checked",
    ]

    private func lab() throws -> Lab {
        let env = ProcessInfo.processInfo.environment
        guard env["RACKOON_LAB"] == "1", let host = env["RACKOON_LAB_HOST"], let key = env["RACKOON_LAB_KEY"],
              let knownHosts = env["RACKOON_LAB_KNOWN_HOSTS"] else {
            throw XCTSkip("integration lab not configured (tools/lab up, then eval \"$(tools/lab env)\")")
        }
        return Lab(host: host, port: Int(env["RACKOON_LAB_PORT"] ?? "") ?? 2222, user: env["RACKOON_LAB_USER"] ?? "rk",
                   sudoUser: env["RACKOON_LAB_SUDO_USER"] ?? "rkpw", sudoPassword: env["RACKOON_LAB_SUDO_PASSWORD"] ?? "",
                   key: key, knownHosts: knownHosts)
    }

    /// Runs the check only if its feature is done on the Mac (otherwise skips, like the scenario runner).
    private func requireApplicable(_ id: String) throws {
        guard try Self.applicableChecks().contains(id) else { throw XCTSkip("\(id): its feature is not done on the Mac") }
    }

    /// `freshConnection` keeps the command off the shared ControlMaster socket: an open master connection has already
    /// checked the host key, so a different known_hosts would never be consulted.
    private func transport(_ lab: Lab, user: String? = nil, knownHosts: String? = nil,
                           freshConnection: Bool = false) -> OpenSSHTransport {
        OpenSSHTransport(destination: "\(user ?? lab.user)@\(lab.host)", port: lab.port, identityFile: lab.key,
                         leadingOptions: ["-F", "/dev/null"] + (freshConnection ? ["-o", "ControlPath=none"] : []) + [
                                          "-o", "UserKnownHostsFile=\(knownHosts ?? lab.knownHosts)",
                                          "-o", "GlobalKnownHostsFile=/dev/null",
                                          "-o", "StrictHostKeyChecking=yes"])
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await chunk in stream { text += chunk }
        return text
    }

    func testEveryApplicableCheckHasARunner() throws {
        for id in try Self.applicableChecks() {
            XCTAssertTrue(Self.implemented.contains(id), "\(id) has no Swift lab runner, but its feature is done on the Mac")
        }
    }

    func testOverviewParses() async throws {
        let lab = try lab()
        try requireApplicable("overview_parses")
        let result = try await transport(lab).run(ServerSession.overviewCommand, timeout: 30)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let overview = try OverviewParser.parse(result.stdout)
        XCTAssertFalse(overview.hostname.isEmpty)
        XCTAssertFalse(overview.disks.isEmpty)
        XCTAssertGreaterThan(overview.cpu.total, 0)
        XCTAssertTrue(overview.rebootRequired)
        XCTAssertEqual(overview.tailscaleIP, Self.labFacts["tailscaleIP"] as? String)
        XCTAssertEqual(overview.pendingUpdates, (Self.labFacts["pending"] as? [String])?.count)
        XCTAssertEqual(overview.securityUpdates, (Self.labFacts["security"] as? [String])?.count)
    }

    func testUpdatesParse() async throws {
        let lab = try lab()
        try requireApplicable("updates_parse")
        let result = try await transport(lab).run(UpdatesSession.command, timeout: 60)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let snapshot = try UpdatesParser.parse(result.stdout)
        XCTAssertEqual(snapshot.packages.map(\.name).sorted(), Self.labFacts["pending"] as? [String])
        XCTAssertEqual(snapshot.packages.filter(\.isSecurity).map(\.name).sorted(), Self.labFacts["security"] as? [String])
        XCTAssertTrue(snapshot.rebootRequired)
    }

    private func labStack(_ lab: Lab) async throws -> DockerStack {
        let result = try await transport(lab).run(DockerSession.command, timeout: 60)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let snapshot = try DockerParser.parse(result.stdout)
        return try XCTUnwrap(snapshot.stacks.first { $0.name == Self.labFacts["stack"] as? String }, "labstack not found")
    }

    func testDockerParses() async throws {
        let lab = try lab()
        try requireApplicable("docker_parses")
        let stack = try await labStack(lab)
        let ticker = try XCTUnwrap(stack.containers.first { $0.service == Self.labFacts["service"] as? String })
        XCTAssertEqual(ticker.state, "running")
        XCTAssertNotNil(ComposeAction.up.command(for: stack))
    }

    func testStreamExitStatus() async throws {
        let lab = try lab()
        try requireApplicable("stream_exit_status")
        let text = try await collect(transport(lab).stream(StreamedCommand.wrap("echo lab-out; exit 3", cols: 80, rows: 24)))
        var parser = StreamOutputParser()
        let shown = parser.push(text)
        let end = parser.finish()
        XCTAssertEqual(end.exitCode, 3, text)
        XCTAssertTrue((shown + end.text).contains("lab-out"))
    }

    func testLogsCancelLeavesNothing() async throws {
        let lab = try lab()
        try requireApplicable("logs_cancel_leaves_nothing")
        let stack = try await labStack(lab)
        let ticker = try XCTUnwrap(stack.containers.first)
        let command = try XCTUnwrap(DockerSession.logsCommand(id: ticker.id))
        var seen = ""
        for try await chunk in transport(lab).stream(command) {
            seen += chunk
            if seen.contains("tick") { break }   // leaving the loop cancels the stream: Ctrl-C, then teardown
        }
        XCTAssertTrue(seen.contains("tick"))
        // `[l]` keeps the pattern from matching the shell that runs pgrep itself.
        var left = "?"
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(500))
            left = try await transport(lab).run("pgrep -f 'docker [l]ogs -f' | wc -l", timeout: 15).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if left == "0" { break }
        }
        XCTAssertEqual(left, "0", "docker logs is still running on the server after cancelling")
    }

    func testHostKeyMismatchBlocked() async throws {
        let lab = try lab()
        try requireApplicable("hostkey_mismatch_blocked")
        // A fresh key that is certainly not the lab's, recorded for the lab's address.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rk-lab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", dir.appendingPathComponent("k").path]
        try keygen.run()
        keygen.waitUntilExit()
        let pub = try String(contentsOf: dir.appendingPathComponent("k.pub"), encoding: .utf8).split(separator: " ")
        let wrong = dir.appendingPathComponent("known_hosts")
        try "[\(lab.host)]:\(lab.port) \(pub[0]) \(pub[1])\n".write(to: wrong, atomically: true, encoding: .utf8)
        let marker = "/tmp/rk-lab-hostkey-\(UUID().uuidString)"
        let result = try await transport(lab, knownHosts: wrong.path, freshConnection: true).run("touch \(marker)", timeout: 20)
        XCTAssertEqual(result.exitCode, 255, result.stderr)
        XCTAssertTrue(result.stderr.contains("HOST IDENTIFICATION HAS CHANGED") || result.stderr.contains("verification failed"),
                      result.stderr)
        let check = try await transport(lab).run("test -e \(marker) && echo present || echo absent", timeout: 15)
        XCTAssertEqual(check.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "absent")
    }

    func testStdinExactBytes() async throws {
        let lab = try lab()
        try requireApplicable("stdin_exact_bytes")
        let size = 1 << 20
        let result = try await transport(lab).run("wc -c", input: String(repeating: "r", count: size), timeout: 30)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), String(size))
    }

    func testSudoPasswordChecked() async throws {
        let lab = try lab()
        try requireApplicable("sudo_password_checked")
        let sudo = transport(lab, user: lab.sudoUser)
        // -k: ignore any cached credential, so the password is really checked each time.
        let wrong = try await sudo.run("sudo -k -S -p '' id -u", input: "not-the-password\n", timeout: 30)
        XCTAssertNotEqual(wrong.exitCode, 0)
        XCTAssertEqual(RebootSession.classifySudoFailure(wrong.stdout + "\n" + wrong.stderr, exitCode: wrong.exitCode), .badPassword,
                       wrong.stderr)
        let right = try await sudo.run("sudo -k -S -p '' id -u", input: lab.sudoPassword + "\n", timeout: 30)
        XCTAssertEqual(right.exitCode, 0, right.stderr)
        XCTAssertEqual(right.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "0")
    }
}
