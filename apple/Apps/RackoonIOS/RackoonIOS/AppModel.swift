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
    /// Docker per server; a model keeps its last action's output while the app runs.
    let docker = DockerStore()
    /// App logos and site icons, cached on this device (a temporary folder in demo mode).
    private(set) var icons: AppIconStore
    private(set) var favicons: FaviconStore
    /// Remembered sudo passwords (Keychain, unlocked with Face ID); none in demo mode.
    private(set) var vault: SudoVault
    /// Docker through sudo, per server, for a limited time.
    let elevation = DockerElevation()
    /// Reboots in progress (or just finished), by server id.
    var reboots: [String: RebootFlow] = [:]
    /// Each server's Updates screen model, kept so an install's output survives leaving the screen.
    @ObservationIgnored private var updatesModels: [String: UpdatesModel] = [:]
    @ObservationIgnored private let makeVault: (Bool) -> SudoVault

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let dataDirectory: URL
    @ObservationIgnored private let secrets: any SecretStore
    /// "iPhone" or "iPad", for advice that names this device.
    @ObservationIgnored let deviceName: String
    /// False in tests: icons are never downloaded.
    @ObservationIgnored private let network: Bool
    static let demoKey = "demoMode"

    /// `dataDirectory` is where servers.json, known_hosts.json, sign-in.json and the snapshots live (Application
    /// Support/Rackoon in the app). Secrets go to `secrets` (the Keychain in the app).
    init(appearance: AppearanceStore, safety: SafetyStore, defaults: UserDefaults = .standard, dataDirectory: URL,
         secrets: any SecretStore, deviceName: String = "iPhone", demo: Bool? = nil, network: Bool = true,
         vault: @escaping (Bool) -> SudoVault = { SudoVault.system(demo: $0) }) {
        self.appearance = appearance
        self.safety = safety
        self.defaults = defaults
        self.dataDirectory = dataDirectory
        self.secrets = secrets
        self.deviceName = deviceName
        self.network = network
        let on = demo ?? Self.demoRequested(defaults: defaults)
        isDemo = on
        (servers, trust, signIn) = Self.models(demo: on, dataDirectory: dataDirectory, secrets: secrets)
        (icons, favicons) = Self.iconStores(demo: on, dataDirectory: dataDirectory, network: network)
        makeVault = vault
        self.vault = vault(on)
        fleet = makeFleet()
        self.vault.load(servers.servers)
        elevation.changed = { [weak self] id in self?.docker.forget(id) }
    }

    /// Demo mode keeps its icon choices in a temporary folder, so trying the demo never changes the real ones.
    private static func iconStores(demo: Bool, dataDirectory: URL, network: Bool) -> (AppIconStore, FaviconStore) {
        let base = demo ? FileManager.default.temporaryDirectory.appendingPathComponent("rackoon-demo-icons", isDirectory: true) : dataDirectory
        return (AppIconStore(directory: base.appendingPathComponent("app-icons", isDirectory: true), network: network),
                FaviconStore(directory: base.appendingPathComponent("favicons", isDirectory: true), network: network))
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
        docker.forgetAll()
        updatesModels = [:]
        for flow in reboots.values { flow.cancel() }
        reboots = [:]
        for server in servers.servers { elevation.lock(server.id) }
        isDemo = on
        (servers, trust, signIn) = Self.models(demo: on, dataDirectory: dataDirectory, secrets: secrets)
        (icons, favicons) = Self.iconStores(demo: on, dataDirectory: dataDirectory, network: network)
        vault = makeVault(on)
        vault.load(servers.servers)
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

    /// Opens a new terminal tab on a server, or says why it can't. With `command`, the tab runs that instead of a login shell
    /// (a container's shell).
    @discardableResult
    func openTerminal(on server: Server, command: String? = nil, title: String? = nil) -> String? {
        switch terminalOpener(for: server) {
        case .success(let opener):
            terminals.newTab(for: server.id, opener: opener, command: command, title: title, highlight: appearance.highlightOutput)
            return nil
        case .failure(let reason):
            return reason.message
        }
    }

    /// The server's Docker model, or why Docker can't be read yet (the host key, a missing secret). Read-only does not
    /// block reading; every action checks it.
    func dockerModel(for server: Server) -> Result<DockerModel, FleetModel.BlockedReason> {
        let key = elevation.key(server.id)
        if let model = docker.existing(server.id), model.accessKey == key { return .success(model) }
        switch trust.state(for: server) {
        case .trusted, .demo: break
        default: return .failure(.init(message: "Trust the server's host key on its Overview first."))
        }
        switch transport(for: server) {
        case .success(let base):
            // Through sudo while the user has unlocked Docker for this server; a model made under another key is stale.
            if docker.existing(server.id) != nil { docker.forget(server.id) }
            let transport = elevation.transport(for: server.id, base: base)
            return .success(docker.model(for: server) { DockerModel(server: server, transport: transport, safety: safety, accessKey: key) })
        case .failure(let reason):
            return .failure(reason)
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
            docker.forget(id)
            updatesModels[id] = nil
            elevation.lock(id)
            vault.forget(id)   // a saved sudo password belongs to the old address
        }
        return problem
    }

    func remove(id: String) {
        terminals.closeAll(for: id)
        docker.forget(id)
        updatesModels[id] = nil
        reboots[id]?.cancel()
        reboots[id] = nil
        elevation.lock(id)
        vault.forget(id)
        icons.forget(serverID: id)
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
        docker.forget(id)
        updatesModels[id] = nil
    }

    /// The server's Updates model (made on first use, kept while the app runs), or why there is none yet.
    func updatesModel(for server: Server) -> Result<UpdatesModel, FleetModel.BlockedReason> {
        if let model = updatesModels[server.id] { return .success(model) }
        switch trust.state(for: server) {
        case .trusted, .demo: break
        default: return .failure(.init(message: "Trust the server's host key on its Overview first."))
        }
        switch transport(for: server) {
        case .success(let transport):
            let model = UpdatesModel(server: server, transport: transport, safety: safety, vault: vault)
            updatesModels[server.id] = model
            return .success(model)
        case .failure(let reason):
            return .failure(reason)
        }
    }

    enum SignInChoice: Equatable {
        /// Leave the saved method and secret as they are.
        case keep
        case tailscale
        case key(String, passphrase: String?)
        case password(String)
    }
}
