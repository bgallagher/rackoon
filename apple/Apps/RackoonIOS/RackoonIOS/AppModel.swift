import Foundation
import Observation
import RackoonCore
import RackoonDemo
import RackoonSSHEmbedded

/// Everything the screens share. Demo mode swaps the server list, host keys, sign-in and transports for the made-up
/// servers in `RackoonDemo` (the Mac's demo data): nothing real is read or written and nothing is sent anywhere.
@MainActor @Observable
final class AppModel {
    let appearance: AppearanceStore
    let safety: SafetyStore
    private(set) var isDemo: Bool
    private(set) var servers: ServersModel
    private(set) var trust: HostTrustModel
    private(set) var signIn: SignInStore
    private(set) var fleet: FleetModel!
    /// Terminal tabs per server; they outlive screens and end on close, removal or an edit of the address.
    let terminals = TerminalStore()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let dataDirectory: URL
    @ObservationIgnored private let secrets: any SecretStore
    /// "iPhone" or "iPad", for advice that names this device.
    @ObservationIgnored let deviceName: String
    static let demoKey = "demoMode"

    /// `dataDirectory` is where servers.json, known_hosts.json, sign-in.json and the snapshots live (Application
    /// Support/Rackoon in the app). Secrets go to `secrets` (the Keychain in the app).
    init(appearance: AppearanceStore, safety: SafetyStore, defaults: UserDefaults = .standard, dataDirectory: URL,
         secrets: any SecretStore, deviceName: String = "iPhone", demo: Bool? = nil) {
        self.appearance = appearance
        self.safety = safety
        self.defaults = defaults
        self.dataDirectory = dataDirectory
        self.secrets = secrets
        self.deviceName = deviceName
        let on = demo ?? Self.demoRequested(defaults: defaults)
        isDemo = on
        (servers, trust, signIn) = Self.models(demo: on, dataDirectory: dataDirectory, secrets: secrets)
        fleet = makeFleet()
    }

    static func live(deviceName: String) -> AppModel {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppModel(appearance: .bundled(), safety: SafetyStore(),
                        dataDirectory: base.appendingPathComponent("Rackoon", isDirectory: true),
                        secrets: KeychainSecretStore(), deviceName: deviceName)
    }

    /// `RACKOON_DEMO=1` in the environment (Xcode scheme, `SIMCTL_CHILD_RACKOON_DEMO`), `-demoMode YES` on the command
    /// line, or the switch in Settings.
    static func demoRequested(defaults: UserDefaults) -> Bool {
        ProcessInfo.processInfo.environment["RACKOON_DEMO"] != nil || defaults.bool(forKey: demoKey)
    }

    private static func models(demo: Bool, dataDirectory: URL, secrets: any SecretStore) -> (ServersModel, HostTrustModel, SignInStore) {
        if demo {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rackoon-demo-\(UUID().uuidString)", isDirectory: true)
            let store = ServerStore(directory: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? store.saveServers(DemoFleet.servers)
            return (ServersModel(store: store), HostTrustModel(knownHosts: InMemoryKnownHosts(), isDemo: true),
                    SignInStore(file: nil, secrets: MemorySecretStore()))
        }
        return (ServersModel(store: ServerStore(directory: dataDirectory)),
                HostTrustModel(knownHosts: JSONFileKnownHosts(url: dataDirectory.appendingPathComponent("known_hosts.json"))),
                SignInStore(file: dataDirectory.appendingPathComponent("sign-in.json"), secrets: secrets))
    }

    private func makeFleet() -> FleetModel {
        FleetModel(FleetModel.Dependencies(
            transport: { [unowned self] server in self.transport(for: server) },
            gate: { [unowned self] server in
                switch self.trust.state(for: server) {
                case .trusted, .demo: .open
                case .unchecked: .needsCheck
                case .checking: .blocked("Checking the host key…")
                case .unknown: .blocked("The host key is not trusted yet.")
                case .changed: .blocked("The host key changed since it was trusted. Connection blocked.")
                case .failed(let message): .blocked(message)
                }
            },
            checkHostKey: { [unowned self] server in await self.trust.check(server) },
            store: servers.store,
            server: { [unowned self] id in self.servers.server(id: id) }))
    }

    /// Switches demo mode on or off now: the screens are rebuilt on the other server list.
    func setDemo(_ on: Bool) {
        defaults.set(on, forKey: Self.demoKey)
        guard on != isDemo else { return }
        fleet.pause()
        terminals.closeEverything()
        isDemo = on
        (servers, trust, signIn) = Self.models(demo: on, dataDirectory: dataDirectory, secrets: secrets)
        fleet = makeFleet()
    }

    /// The transport for a server: the demo's, or the embedded SSH client signed in the way the user chose.
    func transport(for server: Server) -> Result<SSHTransport, FleetModel.BlockedReason> {
        if isDemo { return .success(DemoFleet.transport(for: server)) }
        return embedded(for: server).map { $0 }
    }

    private func embedded(for server: Server) -> Result<EmbeddedSSHTransport, FleetModel.BlockedReason> {
        guard let auth = signIn.auth(for: server.id) else {
            return .failure(.init(message: "The saved \(signIn.method(for: server.id) == .key ? "key" : "password") is missing on this \(deviceName). Choose it again under Edit."))
        }
        return .success(EmbeddedSSHTransport(endpoint: SSHEndpoint(host: server.host, port: HostTrustModel.port(server),
                                                                   user: server.user ?? "root", auth: auth),
                                             knownHosts: trust.knownHosts))
    }

    /// What opens terminals on a server, or why none can be opened now (Read-only, the host key, a missing secret).
    func terminalOpener(for server: Server) -> Result<any TerminalOpening, FleetModel.BlockedReason> {
        // A terminal can change anything on the server, so Read-only keeps it closed (as on Android).
        if safety.readOnly { return .failure(.init(message: "Read-only is on, so terminals are off. Turn it off to open one.")) }
        if isDemo { return .success(DemoTerminals(host: server.name)) }
        switch trust.state(for: server) {
        case .trusted: break
        default: return .failure(.init(message: "Trust the server's host key on its Overview first."))
        }
        return embedded(for: server).map { $0 as any TerminalOpening }
    }

    /// Opens a new terminal tab on a server, or says why it can't.
    @discardableResult
    func openTerminal(on server: Server) -> String? {
        switch terminalOpener(for: server) {
        case .success(let opener):
            terminals.newTab(for: server.id, opener: opener, highlight: appearance.highlightOutput)
            return nil
        case .failure(let reason):
            return reason.message
        }
    }

    /// The last poll's error explained for this device and sign-in method, or nil.
    func failure(for server: Server, state: ServerState) -> ConnectionFailure? {
        guard let error = state.error else { return nil }
        return ConnectionFailure.explain(error, signIn: isDemo ? nil : signIn.method(for: server.id), device: deviceName)
    }

    // MARK: changes that touch more than one store

    func update(id: String, with draft: ServersModel.Draft) -> String? {
        let (problem, changed) = servers.update(id: id, with: draft)
        if changed, let server = servers.server(id: id) {
            trust.reset(server)
            fleet.reset(id)
            terminals.closeAll(for: id)
        }
        return problem
    }

    func remove(id: String) {
        terminals.closeAll(for: id)
        fleet.forget(id)
        signIn.forget(id)
        servers.remove(id: id)
    }

    /// Reads the server's host key again; polling resumes if it turns out to be the trusted one.
    func checkHostKey(_ server: Server) async {
        await trust.check(server)
        fleet.reset(server.id)
    }

    /// Trusts the key the user was shown; polling starts if a screen is waiting for it. False if it could not be trusted
    /// (the server presented another key since, or one is already trusted).
    @discardableResult
    func trust(_ key: HostKeyInfo, for server: Server) -> Bool {
        guard trust.trust(key, for: server) else { return false }
        fleet.reset(server.id)
        return true
    }

    /// Applies a sign-in choice from the form. Throws a readable error (a key that can't be read, a wrong passphrase).
    func setSignIn(_ choice: SignInChoice, for id: String) throws {
        switch choice {
        case .keep: return
        case .tailscale: try signIn.useTailscale(for: id)
        case .key(let text, let passphrase): try signIn.useKey(text, passphrase: passphrase, for: id)
        case .password(let password): try signIn.usePassword(password, for: id)
        }
        fleet.reset(id)
        terminals.closeAll(for: id)
    }

    enum SignInChoice: Equatable {
        /// Leave the saved method and secret as they are.
        case keep
        case tailscale
        case key(String, passphrase: String?)
        case password(String)
    }
}
