import Foundation
import XCTest
@testable import RackoonCore

final class SSHAttemptTests: XCTestCase {
    /// A real `ssh -v` transcript shape (OpenSSH 9/10): one default key on disk, one agent key with a comment that has
    /// spaces, the server accepting the file key and the login still failing (a passphrase nobody could type).
    private let transcript = """
        OpenSSH_10.0p2, LibreSSL 3.3.6
        debug1: Reading configuration data /etc/ssh/ssh_config
        debug1: Will attempt key: /Users/me/.ssh/id_rsa RSA SHA256:n5a8Q0Zq9fB6xYc1VhK2mD3pL4sT7uW8vJ0kA1bC2dE
        debug1: Will attempt key: work laptop ED25519 SHA256:Zr3m1cXy8qTl9vK0wNp2hJb4eGd6fA7sU5iO3lP1kM agent
        debug1: Will attempt key: /Users/me/.ssh/id_ecdsa
        debug1: Will attempt key: /Users/me/.ssh/id_ed25519
        debug1: Authentications that can continue: publickey,password
        debug1: Next authentication method: publickey
        debug1: Offering public key: /Users/me/.ssh/id_rsa RSA SHA256:n5a8Q0Zq9fB6xYc1VhK2mD3pL4sT7uW8vJ0kA1bC2dE
        debug1: Server accepts key: /Users/me/.ssh/id_rsa RSA SHA256:n5a8Q0Zq9fB6xYc1VhK2mD3pL4sT7uW8vJ0kA1bC2dE
        debug1: Offering public key: work laptop ED25519 SHA256:Zr3m1cXy8qTl9vK0wNp2hJb4eGd6fA7sU5iO3lP1kM agent
        debug1: Authentications that can continue: publickey,password
        debug1: Trying private key: /Users/me/.ssh/id_ecdsa
        debug1: Trying private key: /Users/me/.ssh/id_ed25519
        debug1: No more authentication methods to try.
        me@203.0.113.7: Permission denied (publickey,password).
        """

    func testParsesOfferedAcceptedAndMethods() {
        let attempt = SSHAttempt.parse(transcript)
        XCTAssertEqual(attempt.offered, ["/Users/me/.ssh/id_rsa (RSA)", "work laptop (ED25519, from ssh-agent)"],
                       "only keys that were sent count; 'Will attempt' and 'Trying private key' are not offers")
        XCTAssertEqual(attempt.accepted, ["/Users/me/.ssh/id_rsa (RSA)"])
        XCTAssertEqual(attempt.methods, ["publickey", "password"])
        XCTAssertEqual(attempt.problems, [])
    }

    func testDescribesKeysInEveryShapeSSHPrints() {
        XCTAssertEqual(SSHAttempt.describeKey("/Users/me/.ssh/id_rsa RSA SHA256:abc"), "/Users/me/.ssh/id_rsa (RSA)")
        XCTAssertEqual(SSHAttempt.describeKey("/Users/me/.ssh/deploy ED25519 SHA256:abc explicit"), "/Users/me/.ssh/deploy (ED25519)",
                       "'explicit' marks a -i key and is not part of the name")
        XCTAssertEqual(SSHAttempt.describeKey("work laptop ED25519 SHA256:abc agent"), "work laptop (ED25519, from ssh-agent)")
        XCTAssertEqual(SSHAttempt.describeKey("yubikey ED25519-SK SHA256:abc authenticator agent"), "yubikey (ED25519-SK, from ssh-agent)")
        XCTAssertEqual(SSHAttempt.describeKey("/Users/me/.ssh/id_ecdsa"), "/Users/me/.ssh/id_ecdsa", "no public key loaded: file name only")
    }

    func testCollectsKeyFileProblemsAndNothingElse() {
        let attempt = SSHAttempt.parse("""
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            @         WARNING: UNPROTECTED PRIVATE KEY FILE!          @
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            Permissions 0644 for '/Users/me/.ssh/loose' are too open.
            Load key "/Users/me/.ssh/loose": bad permissions
            debug1: Authentications that can continue: publickey
            me@host: Permission denied (publickey).
            """)
        XCTAssertEqual(attempt.problems, ["Permissions 0644 for '/Users/me/.ssh/loose' are too open.", "Load key \"/Users/me/.ssh/loose\": bad permissions"])
        XCTAssertEqual(attempt.offered, [])
        XCTAssertEqual(attempt.methods, ["publickey"])
    }

    func testEmptyOutputIsAnEmptyAttempt() {
        XCTAssertEqual(SSHAttempt.parse(""), SSHAttempt())
    }
}

final class ConnectionFailureTests: XCTestCase {
    func testAuthRefusedWithoutDiagnosisExplainsTheRules() throws {
        let f = try XCTUnwrap(ConnectionFailure.explain("me@203.0.113.7: Permission denied (publickey).\n"))
        XCTAssertEqual(f.kind, .authRefused)
        XCTAssertTrue(f.advice.contains("never asks for a password"))
        XCTAssertTrue(f.advice.contains("Edit Connection"))
    }

    func testAuthRefusedNamesTheKeysThatWereOffered() throws {
        let attempt = SSHAttempt(offered: ["/Users/me/.ssh/id_rsa (RSA)", "work laptop (ED25519, from ssh-agent)"], methods: ["publickey"])
        let f = try XCTUnwrap(ConnectionFailure.explain("Permission denied (publickey).", attempt: attempt))
        XCTAssertTrue(f.advice.contains("ssh offered /Users/me/.ssh/id_rsa (RSA) and work laptop (ED25519, from ssh-agent) and the server accepted none"), f.advice)
        XCTAssertFalse(f.advice.contains("password login"), "the server allows keys only, so password advice would mislead")
    }

    func testAuthRefusedWithAnAcceptedKeyPointsAtThePassphrase() throws {
        let attempt = SSHAttempt(offered: ["/Users/me/.ssh/id_rsa (RSA)"], accepted: ["/Users/me/.ssh/id_rsa (RSA)"], methods: ["publickey"])
        let f = try XCTUnwrap(ConnectionFailure.explain("Permission denied (publickey).", attempt: attempt))
        XCTAssertTrue(f.advice.hasPrefix("The server accepts /Users/me/.ssh/id_rsa (RSA), but ssh could not use it."), f.advice)
        XCTAssertTrue(f.advice.contains("ssh-add"))
    }

    func testAuthRefusedWithNoKeyAtAllSaysSo() throws {
        let f = try XCTUnwrap(ConnectionFailure.explain("Permission denied (publickey).", attempt: SSHAttempt(methods: ["publickey"])))
        XCTAssertTrue(f.advice.hasPrefix("ssh had no key to offer"), f.advice)
    }

    func testAuthRefusedMentionsPasswordLoginOnlyWhenTheServerAllowsIt() throws {
        let attempt = SSHAttempt(offered: ["/Users/me/.ssh/id_rsa (RSA)"], methods: ["publickey", "password"], problems: ["Load key \"/Users/me/.ssh/x\": bad permissions"])
        let f = try XCTUnwrap(ConnectionFailure.explain("Permission denied (publickey,password).", attempt: attempt))
        XCTAssertTrue(f.advice.contains("password login, which Rackoon can't use"), f.advice)
        XCTAssertTrue(f.advice.contains("bad permissions"), "ssh's own key-file complaints are passed on")
    }

    func testNetworkFailuresAreExplained() {
        XCTAssertEqual(ConnectionFailure.explain("ssh: connect to host 192.168.6.157 port 22: No route to host")?.kind, .unreachable)
        XCTAssertEqual(ConnectionFailure.explain("ssh: connect to host x port 22: Operation timed out")?.kind, .unreachable)
        XCTAssertEqual(ConnectionFailure.explain("Timed out after 10s")?.kind, .unreachable, "the app's own timeout")
        XCTAssertEqual(ConnectionFailure.explain("ssh: connect to host x port 2222: Connection refused")?.headline, "Nothing accepts SSH at that address and port.")
        XCTAssertEqual(ConnectionFailure.explain("kex_exchange_identification: Connection closed by remote host")?.kind, .unreachable)
        XCTAssertEqual(ConnectionFailure.explain("ssh: Could not resolve hostname nas.local: nodename nor servname provided, or not known")?.kind, .unresolved)
    }

    func testUnknownMessagesGetNoExplanation() {
        XCTAssertNil(ConnectionFailure.explain("Command failed (exit 1)"))
        XCTAssertNil(ConnectionFailure.explain("The host key for x has changed since you last connected."))
    }

    func testList() {
        XCTAssertEqual(ConnectionFailure.list([]), "")
        XCTAssertEqual(ConnectionFailure.list(["a"]), "a")
        XCTAssertEqual(ConnectionFailure.list(["a", "b"]), "a and b")
        XCTAssertEqual(ConnectionFailure.list(["a", "b", "c"]), "a, b and c")
    }
}

final class ServerInputTests: XCTestCase {
    private func problem(host: String = "vps.example.com", user: String = "", port: String = "", key: String = "",
                         exists: Bool = true) -> String? {
        ServerInput.problem(host: host, user: user, port: port, identityFile: key, fileExists: { _ in exists })
    }

    func testGoodInputHasNoProblem() {
        XCTAssertNil(problem())
        XCTAssertNil(problem(host: " vps ", user: "root", port: "2222", key: "~/.ssh/deploy"))
    }

    func testHostAndUserCannotBecomeSSHOptions() {
        XCTAssertEqual(problem(host: ""), "A host is needed.")
        XCTAssertEqual(problem(host: "-oProxyCommand=evil"), "A host can't start with a dash.")
        XCTAssertEqual(problem(host: "two words"), "A host can't contain spaces.")
        XCTAssertEqual(problem(user: "-v"), "A user name can't start with a dash.")
        XCTAssertEqual(problem(user: "me@there"), "A user name can't contain spaces or @.")
    }

    func testPortMustBeInRange() {
        XCTAssertNotNil(problem(port: "0"))
        XCTAssertNotNil(problem(port: "65536"))
        XCTAssertNotNil(problem(port: "ssh"))
        XCTAssertNil(problem(port: " 22 "))
    }

    func testKeyFileMustBeAReadablePrivateKey() {
        XCTAssertEqual(problem(key: "~/.ssh/id_ed25519.pub"), "That is the public half of the key. Choose the private key file (the one without .pub).")
        XCTAssertEqual(problem(key: "~/.ssh/nothing", exists: false), "There is no readable file at ~/.ssh/nothing.")
        XCTAssertNil(problem(key: "", exists: false), "no key file is fine: ssh picks")
    }

    func testKeyFileCheckExpandsTilde() throws {
        var seen: String?
        _ = ServerInput.problem(host: "h", user: "", port: "", identityFile: "~/.ssh/k", fileExists: { seen = $0; return true })
        XCTAssertEqual(seen, NSString(string: "~/.ssh/k").expandingTildeInPath)
    }
}

/// The explanations for an embedded SSH client (iOS), from its own messages and the sign-in method in use.
final class EmbeddedConnectionFailureTests: XCTestCase {
    private func explain(_ raw: String, _ signIn: SignInMethod? = nil) -> ConnectionFailure? {
        ConnectionFailure.explain(raw, signIn: signIn, device: "iPhone")
    }

    func testARefusedLoginIsExplainedFromTheSignInMethod() throws {
        let raw = "Sign-in was refused: the server refused it (it accepts: publickey)"
        XCTAssertEqual(explain(raw, .tailscale)?.kind, .authRefused)
        XCTAssertTrue(try XCTUnwrap(explain(raw, .tailscale)).advice.contains("Tailscale SSH did not let this user in"))
        XCTAssertTrue(try XCTUnwrap(explain(raw, .key)).advice.contains("authorized_keys"))
        XCTAssertTrue(try XCTUnwrap(explain(raw, .password)).advice.contains("PasswordAuthentication no"))
        XCTAssertTrue(try XCTUnwrap(explain(raw)).advice.contains("sign-in method"))
    }

    func testNetworkFailures() {
        XCTAssertEqual(explain("Could not reach the server: Unable to resolve host box.tailnet.ts.net")?.kind, .unresolved)
        XCTAssertEqual(explain("Could not reach the server: connect(descriptor:addr:size:): Connection refused (errno: 61)")?.headline,
                       "Nothing accepts SSH at that address and port.")
        XCTAssertEqual(explain("Connection lost: the server closed the connection")?.headline, "The server dropped the connection.")
        XCTAssertEqual(explain("Could not reach the server: timed out")?.headline, "Can't reach the server.")
        XCTAssertEqual(explain("Could not reach the server: connect(descriptor:addr:size:): No route to host (errno: 65)")?.kind, .unreachable)
    }

    func testTheDeviceIsNamedAndUnknownTextIsLeftAlone() throws {
        XCTAssertTrue(try XCTUnwrap(ConnectionFailure.explain("Could not reach the server: timed out", signIn: nil, device: "iPad")).advice.contains("this iPad"))
        XCTAssertNil(explain("Command failed (exit 2)"))
        XCTAssertNil(explain(""))
    }

    func testTheMacExplanationIsUnchanged() {
        // The OpenSSH wording still goes through the Mac's own rules.
        XCTAssertEqual(ConnectionFailure.explain("user@host: Permission denied (publickey).")?.kind, .authRefused)
        XCTAssertTrue(ConnectionFailure.explain("user@host: Permission denied (publickey).")?.advice.contains("ssh") == true)
    }
}
