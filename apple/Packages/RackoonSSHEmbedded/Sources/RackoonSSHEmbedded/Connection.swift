import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH

/// One authenticated SSH connection: a TCP socket with NIOSSH on it. Commands and shells are session channels on it.
final class SSHConnection: Sendable {
    let channel: Channel
    private let ssh: NIOLoopBound<NIOSSHHandler>

    private init(channel: Channel, ssh: NIOLoopBound<NIOSSHHandler>) {
        self.channel = channel
        self.ssh = ssh
    }

    var isActive: Bool { channel.isActive }

    func close() {
        channel.close(promise: nil)
    }

    /// Opens a session channel with `handler` installed. Fails before anything was sent to the server, so a caller may
    /// retry on a fresh connection.
    func openSession(_ handler: @escaping @Sendable () -> any ChannelHandler & Sendable) async throws -> Channel {
        let loop = channel.eventLoop
        let ssh = self.ssh
        return try await loop.flatSubmit {
            let promise = loop.makePromise(of: Channel.self)
            ssh.value.createChannel(promise, channelType: .session) { child, _ in
                child.eventLoop.makeCompletedFuture { try child.pipeline.syncOperations.addHandler(handler()) }
            }
            return promise.futureResult
        }.get()
    }

    /// Connects, checks the host key against `knownHosts` (an unknown or changed key stops the handshake before any
    /// credentials are sent) and signs in.
    static func open(_ endpoint: SSHEndpoint, knownHosts: any KnownHostsStore, timeout: TimeInterval) async throws -> SSHConnection {
        let validator = StrictHostKeyValidator(host: endpoint.host, port: endpoint.port, store: knownHosts)
        let auth = try SingleAuthDelegate(user: endpoint.user, auth: endpoint.auth)
        do {
            return try await handshake(host: endpoint.host, port: endpoint.port, timeout: timeout,
                                       configuration: SSHClientConfiguration(userAuthDelegate: auth, serverAuthDelegate: validator))
        } catch {
            switch validator.verdict {
            case .unknown(let presented): throw EmbeddedSSHError.hostKeyUnknown(presented)
            case .changed(let trusted, let presented): throw EmbeddedSSHError.hostKeyChanged(trusted: trusted, presented: presented)
            case .trusted, nil: throw mapError(error, connecting: true)
            }
        }
    }

    /// Reads a server's host key without signing in: the handshake stops as soon as the key is presented.
    static func scanHostKey(host: String, port: Int, timeout: TimeInterval) async throws -> HostKeyInfo {
        let scanner = ScanningHostKeyValidator()
        do {
            let connection = try await handshake(host: host, port: port, timeout: timeout,
                                                 configuration: SSHClientConfiguration(userAuthDelegate: try SingleAuthDelegate(user: "rackoon-scan", auth: .none),
                                                                                       serverAuthDelegate: scanner))
            connection.close()
        } catch {
            if let key = scanner.key { return key }
            throw mapError(error, connecting: true)
        }
        throw EmbeddedSSHError.connectionLost("the server did not present a host key")
    }

    private static func handshake(host: String, port: Int, timeout: TimeInterval,
                                  configuration: SSHClientConfiguration) async throws -> SSHConnection {
        let group = MultiThreadedEventLoopGroup.singleton
        let loop = group.any()
        let signedIn = loop.makePromise(of: Void.self)
        let limit = TimeAmount.milliseconds(Int64(timeout * 1000))
        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(limit)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(role: .client(configuration), allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandlers(ssh, SignInWatcher(signedIn))
                }
            }
        let channel: Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            signedIn.fail(error)
            throw error
        }
        let deadline = loop.scheduleTask(in: limit) { signedIn.fail(EmbeddedSSHError.unreachable("timed out signing in")) }
        do {
            try await signedIn.futureResult.get()
            deadline.cancel()
        } catch {
            deadline.cancel()
            channel.close(promise: nil)
            throw error
        }
        let ssh = try await loop.submit {
            NIOLoopBound(try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self), eventLoop: loop)
        }.get()
        return SSHConnection(channel: channel, ssh: ssh)
    }
}

/// Completes `promise` when sign-in succeeds, or fails it with the first error or when the connection closes first.
private final class SignInWatcher: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any
    private let promise: EventLoopPromise<Void>

    init(_ promise: EventLoopPromise<Void>) { self.promise = promise }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { promise.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise.fail(EmbeddedSSHError.connectionLost("the server closed the connection"))
        context.fireChannelInactive()
    }
}

/// What a session channel reports, in order.
enum SessionEvent: Sendable {
    case stdout(ByteBuffer)
    case stderr(ByteBuffer)
    case exit(Int32)
    /// The channel is closed; nothing follows.
    case closed
}

/// Turns a session channel's data and requests into `SessionEvent`s.
final class SessionHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = SSHChannelData
    private let events: AsyncStream<SessionEvent>.Continuation

    init(_ events: AsyncStream<SessionEvent>.Continuation) { self.events = events }

    func handlerAdded(context: ChannelHandlerContext) {
        // The server's EOF is not the end: the exit status follows it, then the close.
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = message.data else { return }
        switch message.type {
        case .channel: events.yield(.stdout(bytes))
        case .stdErr: events.yield(.stderr(bytes))
        default: break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            events.yield(.exit(Int32(truncatingIfNeeded: status.exitStatus)))
        case let signal as SSHChannelRequestEvent.ExitSignal:
            // Like a shell: 128 + the signal number.
            events.yield(.exit(128 + Self.signalNumber(signal.signalName)))
        case ChannelEvent.inputClosed:
            break
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        events.yield(.closed)
        events.finish()
        context.fireChannelInactive()
    }

    static func signalNumber(_ name: String) -> Int32 {
        ["HUP": 1, "INT": 2, "QUIT": 3, "ILL": 4, "ABRT": 6, "FPE": 8, "KILL": 9, "SEGV": 11, "PIPE": 13, "ALRM": 14,
         "TERM": 15, "USR1": 10, "USR2": 12][name] ?? 0
    }
}

extension Channel {
    func send(_ bytes: some Sequence<UInt8>) async throws {
        try await writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: bytes)))).get()
    }

    func request(_ event: Any & Sendable) async throws {
        try await triggerUserOutboundEvent(event).get()
    }
}

func mapError(_ error: Error, connecting: Bool) -> Error {
    switch error {
    case let error as EmbeddedSSHError: return error
    case is CancellationError: return error
    case let error as NIOConnectionError:
        if error.dnsAError != nil || error.dnsAAAAError != nil, error.connectionErrors.isEmpty {
            return EmbeddedSSHError.unreachable("Unable to resolve host \(error.host)")
        }
        let first = error.connectionErrors.first.map { String(describing: $0.error) } ?? "no address answered"
        return EmbeddedSSHError.unreachable(first)
    case ChannelError.connectTimeout:
        return EmbeddedSSHError.unreachable("timed out")
    case let error as IOError where connecting:
        return EmbeddedSSHError.unreachable(error.description)
    default:
        return EmbeddedSSHError.connectionLost(String(describing: error))
    }
}
