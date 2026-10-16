import Foundation
@testable import RackoonSSHEmbedded
import XCTest

/// The same cases as Android's HostKeyTests and KeyLoadingTests, on the same ssh-keygen keys
/// (android/ssh/src/test/resources/keys), so both transports judge keys alike.
final class HostKeyTests: XCTestCase {
    private let ed25519 = HostKeyInfo(openSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEyGyUFkH3BGs3cx7DNxG9/1PKihMHs6TGgFyU01Qpz9")!

    private func flipped(_ info: HostKeyInfo, at index: Int) -> HostKeyInfo {
        var blob = info.blob
        blob[blob.startIndex + index] ^= 1
        return HostKeyInfo(keyType: info.keyType, blob: blob)
    }

    func testFingerprintMatchesSshKeygen() {
        XCTAssertEqual(ed25519.fingerprint, "SHA256:XJxmt/YQHgzloTSoo+L3aRByH4hKuQjhvNTee3Su76o")
        XCTAssertEqual(ed25519.algorithmLabel, "Ed25519")
    }

    func testReadsAKeyLineWithACommentOrALineEnd() {
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEyGyUFkH3BGs3cx7DNxG9/1PKihMHs6TGgFyU01Qpz9"
        XCTAssertEqual(HostKeyInfo(openSSH: line + "\n"), ed25519)
        XCTAssertEqual(HostKeyInfo(openSSH: line + " root@box\n"), ed25519)
        XCTAssertNil(HostKeyInfo(openSSH: "ssh-ed25519"))
        XCTAssertNil(HostKeyInfo(openSSH: "ssh-ed25519 not*base64"))
    }

    func testVerdictsTellUnknownTrustedAndChangedApart() {
        let store = InMemoryKnownHosts()
        XCTAssertEqual(store.verdict(host: "h", port: 22, presented: ed25519), .unknown(presented: ed25519))
        store.trust(host: "h", port: 22, key: ed25519)
        XCTAssertEqual(store.verdict(host: "h", port: 22, presented: ed25519), .trusted)
        XCTAssertEqual(store.verdict(host: "H", port: 22, presented: ed25519), .trusted, "host names compare case-insensitively")
        XCTAssertEqual(store.verdict(host: "h", port: 2222, presented: ed25519), .unknown(presented: ed25519), "another port is another server")
        let changed = flipped(ed25519, at: 10)
        guard case .changed(let trusted, let presented) = store.verdict(host: "h", port: 22, presented: changed) else {
            return XCTFail("a different key must be reported as changed")
        }
        XCTAssertEqual(trusted.fingerprint, ed25519.fingerprint)
        XCTAssertEqual(presented, changed)
        store.forget(host: "h", port: 22)
        XCTAssertEqual(store.verdict(host: "h", port: 22, presented: changed), .unknown(presented: changed))
    }

    func testJSONStoreSurvivesARestartAndIgnoresACorruptFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rk-kh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("known_hosts.json")
        JSONFileKnownHosts(url: url).trust(host: "box", port: 22, key: ed25519)
        XCTAssertEqual(JSONFileKnownHosts(url: url).verdict(host: "box", port: 22, presented: ed25519), .trusted)
        try Data("{not json".utf8).write(to: url)
        XCTAssertNil(JSONFileKnownHosts(url: url).lookup(host: "box", port: 22))
    }
}

final class KeyLoadingTests: XCTestCase {
    private func key(_ name: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent("android/ssh/src/test/resources/keys/\(name)"), encoding: .utf8)
    }

    private func detail(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch EmbeddedSSHError.authFailed(let detail) {
            return detail
        } catch {
            return "unexpected \(error)"
        }
    }

    func testLoadsAnUnencryptedEd25519Key() throws {
        let key = try SSHKeys.load(try key("t_ed25519"), passphrase: nil)
        XCTAssertTrue(String(openSSHPublicKey: key.publicKey).hasPrefix("ssh-ed25519 "))
    }

    func testLoadsAnEncryptedKeyWithTheRightPassphrase() throws {
        _ = try SSHKeys.load(try key("t_ed25519_pass"), passphrase: "correct horse")
    }

    func testAnEncryptedKeyWithoutOrWithAWrongPassphraseIsExplained() throws {
        let text = try key("t_ed25519_pass")
        XCTAssertTrue(detail { _ = try SSHKeys.load(text, passphrase: nil) }?.contains("passphrase") == true)
        XCTAssertTrue(detail { _ = try SSHKeys.load(text, passphrase: "nope") }?.contains("passphrase") == true)
    }

    func testRSAAndECDSAAreRefusedInPlainWords() throws {
        // Not yet supported on this transport (docs/ios-spikes.md); Android loads both.
        XCTAssertTrue(detail { _ = try SSHKeys.load(try key("t_rsa"), passphrase: nil) }?.contains("not supported") == true)
        XCTAssertNotNil(detail { _ = try SSHKeys.load(try key("t_ecdsa"), passphrase: nil) })
    }

    func testAPublicKeyOrRandomTextIsExplained() {
        XCTAssertTrue(detail { _ = try SSHKeys.load("ssh-ed25519 AAAAC3Nza test", passphrase: nil) }?.contains("public key") == true)
        XCTAssertTrue(detail { _ = try SSHKeys.load("hello", passphrase: nil) }?.contains("not a private key") == true)
    }
}
