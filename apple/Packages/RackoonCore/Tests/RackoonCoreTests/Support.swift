import Foundation
@testable import RackoonCore

/// Repo root, found from this file's location (<root>/apple/Packages/RackoonCore/Tests/RackoonCoreTests/).
let repoRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { url.deleteLastPathComponent() }
    return url
}()

var specDir: URL { repoRoot.appendingPathComponent("spec") }

/// Replays canned output; records what it was asked to run.
final class FakeTransport: SSHTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<CommandResult, Error>]
    private(set) var commands: [String] = []
    /// What was written to a command's standard input (`run(_:input:timeout:)`), in order.
    private(set) var inputs: [String] = []
    /// What `stream` yields, chunk by chunk, before finishing; and what it was asked to run.
    var streamChunks: [String] = []
    private(set) var streamedCommands: [String] = []

    init(_ responses: [Result<CommandResult, Error>]) { queue = responses }

    func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        try next(command).get()
    }

    func run(_ command: String, input: String, timeout: TimeInterval) async throws -> CommandResult {
        lock.withLock { inputs.append(input) }
        return try next(command).get()
    }

    private func next(_ command: String) -> Result<CommandResult, Error> {
        lock.lock(); defer { lock.unlock() }
        commands.append(command)
        guard !queue.isEmpty else { return .success(CommandResult(stdout: "", exitCode: 1)) }
        return queue.count > 1 ? queue.removeFirst() : queue[0]
    }

    private var typist: Task<[String], Never>?

    /// Yields `streamChunks` like `stream`, and collects what was typed (read it with `typedIntoStream()`).
    func stream(_ command: String, input: AsyncStream<String>) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        streamedCommands.append(command)
        let chunks = streamChunks
        typist = Task { var got: [String] = []; for await s in input { got.append(s) }; return got }
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    /// Everything typed into the last `stream(_:input:)`, once the runner has closed its input.
    func typedIntoStream() async -> [String] { await (lock.withLock { typist })?.value ?? [] }

    func stream(_ command: String) -> AsyncThrowingStream<String, Error> {
        lock.lock(); streamedCommands.append(command); let chunks = streamChunks; lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

#if os(iOS)
import XCTest

/// For a test that checks a command in a real shell: on iOS (no shell) it is skipped, elsewhere it runs.
func requireShell() throws {
    throw XCTSkip("needs a real shell, which iOS does not have")
}

/// iOS has no `Process` and no `/bin/sh`. The tests that prove a command by running it in a real shell (quoting, guards,
/// tar) use this stand-in there: it compiles, and `run()` skips the test, so iOS reports them as skipped, never as passed.
/// They still run on macOS and Linux, where the shell exists. Everything else in RackoonCoreTests runs on iOS as is.
final class Process {
    var executableURL: URL?
    var arguments: [String]?
    var environment: [String: String]?
    var currentDirectoryURL: URL?
    var standardInput: Any?
    var standardOutput: Any?
    var standardError: Any?
    private(set) var terminationStatus: Int32 = -1

    func run() throws {
        throw XCTSkip("needs a real shell (\(executableURL?.path ?? "a program")), which iOS does not have")
    }

    func waitUntilExit() {}
}
#else
func requireShell() throws {}
#endif
