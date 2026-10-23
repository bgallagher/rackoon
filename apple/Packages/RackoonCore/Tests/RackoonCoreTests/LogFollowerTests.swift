import Foundation
@testable import RackoonCore
import XCTest

/// Streams canned chunks per command (or `fallback`), optionally failing, or staying open until cancelled.
private final class LogStreams: SSHTransport, @unchecked Sendable {
    private let lock = NSLock()
    var byCommand: [String: [String]] = [:]
    var fallback: [String] = []
    var failWith: String?
    var keepOpen = false
    private var _open = 0
    private var _started: [String] = []
    var open: Int { lock.withLock { _open } }
    var started: [String] { lock.withLock { _started } }

    func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult { CommandResult(stdout: "") }

    func stream(_ command: String) -> AsyncThrowingStream<String, Error> {
        let chunks = byCommand[command] ?? fallback
        let failure = failWith, stay = keepOpen
        lock.withLock { _started.append(command); _open += 1 }
        return AsyncThrowingStream { c in
            for chunk in chunks { c.yield(chunk) }
            if let failure { c.finish(throwing: StreamFailure(message: failure)); return }
            if !stay { c.finish() }
            c.onTermination = { [weak self] _ in self?.lock.withLock { self?._open -= 1 } }
        }
    }
}

private struct StreamFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func container(_ id: String, _ service: String) -> DockerContainer {
    DockerContainer(id: id, name: "media-\(service)-1", image: "img", state: "running", health: "none", status: "Up", ports: [],
                    project: "media", service: service)
}

@MainActor
final class LogFollowerTests: XCTestCase {
    private let web = container("aaaaaaaaaaaa", "web")
    private let db = container("bbbbbbbbbbbb", "db")

    func testLinesFromSeveralContainersAreMergedAndTagged() async {
        let t = LogStreams()
        t.byCommand[DockerSession.logsCommand(id: web.id)!] = ["2026-10-12T07:15:02Z INFO a1\r\n", "2026-10-12T07:15:03Z ERROR a2\r\n"]
        t.byCommand[DockerSession.logsCommand(id: db.id)!] = ["level=warn msg=slow\r\n"]
        let f = LogFollower(transport: t, flushDelay: 0.01)
        f.follow([web, db])
        await waitFor("both streams to end") { !f.state.live }
        XCTAssertEqual(f.state.received, 3)
        XCTAssertEqual(Set(f.state.entries.map(\.source)), ["web", "db"])
        XCTAssertEqual(f.state.entries.filter { $0.source == "web" }.map(\.level), [.info, .error])
        XCTAssertEqual(f.state.entries.first { $0.source == "db" }?.level, .warn)
        XCTAssertEqual(f.state.containers.map(\.id), [web.id, db.id])
    }

    func testLinesSplitAcrossChunksAreJoinedAndEndingsNormalised() async {
        let t = LogStreams()
        t.fallback = ["hello wor", "ld\r\nsecond ", "line\r\nthird (no newline yet)"]
        let f = LogFollower(transport: t, flushDelay: 0.01)
        f.follow([web])
        await waitFor { !f.state.live }
        XCTAssertEqual(f.state.entries.map(\.line), ["hello world", "second line"])
    }

    func testTheBufferIsCappedButReceivedKeepsCounting() async {
        let t = LogStreams()
        t.fallback = [(1...50).map { "line \($0)\r\n" }.joined()]
        let f = LogFollower(transport: t, maxEntries: 10, flushDelay: 0.01)
        f.follow([web])
        await waitFor { !f.state.live }
        XCTAssertEqual(f.state.entries.count, 10)
        XCTAssertEqual(f.state.received, 50)
        XCTAssertEqual(f.state.entries.last?.line, "line 50")
    }

    func testFollowingTheSameContainersAgainDoesNothingAndOthersRestart() async {
        let t = LogStreams()
        t.fallback = ["one\r\n"]
        t.keepOpen = true
        let f = LogFollower(transport: t, flushDelay: 0.01)
        f.follow([web])
        await waitFor { f.state.received == 1 }
        f.follow([web])
        await settle(0.05)
        XCTAssertEqual(t.started.count, 1, "an identical running follow is not restarted")
        f.follow([db])
        await waitFor { f.state.entries.first?.source == "db" }
        XCTAssertEqual(f.state.containers.map(\.id), [db.id])
        XCTAssertEqual(Set(f.state.entries.map(\.source)), ["db"])
        f.stop()
    }

    func testStopEndsTheRemoteStreamsAndClearsEverything() async {
        let t = LogStreams()
        t.fallback = ["one\r\n"]
        t.keepOpen = true
        let f = LogFollower(transport: t, flushDelay: 0.01)
        f.follow([web, db])
        await waitFor { t.open == 2 && f.state.received == 2 }
        f.stop()
        XCTAssertEqual(f.state, LogsState())
        // Cancelling the stream is what sends Ctrl-C to the remote `docker logs -f` in a real transport.
        await waitFor("both streams to be cancelled") { t.open == 0 }
    }

    func testAStreamErrorIsReported() async {
        let t = LogStreams()
        t.failWith = "connection dropped"
        let f = LogFollower(transport: t, flushDelay: 0.01)
        f.follow([web])
        await waitFor { !f.state.live }
        XCTAssertEqual(f.state.error, "connection dropped")
    }

    func testContainersWithAnUnsafeIdAreNotFollowed() async {
        let t = LogStreams()
        let f = LogFollower(transport: t, flushDelay: 0.01)
        f.follow([container("not-hex; rm -rf /", "x")])
        await waitFor { !f.state.live }
        XCTAssertTrue(t.started.isEmpty)
        XCTAssertTrue(f.state.entries.isEmpty)
    }
}

final class LogViewTests: XCTestCase {
    private let entries = [
        LogEntry(id: 0, source: "web", line: "2026-10-12T07:15:02Z INFO started"),
        LogEntry(id: 1, source: "web", line: "2026-10-12T07:15:03Z ERROR boom: connection refused"),
        LogEntry(id: 2, source: "db", line: "level=warn msg=\"slow query\""),
        LogEntry(id: 3, source: "db", line: "plain line with the word error in prose"),
    ]

    func testFiltersCombine() {
        XCTAssertEqual(LogView.filtered(entries).count, 4)
        XCTAssertEqual(LogView.filtered(entries, focus: "web").map(\.id), [0, 1])
        XCTAssertEqual(LogView.filtered(entries, level: .error).map(\.id), [1])
        XCTAssertEqual(LogView.filtered(entries, search: "PROSE").map(\.id), [3])
        XCTAssertEqual(LogView.filtered(entries, focus: "db", level: .error), [])
        XCTAssertEqual(LogView.filtered(entries, focus: "db", level: .warn, search: "slow").map(\.id), [2])
    }

    func testProseIsNotALevelButCountsAsInfoSoTheChipsAddUp() {
        let counts = LogView.counts(entries)
        XCTAssertEqual(counts[nil], 4)
        XCTAssertEqual(counts[.error], 1)
        XCTAssertEqual(counts[.warn], 1)
        XCTAssertEqual(counts[.info], 2, "the INFO line and the prose line")
        XCTAssertEqual(counts[nil], [LogLevel.error, .warn, .info, .debug].reduce(0) { $0 + (counts[$1] ?? 0) }, "level chips sum to All")
        XCTAssertEqual(LogView.filtered(entries, level: .info).map(\.id), [0, 3])
        let web = LogView.counts(entries, focus: "web")
        XCTAssertEqual(web[nil], 2)
        XCTAssertNil(web[.warn])
    }

    func testCopyTextTagsTheContainerOnlyWhenSeveralAreMixed() {
        let two = Array(entries.prefix(2))
        XCTAssertEqual(LogView.text(two, showSource: true), "web | \(two[0].line)\nweb | \(two[1].line)")
        XCTAssertEqual(LogView.text(two, showSource: false), "\(two[0].line)\n\(two[1].line)")
    }

    func testARowShowsTimeLevelAndMessageSeparately() {
        XCTAssertEqual(entries[0].parts, LogParts(time: "2026-10-12T07:15:02Z", level: .info, message: "started"))
        XCTAssertEqual(entries[1].parts, LogParts(time: "2026-10-12T07:15:03Z", level: .error, message: "boom: connection refused"))
        XCTAssertEqual(entries[2].parts, LogParts(time: nil, level: .warn, message: "msg=\"slow query\""))
        XCTAssertEqual(entries[3].parts, LogParts(time: nil, level: nil, message: "plain line with the word error in prose"))
        // The level word stays when it is in the middle of the message.
        XCTAssertEqual(LogEntry(id: 9, source: "x", line: "2026-10-12T07:15:03Z job ERROR handler ran").parts.message, "job ERROR handler ran")
    }
}
