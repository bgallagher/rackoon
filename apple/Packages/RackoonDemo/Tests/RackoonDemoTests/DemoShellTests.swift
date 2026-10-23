import Foundation
import RackoonCore
@testable import RackoonDemo
import XCTest

/// The demo terminal answers from one table on both apps: in-process on iOS, as a generated bash script on the Mac.
final class DemoShellTests: XCTestCase {
    private func read(_ shell: DemoShellSession, until needle: String, into text: inout String,
                      _ iterator: inout AsyncStream<[UInt8]>.Iterator) async {
        while !text.contains(needle), let bytes = await iterator.next() { text += String(decoding: bytes, as: UTF8.self) }
    }

    func testTheInAppShellShowsTheBannerAndAnswersTypedLines() async {
        let shell = DemoShellSession(host: "homelab")
        var it = shell.output.makeAsyncIterator()
        var text = ""
        await read(shell, until: "root@homelab:~# ", into: &text, &it)
        XCTAssertTrue(text.contains("Welcome to Ubuntu"))
        await shell.write(Array("whoamx".utf8) + [0x7F] + Array("i\r".utf8))
        await read(shell, until: "root\r\n", into: &text, &it)
        await shell.write(Array("df -h\r".utf8))
        await read(shell, until: "/boot/efi", into: &text, &it)
        await shell.write(Array("rm -rf /\r".utf8))
        await read(shell, until: "only a few commands are simulated", into: &text, &it)
        XCTAssertTrue(text.contains("\r\n"), "a terminal gets CR LF")
        await shell.write(Array("exit\r".utf8))
        while await it.next() != nil {}
        let end = await shell.awaitEnd()
        XCTAssertEqual(end, .remoteExit(0))
    }

    func testClosingIsClosedByUser() async {
        let shell = DemoShellSession(host: "garage-nuc")
        await shell.close()
        let end = await shell.awaitEnd()
        XCTAssertEqual(end, .closedByUser)
    }

    func testEveryRuleAnswers() {
        XCTAssertEqual(DemoShell.reply(to: "whoami"), .text("root"))
        XCTAssertEqual(DemoShell.reply(to: "docker ps -a").self, DemoShell.reply(to: "docker ps"))
        XCTAssertEqual(DemoShell.reply(to: "logout"), .logout)
        XCTAssertEqual(DemoShell.reply(to: ""), .nothing)
        guard case .text(let other) = DemoShell.reply(to: "sudo reboot") else { return XCTFail("unknown commands get a note") }
        XCTAssertTrue(other.hasPrefix("sudo reboot:"))
    }

    #if os(macOS)
    /// The Mac's generated script gives the same answers as the table (iOS has no shell to run it in).
    func testTheGeneratedBashScriptAnswersLikeTheTable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("demo-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("demo-shell.sh")
        try DemoShell.bashScript.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, "homelab"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        input.fileHandleForWriting.write(Data("hostname\nwhoami\ndf -h\nmystery\nexit\n".utf8))
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertTrue(text.contains("Welcome to Ubuntu"))
        XCTAssertTrue(text.contains("homelab\nroot\n"), text)
        if case .text(let df) = DemoShell.reply(to: "df -h") { XCTAssertTrue(text.contains(df)) }
        XCTAssertTrue(text.contains("mystery: demo shell, so only a few commands are simulated"))
        XCTAssertTrue(text.hasSuffix("logout\n"))
    }
    #endif
}
