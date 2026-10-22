import Foundation
import XCTest
@testable import RackoonCore

final class ServicesPresentationTests: XCTestCase {
    private func service(_ id: String, kind: String = "system", status: String = "running", name: String? = nil, unit: String? = "x.service",
                         detail: String = "", result: String? = nil, extra: [String: Any] = [:]) throws -> DiscoveredService {
        var fields: [String: Any] = ["id": id, "kind": kind, "name": name ?? id, "detail": detail, "status": status, "subState": "",
                                     "restarts": 0, "ports": [], "isPlumbing": false, "visibleByDefault": true]
        if let unit { fields["unit"] = unit }
        if let result { fields["result"] = result }
        fields.merge(extra) { $1 }
        return try JSONDecoder().decode(DiscoveredService.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    func testFiltersMatchTheChips() throws {
        let running = try service("a"), starting = try service("b", status: "starting"), failed = try service("c", status: "failed")
        let looping = try service("d", status: "restarting"), stopped = try service("e", status: "stopped"), stopping = try service("f", status: "stopping")
        let all = [running, starting, failed, looping, stopped, stopping]
        XCTAssertEqual(all.filter(ServiceStatusFilter.running.includes).map(\.id), ["a", "b"])
        XCTAssertEqual(all.filter(ServiceStatusFilter.attention.includes).map(\.id), ["c", "d"])
        XCTAssertEqual(all.filter(ServiceStatusFilter.stopped.includes).map(\.id), ["e", "f"])
    }

    func testProblemsComeFirstThenRunningThenByName() throws {
        let list = [try service("zed"), try service("b", status: "stopped"), try service("Alpha"), try service("x", status: "failed")]
        XCTAssertEqual(ServicesPresentation.sorted(list).map(\.id), ["x", "Alpha", "zed", "b"])
    }

    func testStatusWordsAndTones() throws {
        XCTAssertEqual(ServicesPresentation.status(try service("a", status: "failed", result: "exit-code")).text, "Failed (exit-code)")
        XCTAssertEqual(ServicesPresentation.status(try service("a", status: "failed")).tone, "danger")
        XCTAssertEqual(ServicesPresentation.status(try service("a", status: "restarting")).text, "Crash loop")
        XCTAssertEqual(ServicesPresentation.status(try service("a", status: "stopped")).tone, "idle")
        XCTAssertEqual(ServicesPresentation.kindLabel(.process), "Started by hand")
    }

    func testFactsSayOnlyWhatIsKnown() throws {
        let s = try service("a", extra: ["activeSeconds": 90, "memoryBytes": 2048, "enabledAtBoot": true, "restarts": 1])
        XCTAssertEqual(ServicesPresentation.facts(s, uptime: { "\(Int($0))s" }, bytes: { "\($0)B" }),
                       ["Up 90s", "2048B", "Starts at boot", "1 restart"])
        XCTAssertEqual(ServicesPresentation.facts(try service("b"), uptime: { _ in "" }, bytes: { _ in "" }), [])
    }

    func testADescriptionThatOnlyRepeatsTheNameIsLeftOut() throws {
        XCTAssertNil(ServicesPresentation.description(try service("cloudflared", unit: "cloudflared.service", detail: "cloudflared")))
        XCTAssertEqual(ServicesPresentation.description(try service("ts", unit: "tailscaled.service", detail: "Tailscale node agent")), "Tailscale node agent")
        XCTAssertNil(ServicesPresentation.description(try service("p", kind: "process", unit: nil, detail: "npx paperclipai")))
        XCTAssertEqual(ServicesPresentation.identity(try service("p", kind: "process", unit: nil, detail: "npx paperclipai")), "npx paperclipai")
    }

    func testActionsFollowTheState() throws {
        XCTAssertEqual(ServicesPresentation.actions(for: try service("a")), [.restart, .stop, .status, .logs])
        XCTAssertEqual(ServicesPresentation.actions(for: try service("a", status: "failed")), [.restart, .start, .status, .logs])
        XCTAssertEqual(ServicesPresentation.actions(for: try service("p", kind: "process", unit: nil)), [])
    }

    func testSubtitleCountsShownHiddenAndProblems() throws {
        let snap = ServicesSnapshot(services: [try service("a"), try service("b", status: "failed"), try service("c")], isRoot: false, hasSystemd: true)
        XCTAssertEqual(ServicesPresentation.subtitle(snap) { $0.id != "c" }, "2 shown · 1 hidden · 1 needs attention")
    }

    func testWebPortsBecomeLinks() {
        XCTAssertEqual(ServicesPresentation.link(ServicePort(address: "0.0.0.0", port: 8080), webHost: "100.64.0.1")?.absoluteString,
                       "http://100.64.0.1:8080")
        XCTAssertNil(ServicesPresentation.link(ServicePort(address: "0.0.0.0", port: 22), webHost: "100.64.0.1"))
    }

    // MARK: files

    func testCopyNamesAvoidTakenNames() {
        XCTAssertEqual(RemoteFileNames.copyName("report.pdf", avoiding: ["report.pdf"]), "report copy.pdf")
        XCTAssertEqual(RemoteFileNames.copyName("report.pdf", avoiding: ["report copy.pdf"]), "report copy 2.pdf")
        XCTAssertEqual(RemoteFileNames.copyName(".env", avoiding: []), ".env copy")
        XCTAssertEqual(RemoteFileNames.copyName("photos", avoiding: []), "photos copy")
    }

    func testNameProblems() {
        XCTAssertEqual(RemoteFileNames.problem("  ", taken: []), "Enter a name")
        XCTAssertNotNil(RemoteFileNames.problem("a/b", taken: []))
        XCTAssertEqual(RemoteFileNames.problem("a", taken: ["a"]), "That name is already taken")
        XCTAssertNil(RemoteFileNames.problem("new folder", taken: ["a"]))
    }

    func testADeletePlanRefusesShallowFolders() {
        let ok = DeletePlan(directory: "/home/me/stacks/app", items: [("data", true), ("notes.txt", false)])
        XCTAssertTrue(ok.problems.isEmpty)
        XCTAssertEqual(ok.commands.count, 2)
        XCTAssertTrue(ok.hasFolder)
        let refused = DeletePlan(directory: "/", items: [("etc", true)])
        XCTAssertEqual(refused.commands, [])
        XCTAssertEqual(refused.problems.count, 1)
    }

    // MARK: commands

    func testLibrarySearchKeepsGroupsInOrder() {
        XCTAssertEqual(CommandLibrary.visibleGroups(matching: "").map(\.name), CommandLibrary.groups)
        let docker = CommandLibrary.visibleGroups(matching: "  PRUNE ")
        XCTAssertEqual(docker.map(\.name), ["Maintenance"])
        XCTAssertEqual(docker.first?.commands.map(\.id), ["docker_prune"])
        XCTAssertTrue(CommandLibrary.visibleGroups(matching: "nothing-like-this").isEmpty)
    }

    func testParamsProblemNamesTheMissingValue() throws {
        let logs = try XCTUnwrap(CommandLibrary.all.first { $0.id == "container_logs" })
        XCTAssertEqual(CommandLibrary.paramsProblem(logs, params: [:]), "Enter a valid container")
        XCTAssertEqual(CommandLibrary.paramsProblem(logs, params: ["container": "x; rm -rf /"]), "Enter a valid container")
        XCTAssertNil(CommandLibrary.paramsProblem(logs, params: ["container": "web-1"]))
    }

    func testHistoryKeepsTheNewestTwentyWithoutRepeats() {
        var h = CommandHistory()
        for i in 0..<25 { h.remember("echo \(i)") }
        h.remember("echo 10")
        XCTAssertEqual(h.items.count, CommandHistory.limit)
        XCTAssertEqual(h.items.first, "echo 10")
        XCTAssertEqual(h.items.filter { $0 == "echo 10" }.count, 1)
        h.clear()
        XCTAssertEqual(h.items, [])
    }
}
