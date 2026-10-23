import Foundation
import Observation
import RackoonCore
import RackoonSSHEmbedded

/// Host-key trust for every saved server, as on the Mac and Android: the first connection shows the server's key for the
/// user to confirm (only that exact key is then trusted), and a key that changed since is blocked and never offered for
/// acceptance. Keys live in `known_hosts.json` beside servers.json.
@MainActor @Observable
final class HostTrustModel {
    enum State: Equatable {
        case unchecked
        case checking
        case trusted(TrustedHostKey)
        /// Nothing trusted yet: show this key and ask.
        case unknown(HostKeyInfo)
        /// The server presents another key than the one trusted. Blocked.
        case changed(trusted: TrustedHostKey, presented: HostKeyInfo)
        case failed(String)
        /// Demo servers are not real hosts; there is no key to check.
        case demo
    }

    typealias Scanner = @Sendable (_ host: String, _ port: Int) async throws -> HostKeyInfo

    private(set) var states: [String: State] = [:]
    /// The key each server presented at its last check, when nothing was trusted for it.
    @ObservationIgnored private var presented: [String: HostKeyInfo] = [:]
    @ObservationIgnored let knownHosts: any KnownHostsStore
    @ObservationIgnored private let scan: Scanner
    @ObservationIgnored private let isDemo: Bool

    init(knownHosts: any KnownHostsStore, isDemo: Bool = false,
         scan: @escaping Scanner = { host, port in try await EmbeddedSSHTransport.scanHostKey(host: host, port: port, timeout: 20) }) {
        self.knownHosts = knownHosts
        self.isDemo = isDemo
        self.scan = scan
    }

    static func port(_ server: Server) -> Int { server.port ?? 22 }

    func state(for server: Server) -> State {
        if isDemo { return .demo }
        if let state = states[server.id] { return state }
        if let trusted = knownHosts.lookup(host: server.host, port: Self.port(server)) { return .trusted(trusted) }
        return .unchecked
    }

    /// Reads the key the server presents now (no sign-in) and compares it with what is trusted.
    func check(_ server: Server) async {
        guard !isDemo else { return }
        states[server.id] = .checking
        do {
            let read = try await scan(server.host, Self.port(server))
            switch knownHosts.verdict(host: server.host, port: Self.port(server), presented: read) {
            case .trusted:
                states[server.id] = knownHosts.lookup(host: server.host, port: Self.port(server)).map(State.trusted) ?? .unknown(read)
            case .unknown(let key):
                presented[server.id] = key
                states[server.id] = .unknown(key)
            case .changed(let trusted, let key):
                states[server.id] = .changed(trusted: trusted, presented: key)
            }
        } catch EmbeddedSSHError.hostKeyChanged(let trusted, let changed) {
            states[server.id] = .changed(trusted: trusted, presented: changed)
        } catch {
            states[server.id] = .failed(error.localizedDescription)
        }
    }

    /// Trusts exactly the key the user was shown, and only if nothing is trusted for that server yet: a changed key can
    /// never be accepted through here.
    @discardableResult
    func trust(_ key: HostKeyInfo, for server: Server) -> Bool {
        // The key last read from this server (kept while a re-check is running, so a tap during it still works), and
        // nothing trusted for it yet: a changed key can never be replaced through here.
        guard presented[server.id] == key,
              knownHosts.lookup(host: server.host, port: Self.port(server)) == nil else { return false }
        knownHosts.trust(host: server.host, port: Self.port(server), key: key)
        states[server.id] = knownHosts.lookup(host: server.host, port: Self.port(server)).map(State.trusted)
        return true
    }

    /// An edit moved the server to another address: forget the last reading, so the next check is about the new one.
    /// Trusted keys stay keyed by address, so another saved server at the old address keeps its trust.
    func reset(_ server: Server) {
        states[server.id] = nil
        presented[server.id] = nil
    }
}

extension HostTrustModel.State {
    var isChanged: Bool {
        if case .changed = self { return true }
        return false
    }
}

extension TrustedHostKey {
    /// Worked out from the stored key itself, never taken from the stored text, so an edited file can't show a false one.
    var computedFingerprint: String { HostKeyInfo(keyType: keyType, blob: blob).fingerprint }
}
