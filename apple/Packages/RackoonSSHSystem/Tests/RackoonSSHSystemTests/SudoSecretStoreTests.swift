// Apple-only: the saved sudo password is sealed with the Secure Enclave (CryptoKit, LocalAuthentication). On Linux,
// where only the integration lab's tests build this module, it is left out.
#if canImport(CryptoKit) && canImport(LocalAuthentication)
import Foundation
import XCTest
import RackoonCore
@testable import RackoonSSHSystem

final class SudoSecretStoreTests: XCTestCase {
    private var dir: URL!
    private let server = Server(id: "940AE65F-4805-4CAA-ACB9-F6AB965FCC14", name: "lab", host: "192.168.6.8", user: "lab",
                                identityFile: "~/.ssh/id_rsa.pem")
    private let resolved = SSHResolved(user: "lab", hostname: "192.168.6.8", port: 22)
    private var scope: SudoSecretScope { SudoSecretScope(server: server, resolved: resolved) }

    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("rk-sudo-store-\(UUID().uuidString)/sudo") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    private func store(refuse: Bool = false) -> SudoSecretFileStore { SudoSecretFileStore(directory: dir, sealer: SoftwareSealer(refuse: refuse)) }
    private var file: URL { dir.appendingPathComponent("940AE65F-4805-4CAA-ACB9-F6AB965FCC14.json") }

    func testRoundTripIsPrivateAndNeverPlaintext() async throws {
        let s = store()
        XCTAssertFalse(s.isRemembered(serverID: server.id))
        try s.remember("correct horse battery", scope: scope)
        XCTAssertTrue(s.isRemembered(serverID: server.id))
        let got = try await s.secret(for: scope, reason: "test")
        XCTAssertEqual(got, "correct horse battery")
        let raw = try Data(contentsOf: file)
        XCTAssertNil(raw.range(of: Data("correct horse".utf8)), "never written in plain text")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testAChangedConnectionForgetsInsteadOfOpening() async throws {
        let s = store()
        try s.remember("pw", scope: scope)
        var moved = scope
        moved.destination = "lab@10.0.0.99"   // the saved connection details changed
        do { _ = try await s.secret(for: moved, reason: "test"); XCTFail() } catch { XCTAssertEqual(error as? SudoSecretError, .scopeChanged) }
        XCTAssertFalse(s.isRemembered(serverID: server.id), "forgotten, not kept for later")
    }

    func testOnlyANewResolutionRefusesButKeepsTheRecord() async throws {
        let s = store()
        try s.remember("pw", scope: scope)
        var elsewhere = scope
        elsewhere.resolved.hostname = "100.64.0.7"   // same saved details; ssh -G now answers differently
        do { _ = try await s.secret(for: elsewhere, reason: "test"); XCTFail() } catch { XCTAssertEqual(error as? SudoSecretError, .resolvedElsewhere) }
        XCTAssertTrue(s.isRemembered(serverID: server.id), "kept for when it resolves back")
        let back = try await s.secret(for: scope, reason: "test")
        XCTAssertEqual(back, "pw")
    }

    func testARecordCopiedToAnotherServerDoesNotOpen() async throws {
        let s = store()
        try s.remember("pw", scope: scope)
        let other = Server(id: "11111111-2222-3333-4444-555555555555", name: "other", host: "192.168.6.8", user: "lab",
                           identityFile: "~/.ssh/id_rsa.pem")
        // Rename the file and rewrite its visible scope: the sealed part still carries the first server's scope.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        var visible = json["scope"] as! [String: Any]
        visible["serverID"] = other.id
        json["scope"] = visible
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("\(other.id).json"))
        do { _ = try await s.secret(for: SudoSecretScope(server: other, resolved: resolved), reason: "test"); XCTFail() }
        catch { XCTAssertEqual(error as? SudoSecretError, .unreadable) }
        XCTAssertFalse(s.isRemembered(serverID: other.id))
        XCTAssertTrue(s.isRemembered(serverID: server.id), "the real record is untouched")
    }

    func testCancellingKeepsTheRecord() async throws {
        try store().remember("pw", scope: scope)
        do { _ = try await store(refuse: true).secret(for: scope, reason: "test"); XCTFail() }
        catch { XCTAssertEqual(error as? SudoSecretError, .cancelled) }
        XCTAssertTrue(store().isRemembered(serverID: server.id))
    }

    func testDamagedFilesCountAsNotRememberedAndForgetRemoves() async throws {
        let s = store()
        try s.remember("pw", scope: scope)
        try Data("{not json".utf8).write(to: file)
        XCTAssertFalse(s.isRemembered(serverID: server.id))
        do { _ = try await s.secret(for: scope, reason: "test"); XCTFail() } catch { XCTAssertEqual(error as? SudoSecretError, .notRemembered) }
        try s.remember("pw", scope: scope)
        s.forget(serverID: server.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try s.remember("pw", scope: scope)
        s.forgetAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testFileNamesCanNotEscapeTheFolder() throws {
        let s = store()
        let sneaky = Server(id: "../../etc/x", name: "x", host: "h")
        try s.remember("pw", scope: SudoSecretScope(server: sneaky, resolved: resolved))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("etcx.json").path))
    }
}

final class SSHResolvedTests: XCTestCase {
    func testParsesSshG() {
        let text = "user lab\nhostname 192.168.6.8\nport 2222\nidentityfile ~/.ssh/id_rsa\nbatchmode no\n"
        XCTAssertEqual(SSHResolved.parse(text), SSHResolved(user: "lab", hostname: "192.168.6.8", port: 2222))
        XCTAssertNil(SSHResolved.parse("user lab\nport 22\n"), "no hostname")
    }

    func testScopeEncodingIsStable() {
        let server = Server(id: "1", name: "a", host: "h", user: "u", port: 22)
        let a = SudoSecretScope(server: server, resolved: SSHResolved(user: "u", hostname: "h", port: 22))
        XCTAssertEqual(a.authenticatedData, SudoSecretScope(server: server, resolved: SSHResolved(user: "u", hostname: "h", port: 22)).authenticatedData)
        var renamed = server
        renamed.name = "renamed"
        XCTAssertEqual(SudoSecretScope(server: renamed, resolved: a.resolved), a, "a rename alone keeps the password")
    }

    func testResolveRunsTheRealSshG() async throws {
        let resolved = await OpenSSHTransport.resolve(Server(name: "x", host: "198.51.100.7", user: "probe", port: 2200))
        let r = try XCTUnwrap(resolved)
        XCTAssertEqual(r, SSHResolved(user: "probe", hostname: "198.51.100.7", port: 2200), "ssh -G applies settings without connecting")
    }
}
#endif
