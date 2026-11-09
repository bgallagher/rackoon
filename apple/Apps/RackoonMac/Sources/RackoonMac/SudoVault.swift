import Foundation
import Observation
import RackoonCore
import RackoonSSHSystem
import Security

/// Remembered sudo passwords on this Mac ("Remember on this Mac" in the sudo password sheet). Each one is sealed by its
/// own Secure Enclave key and every use asks for Touch ID, the Apple Watch or the login password. Opt-in per server,
/// saved only after the server accepted the password, never synced, separate for the stable and dev builds, and
/// forgotten when the server's connection details change, when it is removed, or when the server rejects it.
@MainActor @Observable
final class SudoVault {
    static let shared = SudoVault()

    /// Servers with a saved password (refreshed after every change; reading it never prompts).
    private(set) var remembered: Set<String> = []
    @ObservationIgnored private let store: SudoSecretStore?

    /// Why "Remember" is not offered, for the record (nil when it is).
    let unavailableReason: String?

    private init() {
        let reason = Self.unavailableReason()
        unavailableReason = reason
        if reason == nil {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // One folder per build: a dev build never reads or overwrites the stable build's records.
            let folder = base.appendingPathComponent("Rackoon/sudo/\(Bundle.main.bundleIdentifier ?? "unbundled")", isDirectory: true)
            store = SudoSecretFileStore(directory: folder, sealer: SecureEnclaveSealer())
        } else {
            store = nil
        }
    }

    /// Offered only in a bundled, hardened-runtime build (so another program can't inject code into Rackoon to make it
    /// ask for the password on its behalf), never in demo mode, and only on a Mac with a Secure Enclave and a login
    /// password or Touch ID.
    private static func unavailableReason() -> String? {
        if Demo.isOn { return "demo mode" }
        let env = ProcessInfo.processInfo.environment
        if env["RACKOON_DEMO_UPDATES"] != nil || env["RACKOON_DEMO_REBOOT"] != nil { return "a demo switch is on" }
        if Bundle.main.bundleURL.pathExtension != "app" { return "not running from an app bundle (swift run)" }
        if !hasHardenedRuntime() { return "the app is not signed with the hardened runtime" }
        if !SecureEnclaveSealer.isAvailable { return "this Mac has no Secure Enclave or no login authentication" }
        return nil
    }

    private static func hasHardenedRuntime() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let flags = dict[kSecCodeInfoFlags as String] as? UInt32 else { return false }
        return flags & SecCodeSignatureFlags.runtime.rawValue != 0
    }

    var canRemember: Bool { store != nil }

    func isRemembered(_ server: Server) -> Bool { remembered.contains(server.id) || (store?.isRemembered(serverID: server.id) ?? false) }

    /// Saves the password for `server`. Call only after the server accepted it. Fails quietly (it is a convenience).
    func remember(_ password: String, for server: Server) async {
        guard let store, let resolved = await OpenSSHTransport.resolve(server) else { return }
        try? store.remember(password, scope: SudoSecretScope(server: server, resolved: resolved))
        refresh(server)
    }

    /// The saved password, after Touch ID, the Apple Watch or the login password. `reason` completes
    /// "Rackoon is trying to …". A changed server (or an ssh alias now pointing elsewhere) forgets it instead.
    func unlock(_ server: Server, reason: String) async -> Result<String, SudoSecretError> {
        guard let store, store.isRemembered(serverID: server.id) else { return .failure(.notRemembered) }
        guard let resolved = await OpenSSHTransport.resolve(server) else { return .failure(.scopeChanged) }
        do {
            let secret = try await store.secret(for: SudoSecretScope(server: server, resolved: resolved), reason: reason)
            return .success(secret)
        } catch let error as SudoSecretError {
            refresh(server)
            return .failure(error)
        } catch {
            refresh(server)
            return .failure(.unreadable)
        }
    }

    /// Several saved passwords after ONE Touch ID / Apple Watch / login password approval, keyed by server id. Same
    /// rules per server as `unlock`.
    func unlockMany(_ servers: [Server], reason: String) async -> [String: Result<String, SudoSecretError>] {
        guard let store else { return Dictionary(uniqueKeysWithValues: servers.map { ($0.id, .failure(.notRemembered)) }) }
        var out: [String: Result<String, SudoSecretError>] = [:]
        var scopes: [SudoSecretScope] = []
        for server in servers {
            guard store.isRemembered(serverID: server.id) else { out[server.id] = .failure(.notRemembered); continue }
            guard let resolved = await OpenSSHTransport.resolve(server) else { out[server.id] = .failure(.scopeChanged); continue }
            scopes.append(SudoSecretScope(server: server, resolved: resolved))
        }
        for (id, result) in await store.secrets(for: scopes, reason: reason) { out[id] = result }
        for server in servers { refresh(server) }
        return out
    }

    func forget(_ serverID: String) {
        store?.forget(serverID: serverID)
        remembered.remove(serverID)
    }

    func forgetAll() {
        store?.forgetAll()
        remembered = []
    }

    private func refresh(_ server: Server) {
        if store?.isRemembered(serverID: server.id) == true { remembered.insert(server.id) } else { remembered.remove(server.id) }
    }

    /// Fills `remembered` for the saved servers (at launch). Never prompts. Also deletes records of servers that no
    /// longer exist, in every build's folder: servers.json is shared, so a server removed in the dev build (or under
    /// swift run, where Remember is off) must not leave its sealed password behind in the stable build's folder.
    func load(_ servers: [Server]) {
        guard !Demo.isOn else { return }   // the demo's made-up server list must never clean the real records
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rackoon/sudo", isDirectory: true)
        let known = Set(servers.map { String($0.id.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(64)) })
        for folder in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "json" && !known.contains(file.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        guard let store else { return }
        remembered = Set(servers.map(\.id).filter { store.isRemembered(serverID: $0) })
    }
}

/// Where the password of a password run came from: typed into the sheet (and whether to remember it once accepted),
/// or the saved one (forgotten at once if the server rejects it, never retried).
enum SudoPasswordSource: Equatable { case typed(remember: Bool), saved }

extension SudoVault {
    /// Added to a confirm sheet whose command will use the saved password.
    static func useNote(_ server: Server) -> String {
        "It uses the sudo password saved on this Mac for \(server.name): Touch ID, your Apple Watch or your login password unlocks it."
    }

    /// Completes the system prompt's "Rackoon is trying to …".
    static func reason(_ server: Server, doing label: String) -> String {
        let what = label.trimmingCharacters(in: CharacterSet(charactersIn: "…. ")).lowercased()
        return "use the saved sudo password on \(server.name) (\(what))"
    }
}

extension Server {
    /// Everything that decides where a connection goes. Views holding a transport are keyed by it.
    var connectionKey: String {
        [id, sshDestination, port.map(String.init) ?? "", identityFile ?? "", sshConfigAlias ?? ""].joined(separator: "|")
    }
}

extension SudoSecretError {
    /// What the sheet says when a saved password could not be used and the user has to type it.
    var sheetProblem: String? {
        switch self {
        case .scopeChanged, .unreadable, .resolvedElsewhere: errorDescription
        case .notRemembered, .cancelled: nil
        }
    }
}
