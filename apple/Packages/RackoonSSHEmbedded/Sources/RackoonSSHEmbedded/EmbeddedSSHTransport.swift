import Foundation
import NIOConcurrencyHelpers
import NIOCore
@preconcurrency import NIOSSH
import RackoonCore

/// SwiftNIO SSH behind Core's `SSHTransport`, for platforms without `/usr/bin/ssh` (iOS). Follows Android's
/// `SshjTransport`: one long-lived authenticated connection serves `run` (a channel per command, like a ControlMaster)
/// and terminal shells; `stream` uses its own connection with a pty, because stopping a stream must send Ctrl-C through
/// the pty (closing alone leaves the remote command running). Host keys are checked against `knownHosts` before any
/// credentials are sent: an unknown key is reported for the user to confirm, a changed one is blocked.
public final class EmbeddedSSHTransport: SSHTransport, TerminalOpening {
    public let endpoint: SSHEndpoint
    private let knownHosts: any KnownHostsStore
    private let connectTimeout: TimeInterval
    private let shared = SharedConnection()

    public init(endpoint: SSHEndpoint, knownHosts: any KnownHostsStore, connectTimeout: TimeInterval = 30) {
        self.endpoint = endpoint
        self.knownHosts = knownHosts
        self.connectTimeout = connectTimeout
    }

    /// Reads a server's host key without signing in. The caller shows its fingerprint and, if the user agrees, passes it
    /// to `KnownHostsStore.trust`.
    public static func scanHostKey(host: String, port: Int = 22, timeout: TimeInterval = 30) async throws -> HostKeyInfo {
        try await SSHConnection.scanHostKey(host: host, port: port, timeout: timeout)
    }

    private func openConnection() async throws -> SSHConnection {
        try await SSHConnection.open(endpoint, knownHosts: knownHosts, timeout: connectTimeout)
    }

    private func connection() async throws -> SSHConnection {
        try await shared.get { [self] in try await openConnection() }
    }

    /// Connects now (host key, sign-in) without running anything. Used by "Test connection" and before polling.
    public func connect() async throws {
        _ = try await connection()
    }

    /// Closes the shared connection (terminals on it end too).
    public func close() async {
        await shared.close()
    }

    // MARK: Commands

    public func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        try await execute(command, input: nil, timeout: timeout)
    }

    public func run(_ command: String, input: String, timeout: TimeInterval) async throws -> CommandResult {
        try await execute(command, input: Data(input.utf8), timeout: timeout)
    }

    private func execute(_ command: String, input: Data?, timeout: TimeInterval) async throws -> CommandResult {
        let (channel, events) = try await openSessionChannel()
        return try await collect(channel, command: command, input: input, events: events, timeout: timeout)
    }

    /// A session channel on the shared connection. If the connection died under us (the network changed, the server
    /// rebooted), nothing was sent yet, so it reconnects once and tries again. A command that already started is never re-run.
    func openSessionChannel() async throws -> (Channel, AsyncStream<SessionEvent>) {
        var retried = false
        while true {
            let connection = try await connection()
            let (events, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
            do {
                let channel = try await connection.openSession { SessionHandler(continuation) }
                return (channel, events)
            } catch {
                await shared.invalidate(connection)
                if retried { throw mapError(error, connecting: false) }
                retried = true
            }
        }
    }

    private func collect(_ channel: Channel, command: String, input: Data?, events: AsyncStream<SessionEvent>,
                         timeout: TimeInterval) async throws -> CommandResult {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CommandResult?.self) { group in
                group.addTask {
                    try await channel.request(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false))
                    if let input {
                        var offset = 0
                        while offset < input.count {
                            let end = min(offset + 32 * 1024, input.count)
                            try await channel.send(input[offset..<end])
                            offset = end
                        }
                    }
                    // Like `ssh -n` when there is no input: the command sees end of input instead of waiting for it.
                    try? await channel.close(mode: .output).get()
                    var stdout = ByteBuffer(), stderr = ByteBuffer()
                    var code: Int32 = -1
                    for await event in events {
                        switch event {
                        case .stdout(var bytes): stdout.writeBuffer(&bytes)
                        case .stderr(var bytes): stderr.writeBuffer(&bytes)
                        case .exit(let status): code = status
                        case .closed: break
                        }
                    }
                    return CommandResult(stdout: String(buffer: stdout), stderr: String(buffer: stderr), exitCode: code)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let result = first else {
                    channel.close(promise: nil)
                    throw EmbeddedSSHError.timeout(timeout)
                }
                return result
            }
        } onCancel: {
            channel.close(promise: nil)
        }
    }

    // MARK: Streams

    public func stream(_ command: String) -> AsyncThrowingStream<String, Error> {
        stream(command, input: nil)
    }

    public func stream(_ command: String, input: AsyncStream<String>) -> AsyncThrowingStream<String, Error> {
        stream(command, input: Optional(input))
    }

    private func stream(_ command: String, input: AsyncStream<String>?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                let connection: SSHConnection
                do {
                    connection = try await openConnection()
                } catch {
                    continuation.finish(throwing: mapError(error, connecting: true))
                    return
                }
                defer { connection.close() }
                let (events, eventSink) = AsyncStream.makeStream(of: SessionEvent.self)
                let channel: Channel
                do {
                    channel = try await connection.openSession { SessionHandler(eventSink) }
                    try await channel.request(SSHChannelRequestEvent.PseudoTerminalRequest(
                        wantReply: false, term: "xterm-256color", terminalCharacterWidth: 80, terminalRowHeight: 24,
                        terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:])))
                    try await channel.request(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false))
                } catch {
                    continuation.finish(throwing: mapError(error, connecting: false))
                    return
                }
                let typist = input.map { input in
                    Task {
                        for await text in input { try? await channel.send(Array(text.utf8)) }
                    }
                }
                defer { typist?.cancel() }

                var chunker = Utf8Chunker()
                var remoteClosed = false
                for await event in events {
                    switch event {
                    case .stdout(let bytes), .stderr(let bytes):
                        let text = chunker.push(Data(bytes.readableBytesView))
                        if !text.isEmpty { continuation.yield(text) }
                    case .exit: break
                    case .closed: remoteClosed = true
                    }
                }
                if remoteClosed {
                    let rest = chunker.finish()
                    if !rest.isEmpty { continuation.yield(rest) }
                    continuation.finish()
                    return
                }
                // Cancelled: stop the remote command the way a terminal does, Ctrl-C through the pty, then give it two
                // seconds to exit before closing. NIO futures, not Task.sleep: this task is already cancelled.
                channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: [0x03]))), promise: nil)
                let grace = channel.eventLoop.scheduleTask(in: .seconds(2)) { channel.close(promise: nil) }
                try? await channel.closeFuture.get()
                grace.cancel()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Terminals

    public func openTerminal(cols: Int, rows: Int, command: String?) async throws -> any TerminalShell {
        try await openShell(cols: cols, rows: rows, command: command)
    }

    /// Opens a terminal of the given size on the shared connection: a login shell, or, with `command`, that command on a
    /// pty (for example `docker exec -it <id> sh`). Take the size from the emulator's measured size.
    public func openShell(cols: Int, rows: Int, command: String? = nil) async throws -> EmbeddedShell {
        let connection = try await connection()
        let (events, eventSink) = AsyncStream.makeStream(of: SessionEvent.self)
        do {
            let channel = try await connection.openSession { SessionHandler(eventSink) }
            try await channel.request(SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: false, term: "xterm-256color", terminalCharacterWidth: cols, terminalRowHeight: rows,
                terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:])))
            if let command {
                try await channel.request(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false))
            } else {
                try await channel.request(SSHChannelRequestEvent.ShellRequest(wantReply: false))
            }
            return EmbeddedShell(channel: channel, events: events)
        } catch {
            await shared.invalidate(connection)
            throw mapError(error, connecting: false)
        }
    }
}

/// A terminal session: a shell on a pty that can be resized.
public final class EmbeddedShell: TerminalShell {
    private let channel: Channel
    private let pump: Task<Int32?, Never>
    private let closedByUser = NIOLockedValueBoxBool()
    /// Everything the remote side prints (stdout and stderr share the pty), as raw bytes for the terminal emulator.
    public let output: AsyncStream<[UInt8]>

    init(channel: Channel, events: AsyncStream<SessionEvent>) {
        self.channel = channel
        let (output, sink) = AsyncStream.makeStream(of: [UInt8].self)
        self.output = output
        pump = Task {
            var code: Int32?
            for await event in events {
                switch event {
                case .stdout(let bytes), .stderr(let bytes): sink.yield(Array(bytes.readableBytesView))
                case .exit(let status): code = status
                case .closed: break
                }
            }
            sink.finish()
            return code
        }
    }

    public func write(_ bytes: [UInt8]) async {
        // A failed write means the session is ending; awaitEnd() reports why.
        try? await channel.send(bytes)
    }

    public func resize(cols: Int, rows: Int) async {
        try? await channel.request(SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0))
    }

    /// Waits until the session is over and says why.
    public func awaitEnd() async -> SessionEnd {
        let code = await pump.value
        if closedByUser.value { return .closedByUser }
        if let code { return .remoteExit(code) }
        return .connectionLost   // the channel closed without a status: treat it as a dropped link
    }

    /// Ends the session now (the user closed it).
    public func close() async {
        closedByUser.set()
        try? await channel.close().get()
    }
}

/// The one connection `run` and terminals share, opened on first use and replaced when it has died.
private actor SharedConnection {
    private var current: Task<SSHConnection, Error>?

    func get(_ open: @escaping @Sendable () async throws -> SSHConnection) async throws -> SSHConnection {
        if let task = current {
            if let connection = try? await task.value, connection.isActive { return connection }
            if current == task { current = nil } else { return try await get(open) }
        }
        let task = Task { try await open() }
        current = task
        do {
            return try await task.value
        } catch {
            if current == task { current = nil }
            throw error
        }
    }

    func invalidate(_ connection: SSHConnection) async {
        if let task = current, let live = try? await task.value, live === connection { current = nil }
        connection.close()
    }

    func close() async {
        if let task = current, let connection = try? await task.value { connection.close() }
        current = nil
    }
}

private final class NIOLockedValueBoxBool: Sendable {
    private let box = NIOLockedValueBox(false)
    var value: Bool { box.withLockedValue { $0 } }
    func set() { box.withLockedValue { $0 = true } }
}
