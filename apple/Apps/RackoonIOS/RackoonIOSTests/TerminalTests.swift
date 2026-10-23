import Foundation
import RackoonCore
import RackoonSSHEmbedded
@testable import RackoonIOS
import XCTest

/// A shell whose output and ending the test controls.
private final class FakeShell: TerminalShell, @unchecked Sendable {
    let output: AsyncStream<[UInt8]>
    private let sink: AsyncStream<[UInt8]>.Continuation
    private let lock = NSLock()
    private var end: SessionEnd?
    private var waiters: [CheckedContinuation<SessionEnd, Never>] = []
    private(set) var written: [[UInt8]] = []
    private(set) var sizes: [(Int, Int)] = []

    init() { (output, sink) = AsyncStream.makeStream(of: [UInt8].self) }

    func say(_ text: String) { sink.yield(Array(text.utf8)) }

    func finish(_ reason: SessionEnd) {
        let toResume: [CheckedContinuation<SessionEnd, Never>] = lock.withLock {
            end = reason
            defer { waiters = [] }
            return waiters
        }
        sink.finish()
        for w in toResume { w.resume(returning: reason) }
    }

    func write(_ bytes: [UInt8]) async { lock.withLock { written.append(bytes) } }
    func resize(cols: Int, rows: Int) async { lock.withLock { sizes.append((cols, rows)) } }

    func awaitEnd() async -> SessionEnd {
        await withCheckedContinuation { c in
            let done: SessionEnd? = lock.withLock {
                if let end { return end }
                waiters.append(c)
                return nil
            }
            if let done { c.resume(returning: done) }
        }
    }

    func close() async { finish(.closedByUser) }
}

/// Hands out shells in order and records the sizes it was asked for.
private final class FakeOpener: TerminalOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<FakeShell, Error>]
    private(set) var opened: [(cols: Int, rows: Int)] = []

    init(_ queue: [Result<FakeShell, Error>]) { self.queue = queue }

    var count: Int { lock.withLock { opened.count } }

    func openTerminal(cols: Int, rows: Int, command: String?) async throws -> any TerminalShell {
        let next: Result<FakeShell, Error> = lock.withLock {
            opened.append((cols, rows))
            return queue.isEmpty ? .success(FakeShell()) : queue.removeFirst()
        }
        return try next.get()
    }
}

@MainActor
private final class Recorder: TerminalDisplay {
    var bytes: [UInt8] = []
    var text: String { String(decoding: bytes, as: UTF8.self) }
    func feed(_ chunk: ArraySlice<UInt8>) { bytes += chunk }
}

/// Records the backoff the tab asked to wait, without waiting.
private final class Waits: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var delays: [TimeInterval] = []
    func sleep(_ seconds: TimeInterval) async throws { lock.withLock { delays.append(seconds) } }
}

@MainActor
final class TerminalTabTests: XCTestCase {
    private func tab(_ opener: FakeOpener, highlight: Bool = true, waits: Waits = Waits()) -> (TerminalTab, Recorder) {
        let tab = TerminalTab(serverID: "s1", title: "Shell", opener: opener, highlight: highlight, sleep: waits.sleep)
        let recorder = Recorder()
        tab.display = recorder
        return (tab, recorder)
    }

    func testThePtyOpensAtTheViewsFirstSizeAndFollowsLaterOnes() async throws {
        let shell = FakeShell()
        let opener = FakeOpener([.success(shell)])
        let (tab, _) = tab(opener)
        XCTAssertEqual(tab.phase, .waitingForSize)
        XCTAssertEqual(opener.count, 0, "nothing opens before the emulator knows its size")
        tab.setSize(cols: 53, rows: 48)
        try await waitUntil { tab.phase == .live }
        XCTAssertEqual(opener.opened.first?.cols, 53)
        XCTAssertEqual(opener.opened.first?.rows, 48)
        tab.setSize(cols: 53, rows: 22)
        tab.setSize(cols: 53, rows: 20)
        try await waitUntil { !shell.sizes.isEmpty }
        XCTAssertEqual(shell.sizes.map(\.1), [20], "resizes are debounced to the last one")
        tab.send(Array("ls\r".utf8))
        try await waitUntil { shell.written.count == 1 }
        tab.close()
    }

    func testKeystrokesReachTheShellInTheOrderTyped() async throws {
        let shell = FakeShell()
        let (tab, _) = tab(FakeOpener([.success(shell)]))
        tab.setSize(cols: 80, rows: 24)
        try await waitUntil { tab.phase == .live }
        let typed = Array("docker ps --format '{{.Names}}' && uptime\r".utf8)
        for byte in typed { tab.send([byte]) }
        try await waitUntil { shell.written.count == typed.count }
        XCTAssertEqual(shell.written.flatMap { $0 }, typed)
        tab.close()
    }

    func testOutputIsHighlightedInProcessAndTheSwitchTurnsItOff() async throws {
        let shell = FakeShell()
        let (tab, screen) = tab(FakeOpener([.success(shell)]))
        tab.setSize(cols: 80, rows: 24)
        try await waitUntil { tab.phase == .live }
        shell.say("ping 10.0.0.5 failed\r\nok\r\n")
        try await waitUntil { screen.text.contains("ok") }
        XCTAssertTrue(screen.text.contains("\u{1B}[35m10.0.0.5\u{1B}[39m"), screen.text.debugDescription)
        tab.setHighlight(false)
        shell.say("ping 10.0.0.6 failed\r\ndone\r\n")
        try await waitUntil { screen.text.contains("done") }
        XCTAssertTrue(screen.text.contains("ping 10.0.0.6 failed"), "plain while off")
        tab.close()
    }

    func testADroppedConnectionIsRetriedWithBackoffButAnExitIsFinal() async throws {
        let first = FakeShell(), second = FakeShell()
        let opener = FakeOpener([.success(first), .success(second)])
        let waits = Waits()
        let (tab, screen) = tab(opener, waits: waits)
        tab.setSize(cols: 80, rows: 24)
        try await waitUntil { tab.phase == .live }
        first.say("before the drop\r\n")
        first.finish(.connectionLost)
        try await waitUntil { opener.count == 2 && tab.phase == .live }
        XCTAssertEqual(waits.delays, [1])
        XCTAssertTrue(screen.text.contains("before the drop"), "scrollback is kept")
        XCTAssertTrue(screen.text.contains("Reconnecting in 1 s (attempt 1 of 5)"))
        second.finish(.remoteExit(0))
        try await waitUntil { tab.phase == .ended("Session ended.") }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(opener.count, 2, "an exit is never retried")
    }

    func testRetriesRunOutAndASignInFailureIsNotRetried() async throws {
        let unreachable = EmbeddedSSHError.unreachable("timed out")
        let opener = FakeOpener(Array(repeating: .failure(unreachable), count: 6))
        let waits = Waits()
        let (tab, _) = tab(opener, waits: waits)
        tab.setSize(cols: 80, rows: 24)
        try await waitUntil { tab.phase == .ended("Connection lost. Reconnect to try again.") }
        XCTAssertEqual(waits.delays, [1, 2, 4, 8, 15])
        XCTAssertEqual(opener.count, 6)

        let refused = FakeOpener([.failure(EmbeddedSSHError.authFailed("no"))])
        let (tab2, _) = self.tab(refused, waits: Waits())
        tab2.setSize(cols: 80, rows: 24)
        try await waitUntil { if case .ended = tab2.phase { true } else { false } }
        XCTAssertEqual(refused.count, 1, "a refused sign-in needs the user, not a retry")
    }

    func testReconnectNowStartsAgainWithAFreshBudget() async throws {
        let opener = FakeOpener([.failure(EmbeddedSSHError.authFailed("no")), .success(FakeShell())])
        let (tab, _) = tab(opener)
        tab.setSize(cols: 80, rows: 24)
        try await waitUntil { if case .ended = tab.phase { true } else { false } }
        tab.reconnectNow()
        try await waitUntil { tab.phase == .live }
        tab.close()
    }
}

@MainActor
final class TerminalStoreTests: XCTestCase {
    func testTabsArePerServerOutliveScreensAndCloseWithTheirServer() async throws {
        let sandbox = Sandbox()
        let app = sandbox.app(demo: true)
        let homelab = app.servers.servers[0], nuc = app.servers.servers[1]
        XCTAssertNil(app.openTerminal(on: homelab))
        XCTAssertNil(app.openTerminal(on: homelab))
        XCTAssertNil(app.openTerminal(on: nuc))
        XCTAssertEqual(app.terminals.tabs(for: homelab.id).map(\.title), ["Shell", "Shell 2"])
        XCTAssertEqual(app.terminals.selectedTab(for: homelab.id)?.title, "Shell 2")
        XCTAssertEqual(app.terminals.count, 3)
        app.remove(id: homelab.id)
        XCTAssertTrue(app.terminals.tabs(for: homelab.id).isEmpty)
        XCTAssertEqual(app.terminals.count, 1)
    }

    func testReadOnlyKeepsTerminalsClosed() {
        let sandbox = Sandbox()
        let app = sandbox.app(demo: true)
        app.safety.setReadOnly(true)
        XCTAssertNotNil(app.openTerminal(on: app.servers.servers[0]))
        XCTAssertEqual(app.terminals.count, 0)
    }

    func testAnUntrustedServerGetsNoTerminal() {
        let sandbox = Sandbox()
        let app = sandbox.app()
        var d = ServersModel.Draft()
        d.host = "box"
        app.servers.add(d)
        XCTAssertEqual(app.openTerminal(on: app.servers.servers[0]), "Trust the server's host key on its Overview first.")
    }

    func testTheDemoTerminalAnswers() async throws {
        let sandbox = Sandbox()
        let app = sandbox.app(demo: true)
        let homelab = app.servers.servers[0]
        app.openTerminal(on: homelab)
        let tab = try XCTUnwrap(app.terminals.selectedTab(for: homelab.id))
        let screen = Recorder()
        tab.display = screen
        tab.setSize(cols: 80, rows: 24)
        try await waitUntil { screen.text.contains("root@homelab:~# ") }
        tab.send(Array("whoami\r".utf8))
        try await waitUntil { screen.text.contains("root\r\n") }
        XCTAssertTrue(screen.text.contains("Welcome to Ubuntu"))
    }
}
