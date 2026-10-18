import Foundation
import Observation
import RackoonCore
import RackoonSSHEmbedded
import Security

/// Where sign-in secrets live. The app uses the Keychain; tests and demo mode use memory.
protocol SecretStore: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, for account: String) throws
    func delete(_ account: String) throws
}

enum SecretStoreError: Error, LocalizedError, Equatable {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The Keychain refused: \(text)"
        }
    }
}

/// Generic-password items, this device only, readable after the first unlock (so a poll can run while the app is open
/// with the screen locked). Never synced to iCloud, never in backups.
struct KeychainSecretStore: SecretStore {
    var service = "com.bgallagher.rackoon.sign-in"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read(_ account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
        return out as? Data
    }

    func write(_ data: Data, for account: String) throws {
        try delete(account)
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }
}

final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func read(_ account: String) throws -> Data? { lock.withLock { items[account] } }
    func write(_ data: Data, for account: String) throws { lock.withLock { items[account] = data } }
    func delete(_ account: String) throws { lock.withLock { _ = items.removeValue(forKey: account) } }
}

/// How each server is signed in to. The method is kept in `sign-in.json` beside servers.json (no secrets in it); a key
/// (with its passphrase) or a password goes to the `SecretStore` only. Tailscale SSH needs nothing stored and is the default.
@MainActor @Observable
final class SignInStore {
    private(set) var methods: [String: SignInMethod]
    @ObservationIgnored private let file: URL?
    @ObservationIgnored let secrets: any SecretStore

    private struct KeySecret: Codable {
        var text: String
        var passphrase: String?
    }

    init(file: URL?, secrets: any SecretStore) {
        self.file = file
        self.secrets = secrets
        methods = file.flatMap { try? JSONDecoder().decode([String: SignInMethod].self, from: Data(contentsOf: $0)) } ?? [:]
    }

    func method(for serverID: String) -> SignInMethod { methods[serverID] ?? .tailscale }

    func useTailscale(for serverID: String) throws {
        try secrets.delete(serverID)
        set(.tailscale, for: serverID)
    }

    /// Checks the key can be read (and its passphrase is right) before anything is saved.
    func useKey(_ text: String, passphrase: String?, for serverID: String) throws {
        let pass = passphrase.flatMap { $0.isEmpty ? nil : $0 }
        _ = try SSHKeys.load(text, passphrase: pass)
        try secrets.write(try JSONEncoder().encode(KeySecret(text: text, passphrase: pass)), for: serverID)
        set(.key, for: serverID)
    }

    func usePassword(_ password: String, for serverID: String) throws {
        try secrets.write(Data(password.utf8), for: serverID)
        set(.password, for: serverID)
    }

    /// The server was removed: nothing of its sign-in is kept.
    func forget(_ serverID: String) {
        try? secrets.delete(serverID)
        methods[serverID] = nil
        save()
    }

    func hasSecret(for serverID: String) -> Bool { (try? secrets.read(serverID)) != nil }

    /// What the transport signs in with. A key or password that is missing (deleted from the Keychain, restored backup)
    /// gives nil, which the Overview explains instead of trying something else.
    func auth(for serverID: String) -> SSHAuth? {
        switch method(for: serverID) {
        case .tailscale:
            return SSHAuth.none
        case .key:
            guard let data = try? secrets.read(serverID), let key = try? JSONDecoder().decode(KeySecret.self, from: data) else { return nil }
            return .privateKey(key.text, passphrase: key.passphrase)
        case .password:
            guard let data = try? secrets.read(serverID) else { return nil }
            return .password(String(decoding: data, as: UTF8.self))
        }
    }

    private func set(_ method: SignInMethod, for serverID: String) {
        methods[serverID] = method
        save()
    }

    private func save() {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(methods).write(to: file, options: .atomic)
    }
}

extension SignInMethod {
    var title: String {
        switch self {
        case .tailscale: "Tailscale SSH"
        case .key: "Private key"
        case .password: "Password"
        }
    }
}
