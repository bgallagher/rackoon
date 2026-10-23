import Foundation
@testable import RackoonCore
import XCTest

/// A tiny fake server for the stack editor and the Add container page: answers file reads, checks and saves from memory,
/// image lookups, listening ports, scratch checks and creates, and counts what it was asked.
final class FakeStackServer: SSHTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _composeText: String
    private var _envText: String?
    var composeText: String { get { lock.withLock { _composeText } } set { lock.withLock { _composeText = newValue } } }
    var envText: String? { get { lock.withLock { _envText } } set { lock.withLock { _envText = newValue } } }
    var imageFound = true
    var listening = "LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*\nLISTEN 0 4096 0.0.0.0:8080 0.0.0.0:*\n"
    var rejectWith: String?
    var warnWith: String?
    var exists = false
    var changeUnderneath = false
    var tooLarge = false
    private var _checks = 0
    private var _created: [String] = []
    var checks: Int { lock.withLock { _checks } }
    var created: [String] { lock.withLock { _created } }

    init(compose: String = "services:\n  web:\n    image: nginx\n") { _composeText = compose }

    /// Any 64-character lowercase hex string works as a hash here; it only has to change with the text.
    static func sha(_ text: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(repeating: String(format: "%016llx", h), count: 4)
    }

    private func content(_ command: String) -> String {
        guard let r = command.range(of: #"echo '([A-Za-z0-9+/=]*)' \| base64 -d"#, options: .regularExpression) else { return "" }
        let match = String(command[r])
        let b64 = match.dropFirst("echo '".count).prefix { $0 != "'" }
        return Data(base64Encoded: String(b64)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        if command.hasPrefix("timeout 20 docker manifest inspect") { return CommandResult(stdout: imageFound ? "found\n" : "notfound\n") }
        if command == ContainerChecks.listeningPortsCommand { return CommandResult(stdout: listening) }
        if command.hasPrefix("T=$(mktemp -d)") {
            lock.withLock { _checks += 1 }
            if let rejectWith { return CommandResult(stdout: rejectWith + "\n", exitCode: 1) }
            return CommandResult(stdout: warnWith.map { $0 + "\n" } ?? "")
        }
        if command.hasPrefix("D="), command.contains("##created") {
            if exists { return CommandResult(stdout: "##exists\n", exitCode: 3) }
            lock.withLock { _created.append(command) }
            return CommandResult(stdout: "##created\n")
        }
        if command.hasPrefix("F='"), command.contains("echo '##meta'") {
            if tooLarge { return CommandResult(stdout: "##toolarge\n") }
            guard let text = command.contains(".env'") ? envText : composeText else { return CommandResult(stdout: "##missing\n") }
            return CommandResult(stdout: "##meta\n1700000000 644 root:root\n##sha256\n\(Self.sha(text))\n##content\n\(Data(text.utf8).base64EncodedString())\n")
        }
        if command.contains(".rackoon-check.") {
            lock.withLock { _checks += 1 }
            if let rejectWith { return CommandResult(stdout: rejectWith + "\n", exitCode: 1) }
            return CommandResult(stdout: "")
        }
        if command.contains("echo '##saved'") {
            if changeUnderneath { return CommandResult(stdout: "##changed\n", exitCode: 3) }
            let text = content(command)
            if command.contains("/.env'") { envText = text } else { composeText = text }
            return CommandResult(stdout: "##saved\n\(Self.sha(text))\n")
        }
        return CommandResult(stdout: "")
    }

    func stream(_ command: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
}

/// Waits (up to two seconds) for something async to come true.
@MainActor
func waitFor(_ what: String = "condition", _ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<400 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("timed out waiting for \(what)", file: file, line: line)
}

/// Lets queued tasks run for a moment, for asserting that something did NOT happen.
func settle(_ seconds: TimeInterval = 0.1) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
}
