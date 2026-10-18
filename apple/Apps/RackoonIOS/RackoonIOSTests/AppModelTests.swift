import Foundation
import RackoonCore
import RackoonSSHEmbedded
@testable import RackoonIOS
import XCTest

/// A UserDefaults domain and a data folder of the test's own, so nothing touches the app's real settings or servers.
@MainActor
final class Sandbox {
    let suite = "rackoon-ios-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rackoon-ios-\(UUID().uuidString)", isDirectory: true)

    init() { defaults = UserDefaults(suiteName: suite)! }

    deinit {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    let secrets = MemorySecretStore()

    func app(demo: Bool = false, systemIsDark: Bool = true) -> AppModel {
        AppModel(appearance: AppearanceStore(themesData: Self.themes, defaults: defaults, systemIsDark: systemIsDark),
                 safety: SafetyStore(defaults: defaults), defaults: defaults, dataDirectory: directory, secrets: secrets, demo: demo)
    }

    /// The themes.json the app bundles (the Mac's own file, referenced by the project).
    static let themes: Data? = Bundle.main.url(forResource: "themes", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
}

@MainActor
final class ThemeTests: XCTestCase {
    func testTheBundledThemesLoad() throws {
        let store = AppearanceStore(themesData: Sandbox.themes, defaults: Sandbox().defaults)
        XCTAssertNil(store.themeError)
        XCTAssertEqual(store.themes.count, 45, "the app bundles the shared themes.json")
        XCTAssertFalse(store.darkThemes.isEmpty)
        XCTAssertFalse(store.lightThemes.isEmpty)
    }

    func testAutomaticFollowsTheSystem() {
        let sandbox = Sandbox()
        let store = AppearanceStore(themesData: Sandbox.themes, defaults: sandbox.defaults, systemIsDark: true)
        XCTAssertTrue(store.isAutomatic)
        XCTAssertNil(store.fixedColorScheme, "Automatic leaves the system in charge")
        XCTAssertEqual(store.resolvedTheme.id, ThemeCatalog.defaultID)
        store.setSystemIsDark(false)
        XCTAssertEqual(store.resolvedTheme.id, ThemeCatalog.lightDefaultID)
        XCTAssertEqual(store.palette, AppPalette.derive(from: store.resolvedTheme))
    }

    func testAChosenThemeIsKeptAndForcesItsAppearance() throws {
        let sandbox = Sandbox()
        let store = AppearanceStore(themesData: Sandbox.themes, defaults: sandbox.defaults)
        let light = try XCTUnwrap(store.lightThemes.first { $0.id != ThemeCatalog.lightDefaultID })
        store.select(light.id)
        XCTAssertEqual(store.resolvedTheme, light)
        XCTAssertEqual(store.fixedColorScheme, .light)
        store.setSystemIsDark(true)
        XCTAssertEqual(store.resolvedTheme, light, "a fixed theme ignores the system")
        XCTAssertEqual(AppearanceStore(themesData: Sandbox.themes, defaults: sandbox.defaults).selectionID, light.id, "saved")
    }

    func testAMissingOrBrokenThemeFileFallsBackAndSaysSo() {
        let sandbox = Sandbox()
        sandbox.defaults.set("no-such-theme", forKey: AppearanceStore.selectionKey)
        let ok = AppearanceStore(themesData: Sandbox.themes, defaults: sandbox.defaults)
        XCTAssertTrue(ok.isAutomatic, "an unknown saved id becomes Automatic")
        let broken = AppearanceStore(themesData: Data("{".utf8), defaults: sandbox.defaults)
        XCTAssertNotNil(broken.themeError)
        XCTAssertEqual(broken.themes, [AppearanceStore.fallback])
        XCTAssertEqual(broken.fixedColorScheme, .dark, "the fallback is dark, so system controls are forced to match")
    }
}

@MainActor
final class ReadOnlyTests: XCTestCase {
    func testTheSwitchReachesThePolicyAndIsSaved() throws {
        let sandbox = Sandbox()
        let safety = SafetyStore(defaults: sandbox.defaults)
        XCTAssertFalse(safety.readOnly)
        let intent = Intent(summary: "Restart", command: "docker restart abc", risk: .mutate)
        let confirmation = try safety.policy.confirm(intent)
        safety.setReadOnly(true)
        XCTAssertTrue(safety.policy.isReadOnly)
        XCTAssertThrowsError(try safety.policy.authorize(intent, with: confirmation), "checked again at run time")
        XCTAssertTrue(SafetyStore(defaults: sandbox.defaults).readOnly, "saved")
        safety.setReadOnly(false)
        XCTAssertNoThrow(try safety.policy.authorize(intent, with: confirmation))
    }
}

@MainActor
final class SavedServersTests: XCTestCase {
    private func draft(_ host: String, name: String = "", user: String = "", port: String = "") -> ServersModel.Draft {
        var d = ServersModel.Draft()
        d.host = host
        d.name = name
        d.user = user
        d.port = port
        return d
    }

    func testAddEditRemoveAreSaved() throws {
        let sandbox = Sandbox()
        let app = sandbox.app()
        XCTAssertNil(app.servers.add(draft("box.tailnet.ts.net", name: "Box", user: "admin", port: "2222")))
        XCTAssertNil(app.servers.add(draft("10.0.0.5")))
        let reloaded = ServersModel(store: ServerStore(directory: sandbox.directory))
        XCTAssertEqual(reloaded.servers.map(\.name), ["Box", "10.0.0.5"], "an empty name becomes the host")
        let box = try XCTUnwrap(reloaded.servers.first)
        XCTAssertEqual(box.addressLine, "admin@box.tailnet.ts.net:2222")

        XCTAssertNil(app.update(id: box.id, with: draft("box.tailnet.ts.net", name: "Renamed", user: "admin", port: "2222")))
        XCTAssertEqual(app.servers.server(id: box.id)?.name, "Renamed")
        XCTAssertEqual(app.servers.server(id: box.id)?.port, 2222)

        app.remove(id: box.id)
        XCTAssertEqual(ServersModel(store: ServerStore(directory: sandbox.directory)).servers.map(\.name), ["10.0.0.5"])
    }

    func testBadInputIsRefusedWithTheSharedRules() {
        let app = Sandbox().app()
        XCTAssertEqual(app.servers.add(draft("")), "A host is needed.")
        XCTAssertNotNil(app.servers.add(draft("-oProxyCommand=x")), "a host can't become an ssh option")
        XCTAssertNotNil(app.servers.add(draft("box", user: "a b")))
        XCTAssertNotNil(app.servers.add(draft("box", port: "70000")))
        XCTAssertTrue(app.servers.servers.isEmpty)
        XCTAssertNil(draft("box", port: "22").applied(to: nil).port, "the default port is not stored")
    }

    func testReorderAndSearch() {
        let app = Sandbox().app()
        for host in ["alpha", "bravo", "charlie"] { app.servers.add(draft(host)) }
        app.servers.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(app.servers.servers.map(\.host), ["charlie", "alpha", "bravo"])
        app.servers.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(app.servers.servers.map(\.host), ["alpha", "bravo", "charlie"])
        XCTAssertEqual(app.servers.filtered("brav").map(\.host), ["bravo"])
        XCTAssertEqual(app.servers.filtered("").count, 3)
    }
}

@MainActor
final class HostTrustTests: XCTestCase {
    private let key = HostKeyInfo(openSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEyGyUFkH3BGs3cx7DNxG9/1PKihMHs6TGgFyU01Qpz9")!
    private var other: HostKeyInfo {
        var blob = key.blob
        blob[blob.startIndex + 20] ^= 1
        return HostKeyInfo(keyType: key.keyType, blob: blob)
    }

    private func model(presenting presented: HostKeyInfo, store: InMemoryKnownHosts = InMemoryKnownHosts()) -> HostTrustModel {
        HostTrustModel(knownHosts: store, scan: { _, _ in presented })
    }

    func testFirstContactAsksAndTrustsExactlyTheKeyShown() async {
        let trust = model(presenting: key)
        let server = Server(name: "box", host: "box", port: 2222)
        XCTAssertEqual(trust.state(for: server), .unchecked)
        await trust.check(server)
        XCTAssertEqual(trust.state(for: server), .unknown(key))
        XCTAssertFalse(trust.trust(other, for: server), "only the key the user saw can be trusted")
        XCTAssertTrue(trust.trust(key, for: server))
        guard case .trusted(let saved) = trust.state(for: server) else { return XCTFail("not trusted") }
        XCTAssertEqual(saved.fingerprint, key.fingerprint)
        XCTAssertNotNil(trust.knownHosts.lookup(host: "box", port: 2222))
        XCTAssertNil(trust.knownHosts.lookup(host: "box", port: 22), "trust is per host and port")
    }

    /// The sheet's Trust works even if a re-check started meanwhile: it trusts the key last read, not the screen's state.
    func testTrustingWhileARecheckRunsStillTrustsTheShownKey() async {
        let calls = Counter()
        let shown = key
        let trust = HostTrustModel(knownHosts: InMemoryKnownHosts(), scan: { _, _ in
            if calls.next() == 1 { return shown }
            throw EmbeddedSSHError.unreachable("timed out")
        })
        let server = Server(name: "box", host: "box")
        await trust.check(server)
        await trust.check(server)
        guard case .failed = trust.state(for: server) else { return XCTFail("the second check failed") }
        XCTAssertTrue(trust.trust(key, for: server))
        XCTAssertNotNil(trust.knownHosts.lookup(host: "box", port: 22))
    }

    func testAChangedKeyIsBlockedAndCannotBeTrusted() async {
        let store = InMemoryKnownHosts()
        store.trust(host: "box", port: 22, key: key)
        let trust = model(presenting: other, store: store)
        let server = Server(name: "box", host: "box")
        await trust.check(server)
        guard case .changed(let trusted, let presented) = trust.state(for: server) else { return XCTFail("must be blocked") }
        XCTAssertEqual(trusted.fingerprint, key.fingerprint)
        XCTAssertEqual(presented, other)
        XCTAssertFalse(trust.trust(other, for: server), "a changed key is never offered for acceptance")
        XCTAssertEqual(store.lookup(host: "box", port: 22)?.fingerprint, key.fingerprint, "the trusted key is untouched")
    }

    func testAnUnreachableServerSaysWhy() async {
        let trust = HostTrustModel(knownHosts: InMemoryKnownHosts(), scan: { _, _ in throw EmbeddedSSHError.unreachable("timed out") })
        let server = Server(name: "box", host: "box")
        await trust.check(server)
        guard case .failed(let message) = trust.state(for: server) else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.contains("timed out"))
    }

    func testTrustedKeysAreSavedBesideTheServers() async {
        let sandbox = Sandbox()
        let app = sandbox.app()
        XCTAssertTrue(app.trust.knownHosts is JSONFileKnownHosts)
        app.trust.knownHosts.trust(host: "box", port: 22, key: key)
        let again = sandbox.app()
        XCTAssertNotNil(again.trust.knownHosts.lookup(host: "box", port: 22))
    }
}

@MainActor
final class DemoModeTests: XCTestCase {
    func testDemoShowsTheSharedDemoServersAndAnswersWithoutANetwork() async throws {
        let sandbox = Sandbox()
        let app = sandbox.app(demo: true)
        XCTAssertEqual(app.servers.servers.map(\.name), ["homelab", "garage-nuc"])
        let homelab = app.servers.servers[0]
        XCTAssertEqual(app.trust.state(for: homelab), .demo)
        app.fleet.attach(homelab.id, fast: true)
        await app.fleet.refresh(homelab.id)
        try await waitUntil { app.fleet.states[homelab.id]?.overview?.hostname == "homelab" }
        XCTAssertFalse(app.fleet.state(for: homelab.id).attention.isEmpty, "the demo shows the attention strip")
        app.fleet.detach(homelab.id, fast: true)
    }

    func testSwitchingDemoOffBringsBackTheRealListUntouched() {
        let sandbox = Sandbox()
        let app = sandbox.app()
        var d = ServersModel.Draft()
        d.host = "real.example"
        app.servers.add(d)
        app.setDemo(true)
        XCTAssertTrue(app.isDemo)
        XCTAssertEqual(app.servers.servers.count, 2)
        var extra = ServersModel.Draft()
        extra.host = "added-in-demo"
        app.servers.add(extra)
        app.setDemo(false)
        XCTAssertEqual(app.servers.servers.map(\.host), ["real.example"], "demo changes never reach servers.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.directory.appendingPathComponent("known_hosts.json").path))
    }
}

/// Waits (briefly) for something the fleet's listener task delivers on the main actor.
@MainActor
func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw WaitTimeout() }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

struct WaitTimeout: Error, CustomStringConvertible {
    var description: String { "the condition did not become true in time" }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}
