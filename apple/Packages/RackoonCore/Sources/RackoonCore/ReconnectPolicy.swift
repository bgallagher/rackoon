import Foundation

/// Why a terminal session ended. Only a lost connection is ever retried: the user closing it or the remote shell
/// exiting is final. Mirrors Android's `SessionEnd`.
public enum SessionEnd: Sendable, Equatable {
    /// The connection failed or dropped (it could not start, or the link went away).
    case connectionLost
    /// The remote command or shell ended on its own, with this status.
    case remoteExit(Int32)
    /// The user closed it.
    case closedByUser
}

public enum ReconnectDecision: Sendable, Equatable {
    /// Try again after `delay` seconds; this is attempt `attempt` of `of`.
    case retry(delay: TimeInterval, attempt: Int, of: Int)
    case giveUp
}

/// The terminal's auto-reconnect rule, the same as the Mac app's and Android's `ReconnectPolicy`: retry only when the
/// connection was lost, up to 5 times with 1/2/4/8/15 s of backoff, and a session that lasted 10 s or more earns a fresh
/// budget (so a long-lived session that drops once is not penalised by earlier flapping). Pure and deterministic.
public struct ReconnectPolicy: Sendable {
    private let delays: [TimeInterval]
    private let freshBudgetAfter: TimeInterval
    private var used = 0

    public init(delays: [TimeInterval] = [1, 2, 4, 8, 15], freshBudgetAfter: TimeInterval = 10) {
        self.delays = delays
        self.freshBudgetAfter = freshBudgetAfter
    }

    public var maxAttempts: Int { delays.count }

    /// Called when a session (or a reconnect attempt) ends, with how long it had been connected.
    public mutating func onEnded(_ end: SessionEnd, connectedFor: TimeInterval) -> ReconnectDecision {
        guard end == .connectionLost else { return .giveUp }
        if connectedFor >= freshBudgetAfter { used = 0 }
        guard used < maxAttempts else { return .giveUp }
        let delay = delays[used]
        used += 1
        return .retry(delay: delay, attempt: used, of: maxAttempts)
    }

    /// The user pressed Reconnect now, or a new session started on purpose: forget earlier failures.
    public mutating func reset() { used = 0 }
}

/// A terminal session on a server: a shell, or one command, on a pty that can be resized. Implemented by the embedded
/// SSH client (iOS) and the demo's fake shell; the Mac's terminal tabs run ssh in SwiftTerm's own process view instead.
public protocol TerminalShell: AnyObject, Sendable {
    /// Everything the remote side prints (stdout and stderr share the pty), as raw bytes for the terminal emulator.
    /// Read it once.
    var output: AsyncStream<[UInt8]> { get }
    func write(_ bytes: [UInt8]) async
    func resize(cols: Int, rows: Int) async
    /// Waits until the session is over and says why (only `.connectionLost` is ever retried).
    func awaitEnd() async -> SessionEnd
    /// Ends the session now (the user closed it).
    func close() async
}

/// Opens terminals on one server. Take `cols`/`rows` from the emulator's measured size.
public protocol TerminalOpening: Sendable {
    func openTerminal(cols: Int, rows: Int, command: String?) async throws -> any TerminalShell
}
