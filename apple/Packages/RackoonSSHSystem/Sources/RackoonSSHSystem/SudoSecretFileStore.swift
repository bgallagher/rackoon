// Apple-only: the saved sudo password is sealed with the Secure Enclave (CryptoKit, LocalAuthentication). On Linux,
// where only the integration lab's tests build this module, it is left out.
#if canImport(CryptoKit) && canImport(LocalAuthentication)
import CryptoKit
import Foundation
import LocalAuthentication
import RackoonCore
import Security
import Subprocess

/// An encrypted secret: `box` (AES-GCM, combined) under a key agreed between a throwaway `ephemeral` key and the
/// record's own private `key`. For the Secure Enclave sealer `key` is the enclave's wrapped key blob, usable only on
/// this Mac and only after the user approves; for the software sealer (tests) it is a raw private key.
public struct SealedSecret: Codable, Sendable, Equatable {
    public var key: Data
    public var ephemeral: Data
    public var box: Data
}

/// Seals and opens secrets. Swapped for a software key in tests, so the store can be tested without prompts.
public protocol SudoSealer: Sendable {
    /// Never prompts.
    func seal(_ plaintext: Data, authenticating aad: Data) throws -> SealedSecret
    /// Prompts (Touch ID, Apple Watch or login password). Throws `SudoSecretError.cancelled` if the user says no or the
    /// approval fails (the record is kept), `.unreadable` only if the record itself can't be opened.
    func open(_ sealed: SealedSecret, authenticating aad: Data, reason: String) async throws -> Data
}

enum SealCrypto {
    static let info = Data("rackoon-sudo-v1".utf8)

    static func key(_ secret: SharedSecret) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32)
    }
}

/// A new Secure Enclave key per record. Its access control lets it be used after Touch ID (any enrolled finger), the
/// paired Apple Watch, or the login password, the same choices macOS offers for its own admin prompts, and only while
/// the Mac is unlocked, on this Mac. Nothing is stored in the keychain: the enclave's wrapped key blob lives in the
/// record and is useless anywhere else.
public struct SecureEnclaveSealer: SudoSealer {
    public init() {}

    public static var isAvailable: Bool {
        var error: NSError?
        return SecureEnclave.isAvailable && LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    static func accessControl() throws -> SecAccessControl {
        var flags: SecAccessControlCreateFlags = [.privateKeyUsage, .or, .biometryAny, .devicePasscode]
        if #available(macOS 15.0, *) { flags.insert(.companion) }   // Apple Watch
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return access
    }

    public func seal(_ plaintext: Data, authenticating aad: Data) throws -> SealedSecret {
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: Self.accessControl())
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let symmetric = SealCrypto.key(try ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey))
        let box = try AES.GCM.seal(plaintext, using: symmetric, authenticating: aad)
        guard let combined = box.combined else { throw SudoSecretError.unreadable }
        return SealedSecret(key: key.dataRepresentation, ephemeral: ephemeral.publicKey.x963Representation, box: combined)
    }

    public func open(_ sealed: SealedSecret, authenticating aad: Data, reason: String) async throws -> Data {
        // 1. Approval, asked for explicitly and in the order macOS's own prompts use: Touch ID or the paired Apple Watch
        //    (a double-click of the side button, which works with the lid closed), then the login password. Letting the
        //    key operation raise its own prompt, or asking for the key's access rule, was found to offer only the
        //    password with the lid closed.
        let context = try await Self.approve(reason: reason)
        // 2. Use the key with that approved context. If that still wants to prompt (it needed an approval the policy did
        //    not give), fall back to approving for the key's own access rule, then try once more.
        do {
            return try Self.unwrap(sealed, aad: aad, context: context)
        } catch where Self.needsApproval(error) {
            let again = LAContext()
            do {
                _ = try await again.evaluateAccessControl(Self.accessControl(), operation: .useKeyKeyExchange, localizedReason: reason)
            } catch {
                throw SudoSecretError.cancelled
            }
            return try Self.unwrap(sealed, aad: aad, context: again)
        }
    }

    /// macOS's own owner-approval prompt (`.deviceOwnerAuthentication`): Touch ID, the paired Apple Watch (double-click
    /// the side button, works with the lid closed) or the login password, whichever is available, like its admin
    /// prompts. Returns the approved context: the key must be used with the very context that was approved.
    ///
    /// Verified on a real Mac with the lid closed (`rackoon-probe local watch-check`, trial B): this policy offered the
    /// Watch and the key then opened with no second prompt. Two alternatives did NOT work there and must not come back:
    /// asking for the key's own access rule (`evaluateAccessControl`, cancelled without a Watch offer) and the explicit
    /// Touch ID-or-Watch policy followed by a password fallback (failed outright).
    static func approve(reason: String) async throws -> LAContext {
        let context = LAContext()
        do {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return context
        } catch {
            throw SudoSecretError.cancelled
        }
    }

    private static func unwrap(_ sealed: SealedSecret, aad: Data, context: LAContext) throws -> Data {
        do {
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: sealed.key, authenticationContext: context)
            let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: sealed.ephemeral)
            let symmetric = SealCrypto.key(try key.sharedSecretFromKeyAgreement(with: ephemeral))
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed.box), using: symmetric, authenticating: aad)
        } catch {
            if Self.isCancellation(error) { throw SudoSecretError.cancelled }
            if needsApproval(error) { throw error }
            throw SudoSecretError.unreadable
        }
    }

    /// The key operation wanted to prompt but the context did not carry an approval.
    static func needsApproval(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == LAErrorDomain, [LAError.authenticationFailed.rawValue, LAError.notInteractive.rawValue].contains(ns.code) { return true }
        if ns.domain == NSOSStatusErrorDomain, [Int(errSecAuthFailed), Int(errSecInteractionNotAllowed)].contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return needsApproval(underlying) }
        return false
    }

    /// CryptoKit reports a cancelled prompt as a wrapped LocalAuthentication or Security error.
    static func isCancellation(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == LAErrorDomain, [LAError.userCancel.rawValue, LAError.appCancel.rawValue, LAError.systemCancel.rawValue].contains(ns.code) { return true }
        if ns.domain == NSOSStatusErrorDomain, ns.code == Int(errSecUserCanceled) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isCancellation(underlying) }
        return "\(error)".contains("errSecUserCanceled") || "\(error)".contains("-128")
    }
}

/// A software key instead of the Secure Enclave, for tests only: same record format, no prompt.
public struct SoftwareSealer: SudoSealer {
    public var refuse = false
    public init(refuse: Bool = false) { self.refuse = refuse }

    public func seal(_ plaintext: Data, authenticating aad: Data) throws -> SealedSecret {
        let key = P256.KeyAgreement.PrivateKey()
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let box = try AES.GCM.seal(plaintext, using: SealCrypto.key(try ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey)),
                                   authenticating: aad)
        return SealedSecret(key: key.rawRepresentation, ephemeral: ephemeral.publicKey.x963Representation, box: box.combined!)
    }

    public func open(_ sealed: SealedSecret, authenticating aad: Data, reason: String) async throws -> Data {
        if refuse { throw SudoSecretError.cancelled }
        do {
            let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: sealed.key)
            let symmetric = SealCrypto.key(try key.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: sealed.ephemeral)))
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed.box), using: symmetric, authenticating: aad)
        } catch {
            throw SudoSecretError.unreadable
        }
    }
}

/// One JSON file per server in a private folder: `<serverID>.json`, mode 600, folder 700, written atomically, excluded
/// from backups. The file holds the scope (not secret) and the sealed password; the scope is also bound into the seal,
/// so a record copied under another server's name does not open.
public final class SudoSecretFileStore: SudoSecretStore, @unchecked Sendable {
    private struct Record: Codable {
        var v = 1
        var scope: SudoSecretScope
        var sealed: SealedSecret
    }

    public let directory: URL
    private let sealer: SudoSealer
    private let lock = NSLock()

    public init(directory: URL, sealer: SudoSealer) {
        self.directory = directory
        self.sealer = sealer
    }

    private func file(_ serverID: String) -> URL {
        directory.appendingPathComponent(String(serverID.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(64)) + ".json")
    }

    private func read(_ serverID: String) -> Record? {
        guard let data = try? Data(contentsOf: file(serverID)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    public func isRemembered(serverID: String) -> Bool { lock.withLock { read(serverID) != nil } }

    public func remember(_ password: String, scope: SudoSecretScope) throws {
        let sealed = try sealer.seal(Data(password.utf8), authenticating: scope.authenticatedData)
        let data = try JSONEncoder().encode(Record(scope: scope, sealed: sealed))
        try lock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            var dir = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
            let target = file(scope.serverID)
            let temp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw SudoSecretError.unreadable
            }
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
        }
    }

    public func secret(for scope: SudoSecretScope, reason: String) async throws -> String {
        guard let record = lock.withLock({ read(scope.serverID) }) else { throw SudoSecretError.notRemembered }
        guard record.scope == scope else {
            var sameSaved = record.scope
            sameSaved.resolved = scope.resolved
            // Only where ssh goes differs (network-dependent config): refuse, but keep it for when it resolves back.
            if sameSaved == scope { throw SudoSecretError.resolvedElsewhere }
            forget(serverID: scope.serverID)
            throw SudoSecretError.scopeChanged
        }
        let opened: Result<Data, Error>
        do { opened = .success(try await sealer.open(record.sealed, authenticating: scope.authenticatedData, reason: reason)) }
        catch { opened = .failure(error) }
        switch opened {
        case .success(let data):
            guard let text = String(data: data, encoding: .utf8) else { forget(serverID: scope.serverID); throw SudoSecretError.unreadable }
            return text
        case .failure(SudoSecretError.cancelled):
            throw SudoSecretError.cancelled
        case .failure:
            forget(serverID: scope.serverID)
            throw SudoSecretError.unreadable
        }
    }

    public func forget(serverID: String) {
        lock.withLock { _ = try? FileManager.default.removeItem(at: file(serverID)) }
    }

    public func forgetAll() {
        lock.withLock { _ = try? FileManager.default.removeItem(at: directory) }
    }
}

extension OpenSSHTransport {
    /// Where ssh really connects for `server` (`ssh -G`, which applies ~/.ssh/config without connecting), or nil.
    public static func resolve(_ server: Server) async -> SSHResolved? {
        var args = ["-G"]
        if let port = server.port { args += ["-p", String(port)] }
        args += identityArguments(server.identityFile)
        args.append(server.sshDestination)
        guard let result = try? await Subprocess.run(.path("/usr/bin/ssh"), arguments: Arguments(args), input: .none,
                                                     output: .bytes(limit: 1 << 20), error: .discarded),
              exitCode(result.terminationStatus) == 0 else { return nil }
        return SSHResolved.parse(String(decoding: result.standardOutput, as: UTF8.self))
    }
}
#endif
