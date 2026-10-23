import Foundation
import RackoonCore
import RackoonDemo
import RackoonSSHEmbedded
@testable import RackoonIOS
import XCTest

/// Answers the overview command with the demo's reading, or fails with a given error; counts what it was asked.
private final class ScriptedTransport: SSHTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Error?
    private(set) var runs = 0
    private let demo = DemoTransport(profile: .homelab)

    init(failure: Error? = nil) { self.failure = failure }

    func fail(with error: Error?) { lock.withLock { failure = error } }

    func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        let error: Error? = lock.withLock { runs += 1; return failure }
        if let error { throw error }
        return try await demo.run(command, timeout: timeout)
    }

    func stream(_ command: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
}

@MainActor
final class FleetTests: XCTestCase {
    private var sandbox: Sandbox!
    private var store: ServerStore!
    private let server = Server(id: "s1", name: "box", host: "box.example")

    override func setUp() async throws {
        sandbox = Sandbox()
        store = ServerStore(directory: sandbox.directory)
        try FileManager.default.createDirectory(at: sandbox.directory, withIntermediateDirectories: true)
        try store.saveServers([server])
    }

    private func fleet(_ transport: SSHTransport, trusted: Bool = true) -> FleetModel {
        let server = self.server
        return FleetModel(.init(transport: { _ in .success(transport) }, gate: { _ in trusted ? .open : .blocked("The host key is not trusted yet.") },
                                store: store, server: { $0 == server.id ? server : nil }))
    }

    func testAWatchedServerIsPolledAndItsReadingSavedAsTheSnapshot() async throws {
        let transport = ScriptedTransport()
        let fleet = fleet(transport)
        XCTAssertNil(fleet.state(for: "s1").overview)
        fleet.attach("s1", fast: true)
        XCTAssertEqual(fleet.isFast("s1"), true)
        try await waitUntil { fleet.states["s1"]?.overview != nil && fleet.states["s1"]?.isStale == false }
        XCTAssertEqual(fleet.state(for: "s1").overview?.hostname, "homelab")
        XCTAssertNotNil(store.loadSnapshot(serverID: "s1"), "each good reading is saved")
        XCTAssertEqual(fleet.history["s1"]?.samples.last?.up, true)
        fleet.detach("s1", fast: true)
        XCTAssertTrue(fleet.pollingIDs.isEmpty, "nothing is polled once no screen watches it")
    }

    func testTheSavedSnapshotIsPaintedFirstAndMarkedStale() async throws {
        let overview = try OverviewParser.parse(try await DemoTransport(profile: .nuc).run(ServerSession.overviewCommand, timeout: 5).stdout)
        try store.saveSnapshot(overview, serverID: "s1", at: Date(timeIntervalSinceNow: -3600))
        let fleet = fleet(ScriptedTransport(failure: EmbeddedSSHError.unreachable("timed out")))
        let cached = fleet.state(for: "s1")
        XCTAssertEqual(cached.overview?.hostname, "garage-nuc")
        XCTAssertTrue(cached.isStale)
        XCTAssertEqual(Liveness(cached), .unknown, "a saved reading is not shown as answering")
        XCTAssertTrue(Present.freshness(cached, now: Date()).hasPrefix("Saved reading from"))
    }

    func testAFailedPollKeepsTheLastReadingAndIsExplained() async throws {
        let transport = ScriptedTransport()
        let fleet = fleet(transport)
        fleet.attach("s1", fast: true)
        try await waitUntil { fleet.states["s1"]?.overview != nil && fleet.states["s1"]?.isStale == false }
        transport.fail(with: EmbeddedSSHError.authFailed("the server refused it (it accepts: publickey)"))
        await fleet.refresh("s1")
        try await waitUntil { fleet.states["s1"]?.error != nil }
        let state = fleet.state(for: "s1")
        XCTAssertNotNil(state.overview, "the last good data stays on screen")
        XCTAssertEqual(Liveness(state), .down)
        XCTAssertEqual(fleet.history["s1"]?.samples.last?.up, false)
        let failure = ConnectionFailure.explain(state.error ?? "", signIn: .key, device: "iPhone")
        XCTAssertEqual(failure?.kind, .authRefused)
        fleet.detach("s1", fast: true)
    }

    func testAnUntrustedServerIsNeverPolled() async throws {
        let transport = ScriptedTransport()
        let fleet = fleet(transport, trusted: false)
        fleet.attach("s1", fast: true)
        await fleet.refresh("s1")
        XCTAssertTrue(fleet.pollingIDs.isEmpty)
        XCTAssertEqual(fleet.blocked["s1"], "The host key is not trusted yet.")
        XCTAssertEqual(transport.runs, 0, "nothing was sent")
    }

    func testAServerNotCheckedYetIsCheckedFirstThenPolled() async throws {
        let transport = ScriptedTransport()
        let server = self.server
        let gate = GateBox(.needsCheck)
        let fleet = FleetModel(.init(transport: { _ in .success(transport) }, gate: { _ in gate.value },
                                     checkHostKey: { _ in gate.value = .open }, store: store, server: { $0 == server.id ? server : nil }))
        fleet.attach("s1", fast: false)
        try await waitUntil { fleet.pollingIDs.contains("s1") }
        try await waitUntil { fleet.states["s1"]?.overview != nil }
        fleet.detach("s1", fast: false)
    }

    func testAChangedHostKeyStopsPollingAndAsksForACheck() async throws {
        let transport = ScriptedTransport()
        let server = self.server
        let gate = GateBox(.open)
        let checks = Counter()
        let fleet = FleetModel(.init(transport: { _ in .success(transport) }, gate: { _ in gate.value },
                                     checkHostKey: { _ in _ = checks.next(); gate.value = .blocked("changed") },
                                     store: store, server: { $0 == server.id ? server : nil }))
        fleet.attach("s1", fast: true)
        try await waitUntil { fleet.states["s1"]?.overview != nil && fleet.states["s1"]?.isStale == false }
        transport.fail(with: EmbeddedSSHError.hostKeyChanged(trusted: TrustedHostKey(HostKeyInfo(keyType: "ssh-ed25519", blob: Data([1]))),
                                                             presented: HostKeyInfo(keyType: "ssh-ed25519", blob: Data([2]))))
        await fleet.refresh("s1")
        try await waitUntil { fleet.blocked["s1"] == "changed" }
        XCTAssertTrue(fleet.pollingIDs.isEmpty, "nothing more is sent to a server whose key changed")
        XCTAssertEqual(checks.next(), 2, "the key was checked once")
        fleet.detach("s1", fast: true)
    }

    func testOverviewPollsFastAndTheDashboardSlowlyAndTheBackgroundNotAtAll() async throws {
        let fleet = fleet(ScriptedTransport())
        fleet.attach("s1", fast: false)
        XCTAssertEqual(fleet.isFast("s1"), false)
        fleet.attach("s1", fast: true)
        XCTAssertEqual(fleet.isFast("s1"), true, "an open Overview wins")
        fleet.detach("s1", fast: true)
        XCTAssertEqual(fleet.isFast("s1"), false, "back to the dashboard's minute")
        fleet.pause()
        XCTAssertTrue(fleet.pollingIDs.isEmpty)
        fleet.resume()
        XCTAssertEqual(fleet.isFast("s1"), false)
        fleet.detach("s1", fast: false)
    }

    func testForgettingAServerDropsItsSnapshot() async throws {
        let fleet = fleet(ScriptedTransport())
        fleet.attach("s1", fast: true)
        try await waitUntil { self.store.loadSnapshot(serverID: "s1") != nil }
        fleet.forget("s1")
        XCTAssertNil(store.loadSnapshot(serverID: "s1"))
        XCTAssertNil(fleet.state(for: "s1").overview)
    }
}

@MainActor
final class SignInTests: XCTestCase {
    private func key(_ name: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent("android/ssh/src/test/resources/keys/\(name)"), encoding: .utf8)
    }

    func testTheMethodIsSavedAndTheSecretOnlyInTheSecretStore() throws {
        let sandbox = Sandbox()
        let file = sandbox.directory.appendingPathComponent("sign-in.json")
        let store = SignInStore(file: file, secrets: sandbox.secrets)
        XCTAssertEqual(store.method(for: "s1"), .tailscale, "Tailscale SSH is the default")
        if case .some(.none) = store.auth(for: "s1") {} else { XCTFail("Tailscale signs in with none") }

        try store.useKey(try key("t_ed25519_pass"), passphrase: "correct horse", for: "s1")
        XCTAssertEqual(SignInStore(file: file, secrets: sandbox.secrets).method(for: "s1"), .key, "saved")
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("PRIVATE KEY") || onDisk.contains("correct horse"), "no secret in sign-in.json")
        guard case .privateKey(_, let passphrase) = store.auth(for: "s1") else { return XCTFail("expected the key") }
        XCTAssertEqual(passphrase, "correct horse")

        try store.usePassword("hunter2", for: "s2")
        guard case .password(let pw) = store.auth(for: "s2") else { return XCTFail("expected the password") }
        XCTAssertEqual(pw, "hunter2")

        store.forget("s1")
        XCTAssertNil(try sandbox.secrets.read("s1"))
        XCTAssertEqual(store.method(for: "s1"), .tailscale)
    }

    func testABadKeyOrPassphraseIsRefusedBeforeAnythingIsSaved() throws {
        let sandbox = Sandbox()
        let store = SignInStore(file: nil, secrets: sandbox.secrets)
        XCTAssertThrowsError(try store.useKey(try key("t_ed25519_pass"), passphrase: "nope", for: "s1"))
        XCTAssertThrowsError(try store.useKey("ssh-ed25519 AAAA public", passphrase: nil, for: "s1"))
        XCTAssertEqual(store.method(for: "s1"), .tailscale)
        XCTAssertNil(try sandbox.secrets.read("s1"))
    }

    func testAMissingSecretBlocksPollingWithAReason() throws {
        let sandbox = Sandbox()
        let app = sandbox.app()
        app.servers.add({ var d = ServersModel.Draft(); d.host = "box"; return d }(), id: "s1")
        try app.signIn.usePassword("pw", for: "s1")
        try sandbox.secrets.delete("s1")
        guard case .failure(let reason) = app.transport(for: app.servers.servers[0]) else { return XCTFail("must not connect") }
        XCTAssertTrue(reason.message.contains("password is missing"))
    }

    func testTheFormKeepsASavedSecretUnlessANewOneIsTyped() {
        var draft = SignInDraft(saved: .key, hasSecret: true)
        XCTAssertNil(draft.problem)
        XCTAssertEqual(draft.choice, .keep)
        draft.method = .password
        XCTAssertNotNil(draft.problem, "switching to a password needs one")
        draft.password = "pw"
        XCTAssertEqual(draft.choice, .password("pw"))
        var fresh = SignInDraft()
        fresh.method = .key
        XCTAssertEqual(fresh.problem, "Choose the private key to sign in with.")
        fresh.keyText = "-----BEGIN OPENSSH PRIVATE KEY-----"
        XCTAssertEqual(fresh.choice, .key("-----BEGIN OPENSSH PRIVATE KEY-----", passphrase: nil))
    }

    /// The real Keychain, where the test host may use it (a simulator build without signing may not have one).
    func testKeychainRoundTrip() throws {
        let store = KeychainSecretStore(service: "com.bgallagher.rackoon.tests.\(UUID().uuidString)")
        do {
            try store.write(Data("secret".utf8), for: "a")
        } catch SecretStoreError.keychain(let status) where status == errSecMissingEntitlement {
            throw XCTSkip("no Keychain access for this unsigned test host")
        }
        XCTAssertEqual(try store.read("a"), Data("secret".utf8))
        try store.write(Data("other".utf8), for: "a")
        XCTAssertEqual(try store.read("a"), Data("other".utf8), "replacing works")
        try store.delete("a")
        XCTAssertNil(try store.read("a"))
    }
}

final class PresentTests: XCTestCase {
    func testUptimeAndFreshness() {
        XCTAssertEqual(Present.uptime(27 * 86400 + 9 * 3600 + 120), "27d 9h")
        XCTAssertEqual(Present.uptime(3 * 3600 + 12 * 60), "3h 12m")
        XCTAssertEqual(Present.uptime(45 * 60), "45m")
        var state = ServerState()
        XCTAssertEqual(Present.freshness(state, now: Date()), "Not read yet")
        let now = Date()
        state.updatedAt = now.addingTimeInterval(-3)
        state.overview = nil
        XCTAssertEqual(Present.freshness(state, now: now), "Live")
        state.updatedAt = now.addingTimeInterval(-125)
        XCTAssertEqual(Present.freshness(state, now: now), "Updated 2m ago")
    }

    func testTheServerClockShowsItsOwnZone() async throws {
        let overview = try OverviewParser.parse(try await DemoTransport(profile: .homelab).run(ServerSession.overviewCommand, timeout: 5).stdout)
        let polled = Date(timeIntervalSince1970: TimeInterval(overview.serverTime))
        let text = Present.serverClock(overview, polledAt: polled, now: polled.addingTimeInterval(61))
        XCTAssertTrue(text.contains("UTC+00:00"), text)
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "HH:mm:ss"
        XCTAssertTrue(text.contains(f.string(from: polled.addingTimeInterval(61))), "ticks on from the poll")
    }
}

@MainActor
final class GateBox {
    var value: FleetModel.Gate
    init(_ value: FleetModel.Gate) { self.value = value }
}
