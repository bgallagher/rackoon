import Foundation

/// Where ssh really connects for a server, after ~/.ssh/config: `ssh -G` prints it ("user", "hostname", "port").
public struct SSHResolved: Codable, Sendable, Equatable {
    public var user: String
    public var hostname: String
    public var port: Int

    public init(user: String, hostname: String, port: Int) {
        self.user = user
        self.hostname = hostname
        self.port = port
    }

    /// Parses `ssh -G` output, or nil if any of the three is missing.
    public static func parse(_ text: String) -> SSHResolved? {
        var user: String?, host: String?, port: Int?
        for raw in text.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "user": user = parts[1]
            case "hostname": host = parts[1]
            case "port": port = Int(parts[1])
            default: break
            }
        }
        guard let user, let host, let port, !user.isEmpty, !host.isEmpty else { return nil }
        return SSHResolved(user: user, hostname: host, port: port)
    }
}

/// What a remembered sudo password belongs to: one saved server, its connection details as saved, and where ssh
/// really went when the password was accepted. If any of it differs when the password is about to be used (the server
/// was edited, or an ssh config alias now points somewhere else), the password is forgotten instead of typed.
public struct SudoSecretScope: Codable, Sendable, Equatable {
    public var serverID: String
    public var destination: String
    public var port: Int?
    public var identityFile: String?
    public var resolved: SSHResolved

    public init(server: Server, resolved: SSHResolved) {
        serverID = server.id
        destination = server.sshDestination
        port = server.port
        identityFile = server.identityFile
        self.resolved = resolved
    }

    /// A stable encoding, bound into the sealed record so a record can't be moved to another server's scope.
    public var authenticatedData: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data(serverID.utf8)
    }
}

public enum SudoSecretError: Error, Equatable, LocalizedError {
    /// Nothing is saved for this server.
    case notRemembered
    /// The user cancelled Touch ID / Apple Watch / the password prompt. Nothing runs.
    case cancelled
    /// The server's connection details changed since the password was saved. It was forgotten.
    case scopeChanged
    /// The saved details are the same, but ssh now resolves them to a different user, address or port (an alias that
    /// depends on the network, or one that was changed). Not used this time; kept for when it resolves back.
    case resolvedElsewhere
    /// The saved record could not be opened (the key was invalidated, the file is damaged). It was forgotten.
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .notRemembered: "No sudo password is saved for this server."
        case .cancelled: "Cancelled. Nothing was run."
        case .scopeChanged: "The server's connection details changed, so its saved sudo password was forgotten."
        case .resolvedElsewhere: "ssh now reaches this server at a different user, address or port than when its sudo password was saved, so the saved password was not used."
        case .unreadable: "The saved sudo password could not be opened, so it was forgotten."
        }
    }
}

/// Remembered sudo passwords, one per server. Implementations keep them encrypted at rest, ask the user (Touch ID,
/// Apple Watch or the login password) for every `secret` call, never sync them, and never log them.
public protocol SudoSecretStore: Sendable {
    /// Whether something is saved for the server. Never prompts.
    func isRemembered(serverID: String) -> Bool
    /// Saves (or replaces) the server's password. Never prompts. Call only after the server accepted it.
    func remember(_ password: String, scope: SudoSecretScope) throws
    /// The saved password, after the user approves. `scope` is the server as it is NOW: a mismatch forgets the record
    /// and throws `.scopeChanged`. `reason` completes "Rackoon is trying to …".
    func secret(for scope: SudoSecretScope, reason: String) async throws -> String
    /// Several saved passwords after ONE approval where the store can do that (the same rules as `secret`, per server),
    /// keyed by server id. The default asks once per server.
    func secrets(for scopes: [SudoSecretScope], reason: String) async -> [String: Result<String, SudoSecretError>]
    func forget(serverID: String)
    func forgetAll()
}

extension SudoSecretStore {
    public func secrets(for scopes: [SudoSecretScope], reason: String) async -> [String: Result<String, SudoSecretError>] {
        var out: [String: Result<String, SudoSecretError>] = [:]
        for scope in scopes {
            do { out[scope.serverID] = .success(try await secret(for: scope, reason: reason)) }
            catch let error as SudoSecretError { out[scope.serverID] = .failure(error) }
            catch { out[scope.serverID] = .failure(.unreadable) }
        }
        return out
    }
}
