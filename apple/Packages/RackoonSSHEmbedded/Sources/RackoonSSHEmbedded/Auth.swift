import Citadel
import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
@preconcurrency import NIOSSH

/// How to sign in. The secret parts never leave this value: the app keeps them in the Keychain and builds one when connecting.
public enum SSHAuth: Sendable, CustomStringConvertible {
    /// Tailscale SSH: the server identifies the tailnet node, so SSH `none` authentication is accepted. Nothing to store.
    case none
    case password(String)
    /// An OpenSSH private key as text, with its passphrase if it has one.
    case privateKey(String, passphrase: String? = nil)

    public var description: String {
        switch self {
        case .none: "none"
        case .password: "password(***)"
        case .privateKey: "privateKey(***)"
        }
    }
}

/// Where and as whom to connect. `host` is exactly what the user typed (a name, an address or a Tailscale name).
public struct SSHEndpoint: Sendable, CustomStringConvertible {
    public var host: String
    public var port: Int
    public var user: String
    public var auth: SSHAuth

    public init(host: String, port: Int = 22, user: String, auth: SSHAuth) {
        self.host = host
        self.port = port
        self.user = user
        self.auth = auth
    }

    public var description: String { "\(user)@\(host):\(port) (\(auth))" }
}

/// Reading private keys the user imports. A key we cannot use is reported in plain words, before any connection.
public enum SSHKeys {
    public static func load(_ text: String, passphrase: String?) throws -> NIOSSHPrivateKey {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("-----BEGIN"), text.contains("PRIVATE KEY") else {
            throw EmbeddedSSHError.authFailed(text.hasPrefix("ssh-") || text.hasPrefix("ecdsa-")
                ? "That is a public key. Choose the private key file (the one without .pub)."
                : "That file is not a private key.")
        }
        let type: SSHKeyType
        do {
            type = try SSHKeyDetection.detectPrivateKeyType(from: text)
        } catch {
            throw EmbeddedSSHError.authFailed("That key could not be read (\(error.localizedDescription)).")
        }
        let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        do {
            switch type {
            case .ed25519:
                return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: decryptionKey))
            default:
                // RSA through Citadel signs with ssh-rsa (SHA-1), which OpenSSH 8.8 and later refuse; ECDSA keys in
                // OpenSSH format are not parsed by Citadel. See docs/ios-spikes.md.
                throw EmbeddedSSHError.authFailed("\(type) keys are not supported yet. Use an Ed25519 key.")
            }
        } catch let error as EmbeddedSSHError {
            throw error
        } catch {
            throw EmbeddedSSHError.authFailed(decryptionKey == nil
                ? "This key could not be read. If it is protected by a passphrase, enter it."
                : "The passphrase is wrong, or the key could not be read.")
        }
    }
}

/// Offers exactly one sign-in method, once. When the server refuses it, the handshake fails with what the server offers.
final class SingleAuthDelegate: NIOSSHClientUserAuthenticationDelegate, Sendable {
    private let user: String
    private let offer: NIOSSHUserAuthenticationOffer.Offer
    private let offered = NIOLockedValueBox(false)

    init(user: String, auth: SSHAuth) throws {
        self.user = user
        switch auth {
        case .none: offer = .none
        case .password(let password): offer = .password(.init(password: password))
        case .privateKey(let text, let passphrase): offer = .privateKey(.init(privateKey: try SSHKeys.load(text, passphrase: passphrase)))
        }
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        let first = offered.withLockedValue { done in defer { done = true }; return !done }
        guard first else {
            nextChallengePromise.fail(EmbeddedSSHError.authFailed("the server refused it (it accepts: \(Self.describe(availableMethods)))"))
            return
        }
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: user, serviceName: "", offer: offer))
    }

    private static func describe(_ methods: NIOSSHAvailableUserAuthenticationMethods) -> String {
        var names: [String] = []
        if methods.contains(.publicKey) { names.append("publickey") }
        if methods.contains(.password) { names.append("password") }
        if methods.contains(.hostBased) { names.append("hostbased") }
        return names.isEmpty ? "nothing we can offer" : names.joined(separator: ", ")
    }
}
