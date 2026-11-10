import Foundation
import XCTest
@testable import RackoonCore

final class ElevationWindowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testUnlockLastsTheWindowAndNoLonger() {
        var w = ElevationWindow(length: 900)
        XCTAssertNil(w.active("a", at: t0))
        w.unlock("a", password: "pw", now: t0)
        XCTAssertEqual(w.active("a", at: t0.addingTimeInterval(899))?.password, "pw")
        XCTAssertNil(w.active("a", at: t0.addingTimeInterval(900)), "expired exactly at the end, never later")
        XCTAssertNil(w.active("b", at: t0), "per server")
        XCTAssertEqual(ElevationWindow.defaultLength, 15 * 60, "like sudo's own default")
    }

    func testLockForgetsThePasswordAndRecordsWhy() {
        var w = ElevationWindow()
        w.unlock("a", password: "pw", now: t0)
        w.lock("a", reason: "rejected")
        XCTAssertNil(w.active("a", at: t0))
        XCTAssertEqual(w.lockReasons["a"], "rejected")
        w.unlock("a", password: "pw2", now: t0)
        XCTAssertNil(w.lockReasons["a"], "a new unlock clears the old reason")
        XCTAssertEqual(w.active("a", at: t0)?.password, "pw2", "a new unlock replaces the old password")
    }

    func testGenerationChangesOnEveryRealChangeOnly() {
        var w = ElevationWindow()
        XCTAssertEqual(w.generation("a"), 0)
        w.lock("a", reason: "nothing to lock")
        XCTAssertEqual(w.generation("a"), 0, "locking what was not unlocked changes nothing")
        XCTAssertNil(w.lockReasons["a"])
        w.unlock("a", password: "pw", now: t0)
        XCTAssertEqual(w.generation("a"), 1)
        w.lock("a")
        XCTAssertEqual(w.generation("a"), 2, "views keyed by it rebuild their connections")
        XCTAssertEqual(w.generation("b"), 0)
    }

    func testTheChosenLengthOverridesTheDefault() {
        var w = ElevationWindow(length: 900)
        w.unlock("a", password: "pw", now: t0, lasting: .oneHour)
        XCTAssertNotNil(w.active("a", at: t0.addingTimeInterval(3599)))
        XCTAssertNil(w.active("a", at: t0.addingTimeInterval(3600)))
        w.unlock("b", password: "pw", now: t0, lasting: .untilQuit)
        XCTAssertEqual(w.active("b", at: t0.addingTimeInterval(365 * 86_400))?.lastsUntilQuit, true, "no end until the app quits")
        w.lock("b")
        XCTAssertNil(w.active("b", at: t0), "Lock still ends it at once")
        XCTAssertEqual(ElevationWindow.Lasting.standard, .fifteenMinutes, "the default stays like sudo's own")
        XCTAssertEqual(ElevationWindow.Lasting(rawValue: 0), .untilQuit)
        XCTAssertNil(ElevationWindow.Lasting.untilQuit.seconds)
    }
}

final class DockerAccessTests: XCTestCase {
    func testNotInstalledIsRecognisedOnlyFromItsOwnError() {
        XCTAssertTrue(DockerAccess.isNotInstalled(DockerParseError.notInstalled.errorDescription))
        XCTAssertFalse(DockerAccess.isNotInstalled(nil))
        XCTAssertFalse(DockerAccess.isNotInstalled("permission denied while trying to connect to the Docker daemon socket"))
    }

    func testRecognisesDockerSocketRefusals() throws {
        // Captured on Ubuntu 26.04 (minilab) and the older daemon wording in the spec fixture.
        XCTAssertTrue(DockerAccess.isPermissionProblem("permission denied while trying to connect to the docker API at unix:///var/run/docker.sock"))
        let fixture = try String(contentsOf: specDir.appendingPathComponent("fixtures/docker/synthetic-permission-denied.out.txt"), encoding: .utf8)
        do { _ = try DockerParser.parse(fixture); XCTFail("must not parse") } catch {
            let message = try XCTUnwrap((error as? LocalizedError)?.errorDescription)
            XCTAssertTrue(DockerAccess.isPermissionProblem(message))
        }
        XCTAssertFalse(DockerAccess.isPermissionProblem("Cannot connect to the Docker daemon. Is the docker daemon running?"))
        XCTAssertFalse(DockerAccess.isPermissionProblem("ssh: connect to host x port 22: Connection refused"))
    }

    /// The message must never push the user towards a server change (the docker group is root-equivalent).
    func testThePermissionMessageOffersSudoAndNeverAServerChange() throws {
        let text = try XCTUnwrap(DockerParseError.daemon("permission denied while trying to connect to the docker API at unix:///var/run/docker.sock").errorDescription)
        XCTAssertTrue(text.contains("sudo password"))
        for forbidden in ["usermod", "docker group", "gpasswd", "sudoers"] {
            XCTAssertFalse(text.lowercased().contains(forbidden), forbidden)
        }
    }
}

final class SudoAuthFailureTests: XCTestCase {
    func testOnlySudosOwnLinesCount() {
        XCTAssertTrue(SudoElevation.isSudoAuthFailure("sudo: Authentication failed, try again.\nsudo: Authentication required but not attempted\n"), "sudo-rs")
        XCTAssertTrue(SudoElevation.isSudoAuthFailure("Sorry, try again.\nsudo: 1 incorrect password attempt\n"), "classic sudo")
        XCTAssertFalse(SudoElevation.isSudoAuthFailure("Error response from daemon: unauthorized: authentication required\n"), "a registry, not sudo")
        XCTAssertFalse(SudoElevation.isSudoAuthFailure("pam_unix(sshd:auth): authentication failure; user=root\n"), "a log line, not sudo")
        XCTAssertFalse(SudoElevation.isSudoAuthFailure("sudo: unable to resolve host minilab\n"), "a sudo warning that is not a refusal")
    }
}

final class RebootOfferTests: XCTestCase {
    /// Reboot… is offered on exactly the server's reboot-required notice and nowhere else.
    func testRebootIsOfferedOnlyOnTheRebootRequiredItem() throws {
        let text = try String(contentsOf: specDir.appendingPathComponent("fixtures/overview/ubuntu-24.04.out.txt"), encoding: .utf8)
        var overview = try OverviewParser.parse(text)
        overview.rebootRequired = true
        let items = Attention.evaluate(overview)
        let reboot = try XCTUnwrap(items.first { $0.id == Attention.rebootRequiredID }, "the rule id must match the spec")
        XCTAssertTrue(Attention.offersReboot(reboot))
        XCTAssertEqual(items.filter(Attention.offersReboot).count, 1)
        overview.rebootRequired = false
        XCTAssertTrue(Attention.evaluate(overview).filter(Attention.offersReboot).isEmpty)
    }

    func testTheRuleIdMatchesTheSpec() throws {
        let data = try Data(contentsOf: specDir.appendingPathComponent("attention-rules.json"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"\(Attention.rebootRequiredID)\""))
    }
}

final class NoServerChangeGuardTests: XCTestCase {
    /// Rackoon's rule: the server stays untouched. No library entry may change users, groups, sudoers or login
    /// access, whatever a future entry is for. (An earlier version offered "add the user to the docker group".)
    func testNoLibraryEntryChangesUsersGroupsOrSudo() {
        let forbidden = ["usermod", "useradd", "userdel", "groupadd", "groupmod", "gpasswd", "adduser", "addgroup",
                         "visudo", "/etc/sudoers", "/etc/group", "/etc/passwd", "chpasswd", "authorized_keys"]
        for entry in CommandLibrary.all {
            for text in [entry.script, entry.preview ?? ""] {
                for word in forbidden { XCTAssertFalse(text.contains(word), "\(entry.id) contains \(word)") }
            }
        }
        XCTAssertNil(CommandLibrary.all.first { $0.id == "docker_group" })
    }
}

final class SudoTransportEdgeTests: XCTestCase {
    func testStreamsRefuseOnceLockedOrUnquotable() async {
        let t = FakeTransport([])
        let expired = SudoTransport(base: t, password: "pw", validUntil: Date().addingTimeInterval(-1))
        do { for try await _ in expired.stream("docker ps") {}; XCTFail() } catch { XCTAssertEqual(error as? SudoTransportError, .locked) }
        let open = SudoTransport(base: t, password: "pw", validUntil: .distantFuture)
        do { for try await _ in open.stream("a\nb") {}; XCTFail() } catch { XCTAssertEqual(error as? SudoTransportError, .cannotElevate) }
        XCTAssertTrue(t.streamedCommands.isEmpty, "nothing was sent")
    }

    func testACommandOfTheServersOwnFailingIsReturnedNotLocked() async throws {
        let t = FakeTransport([.success(CommandResult(stdout: "", stderr: "Error: No such container: x\n", exitCode: 1))])
        let r = try await SudoTransport(base: t, password: "pw", validUntil: .distantFuture).run("docker stop x", timeout: 20)
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertEqual(r.stderr, "Error: No such container: x\n")
    }
}
