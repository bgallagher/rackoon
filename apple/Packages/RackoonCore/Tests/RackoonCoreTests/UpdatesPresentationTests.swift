import Foundation
@testable import RackoonCore
import XCTest

final class UpdatesPresentationTests: XCTestCase {
    private func pkg(_ name: String, _ security: Bool = false) -> PendingUpdate {
        PendingUpdate(name: name, suite: security ? "noble-security" : "noble-updates", newVersion: "2", oldVersion: "1",
                      architecture: "amd64", isSecurity: security)
    }
    private func snap(_ p: [PendingUpdate] = [], refreshed: Int64? = nil) -> UpdatesSnapshot {
        UpdatesSnapshot(packages: p, held: [], refreshedAt: refreshed, rebootRequired: false)
    }

    func testSubtitleCountsUpdatesAndSecurity() {
        XCTAssertEqual(UpdatesPresentation.subtitle(snap()), "Everything is up to date")
        XCTAssertEqual(UpdatesPresentation.subtitle(snap([pkg("a")])), "1 update available")
        XCTAssertEqual(UpdatesPresentation.subtitle(snap([pkg("a"), pkg("b"), pkg("c", true)])), "3 updates available, 1 security")
    }

    func testRelativeAgeUsesTheLargestUnit() {
        XCTAssertEqual(UpdatesPresentation.relativeAge(30), "just now")
        XCTAssertEqual(UpdatesPresentation.relativeAge(60), "1 minute ago")
        XCTAssertEqual(UpdatesPresentation.relativeAge(5 * 3600 + 59), "5 hours ago")
        XCTAssertEqual(UpdatesPresentation.relativeAge(3 * 86_400), "3 days ago")
        XCTAssertEqual(UpdatesPresentation.relativeAge(61 * 86_400), "2 months ago")
        XCTAssertEqual(UpdatesPresentation.relativeAge(-5), "just now")
    }

    func testStalenessOnlyAfterThreeDays() {
        let now: Int64 = 10_000_000
        XCTAssertNil(UpdatesPresentation.staleness(snap(refreshed: now - 3 * 86_400), now: now))
        XCTAssertEqual(UpdatesPresentation.staleness(snap(refreshed: now - 4 * 86_400), now: now),
                       "Package lists were refreshed 4 days ago. Refresh them to see newer updates.")
        XCTAssertNil(UpdatesPresentation.staleness(snap(), now: now))
        XCTAssertEqual(UpdatesPresentation.refreshedText(snap(), now: now), "unknown")
        XCTAssertEqual(UpdatesPresentation.refreshedText(snap(refreshed: now - 7200), now: now), "2 hours ago")
    }

    func testSecurityComesFirstThenName() {
        XCTAssertEqual(UpdatesPresentation.sorted([pkg("zlib"), pkg("curl", true), pkg("bash"), pkg("openssl", true)]).map(\.name),
                       ["curl", "openssl", "bash", "zlib"])
        XCTAssertEqual(UpdatesPresentation.securityNames([pkg("zlib"), pkg("openssl", true), pkg("curl", true)]), ["curl", "openssl"])
    }

    func testInstallSecurityHasAReasonWhenOff() {
        let some = [pkg("a", true), pkg("b")]
        XCTAssertTrue(UpdatesPresentation.canInstallSecurity(some))
        XCTAssertNil(UpdatesPresentation.installSecurityHint(some, readOnly: false))
        XCTAssertEqual(UpdatesPresentation.installSecurityHint(some, readOnly: true), "Read-only mode is on")
        XCTAssertEqual(UpdatesPresentation.installSecurityHint([pkg("b")], readOnly: false), "No security updates")
        let many = (1...(AptAction.maxPackages + 1)).map { pkg("pkg\($0)", true) }
        XCTAssertFalse(UpdatesPresentation.canInstallSecurity(many))
        XCTAssertEqual(UpdatesPresentation.installSecurityHint(many, readOnly: false), "Too many to list one by one; use Install All")
    }

    func testPromptsSayWhatWillHappen() {
        XCTAssertEqual(UpdatesPresentation.prompt(.refresh, packageCount: 5, securityCount: 2).title, "Refresh package lists?")
        XCTAssertEqual(UpdatesPresentation.prompt(.upgradeAll, packageCount: 5, securityCount: 2).title, "Install all 5 updates?")
        let p = UpdatesPresentation.prompt(.upgrade(packages: ["a", "b", "c", "d", "e", "f", "g", "h"]), packageCount: 9, securityCount: 8)
        XCTAssertEqual(p.title, "Install 8 security updates?")
        XCTAssertEqual(p.message, "Only these packages are upgraded: a, b, c, d, e, f and 2 more.")
        XCTAssertEqual(p.outputTitle, "apt-get install --only-upgrade (8 packages)")
        XCTAssertEqual(UpdatesPresentation.prompt(.upgrade(packages: ["a"]), packageCount: 1, securityCount: 1).title, "Install 1 security update?")
    }
}
