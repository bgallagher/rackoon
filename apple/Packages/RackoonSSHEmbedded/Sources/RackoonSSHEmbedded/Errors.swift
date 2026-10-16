import Foundation

/// What can go wrong reaching a server, in terms the UI can explain. Mirrors Android's `SshException`.
public enum EmbeddedSSHError: Error, LocalizedError, Equatable {
    /// Could not open a connection at all (no route, refused, timed out, unknown host).
    case unreachable(String)
    /// The server did not accept the credentials.
    case authFailed(String)
    /// First connection: nothing is trusted for this server yet. Carries the key to show to the user. No credentials were sent.
    case hostKeyUnknown(HostKeyInfo)
    /// The server presented a different key than the one trusted. Never offered for acceptance. No credentials were sent.
    case hostKeyChanged(trusted: TrustedHostKey, presented: HostKeyInfo)
    /// An established connection dropped or failed mid-command.
    case connectionLost(String)
    /// A command did not finish in time.
    case timeout(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let detail): "Could not reach the server: \(detail)"
        case .authFailed(let detail): "Sign-in was refused: \(detail)"
        case .hostKeyUnknown: "This server's host key is not trusted yet."
        case .hostKeyChanged: "The host key changed since it was trusted. Connection blocked."
        case .connectionLost(let detail): "Connection lost: \(detail)"
        case .timeout(let seconds): "The command did not finish within \(Int(seconds)) s."
        }
    }
}
