import Foundation
import LocalAuthentication
import Observation
import RackoonCore
import Security

/// Where a remembered sudo password lives: one item per server holding the password, readable only after Face ID, Touch ID
/// or the device passcode, plus the scope it belongs to, readable without a prompt. The real one is the Keychain; tests
/// use memory.
protocol SudoKeychain: Sendable {
    func save(password: Data, scope: Data, account: String) throws
    /// The scope saved beside the password. Never prompts.
    func scope(account: String) -> Data?
    /// The password, after the user approves. Throws `SudoSecretError.cancelled` when they don't.
    func password(account: String, prompt: String) async throws -> Data
    func delete(account: String)
    func deleteAll()
}

/// The `SudoSecretStore` of the phone: the Keychain, this device only, never synced or backed up, every read approved
/// with Face ID, Touch ID or the passcode. A saved scope that no longer matches the server is forgotten, never used.
struct KeychainSudoStore: SudoSecretStore {
    let keychain: SudoKeychain

    func isRemembered(serverID: String) -> Bool { keychain.scope(account: serverID) != nil }

    func remember(_ password: String, scope: SudoSecretScope) throws {
        try keychain.save(password: Data(password.utf8), scope: scope.authenticatedData, account: scope.serverID)
    }

    func secret(for scope: SudoSecretScope, reason: String) async throws -> String {
        guard let saved = keychain.scope(account: scope.serverID) else { throw SudoSecretError.notRemembered }
        guard saved == scope.authenticatedData else {
            keychain.delete(account: scope.serverID)
            throw SudoSecretError.scopeChanged
        }
        let data = try await keychain.password(account: scope.serverID, prompt: reason)
        guard let text = String(data: data, encoding: .utf8) else {
            keychain.delete(account: scope.serverID)
            throw SudoSecretError.unreadable
        }
        return text
    }

    func forget(serverID: String) { keychain.delete(account: serverID) }
    func forgetAll() { keychain.deleteAll() }
}

/// The iOS Keychain. The password item is `WhenPasscodeSetThisDeviceOnly` with `.userPresence` (Face ID, Touch ID or the
/// passcode), so it is never synced, never restored to another device, and deleted if the passcode is removed. The scope is
/// a second item without access control, so it can be compared before anyone is asked to approve.
struct SystemSudoKeychain: SudoKeychain {
    static let service = "com.bgallagher.rackoon.sudo"
    private static let scopeService = "com.bgallagher.rackoon.sudo-scope"

    func save(password: Data, scope: Data, account: String) throws {
        delete(account: account)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error) else {
            throw SudoSecretError.unreadable
        }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                   kSecAttrAccount as String: account, kSecValueData as String: password,
                                   kSecAttrAccessControl as String: access]
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SudoSecretError.unreadable }
        let scopeItem: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.scopeService,
                                        kSecAttrAccount as String: account, kSecValueData as String: scope,
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        guard SecItemAdd(scopeItem as CFDictionary, nil) == errSecSuccess else {
            delete(account: account)
            throw SudoSecretError.unreadable
        }
    }

    func scope(account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.scopeService,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    func password(account: String, prompt: String) async throws -> Data {
        // Ask first, explicitly, then read with that approved context: the device shows one prompt, and the approval
        // does not depend on the Keychain enforcing the item's access control by itself (the simulator does not).
        let context = LAContext()
        context.localizedReason = prompt
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: prompt) else { throw SudoSecretError.cancelled }
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel, .authenticationFailed, .userFallback].contains(error.code) {
            throw SudoSecretError.cancelled
        } catch is LAError {
            throw SudoSecretError.unreadable
        }
        return try await Task.detached(priority: .userInitiated) {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                        kSecAttrAccount as String: account, kSecReturnData as String: true,
                                        kSecUseAuthenticationContext as String: context]
            var out: CFTypeRef?
            switch SecItemCopyMatching(query as CFDictionary, &out) {
            case errSecSuccess:
                guard let data = out as? Data else { throw SudoSecretError.unreadable }
                return data
            case errSecUserCanceled, errSecAuthFailed:
                throw SudoSecretError.cancelled
            case errSecItemNotFound:
                throw SudoSecretError.notRemembered
            default:
                throw SudoSecretError.unreadable
            }
        }.value
    }

    func delete(account: String) {
        for service in [Self.service, Self.scopeService] {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                           kSecAttrAccount as String: account] as CFDictionary)
        }
    }

    func deleteAll() {
        for service in [Self.service, Self.scopeService] {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
    }
}

/// Remembered sudo passwords on this device ("Remember on this iPhone" in the sudo password sheet), the phone's
/// `SudoVault`: opt-in per server, saved only after the server accepted the password, every use approved with Face ID,
/// Touch ID or the passcode, and forgotten when the server's address, user or port changes, when it is removed, or when
/// the server rejects it. Never in demo mode.
@MainActor @Observable
final class SudoVault {
    private(set) var remembered: Set<String> = []
    @ObservationIgnored private let store: SudoSecretStore?
    let unavailableReason: String?

    init(store: SudoSecretStore?, unavailableReason: String? = nil) {
        self.store = unavailableReason == nil ? store : nil
        self.unavailableReason = store == nil ? (unavailableReason ?? "not available") : unavailableReason
    }

    /// The device's vault: the Keychain, when the device has a passcode (without one the item can't be created).
    static func system(demo: Bool) -> SudoVault {
        if demo { return SudoVault(store: nil, unavailableReason: "demo mode") }
        var error: NSError?
        guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return SudoVault(store: nil, unavailableReason: "this device has no passcode")
        }
        return SudoVault(store: KeychainSudoStore(keychain: SystemSudoKeychain()))
    }

    var canRemember: Bool { store != nil }

    /// What the device unlocks with, for the sheet's wording.
    nonisolated static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "your passcode"
        }
    }

    /// What a saved password belongs to on a phone: the server as saved (there is no ~/.ssh/config to resolve).
    static func scope(_ server: Server) -> SudoSecretScope {
        SudoSecretScope(server: server, resolved: SSHResolved(user: server.user ?? "root", hostname: server.host, port: server.port ?? 22))
    }

    func isRemembered(_ server: Server) -> Bool { remembered.contains(server.id) || (store?.isRemembered(serverID: server.id) ?? false) }

    /// Saves the password. Call only after the server accepted it. Fails quietly (it is a convenience).
    func remember(_ password: String, for server: Server) {
        guard let store else { return }
        try? store.remember(password, scope: Self.scope(server))
        refresh(server.id)
    }

    /// The saved password after the user approves. A changed server forgets it instead.
    func unlock(_ server: Server, reason: String) async -> Result<String, SudoSecretError> {
        guard let store, store.isRemembered(serverID: server.id) else { return .failure(.notRemembered) }
        do {
            let secret = try await store.secret(for: Self.scope(server), reason: reason)
            return .success(secret)
        } catch let error as SudoSecretError {
            refresh(server.id)
            return .failure(error)
        } catch {
            refresh(server.id)
            return .failure(.unreadable)
        }
    }

    func forget(_ serverID: String) {
        store?.forget(serverID: serverID)
        remembered.remove(serverID)
    }

    /// Fills `remembered` at launch. Never prompts. (A removed server's record is deleted when it is removed.)
    func load(_ servers: [Server]) {
        guard let store else { return }
        remembered = Set(servers.map(\.id).filter { store.isRemembered(serverID: $0) })
    }

    private func refresh(_ serverID: String) {
        if store?.isRemembered(serverID: serverID) == true { remembered.insert(serverID) } else { remembered.remove(serverID) }
    }

    /// Added to a confirm sheet whose command will use the saved password.
    func useNote(_ server: Server) -> String {
        "It uses the sudo password saved on this device for \(server.name): \(Self.biometryName) unlocks it."
    }

    /// The system prompt's reason.
    static func reason(_ server: Server, doing label: String) -> String {
        let what = label.trimmingCharacters(in: CharacterSet(charactersIn: "…. ")).lowercased()
        return "Use the saved sudo password on \(server.name) (\(what))"
    }
}

/// Where the password of a password run came from: typed into the sheet (and whether to remember it once accepted),
/// or the saved one (forgotten at once if the server rejects it, never retried).
enum SudoPasswordSource: Equatable { case typed(remember: Bool), saved }

extension SudoSecretError {
    /// What the sheet says when a saved password could not be used and the user has to type it.
    var sheetProblem: String? {
        switch self {
        case .scopeChanged, .unreadable, .resolvedElsewhere: errorDescription
        case .notRemembered, .cancelled: nil
        }
    }
}
