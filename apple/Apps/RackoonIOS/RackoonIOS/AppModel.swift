import Foundation
import Observation
import RackoonCore
import RackoonDemo
import RackoonSSHEmbedded

/// Everything the screens share. Demo mode swaps the server list, host keys and transports for the made-up servers in
/// `RackoonDemo` (the Mac's demo data): nothing real is read or written and nothing is sent anywhere.
@MainActor @Observable
final class AppModel {
    let appearance: AppearanceStore
    let safety: SafetyStore
    private(set) var isDemo: Bool
    private(set) var servers: ServersModel
    private(set) var trust: HostTrustModel
    /// The last connection check per server: what answered, or why it failed.
    private(set) var checks: [String: ConnectionCheck] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let dataDirectory: URL
    static let demoKey = "demoMode"

    enum ConnectionCheck: Equatable {
        case running
        case answered(hostname: String, os: String, uptime: TimeInterval)
        case failed(String)
    }

    /// `dataDirectory` is where servers.json and known_hosts.json live (Application Support/Rackoon in the app).
    init(appearance: AppearanceStore, safety: SafetyStore, defaults: UserDefaults = .standard, dataDirectory: URL,
         demo: Bool? = nil) {
        self.appearance = appearance
        self.safety = safety
        self.defaults = defaults
        self.dataDirectory = dataDirectory
        let on = demo ?? Self.demoRequested(defaults: defaults)
        isDemo = on
        (servers, trust) = Self.models(demo: on, dataDirectory: dataDirectory)
    }

    static func live() -> AppModel {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppModel(appearance: .bundled(), safety: SafetyStore(),
                        dataDirectory: base.appendingPathComponent("Rackoon", isDirectory: true))
    }

    /// `RACKOON_DEMO=1` in the environment (Xcode scheme, `SIMCTL_CHILD_RACKOON_DEMO`), `-demoMode YES` on the command
    /// line, or the switch in Settings.
    static func demoRequested(defaults: UserDefaults) -> Bool {
        ProcessInfo.processInfo.environment["RACKOON_DEMO"] != nil || defaults.bool(forKey: demoKey)
    }

    private static func models(demo: Bool, dataDirectory: URL) -> (ServersModel, HostTrustModel) {
        if demo {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rackoon-demo-\(UUID().uuidString)", isDirectory: true)
            let store = ServerStore(directory: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? store.saveServers(DemoFleet.servers)
            return (ServersModel(store: store), HostTrustModel(knownHosts: InMemoryKnownHosts(), isDemo: true))
        }
        return (ServersModel(store: ServerStore(directory: dataDirectory)),
                HostTrustModel(knownHosts: JSONFileKnownHosts(url: dataDirectory.appendingPathComponent("known_hosts.json"))))
    }

    /// Switches demo mode on or off now: the screens are rebuilt on the other server list.
    func setDemo(_ on: Bool) {
        defaults.set(on, forKey: Self.demoKey)
        guard on != isDemo else { return }
        isDemo = on
        checks = [:]
        (servers, trust) = Self.models(demo: on, dataDirectory: dataDirectory)
    }

    /// The transport every screen uses. Until key sign-in arrives (stage I2) a real server is reached with SSH `none`
    /// authentication, which is what Tailscale SSH accepts.
    func transport(for server: Server) -> SSHTransport {
        if isDemo { return DemoFleet.transport(for: server) }
        return EmbeddedSSHTransport(endpoint: SSHEndpoint(host: server.host, port: HostTrustModel.port(server),
                                                          user: server.user ?? "root", auth: .none),
                                    knownHosts: trust.knownHosts)
    }

    /// Runs the read-only overview command once and reports who answered.
    func checkConnection(_ server: Server) async {
        checks[server.id] = .running
        do {
            let result = try await transport(for: server).run(ServerSession.overviewCommand, timeout: 30)
            guard result.exitCode == 0 else {
                checks[server.id] = .failed(result.stderr.isEmpty ? "The command failed (exit \(result.exitCode))." : result.stderr)
                return
            }
            let overview = try OverviewParser.parse(result.stdout)
            checks[server.id] = .answered(hostname: overview.hostname, os: overview.os.prettyName, uptime: overview.uptimeSeconds)
        } catch {
            checks[server.id] = .failed(error.localizedDescription)
        }
    }

    // MARK: server list changes that touch other state

    func update(id: String, with draft: ServersModel.Draft) -> String? {
        let (problem, changed) = servers.update(id: id, with: draft)
        if changed, let server = servers.server(id: id) {
            trust.reset(server)
            checks[id] = nil
        }
        return problem
    }

    func remove(id: String) {
        servers.remove(id: id)
        checks[id] = nil
    }
}
