import Crypto
import Foundation
@preconcurrency import NIOSSH
@testable import RackoonCore
@testable import RackoonSSHEmbedded
import XCTest

/// The checks in spec/integration/checks.json, run with the embedded (SwiftNIO SSH) transport against the integration lab
/// (test/lab; `tools/lab up`, then `eval "$(tools/lab env)"`). Skipped when the lab is not configured. The lab's host key
/// is read from the known_hosts file tools/lab scanned, never trusted on first use, and nothing in ~/.ssh is read.
///
/// Unlike the Mac and Android runners, every check runs regardless of the iOS feature matrix: these checks prove the
/// transport and the shared core it feeds, which already exist, while the iOS screens that use them come in later stages
/// (docs/ios-spikes.md). So every check must have a runner here.
final class LabIntegrationTests: XCTestCase {
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
        let hostKey: HostKeyInfo
    }

    private static func json(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: specDir.appendingPathComponent(name))) as! [String: Any]
    }

    private static var labFacts: [String: Any] { ((try? json("integration/checks.json")) ?? [:])["lab"] as? [String: Any] ?? [:] }

    private static let implemented: Set<String> = [
        "overview_parses", "updates_parse", "docker_parses", "stream_exit_status", "logs_cancel_leaves_nothing",
        "hostkey_mismatch_blocked", "stdin_exact_bytes", "sudo_password_checked",
    ]

    private func lab() throws -> Lab {
        let env = ProcessInfo.processInfo.environment
        guard env["RACKOON_LAB"] == "1", let host = env["RACKOON_LAB_HOST"], let keyPath = env["RACKOON_LAB_KEY"],
              let knownHosts = env["RACKOON_LAB_KNOWN_HOSTS"] else {
            throw XCTSkip("integration lab not configured (tools/lab up, then eval \"$(tools/lab env)\")")
        }
        // known_hosts line: `[127.0.0.1]:2222 ssh-ed25519 AAAA…`
        let line = try String(contentsOfFile: knownHosts, encoding: .utf8).split(separator: "\n").first { !$0.hasPrefix("#") }
        let fields = try XCTUnwrap(line).split(separator: " ", maxSplits: 1)
        let hostKey = try XCTUnwrap(HostKeyInfo(openSSH: String(fields[1])), "unreadable lab known_hosts")
        return Lab(host: host, port: Int(env["RACKOON_LAB_PORT"] ?? "") ?? 2222, user: env["RACKOON_LAB_USER"] ?? "rk",
                   sudoUser: env["RACKOON_LAB_SUDO_USER"] ?? "rkpw", sudoPassword: env["RACKOON_LAB_SUDO_PASSWORD"] ?? "",
                   key: try String(contentsOfFile: keyPath, encoding: .utf8), hostKey: hostKey)
    }

    private func transport(_ lab: Lab, user: String? = nil, hostKey: HostKeyInfo? = nil) -> EmbeddedSSHTransport {
        let known = InMemoryKnownHosts()
        known.trust(host: lab.host, port: lab.port, key: hostKey ?? lab.hostKey)
        return EmbeddedSSHTransport(endpoint: SSHEndpoint(host: lab.host, port: lab.port, user: user ?? lab.user,
                                                          auth: .privateKey(lab.key)),
                                    knownHosts: known, connectTimeout: 20)
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await chunk in stream { text += chunk }
        return text
    }

    func testEveryCheckHasARunner() throws {
        let checks = try Self.json("integration/checks.json")["checks"] as! [[String: Any]]
        for id in checks.map({ $0["id"] as! String }) {
            XCTAssertTrue(Self.implemented.contains(id), "\(id) has no runner for the embedded transport")
        }
    }

    func testOverviewParses() async throws {
        let lab = try lab()
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
        let result = try await transport(lab).run(UpdatesSession.command, timeout: 60)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let snapshot = try UpdatesParser.parse(result.stdout)
        XCTAssertEqual(snapshot.packages.map(\.name).sorted(), Self.labFacts["pending"] as? [String])
        XCTAssertEqual(snapshot.packages.filter(\.isSecurity).map(\.name).sorted(), Self.labFacts["security"] as? [String])
        XCTAssertTrue(snapshot.rebootRequired)
    }

    private func labStack(_ transport: EmbeddedSSHTransport) async throws -> DockerStack {
        let result = try await transport.run(DockerSession.command, timeout: 60)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let snapshot = try DockerParser.parse(result.stdout)
        return try XCTUnwrap(snapshot.stacks.first { $0.name == Self.labFacts["stack"] as? String }, "labstack not found")
    }

    func testDockerParses() async throws {
        let lab = try lab()
        let stack = try await labStack(transport(lab))
        let ticker = try XCTUnwrap(stack.containers.first { $0.service == Self.labFacts["service"] as? String })
        XCTAssertEqual(ticker.state, "running")
        XCTAssertNotNil(ComposeAction.up.command(for: stack))
    }

    func testStreamExitStatus() async throws {
        let lab = try lab()
        let text = try await collect(transport(lab).stream(StreamedCommand.wrap("echo lab-out; exit 3", cols: 80, rows: 24)))
        var parser = StreamOutputParser()
        let shown = parser.push(text)
        let end = parser.finish()
        XCTAssertEqual(end.exitCode, 3, text)
        XCTAssertTrue((shown + end.text).contains("lab-out"))
    }

    func testLogsCancelLeavesNothing() async throws {
        let lab = try lab()
        let transport = transport(lab)
        let stack = try await labStack(transport)
        let ticker = try XCTUnwrap(stack.containers.first)
        let command = try XCTUnwrap(DockerSession.logsCommand(id: ticker.id))
        var seen = ""
        for try await chunk in transport.stream(command) {
            seen += chunk
            if seen.contains("tick") { break }   // leaving the loop cancels the stream: Ctrl-C, then teardown
        }
        XCTAssertTrue(seen.contains("tick"))
        // `[l]` keeps the pattern from matching the shell that runs pgrep itself.
        var left = "?"
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 500_000_000)
            left = try await transport.run("pgrep -f 'docker [l]ogs -f' | wc -l", timeout: 15).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if left == "0" { break }
        }
        XCTAssertEqual(left, "0", "docker logs is still running on the server after cancelling")
    }

    func testHostKeyMismatchBlocked() async throws {
        let lab = try lab()
        // A fresh key that is certainly not the lab's, recorded for the lab's address.
        let wrong = HostKeyInfo(openSSH: String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: .init()).publicKey))!
        let marker = "/tmp/rk-lab-hostkey-\(UUID().uuidString)"
        do {
            _ = try await transport(lab, hostKey: wrong).run("touch \(marker)", timeout: 20)
            XCTFail("a changed host key must block the connection")
        } catch EmbeddedSSHError.hostKeyChanged(let trusted, let presented) {
            XCTAssertEqual(trusted.fingerprint, wrong.fingerprint)
            XCTAssertEqual(presented, lab.hostKey)
        }
        let check = try await transport(lab).run("test -e \(marker) && echo present || echo absent", timeout: 15)
        XCTAssertEqual(check.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "absent")
    }

    func testStdinExactBytes() async throws {
        let lab = try lab()
        let size = 1 << 20
        let result = try await transport(lab).run("wc -c", input: String(repeating: "r", count: size), timeout: 30)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), String(size))
    }

    func testSudoPasswordChecked() async throws {
        let lab = try lab()
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

    // MARK: Transport checks beyond checks.json (terminals, first contact)

    /// An unknown host key is reported with the key to show, and nothing is signed in or run.
    func testUnknownHostKeyIsReportedNotTrusted() async throws {
        let lab = try lab()
        let empty = EmbeddedSSHTransport(endpoint: SSHEndpoint(host: lab.host, port: lab.port, user: lab.user, auth: .privateKey(lab.key)),
                                         knownHosts: InMemoryKnownHosts(), connectTimeout: 20)
        do {
            _ = try await empty.run("true", timeout: 10)
            XCTFail("an unknown host key must not be trusted silently")
        } catch EmbeddedSSHError.hostKeyUnknown(let presented) {
            XCTAssertEqual(presented, lab.hostKey)
        }
        let scanned = try await EmbeddedSSHTransport.scanHostKey(host: lab.host, port: lab.port)
        XCTAssertEqual(scanned, lab.hostKey)
    }

    /// A shell gets a pty of the size asked for, follows a resize, and reports its exit status.
    func testShellSizeResizeAndExit() async throws {
        let lab = try lab()
        let transport = transport(lab)
        let shell = try await transport.openShell(cols: 100, rows: 30)
        var output = Data()
        var iterator = shell.output.makeAsyncIterator()
        func readUntil(_ needle: String) async -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                guard let bytes = await iterator.next() else { return false }
                output.append(contentsOf: bytes)
                if String(decoding: output, as: UTF8.self).contains(needle) { return true }
            }
            return false
        }
        await shell.write(Array("stty size; echo size-done\n".utf8))
        let sized = await readUntil("30 100\r\nsize-done")
        XCTAssertTrue(sized, String(decoding: output, as: UTF8.self))
        await shell.resize(cols: 132, rows: 40)
        await shell.write(Array("stty size; echo resized-done\n".utf8))
        let resized = await readUntil("40 132\r\nresized-done")
        XCTAssertTrue(resized, String(decoding: output, as: UTF8.self))
        await shell.write(Array("exit 7\n".utf8))
        while await iterator.next() != nil {}
        let end = await shell.awaitEnd()
        XCTAssertEqual(end, .remoteExit(7))
    }

    /// A Ctrl-C typed into a shell interrupts the foreground program, as in a terminal.
    func testCtrlCInterruptsAShellProgram() async throws {
        let lab = try lab()
        let shell = try await transport(lab).openShell(cols: 80, rows: 24, command: "sleep 30; echo not-interrupted")
        try await Task.sleep(nanoseconds: 500_000_000)
        await shell.write([0x03])
        var text = ""
        for await bytes in shell.output { text += String(decoding: bytes, as: UTF8.self) }
        XCTAssertFalse(text.contains("not-interrupted"))
        let end = await shell.awaitEnd()
        XCTAssertNotEqual(end, .remoteExit(0))
    }
}
