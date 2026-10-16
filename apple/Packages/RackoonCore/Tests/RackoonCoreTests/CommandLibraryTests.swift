import Foundation
import XCTest
@testable import RackoonCore

final class CommandLibraryTests: XCTestCase {
    /// The library as JSON: what spec/command-library.json holds. Optional fields are omitted when empty.
    private func exported() -> [String: Any] {
        let commands: [[String: Any]] = CommandLibrary.all.map { c in
            var d: [String: Any] = ["id": c.id, "title": c.title, "group": c.group, "summary": c.summary, "script": c.script,
                                    "risk": c.risk == .read ? "read" : "mutate"]
            if c.root { d["root"] = true }
            if c.interactive { d["interactive"] = true }
            if let n = c.needs { d["needs"] = n }
            if let p = c.preview { d["preview"] = p }
            if let w = c.warning { d["warning"] = w }
            if !c.params.isEmpty {
                d["params"] = c.params.map { ["id": $0.id, "label": $0.label, "kind": $0.kind.rawValue, "placeholder": $0.placeholder] }
            }
            return d
        }
        return ["groups": CommandLibrary.groups, "commands": commands]
    }

    /// The Swift entries must equal spec/command-library.json (shared with the Kotlin core).
    /// Run with RACKOON_WRITE_GOLDEN=1 to rewrite the file from the Swift entries, then review the diff.
    func testSpecFileMatchesTheSwiftEntries() throws {
        let url = specDir.appendingPathComponent("command-library.json")
        if ProcessInfo.processInfo.environment["RACKOON_WRITE_GOLDEN"] != nil {
            let data = try JSONSerialization.data(withJSONObject: exported(), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try (String(decoding: data, as: UTF8.self) + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary
        XCTAssertEqual(onDisk, exported() as NSDictionary)
    }

    func testEntriesAreWellFormed() {
        let all = CommandLibrary.all
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "ids are unique")
        for c in all {
            XCTAssertTrue(CommandLibrary.groups.contains(c.group), c.id)
            XCTAssertFalse(c.title.isEmpty || c.summary.isEmpty || c.script.isEmpty, c.id)
            // Every {placeholder} has a parameter and every parameter is used.
            let used = Set(c.script.matches(of: /\{([a-z]+)\}/).map { String($0.1) }).subtracting(["Names", "Status", "Image"])
            XCTAssertEqual(used, Set(c.params.map(\.id)), c.id)
            if c.root { XCTAssertTrue(c.script.contains("$S"), "\(c.id) is marked root but never uses $S") }
            if c.isMutating {
                XCTAssertEqual(c.group, "Maintenance", c.id)
                XCTAssertNotNil(c.preview, "\(c.id) needs a dry-run preview")
                XCTAssertFalse(c.interactive, c.id)
            } else {
                XCTAssertNil(c.preview, "\(c.id): read entries have nothing to preview")
                XCTAssertNil(c.warning, c.id)
            }
        }
        XCTAssertFalse(CommandLibrary.commands(in: "Maintenance").contains { !$0.isMutating }, "Maintenance is only for changes")
        for group in CommandLibrary.groups { XCTAssertFalse(CommandLibrary.commands(in: group).isEmpty, group) }
    }

    func testRootNeedsAndParameterGuards() throws {
        let ports = try XCTUnwrap(CommandLibrary.all.first { $0.id == "listening_ports" })
        let path = #"PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"; export PATH; "#
        XCTAssertEqual(ports.fullScript(), path + #"if [ "$(id -u)" -eq 0 ]; then S=; else S='sudo -n'; fi; $S ss -tulpn"#)
        let docker = try XCTUnwrap(CommandLibrary.all.first { $0.id == "docker_disk" })
        XCTAssertEqual(docker.fullScript(), path + "command -v docker >/dev/null 2>&1 || { echo 'docker is not installed on this server.'; exit 0; }; docker system df")

        let logs = try XCTUnwrap(CommandLibrary.all.first { $0.id == "container_logs" })
        XCTAssertTrue(try XCTUnwrap(logs.fullScript(params: ["container": "my-app_1"])).hasSuffix("docker logs --tail 200 'my-app_1' 2>&1"))
        for bad in ["", "a b", "x; reboot", "$(id)", "-rf", "a/b", "web\nlogs"] {
            XCTAssertNil(logs.fullScript(params: ["container": bad]), bad.debugDescription)
        }
        XCTAssertNil(logs.fullScript(), "a missing parameter is refused")
        let cert = try XCTUnwrap(CommandLibrary.all.first { $0.id == "cert_expiry" })
        XCTAssertNotNil(cert.fullScript(params: ["host": "app.example.com"]))
        for bad in ["", "-x.com", "a..b", "a b.com", "x.com;ls", "x.com/path", ".x.com", "x.com."] { XCTAssertNil(cert.fullScript(params: ["host": bad]), bad) }
    }

    func testReadableScriptHidesGuardsAndShowsSudoAndParameters() throws {
        let ports = try XCTUnwrap(CommandLibrary.all.first { $0.id == "listening_ports" })
        XCTAssertEqual(ports.readableScript(), "sudo ss -tulpn")
        let docker = try XCTUnwrap(CommandLibrary.all.first { $0.id == "docker_disk" })
        XCTAssertEqual(docker.readableScript(), "docker system df")
        let logs = try XCTUnwrap(CommandLibrary.all.first { $0.id == "container_logs" })
        XCTAssertEqual(logs.readableScript(), "docker logs --tail 200 <container> 2>&1")
        XCTAssertEqual(logs.readableScript(params: ["container": "x; reboot"]), "docker logs --tail 200 <container> 2>&1",
                       "an invalid value is never shown as if it would run")
        XCTAssertEqual(logs.readableScript(params: ["container": "web"]), "docker logs --tail 200 'web' 2>&1")
        // Everything in the library reads without the guards, and no `$S` is left for a reader to decode.
        for c in CommandLibrary.all {
            XCTAssertFalse(c.readableScript().contains("PATH="), c.id)
            XCTAssertFalse(c.readableScript().contains("$S"), c.id)
        }
    }

    /// A program that lives only in /usr/sbin (as ufw, swapon and fail2ban-client do on Debian) is found even when the ssh
    /// user's PATH has no sbin directory. `chown` is in /usr/sbin on a Mac, so a stripped PATH exercises exactly that.
    func testProgramsInSbinAreFoundWithAMinimalPath() throws {
        try requireShell()
        func run(needs: String) throws -> String {
            let c = LibraryCommand(id: "x", title: "x", group: "Disk", summary: "x", script: "echo RAN", needs: needs)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", try XCTUnwrap(c.fullScript())]
            p.environment = ["PATH": "/nonexistent"]
            let pipe = Pipe()
            p.standardOutput = pipe
            try p.run(); p.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: "/usr/sbin/chown"), "test assumes macOS keeps chown in /usr/sbin")
        XCTAssertEqual(try run(needs: "chown"), "RAN\n")
        XCTAssertEqual(try run(needs: "rackoon-no-such-program"), "rackoon-no-such-program is not installed on this server.\n")
    }

    /// Runs the guard prefix under a real /bin/sh: a missing program prints a sentence and exits 0 instead of failing.
    func testMissingProgramGuardUnderARealShell() throws {
        let c = LibraryCommand(id: "x", title: "x", group: "Disk", summary: "x", script: "echo SHOULD-NOT-RUN", needs: "rackoon-no-such-program")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", try XCTUnwrap(c.fullScript())]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertEqual(out, "rackoon-no-such-program is not installed on this server.\n")
    }

    // MARK: the session

    func testReadRunsWithoutConfirmationAndMutationsNeedOne() async throws {
        let policy = ActionPolicy()
        let transport = FakeTransport([])
        let session = CommandLibrarySession(transport: transport, policy: policy)
        let read = try XCTUnwrap(session.intent(for: try XCTUnwrap(CommandLibrary.all.first { $0.id == "load" })))
        XCTAssertEqual(read.risk, .read)
        let ran = await session.run(read, confirmation: nil, cols: 80, rows: 24, onEvent: { _ in })
        XCTAssertNotNil(ran, "a read runs straight away")
        XCTAssertEqual(transport.streamedCommands.count, 1)

        let prune = try XCTUnwrap(CommandLibrary.all.first { $0.id == "docker_prune" })
        let intent = try XCTUnwrap(session.intent(for: prune, preview: "Stopped container: old"))
        XCTAssertEqual(intent.risk, .mutate)
        let refused = await session.run(intent, confirmation: nil, cols: 80, rows: 24, onEvent: { _ in })
        XCTAssertNil(refused, "a change without a confirmation does not run")
        XCTAssertEqual(transport.streamedCommands.count, 1)
        // The confirmation is for the exact intent, preview included.
        let other = try XCTUnwrap(session.intent(for: prune, preview: "something else"))
        let wrong = await session.run(intent, confirmation: try session.confirm(other), cols: 80, rows: 24, onEvent: { _ in })
        XCTAssertNil(wrong)
        let right = await session.run(intent, confirmation: try session.confirm(intent), cols: 80, rows: 24, onEvent: { _ in })
        XCTAssertNotNil(right)
        XCTAssertEqual(transport.streamedCommands.count, 2)
    }

    func testReadOnlyModeBlocksMutationsButNotReads() async throws {
        let policy = ActionPolicy(readOnly: true)
        let session = CommandLibrarySession(transport: FakeTransport([]), policy: policy)
        let prune = try XCTUnwrap(session.intent(for: try XCTUnwrap(CommandLibrary.all.first { $0.id == "docker_prune" })))
        XCTAssertThrowsError(try session.confirm(prune))
        let read = try XCTUnwrap(session.intent(for: try XCTUnwrap(CommandLibrary.all.first { $0.id == "memory" })))
        let ran = await session.run(read, confirmation: nil, cols: 80, rows: 24, onEvent: { _ in })
        XCTAssertNotNil(ran, "reading is always allowed")
    }

    func testCustomCommandsAlwaysNeedConfirmation() throws {
        let session = CommandLibrarySession(transport: FakeTransport([]), policy: ActionPolicy())
        let intent = try XCTUnwrap(session.customIntent("  uname -a \n"))
        XCTAssertEqual(intent.command, "uname -a")
        XCTAssertEqual(intent.risk, .mutate)
        for bad in ["", "   ", String(repeating: "x", count: 4001), "a\0b"] { XCTAssertNil(session.customIntent(bad)) }
    }

    func testPreviewRunsTheDryRunAsARead() async throws {
        let transport = FakeTransport([.success(CommandResult(stdout: "Stopped container: old\n", stderr: "", exitCode: 0))])
        let session = CommandLibrarySession(transport: transport, policy: ActionPolicy())
        let prune = try XCTUnwrap(CommandLibrary.all.first { $0.id == "docker_prune" })
        let text = await session.preview(for: prune)
        XCTAssertEqual(text, "Stopped container: old")
        XCTAssertTrue(transport.commands.first?.contains("docker images -f dangling=true") ?? false)
        for what in ["Stopped container", "Unused network", "Dangling image", "docker system df"] {
            XCTAssertTrue(transport.commands.first?.contains(what) ?? false, "the prune preview lists: \(what)")
        }
        XCTAssertFalse(transport.commands.first?.contains("prune") ?? true, "the preview never contains the real command")
    }
}
