import Foundation
@testable import RackoonCore
import XCTest

private func container(_ name: String, service: String? = nil, state: String = "running", health: String = "none",
                       project: String? = "media", workingDir: String? = "/srv/media", bookmark: Bookmark? = nil) -> DockerContainer {
    DockerContainer(id: "abcdef012345", name: name, image: "img", state: state, health: health, status: "Up", ports: [],
                    project: project, service: service, workingDir: workingDir,
                    configFile: workingDir.map { "\($0)/compose.yaml" }, configFiles: workingDir.map { ["\($0)/compose.yaml"] } ?? [],
                    bookmark: bookmark)
}

private func stack(_ cs: DockerContainer..., standalone: Bool = false) -> DockerStack {
    DockerStack(name: "media", workingDir: cs.first?.workingDir, configFile: cs.first?.configFile, configFiles: cs.first?.configFiles ?? [],
                containers: cs, isStandalone: standalone)
}

final class ActionPromptsTests: XCTestCase {
    func testUnavailableReasonsComeInTheMacsOrder() {
        let ok = stack(container("media-web-1", service: "web"))
        XCTAssertNil(ActionPrompts.blockedReason(ok, readOnly: false, otherActionRunning: false))
        XCTAssertEqual(ActionPrompts.blockedReason(ok, readOnly: true, otherActionRunning: true), "Read-only mode is on")
        XCTAssertEqual(ActionPrompts.blockedReason(ok, readOnly: false, otherActionRunning: true), "Another stack action is running")
        XCTAssertEqual(ActionPrompts.blockedReason(stack(container("x", project: nil, workingDir: nil), standalone: true), readOnly: false, otherActionRunning: false),
                       "These containers were not started with Docker Compose")
        XCTAssertEqual(ActionPrompts.blockedReason(stack(container("media-web-1", service: "web", workingDir: nil)), readOnly: false, otherActionRunning: false),
                       "No single compose file was found for this stack")
    }

    func testStandaloneReasons() {
        var solo = container("solo", project: nil, workingDir: nil)
        solo.image = "nginx:1"
        let s = DockerStack(name: "solo", workingDir: nil, configFile: nil, configFiles: [], containers: [solo], isStandalone: true)
        XCTAssertNil(ActionPrompts.standaloneBlockedReason(s, readOnly: false, otherActionRunning: false))
        XCTAssertEqual(ActionPrompts.standaloneBlockedReason(s, readOnly: true, otherActionRunning: false), "Read-only mode is on")
        XCTAssertEqual(ActionPrompts.pull(s)?.title, "Pull the latest nginx:1?")
        XCTAssertEqual(ActionPrompts.pull(s)?.destructive, false)
    }

    func testStartHasNoPromptAndStopAndRestartInterrupt() {
        let c = container("media-web-1", service: "web")
        XCTAssertNil(ActionPrompts.container(.start, c))
        XCTAssertEqual(ActionPrompts.container(.stop, c)?.destructive, true)
        // As on the Mac: a restart drops connections, so it is confirmed by a tap on the red button, not Return.
        XCTAssertEqual(ActionPrompts.container(.restart, c)?.destructive, true)
        XCTAssertEqual(ActionPrompts.container(.restart, c)?.title, "Restart media-web-1?")
    }

    func testStackPromptsNameTheStackAndCountItsContainers() {
        let s = stack(container("a", service: "web"), container("b", service: "db"))
        XCTAssertEqual(ActionPrompts.stack(.restart, s).title, "Restart all 2 containers in media?")
        XCTAssertEqual(ActionPrompts.stack(.recreate, stack(container("a", service: "web"))).title, "Recreate all 1 container in media?")
        XCTAssertTrue(ActionPrompts.stack(.recreate, s).destructive)
        XCTAssertTrue(ActionPrompts.stack(.restart, s).destructive)
        XCTAssertFalse(ActionPrompts.stack(.up, s).destructive)
        XCTAssertFalse(ActionPrompts.stack(.pull, s).destructive)
        XCTAssertEqual(ActionPrompts.stack(.up, s).working, "Updating media…")
        for a in ComposeAction.allCases { XCTAssertFalse(ActionPrompts.stack(a, s).message.isEmpty) }
    }

    func testRebuildAppliesOnlyToAServiceTheStackCanAddress() {
        let s = stack(container("a", service: "web"))
        XCTAssertTrue(ActionPrompts.canRebuild(container("a", service: "web"), in: s))
        XCTAssertFalse(ActionPrompts.canRebuild(container("a"), in: s))
        XCTAssertFalse(ActionPrompts.canRebuild(container("a", service: "web"), in: stack(container("a", service: "web", workingDir: nil))))
        XCTAssertEqual(ActionPrompts.rebuild(service: "web", in: s).title, "Rebuild web?")
    }
}

final class DockerPresentationTests: XCTestCase {
    func testLinkScopeMatchesTheMacRules() {
        XCTAssertEqual(LinkScope(href: "http://dockge"), .local)
        XCTAssertEqual(LinkScope(href: "http://grafana.local:3000"), .local)
        XCTAssertEqual(LinkScope(href: "http://192.168.1.5:8080"), .local)
        XCTAssertEqual(LinkScope(href: "http://172.20.0.4"), .local)
        XCTAssertEqual(LinkScope(href: "http://172.40.0.4"), .publicWeb)
        XCTAssertEqual(LinkScope(href: "https://immich.tailnet-name.ts.net"), .tailscale)
        XCTAssertEqual(LinkScope(href: "http://100.125.183.84:9090"), .tailscale)
        XCTAssertEqual(LinkScope(href: "http://100.200.1.1"), .publicWeb)
        XCTAssertEqual(LinkScope(href: "https://aiometadata.example.com"), .publicWeb)
        XCTAssertEqual(LinkScope(href: "not a url"), .publicWeb)
    }

    func testStackStatusPicksTheMostSeriousThing() {
        XCTAssertEqual(stack(container("a", health: "unhealthy"), container("b")).status, StackStatus(text: "1 unhealthy", severity: .danger))
        XCTAssertEqual(stack().status, StackStatus(text: "Not started", severity: .idle))
        XCTAssertEqual(stack(container("a", state: "exited")).status, StackStatus(text: "Stopped", severity: .idle))
        XCTAssertEqual(stack(container("a"), container("b", state: "exited")).status, StackStatus(text: "1 stopped", severity: .warning))
        XCTAssertEqual(stack(container("a"), container("b")).status, StackStatus(text: "", severity: .ok))
    }

    func testSummaryCountsStacksAndContainers() {
        let snap = DockerSnapshot(containers: [container("a"), container("b", health: "unhealthy"), container("c", project: nil),
                                               container("d", state: "exited")])
        XCTAssertEqual(snap.summary, "1 stack · 4 containers · 2 healthy, 1 unhealthy, 1 stopped")
        XCTAssertEqual(DockerSnapshot(containers: [container("x", project: nil)]).summary, "1 container · 1 healthy")
    }

    func testLetterTileHueIsStableAndInRange() {
        XCTAssertEqual(LetterTile.letter("dockge"), "D")
        XCTAssertEqual(LetterTile.letter(""), "?")
        XCTAssertEqual(LetterTile.hue("immich"), LetterTile.hue("immich"))
        for n in ["immich", "dockge", "grafana", "Ünï", "", "a-very-long-stack-name-that-overflows-the-hash-many-times-over"] {
            XCTAssertTrue((0..<6).contains(LetterTile.slot(n, count: 6)))
            XCTAssertTrue((0..<360).contains(LetterTile.hue(n)))
        }
        // djb2: "a" = 5381*33 + 97 = 177670; 177670 % 360 = 190 (the same as Android)
        XCTAssertEqual(LetterTile.hue("a"), 190)
    }

    func testUsageText() {
        var c = container("a")
        XCTAssertEqual(c.usageText { "\($0) B" }, "—")
        c.cpuPercent = 5.6
        c.memoryUsedBytes = 147
        XCTAssertEqual(c.usageText { "\($0) B" }, "6% · 147 B")
        XCTAssertEqual(container("a", state: "exited").usageText { "\($0) B" }, "exited")
    }

    func testAnImageSplitsIntoRepositoryAndTag() {
        XCTAssertEqual(ImageName.parse("ghcr.io/immich-app/immich-machine-learning:release"),
                       ImageName(repository: "ghcr.io/immich-app/immich-machine-learning", tag: ":release"))
        XCTAssertEqual(ImageName.parse("redis:7"), ImageName(repository: "redis", tag: ":7"))
        XCTAssertEqual(ImageName.parse("redis"), ImageName(repository: "redis", tag: nil))
        XCTAssertEqual(ImageName.parse("localhost:5000/app"), ImageName(repository: "localhost:5000/app", tag: nil))
        XCTAssertEqual(ImageName.parse("localhost:5000/app:2"), ImageName(repository: "localhost:5000/app", tag: ":2"))
        XCTAssertEqual(ImageName.parse("nginx@sha256:0123456789abcdef0123"), ImageName(repository: "nginx", tag: "@sha256:0123456789ab"))
    }

    func testShortAddressAndBookmarkLinks() {
        XCTAssertEqual(Bookmark(href: "https://app.example.com/tv").shortAddress, "app.example.com/tv")
        XCTAssertEqual(Bookmark(href: "http://10.0.0.5:8080/").shortAddress, "10.0.0.5:8080")
        let s = stack(container("a", bookmark: Bookmark(href: "http://a")), container("b"), container("c", bookmark: Bookmark(href: "http://c")))
        XCTAssertEqual(s.bookmarkLinks.map(\.href), ["http://a", "http://c"])
    }
}
