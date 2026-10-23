import Foundation
import RackoonCore
@testable import RackoonIOS
import XCTest

/// The Keychain in memory: `approve` decides what Face ID / the passcode would answer.
final class MemorySudoKeychain: SudoKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: (password: Data, scope: Data)] = [:]
    var approve = true
    private(set) var prompts: [String] = []

    func save(password: Data, scope: Data, account: String) throws { lock.withLock { items[account] = (password, scope) } }
    func scope(account: String) -> Data? { lock.withLock { items[account]?.scope } }
    func password(account: String, prompt: String) async throws -> Data {
        try lock.withLock {
            prompts.append(prompt)
            guard approve else { throw SudoSecretError.cancelled }
            guard let item = items[account] else { throw SudoSecretError.notRemembered }
            return item.password
        }
    }
    func delete(account: String) { lock.withLock { items[account] = nil } }
    func deleteAll() { lock.withLock { items = [:] } }
}

private func aServer(_ host: String = "box.lan", id: String = "s1") -> Server {
    Server(id: id, name: "box", host: host, user: "andy")
}

@MainActor
final class SudoVaultTests: XCTestCase {
    func testAPasswordIsUsedOnlyForTheServerItWasSavedFor() async {
        let keychain = MemorySudoKeychain()
        let vault = SudoVault(store: KeychainSudoStore(keychain: keychain))
        XCTAssertTrue(vault.canRemember)
        vault.remember("hunter2", for: aServer())
        XCTAssertTrue(vault.isRemembered(aServer()))
        let unlocked = await vault.unlock(aServer(), reason: "Use it")
        XCTAssertEqual(try? unlocked.get(), "hunter2")
        XCTAssertEqual(keychain.prompts, ["Use it"], "every use asks Face ID / the passcode")

        // The server now points somewhere else: the password is forgotten, never typed there.
        let moved = aServer("elsewhere.lan")
        guard case .failure(.scopeChanged) = await vault.unlock(moved, reason: "Use it") else { return XCTFail() }
        XCTAssertFalse(vault.isRemembered(moved))
        XCTAssertEqual(keychain.prompts.count, 1, "no prompt for a password that will not be used")
    }

    func testCancellingFaceIDKeepsThePasswordAndRunsNothing() async {
        let keychain = MemorySudoKeychain()
        let vault = SudoVault(store: KeychainSudoStore(keychain: keychain))
        vault.remember("hunter2", for: aServer())
        keychain.approve = false
        guard case .failure(.cancelled) = await vault.unlock(aServer(), reason: "x") else { return XCTFail() }
        XCTAssertTrue(vault.isRemembered(aServer()))
        vault.forget(aServer().id)
        XCTAssertFalse(vault.isRemembered(aServer()))
        guard case .failure(.notRemembered) = await vault.unlock(aServer(), reason: "x") else { return XCTFail() }
    }

    func testNothingIsRememberedInDemoModeOrWithoutAStore() {
        let demo = SudoVault.system(demo: true)
        XCTAssertFalse(demo.canRemember)
        XCTAssertEqual(demo.unavailableReason, "demo mode")
        demo.remember("x", for: aServer())
        XCTAssertFalse(demo.isRemembered(aServer()))
    }

    func testRemovingOrMovingAServerForgetsItsPassword() {
        let sandbox = Sandbox()
        let keychain = MemorySudoKeychain()
        let app = sandbox.app(vault: SudoVault(store: KeychainSudoStore(keychain: keychain)))
        var d = ServersModel.Draft()
        d.host = "box.lan"
        app.servers.add(d)
        let s = app.servers.servers[0]
        app.vault.remember("pw", for: s)
        var renamed = ServersModel.Draft(s)
        renamed.name = "renamed"
        XCTAssertNil(app.update(id: s.id, with: renamed))
        XCTAssertTrue(app.vault.isRemembered(s), "a rename changes nothing")
        var moved = ServersModel.Draft(s)
        moved.host = "other.lan"
        XCTAssertNil(app.update(id: s.id, with: moved))
        XCTAssertFalse(app.vault.isRemembered(s), "a new address forgets it")
        app.vault.remember("pw", for: app.servers.servers[0])
        app.remove(id: s.id)
        XCTAssertNil(keychain.scope(account: s.id))
    }
}

/// apt answers from canned text; a streamed install prints what `stream` is set to.
private final class AptServer: SSHTransport, @unchecked Sendable {
    var streamText = "Reading package lists... Done\r\n##rackoon-exit:0\r\n"
    private(set) var streamed: [String] = []
    private(set) var typed: [String] = []
    func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        CommandResult(stdout: """
        ##apt
        ok
        ##upgradable
        Listing...
        zlib1g/noble-updates 1:1.3 amd64 [upgradable from: 1:1.2]
        openssl/noble-security 3.0.13-2 amd64 [upgradable from: 3.0.13-1]
        ##held
        ##refreshed
        \(Int(Date().timeIntervalSince1970) - 3600)
        ##reboot
        yes
        """)
    }
    func stream(_ command: String) -> AsyncThrowingStream<String, Error> {
        streamed.append(command)
        let text = streamText
        return AsyncThrowingStream { $0.yield(text); $0.finish() }
    }
    func stream(_ command: String, input: AsyncStream<String>) -> AsyncThrowingStream<String, Error> {
        streamed.append(command)
        let nonce = command.components(separatedBy: "##rackoon-sudo-").dropFirst().first.map { String($0.prefix(32)) } ?? ""
        return AsyncThrowingStream { c in
            Task {
                c.yield("##rackoon-sudo-\(nonce):")
                for await t in input { self.typed.append(t); break }
                c.yield("\r\n##rackoon-sudo-ok-\(nonce)\r\nDone\r\n##rackoon-exit:0\r\n")
                c.finish()
            }
        }
    }
}

@MainActor
final class UpdatesModelTests: XCTestCase {
    private func make(_ transport: AptServer, vault: SudoVault = SudoVault(store: nil), readOnly: Bool = false) -> UpdatesModel {
        let defaults = UserDefaults(suiteName: "updates-\(UUID().uuidString)")!
        let safety = SafetyStore(defaults: defaults)
        safety.setReadOnly(readOnly)
        let model = UpdatesModel(server: aServer(), transport: transport, safety: safety, vault: vault)
        model.sizeWait = 0
        return model
    }

    func testTheListPutsSecurityFirstAndInstallsAskWithTheExactCommand() async throws {
        let apt = AptServer()
        let model = make(apt)
        await model.load()
        XCTAssertEqual(model.packages.map(\.name), ["openssl", "zlib1g"])
        XCTAssertEqual(model.securityNames, ["openssl"])
        XCTAssertEqual(model.state.snapshot?.rebootRequired, true)
        model.request(.upgradeAll)
        let pending = try XCTUnwrap(model.pending)
        XCTAssertEqual(pending.command, AptAction.upgradeAll.intent?.command)
        XCTAssertEqual(pending.title, "Install all 2 updates?")
        pending.run()
        let output = try XCTUnwrap(model.output)
        try await waitUntil { !output.isRunning && model.working == nil }
        XCTAssertEqual(output.phase, .succeeded)
        XCTAssertNil(model.sudoRequest)
    }

    func testReadOnlyOffersNothing() async {
        let model = make(AptServer(), readOnly: true)
        await model.load()
        model.request(.upgradeAll)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.blockedReason, "Read-only mode is on")
    }

    func testWhenSudoWantsAPasswordTheSheetAsksAndTheSameActionRunsWithIt() async throws {
        let apt = AptServer()
        apt.streamText = "sudo: a password is required\r\n##rackoon-exit:1\r\n"
        let keychain = MemorySudoKeychain()
        let model = make(apt, vault: SudoVault(store: KeychainSudoStore(keychain: keychain)))
        await model.load()
        model.request(.refresh)
        model.pending?.run()
        try await waitUntil { model.sudoRequest != nil }
        let request = try XCTUnwrap(model.sudoRequest)
        XCTAssertTrue(request.command.contains("##rackoon-sudo-"), "the sheet shows the password variant's command")
        XCTAssertFalse(request.command.contains("hunter2"))
        request.submit("hunter2", true)
        try await waitUntil { model.working == nil && apt.typed.count == 1 && model.output?.isRunning == false }
        XCTAssertEqual(apt.typed, ["hunter2\n"], "typed once, at sudo's own prompt")
        try await waitUntil { model.vault_isRemembered(keychain) }
    }

    func testASavedPasswordIsConfirmedAsThePasswordCommand() async throws {
        let keychain = MemorySudoKeychain()
        let vault = SudoVault(store: KeychainSudoStore(keychain: keychain))
        vault.remember("hunter2", for: aServer())
        let apt = AptServer()
        let model = make(apt, vault: vault)
        await model.load()
        model.request(.upgradeAll)
        let pending = try XCTUnwrap(model.pending)
        XCTAssertTrue(pending.command.contains("##rackoon-sudo-"), "the confirm sheet shows the command that will really run")
        XCTAssertTrue(pending.message.contains("saved on this device"))
        pending.run()
        try await waitUntil { apt.typed == ["hunter2\n"] && model.working == nil }
        XCTAssertEqual(keychain.prompts.count, 1)
    }
}

extension UpdatesModel {
    /// Whether the password typed in a test ended up saved (for the server the tests use).
    func vault_isRemembered(_ keychain: MemorySudoKeychain) -> Bool { keychain.scope(account: server.id) != nil }
}

/// Reboot answers: a boot id that changes after the reboot, sudo that needs `password`, or none at all.
private final class RebootServer: SSHTransport, @unchecked Sendable {
    private let lock = NSLock()
    var needsSudo = false
    var password = "pw"
    private var rebooted = false
    func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        lock.withLock {
            if command == RebootSession.bootIDCommand { return CommandResult(stdout: rebooted ? "boot-2\n" : "boot-1\n") }
            if command == RebootSession.rebootCommand {
                if needsSudo { return CommandResult(stdout: "##no-sudo\n", exitCode: 5) }
                rebooted = true
                return CommandResult(stdout: "##rebooting\n")
            }
            return CommandResult(stdout: "", exitCode: 1)
        }
    }
    func run(_ command: String, input: String, timeout: TimeInterval) async throws -> CommandResult {
        lock.withLock {
            guard command == RebootSession.sudoRebootCommand else { return CommandResult(stdout: "", exitCode: 1) }
            guard input == password + "\n" else { return CommandResult(stdout: "", stderr: "Sorry, try again.\nsudo: 1 incorrect password attempt", exitCode: 1) }
            rebooted = true
            return CommandResult(stdout: "##rebooting\n")
        }
    }
    func stream(_ command: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
}

@MainActor
final class RebootFlowTests: XCTestCase {
    private func flow(_ transport: RebootServer, vault: SudoVault = SudoVault(store: nil)) -> RebootFlow {
        let f = RebootFlow(server: aServer(), transport: transport, policy: ActionPolicy(), vault: vault)
        f.interval = 0.02
        return f
    }

    func testARebootWaitsForANewBootID() async throws {
        let f = flow(RebootServer())
        var back = false
        f.onBack = { back = true }
        f.start()
        try await waitUntil(8) { if case .back = f.phase { true } else { false } }
        XCTAssertTrue(back, "the Overview is refreshed at once")
        XCTAssertFalse(f.isActive)
    }

    func testSudoAsksForThePasswordAndAWrongOneAsksAgain() async throws {
        let server = RebootServer()
        server.needsSudo = true
        let keychain = MemorySudoKeychain()
        let f = flow(server, vault: SudoVault(store: KeychainSudoStore(keychain: keychain)))
        f.start()
        try await waitUntil { f.phase == .needsPassword(problem: nil) }
        f.submitPassword("nope", remember: true)
        try await waitUntil { f.phase == .needsPassword(problem: RebootError.badPassword.errorDescription) }
        XCTAssertNil(keychain.scope(account: "s1"), "a refused password is never saved")
        f.submitPassword("pw", remember: true)
        try await waitUntil(8) { if case .back = f.phase { true } else { false } }
        XCTAssertNotNil(keychain.scope(account: "s1"), "saved once the server accepted it")
    }

    func testARejectedSavedPasswordIsForgottenAndTheSheetAsks() async throws {
        let server = RebootServer()
        server.needsSudo = true
        let keychain = MemorySudoKeychain()
        let vault = SudoVault(store: KeychainSudoStore(keychain: keychain))
        vault.remember("old-password", for: aServer())
        let f = flow(server, vault: vault)
        f.startWithSavedPassword()
        try await waitUntil { f.phase == .needsPassword(problem: "The saved sudo password was not accepted, so it was forgotten.") }
        XCTAssertFalse(vault.isRemembered(aServer()))
    }

    func testGivingUpLeavesTheServerRunning() async throws {
        let server = RebootServer()
        server.needsSudo = true
        let f = flow(server)
        f.start()
        try await waitUntil { f.phase == .needsPassword(problem: nil) }
        f.giveUp()
        XCTAssertEqual(f.phase, .failed("Not rebooted: no sudo password was given."))
    }

    func testTheRebootIsOfferedOnlyOutsideReadOnly() {
        let sandbox = Sandbox()
        let app = sandbox.app(demo: true)
        let homelab = app.servers.servers[0]
        let pending = app.rebootRequest(homelab)
        XCTAssertEqual(pending?.command, RebootSession.rebootCommand)
        XCTAssertEqual(pending?.destructive, true)
        app.safety.setReadOnly(true)
        XCTAssertNil(app.rebootRequest(homelab))
    }
}

@MainActor
final class DockerElevationTests: XCTestCase {
    func testUnlockingRebuildsDockerOnSudoAndLockingGoesBack() throws {
        let sandbox = Sandbox()
        let app = sandbox.app(demo: true)
        let homelab = app.servers.servers[0]
        guard case .success(let plain) = app.dockerModel(for: homelab) else { return XCTFail() }
        XCTAssertFalse(plain.transport is SudoTransport)
        app.elevation.unlock(homelab.id, password: "pw")
        XCTAssertNotNil(app.elevation.unlockedUntil(homelab.id))
        guard case .success(let elevated) = app.dockerModel(for: homelab) else { return XCTFail() }
        XCTAssertFalse(elevated === plain, "a model made before the unlock is stale")
        XCTAssertTrue(elevated.transport is SudoTransport)
        app.elevation.lock(homelab.id, reason: "done")
        XCTAssertEqual(app.elevation.lockReason[homelab.id], "done")
        guard case .success(let again) = app.dockerModel(for: homelab) else { return XCTFail() }
        XCTAssertFalse(again.transport is SudoTransport)
    }

    func testAnEditOrRemovalLocksDocker() {
        let sandbox = Sandbox()
        let app = sandbox.app(demo: true)
        let homelab = app.servers.servers[0]
        app.elevation.unlock(homelab.id, password: "pw")
        var moved = ServersModel.Draft(homelab)
        moved.host = "elsewhere.demo"
        XCTAssertNil(app.update(id: homelab.id, with: moved))
        XCTAssertFalse(app.elevation.isUnlocked(homelab.id))
        app.elevation.unlock(homelab.id, password: "pw")
        app.remove(id: homelab.id)
        XCTAssertFalse(app.elevation.isUnlocked(homelab.id))
    }
}
