import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
@preconcurrency import NIOSSH

/// A server's host key as presented in a handshake.
public struct HostKeyInfo: Sendable, Equatable {
    /// The key type as ssh names it, e.g. `ssh-ed25519`.
    public let keyType: String
    /// The public key in ssh wire format (what `ssh-keygen` hashes).
    public let blob: Data

    public init(keyType: String, blob: Data) {
        self.keyType = keyType
        self.blob = blob
    }

    /// Reads an OpenSSH public key line (`ssh-ed25519 AAAA… [comment]`), the format of known_hosts and `.pub` files.
    public init?(openSSH line: String) {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline })
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        self.init(keyType: String(parts[0]), blob: blob)
    }

    init(_ key: NIOSSHPublicKey) {
        // NIOSSH writes `<type> <base64 wire blob>`; that is the only public way to reach the wire bytes.
        self.init(openSSH: String(openSSHPublicKey: key))!
    }

    /// `SHA256:` + base64 without padding, the format `ssh-keygen -lf` prints.
    public var fingerprint: String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    /// A short algorithm name for display: "Ed25519", "RSA", "ECDSA".
    public var algorithmLabel: String {
        if keyType.contains("ed25519") { return "Ed25519" }
        if keyType.contains("rsa") { return "RSA" }
        if keyType.contains("ecdsa") { return "ECDSA" }
        return keyType
    }

    public var openSSH: String { "\(keyType) \(blob.base64EncodedString())" }
}

/// A key the user chose to trust for one server. Stored as JSON, in the same shape as Android's `TrustedHostKey`.
public struct TrustedHostKey: Codable, Sendable, Equatable {
    public let keyType: String
    /// base64 of the wire-format key, as in an OpenSSH known_hosts file.
    public let publicKey: String
    public let fingerprint: String
    /// Epoch milliseconds when it was trusted.
    public let trustedAt: Int64

    public init(_ info: HostKeyInfo, at date: Date = Date()) {
        keyType = info.keyType
        publicKey = info.blob.base64EncodedString()
        fingerprint = info.fingerprint
        trustedAt = Int64(date.timeIntervalSince1970 * 1000)
    }

    public var blob: Data { Data(base64Encoded: publicKey) ?? Data() }
}

/// What to do with a presented key.
public enum HostKeyVerdict: Sendable, Equatable {
    case trusted
    case unknown(presented: HostKeyInfo)
    case changed(trusted: TrustedHostKey, presented: HostKeyInfo)
}

/// Where trusted host keys live. One key per `host:port`.
public protocol KnownHostsStore: Sendable {
    func lookup(host: String, port: Int) -> TrustedHostKey?
    func trust(host: String, port: Int, key: HostKeyInfo)
    func forget(host: String, port: Int)
}

public extension KnownHostsStore {
    /// Compares a presented key with what is trusted. A changed key is never "trusted" by this call.
    func verdict(host: String, port: Int, presented: HostKeyInfo) -> HostKeyVerdict {
        guard let trusted = lookup(host: host, port: port) else { return .unknown(presented: presented) }
        return trusted.blob == presented.blob ? .trusted : .changed(trusted: trusted, presented: presented)
    }
}

func hostKeyID(_ host: String, _ port: Int) -> String { "\(host.lowercased()):\(port)" }

public final class InMemoryKnownHosts: KnownHostsStore {
    private let keys = NIOLockedValueBox([String: TrustedHostKey]())

    public init() {}

    public func lookup(host: String, port: Int) -> TrustedHostKey? { keys.withLockedValue { $0[hostKeyID(host, port)] } }
    public func trust(host: String, port: Int, key: HostKeyInfo) { keys.withLockedValue { $0[hostKeyID(host, port)] = TrustedHostKey(key) } }
    public func forget(host: String, port: Int) { _ = keys.withLockedValue { $0.removeValue(forKey: hostKeyID(host, port)) } }
}

/// `known_hosts.json`: a map from `host:port` to the trusted key. Written atomically; a corrupt file reads as empty.
public final class JSONFileKnownHosts: KnownHostsStore {
    private let url: URL
    private let cache = NIOLockedValueBox<[String: TrustedHostKey]?>(nil)

    public init(url: URL) { self.url = url }

    private func load(_ cached: inout [String: TrustedHostKey]?) -> [String: TrustedHostKey] {
        if let cached { return cached }
        let map = (try? JSONDecoder().decode([String: TrustedHostKey].self, from: Data(contentsOf: url))) ?? [:]
        cached = map
        return map
    }

    private func save(_ map: [String: TrustedHostKey]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(map).write(to: url, options: .atomic)
    }

    public func lookup(host: String, port: Int) -> TrustedHostKey? {
        cache.withLockedValue { load(&$0)[hostKeyID(host, port)] }
    }

    public func trust(host: String, port: Int, key: HostKeyInfo) {
        cache.withLockedValue {
            var map = load(&$0)
            map[hostKeyID(host, port)] = TrustedHostKey(key)
            $0 = map
            save(map)
        }
    }

    public func forget(host: String, port: Int) {
        cache.withLockedValue {
            var map = load(&$0)
            guard map.removeValue(forKey: hostKeyID(host, port)) != nil else { return }
            $0 = map
            save(map)
        }
    }
}

/// Checks the presented key against the store and remembers the verdict, so a refusal becomes a precise error.
final class StrictHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let host: String
    private let port: Int
    private let store: any KnownHostsStore
    private let seen = NIOLockedValueBox<HostKeyVerdict?>(nil)

    init(host: String, port: Int, store: any KnownHostsStore) {
        self.host = host
        self.port = port
        self.store = store
    }

    var verdict: HostKeyVerdict? { seen.withLockedValue { $0 } }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let result = store.verdict(host: host, port: port, presented: HostKeyInfo(hostKey))
        seen.withLockedValue { $0 = result }
        switch result {
        case .trusted: validationCompletePromise.succeed(())
        case .unknown(let presented): validationCompletePromise.fail(EmbeddedSSHError.hostKeyUnknown(presented))
        case .changed(let trusted, let presented): validationCompletePromise.fail(EmbeddedSSHError.hostKeyChanged(trusted: trusted, presented: presented))
        }
    }
}

/// Takes whatever key is presented and stops the handshake there, before any credentials could be sent.
final class ScanningHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private let seen = NIOLockedValueBox<HostKeyInfo?>(nil)
    var key: HostKeyInfo? { seen.withLockedValue { $0 } }

    struct Scanned: Error {}

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        seen.withLockedValue { $0 = HostKeyInfo(hostKey) }
        validationCompletePromise.fail(Scanned())
    }
}
