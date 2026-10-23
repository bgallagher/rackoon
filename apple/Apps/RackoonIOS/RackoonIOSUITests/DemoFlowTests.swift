import XCTest

// The app driven end to end in demo mode (RACKOON_DEMO=1): made-up servers, nothing sent anywhere. RACKOON_UI_TEST=1
// makes every launch start clean (no remembered tab, page or Read-only switch) and turns animations off.

/// Launches the app for one flow and gives the steps every flow shares.
class DemoFlow: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["RACKOON_DEMO"] = "1"
        app.launchEnvironment["RACKOON_UI_TEST"] = "1"
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// Any element with this accessibility identifier.
    func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    @discardableResult
    func waitFor(_ element: XCUIElement, _ timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) did not appear", file: file, line: line)
        return element
    }

    func tap(_ id: String, _ timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        let e = waitFor(element(id), timeout, file: file, line: line)
        // Rows below the fold: scroll until it can be tapped (a CI simulator may be shorter than the local one).
        var tries = 0
        while !e.isHittable && tries < 6 { app.swipeUp(); tries += 1 }
        e.tap()
    }

    /// Switches tab, and checks it did: right after launch a tap can land before the tab bar takes it.
    func tab(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = waitFor(app.tabBars.buttons[name], file: file, line: line)
        for _ in 0..<3 where !button.isSelected {
            button.tap()
            _ = app.navigationBars[name].waitForExistence(timeout: 3)
        }
        XCTAssertTrue(button.isSelected, "the \(name) tab did not open", file: file, line: line)
    }

    /// The Overview of the demo's homelab server, from the Servers tab.
    func openHomelab() {
        tab("Servers")
        waitFor(app.staticTexts["homelab"]).tap()
        waitFor(element("openDocker"))
    }

    /// A screen linked from the Overview (scrolls down to it first).
    func openPlace(_ id: String) {
        let link = element(id)
        var tries = 0
        while !(link.exists && link.isHittable) && tries < 5 { app.swipeUp(); tries += 1 }
        link.tap()
    }

    /// Confirms the sheet that shows the exact command, then waits for the run to finish.
    func confirmAndFinish(file: StaticString = #filePath, line: UInt = #line) {
        waitFor(element("confirmCommand"), file: file, line: line)
        tap("confirmRun", file: file, line: line)
        waitFor(element("outputClose"), 30, file: file, line: line)
    }
}

final class OverviewFlowTests: DemoFlow {
    func testTheDashboardAndAServersOverview() {
        tab("Dashboard")
        waitFor(app.segmentedControls.buttons["Health"])
        waitFor(element("fleetOnline"), 20)
        openHomelab()
        XCTAssertTrue(app.staticTexts["promtail is unhealthy."].waitForExistence(timeout: 10), "the attention list")
        for id in ["openUpdates", "openServices", "openFiles", "openCommands", "openAlerts"] {
            var tries = 0
            while !element(id).exists && tries < 4 { app.swipeUp(); tries += 1 }
            XCTAssertTrue(element(id).exists, id)
        }
    }
}

final class DockerFlowTests: DemoFlow {
    func testAStackActionAsksWithItsCommandThenStreams() {
        openHomelab()
        tap("openDocker")
        tap("stack-jellyfin", 20)
        tap("stackActions")
        // A menu item's label also carries its description line.
        waitFor(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Restart All")).firstMatch).tap()
        confirmAndFinish()
    }
}

final class UpdatesFlowTests: DemoFlow {
    func testInstallAllAsksThenStreamsAptsOutput() {
        openHomelab()
        openPlace("openUpdates")
        waitFor(element("updatesSubtitle"), 20)
        tap("installAll")
        confirmAndFinish()
    }
}

final class ServicesFlowTests: DemoFlow {
    func testStatusStreamsAndRestartAsksFirst() {
        openHomelab()
        openPlace("openServices")
        tap("service-system/cloudflared.service", 20)
        tap("service-status")
        waitFor(element("outputClose"), 30)
        tap("service-restart")
        confirmAndFinish()
    }
}

final class CommandsFlowTests: DemoFlow {
    func testALibraryCommandRunsAndATypedOneAsksFirst() {
        openHomelab()
        openPlace("openCommands")
        tap("command-disk_usage")
        tap("runCommand")
        waitFor(element("outputClose"), 30)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap("customCommand")
        let field = waitFor(element("customCommandText"))
        field.tap()
        field.typeText("uptime")
        waitFor(app.buttons["Run…"]).tap()
        confirmAndFinish()
    }
}

final class FilesFlowTests: DemoFlow {
    func testBrowseAndDownloadIntoDownloads() {
        openHomelab()
        openPlace("openFiles")
        waitFor(element("file-notes.txt"), 20)
        // Swipe the row itself: the identifier also lands on the row's icon, and a swipe there opens nothing.
        let row = app.cells.containing(.any, identifier: "file-notes.txt").firstMatch
        row.swipeLeft()
        let download = app.buttons["Download"]
        if !download.waitForExistence(timeout: 5) {
            // The same action is in the row's long-press menu.
            row.press(forDuration: 1.2)
        }
        waitFor(download).tap()
        waitFor(app.buttons["Share notes.txt"], 15)
        tap("folder-backups")
        waitFor(element("file-photos-2026-09.tar.gz"))
    }
}

final class AlertsFlowTests: DemoFlow {
    func testAnAlertOpensTheServiceThatNeedsFixing() {
        tab("Alerts")
        // The first look comes a few seconds after launch, the services check right after it.
        tap("alert-service_crashing:system/cloudflared.service", 45)
        tap("service-system/cloudflared.service", 20)
        waitFor(element("service-restart"))
    }
}

final class SearchFlowTests: DemoFlow {
    func testACommandFoundBySearchRunsOnTheChosenServer() {
        tab("Search")
        let field = waitFor(app.searchFields.firstMatch)
        field.tap()
        field.typeText("disk usage")
        tap("result-command|disk_usage")
        tap("runCommand")
        waitFor(element("outputClose"), 30)
    }
}

final class ReadOnlyFlowTests: DemoFlow {
    func testReadOnlyTurnsChangesOffButNotReads() {
        tab("Servers")
        let chip = waitFor(element("readOnlyChip"))
        chip.tap()
        XCTAssertEqual(chip.value as? String, "on")
        waitFor(app.staticTexts["homelab"]).tap()
        openPlace("openServices")
        tap("service-system/cloudflared.service", 20)
        XCTAssertFalse(waitFor(element("service-restart")).isEnabled, "a change is off")
        XCTAssertTrue(element("service-status").isEnabled, "a read still runs")
    }
}
