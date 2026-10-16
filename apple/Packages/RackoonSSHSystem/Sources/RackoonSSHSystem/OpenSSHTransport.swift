import Foundation
import RackoonCore
import Subprocess

public enum OpenSSHError: Error, LocalizedError {
    case timedOut(TimeInterval)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let s): "Timed out after \(Int(s))s"
        case .launchFailed(let m): "Could not launch ssh: \(m)"
        }
    }
}

/// Wraps /usr/bin/ssh so ~/.ssh/config, ssh-agent and existing keys just work.
/// Commands share one multiplexed connection (ControlMaster) so polling is cheap.
public struct OpenSSHTransport: SSHTransport {
    public let host: String
    private let port: Int?
    private let identityFile: String?
    private let controlDir: String
    /// `-o` options put in front of every other option (ssh keeps the first value it sees, so these win). Empty in the app;
    /// the integration lab's tests use it to point ssh at the lab's own known_hosts instead of ~/.ssh.
    private let leadingOptions: [String]

    public init(server: Server) {
        self.init(destination: server.sshDestination, port: server.port, identityFile: server.identityFile)
    }

    public init(host: String) {
        self.init(destination: host, port: nil, identityFile: nil)
    }

    init(destination: String, port: Int?, identityFile: String?, leadingOptions: [String] = []) {
        self.host = destination
        self.port = port
        self.identityFile = identityFile
        self.controlDir = Self.controlDirectory()
        self.leadingOptions = leadingOptions
    }

    /// `-i <file> -o IdentitiesOnly=yes` when the server names a key file, so ssh offers that key and only that key (an
    /// agent full of other keys could otherwise use up the server's attempt limit first). `~` is expanded here, so every
    /// ssh invocation (commands, streams, terminals, the host-key check) gets the same path. Empty when there is none.
    public static func identityArguments(_ identityFile: String?) -> [String] {
        guard let file = identityFile?.trimmingCharacters(in: .whitespaces), !file.isEmpty else { return [] }
        return ["-i", NSString(string: file).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
    }

    /// Shared by command polling and terminal tabs so a new tab reuses the open connection.
    /// Unix socket paths are limited to ~104 bytes, so keep this short.
    ///
    /// /tmp is shared by every user, so the folder is only used if it is a real directory (not a symlink) that this user
    /// owns and nobody else can enter. Otherwise (someone made it first) the sockets go to this user's private
    /// temporary folder instead, which is longer but still fits: a socket there could carry other people's commands.
    static func controlDirectory() -> String {
        let dir = "/tmp/rk-\(getuid())"
        mkdir(dir, 0o700)
        if isPrivateDirectory(dir) { return dir }
        return fallbackControlDirectory
    }

    /// A fresh private folder for this run of the app (mkdtemp makes it 0700 and ours), still short: ssh appends a
    /// 40-character hash and, while it sets the socket up, a 17-character temporary suffix, all within ~104 bytes.
    static let fallbackControlDirectory: String = {
        var template = Array("/tmp/rk-\(getuid())-XXXXXX".utf8CString)
        return template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress!).map { String(cString: $0) } ?? "/tmp/rk-\(getuid())-unavailable"
        }
    }()

    /// For connections that carry a secret (a sudo password): the server's key must be the one in known_hosts, whatever
    /// ~/.ssh/config says (a homelab config often has `StrictHostKeyChecking no`). Same file HostKeyVerifier uses.
    static let strictHostKeyArguments: [String] = [
        "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=\(NSString(string: "~/.ssh/known_hosts").expandingTildeInPath)",
    ]

    /// A directory (lstat, so a symlink is not one) owned by this user with no access for group or others.
    static func isPrivateDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid() && (info.st_mode & 0o077) == 0
    }

    /// Options for non-interactive command execution.
    /// Arguments for an interactive shell (`ssh -t`), used by the terminal view.
    public static func terminalArguments(for server: Server) -> [String] {
        // Keepalives make a dead link end the session (ssh exits 255 after about 45 s of silence), which is
        // what lets a terminal tab notice the drop and reconnect itself; without them ssh waits for TCP.
        var args = ["-t",
                    "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=3",
                    "-o", "ControlMaster=auto",
                    "-o", "ControlPersist=120",
                    "-o", "ControlPath=\(controlDirectory())/%C"]
        if let port = server.port { args += ["-p", String(port)] }
        return args + identityArguments(server.identityFile) + [server.sshDestination]
    }

    private var portArguments: [String] { port.map { ["-p", String($0)] } ?? [] }

    func baseArguments() -> [String] {
        leadingOptions + portArguments + [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=120",
            "-o", "ControlPath=\(controlDir)/%C",
        ] + Self.identityArguments(identityFile) + [host]
    }

    /// Most output one command may produce (a safety net; the largest real answers are a few hundred KB).
    static let outputLimit = 64 * 1024 * 1024

    public func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        let arguments = Arguments(baseArguments() + [command])
        do {
            return try await withThrowingTaskGroup(of: CommandResult?.self) { group in
                group.addTask {
                    let result = try await Subprocess.run(
                        .path("/usr/bin/ssh"), arguments: arguments, input: .none,
                        output: .bytes(limit: Self.outputLimit), error: .bytes(limit: Self.outputLimit))
                    return CommandResult(stdout: String(decoding: result.standardOutput, as: UTF8.self),
                                         stderr: String(decoding: result.standardError, as: UTF8.self),
                                         exitCode: Self.exitCode(result.terminationStatus))
                }
                // The timer: whichever finishes first wins; cancelling the loser stops ssh (Subprocess kills it).
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                guard let first else { throw OpenSSHError.timedOut(timeout) }
                return first
            }
        } catch let error as SubprocessError {
            throw OpenSSHError.launchFailed("\(error)")
        }
    }

    /// `run` with `input` written to the remote command's standard input and then closed (ssh forwards its own stdin).
    /// The one way a secret reaches a server: never as part of the command. `input` is not logged or kept.
    /// It uses its own connection, never the shared ControlMaster socket: a multiplexing client hands its stdin to
    /// whatever answers on that socket.
    public func run(_ command: String, input: String, timeout: TimeInterval) async throws -> CommandResult {
        // Built in steps: one long `+` chain is too slow for the compiler to type-check on Linux.
        var args: [String] = leadingOptions + portArguments
        args += [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-e", "none",
        ]
        args += Self.strictHostKeyArguments + Self.identityArguments(identityFile) + [host, command]
        let arguments = Arguments(args)
        do {
            return try await withThrowingTaskGroup(of: CommandResult?.self) { group in
                group.addTask {
                    let result = try await Subprocess.run(
                        .path("/usr/bin/ssh"), arguments: arguments, input: .string(input),
                        output: .bytes(limit: Self.outputLimit), error: .bytes(limit: Self.outputLimit))
                    return CommandResult(stdout: String(decoding: result.standardOutput, as: UTF8.self),
                                         stderr: String(decoding: result.standardError, as: UTF8.self),
                                         exitCode: Self.exitCode(result.terminationStatus))
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                guard let first else { throw OpenSSHError.timedOut(timeout) }
                return first
            }
        } catch let error as SubprocessError {
            throw OpenSSHError.launchFailed("\(error)")
        }
    }

    /// An exit status as ssh (and the old `Process`) reported it: the code, or the signal number if it was killed by one.
    static func exitCode(_ status: TerminationStatus) -> Int32 {
        switch status {
        case .exited(let code): code
        case .signaled(let signal): signal
        }
    }

    /// Streams combined output over a forced remote pseudo-terminal (`-tt`), so lines end in \r\n.
    ///
    /// Stopping the stream sends Ctrl-C through that terminal first, which makes the remote command exit
    /// and ssh finish on its own. Killing the local ssh alone is not enough: some servers (Tailscale SSH,
    /// as found in testing) leave the remote process running, so a quiet `docker logs -f` would stay
    /// behind forever. The kill is only a fallback if ssh has not exited about two seconds after the Ctrl-C
    /// (the teardown sequence below: swift-subprocess kills the process when its grace period ends).
    ///
    /// Streams deliberately do NOT use the shared ControlMaster connection: in testing, Ctrl-C written to
    /// a multiplexed client never reached the remote command, but on its own connection it does.
    public func stream(_ command: String) -> AsyncThrowingStream<String, Error> {
        stream(command, typing: nil)
    }

    /// `stream` with each string from `input` written to ssh's stdin, which `-tt` forwards to the remote pty. Used to
    /// answer sudo's prompt (sudo turns echo off). Nothing from `input` is logged or kept.
    public func stream(_ command: String, input: AsyncStream<String>) -> AsyncThrowingStream<String, Error> {
        stream(command, typing: input)
    }

    private func stream(_ command: String, typing: AsyncStream<String>?) -> AsyncThrowingStream<String, Error> {
        var built: [String] = ["-tt"] + leadingOptions + portArguments
        built += [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            // With a pty, ssh reads `~` at the start of a line as its escape character (`~.` drops the connection), which
            // would mangle a typed password starting with `~`. Nothing typed into a stream is meant for ssh itself.
            "-e", "none",
        ]
        if typing != nil { built += Self.strictHostKeyArguments }
        built += Self.identityArguments(identityFile) + [host, command]
        let args = built   // a constant: the task below must not capture something mutable
        return AsyncThrowingStream { continuation in
            let input = StdinBox()
            var options = PlatformOptions()
            // On cancellation: signal 0 delivers nothing (a pure grace period of two seconds for ssh to end by itself after
            // the Ctrl-C below), then swift-subprocess sends the final kill.
            options.teardownSequence = [.send(signal: Signal(rawValue: 0), allowedDurationToNextStep: .seconds(2))]
            let task = Task {
                do {
                    // Chunks can end in the middle of a multi-byte character; the chunker holds that tail for the next chunk.
                    var chunker = Utf8Chunker()
                    _ = try await Subprocess.run(
                        .path("/usr/bin/ssh"), arguments: Arguments(args), platformOptions: options,
                        input: .inputWriter, output: .sequence, error: .combinedWithOutput
                    ) { execution in
                        input.set(execution.standardInputWriter)
                        let typist = typing.map { typed in
                            Task { for await text in typed { await input.send(Array(text.utf8)) } }
                        }
                        defer { typist?.cancel(); input.clear() }
                        for try await buffer in execution.standardOutput {
                            let text = chunker.push(Data(buffer.withUnsafeBytes { Array($0) }))
                            if !text.isEmpty { continuation.yield(text) }
                        }
                        let tail = chunker.finish()
                        if !tail.isEmpty { continuation.yield(tail) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: OpenSSHError.launchFailed("\(error)"))
                }
            }
            continuation.onTermination = { _ in
                // Ctrl-C to the remote pty first, then cancel: the task's teardown gives ssh its grace period.
                Task {
                    await input.sendInterrupt()
                    task.cancel()
                }
            }
        }
    }
}

/// The running ssh's stdin writer, reachable from outside the run body so a cancelled stream can type Ctrl-C into it.
private final class StdinBox: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: StandardInputWriter?

    func set(_ w: StandardInputWriter) { lock.withLock { writer = w } }
    func clear() { lock.withLock { writer = nil } }

    /// Errors are ignored: the process may already be gone.
    func sendInterrupt() async { await send([0x03]) }

    func send(_ bytes: [UInt8]) async {
        let w = lock.withLock { writer }
        _ = try? await w?.write(bytes)
    }
}
