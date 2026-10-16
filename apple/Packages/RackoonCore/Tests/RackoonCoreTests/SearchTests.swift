import Foundation
import XCTest
@testable import RackoonCore

final class SearchTests: XCTestCase {
    private let lab = Server(id: "a", name: "homelab", host: "192.168.1.20", user: "alice")
    private let nas = Server(id: "b", name: "nas", host: "nas.local")

    private func services() throws -> ServicesSnapshot {
        ServicesParser.parse(try String(contentsOf: specDir.appendingPathComponent("fixtures/services/synthetic-root-failed.out.txt"), encoding: .utf8))
    }

    private func states() throws -> DockerStatesReading {
        DockerStatesParser.parse(try String(contentsOf: specDir.appendingPathComponent("fixtures/docker_states/synthetic-problems.out.txt"), encoding: .utf8))
    }

    private func everything() throws -> [SearchItem] {
        var items = [SearchItems.server(lab, summary: "Online", online: true, os: "Ubuntu 24.04", addresses: ["100.64.0.10"]),
                     SearchItems.server(nas, summary: "Not answering", online: false, os: nil, addresses: [])]
        items += SearchItems.docker(try states(), server: lab)
        items += SearchItems.services(try services(), server: lab) { $0.visibleByDefault }
        items += SearchItems.bookmarks([(Bookmark(href: "https://photos.example.com", name: "Immich", group: "Media"), "immich_server")], server: lab)
        items += SearchItems.commands(CommandLibrary.all)
        var book = AlertBook()
        book.apply(server: "a", serverName: "homelab", source: .services, signals: AlertRules.services(try services()) { $0.visibleByDefault }, at: Date())
        items += SearchItems.alerts(book.active())
        return items
    }

    func testNeedsTwoLetters() throws {
        let items = try everything()
        XCTAssertEqual(Search.run("", in: items).count, 0)
        XCTAssertEqual(Search.run("n ", in: items).count, 0)
        XCTAssertFalse(Search.isSearchable(" a "))
        XCTAssertTrue(Search.isSearchable("ng"))
        XCTAssertGreaterThan(Search.run("ng", in: items).count, 0)
    }

    func testResultsAreGroupedInAFixedOrder() throws {
        // "backup" is a failed service, its alert, and Commands entries about backups/disks may match too.
        let results = Search.run("backup", in: try everything())
        let groups = results.sections.map(\.group)
        XCTAssertEqual(groups, SearchGroup.allCases.filter { groups.contains($0) }, "sections follow SearchGroup order")
        XCTAssertEqual(results.sections.first { $0.group == .services }?.items.first?.title, "backup-sync")
        XCTAssertEqual(results.sections.first { $0.group == .alerts }?.items.first?.title, "backup-sync failed")
        XCTAssertEqual(results.sections.first { $0.group == .services }?.items.first?.tone, "danger")
    }

    func testEveryGroupIsReachable() throws {
        let items = try everything()
        XCTAssertEqual(Search.run("homelab", in: items).sections.first?.group, .servers)
        XCTAssertEqual(Search.run("100.64", in: items).sections.first?.items.first?.target, .server("a"), "found by address")
        let immich = Search.run("immich", in: items)
        XCTAssertEqual(immich.sections.first { $0.group == .docker }?.items.first?.target, .stack(server: "a", stack: "immich"))
        XCTAssertEqual(immich.sections.first { $0.group == .bookmarks }?.items.first?.link, "https://photos.example.com")
        XCTAssertEqual(Search.run("pi-hole", in: items).sections.first { $0.group == .services }?.items.first?.target,
                       .service(server: "a", service: "system/pihole-FTL.service"))
        XCTAssertEqual(Search.run("443", in: items).sections.first { $0.group == .services }?.items.first?.title, "nginx", "found by port")
        let disk = Search.run("disk usage", in: items).sections.first { $0.group == .commands }
        XCTAssertEqual(disk?.items.first?.target, .command("disk_usage"))
        XCTAssertNotNil(Search.run("old-thing", in: items).sections.first { $0.group == .docker })
    }

    func testRankingPrefersTitleMatches() throws {
        let items = try everything()
        let docker = Search.run("immich", in: items).sections.first { $0.group == .docker }!.items
        XCTAssertEqual(docker.first?.title, "immich", "the stack named exactly that comes first")
        // Every word must match somewhere; order of words does not matter.
        XCTAssertEqual(Search.run("homelab nginx", in: items).sections.first { $0.group == .services }?.items.first?.title, "nginx")
        XCTAssertNil(Search.run("nginx zzz", in: items).sections.first)
        // Case and accents don't matter.
        XCTAssertFalse(Search.run("NGÍNX", in: items).sections.isEmpty)
    }

    func testHiddenServicesAreNotSearched() throws {
        let items = SearchItems.services(try services(), server: lab) { $0.visibleByDefault }
        XCTAssertTrue(Search.run("ssh", in: items).sections.isEmpty, "OpenSSH is hidden by default")
        XCTAssertTrue(Search.run("cron", in: items).sections.isEmpty)
    }

    func testFullDockerReadingHasStacksAndContainers() throws {
        let snapshot = try DockerParser.parse(String(contentsOf: specDir.appendingPathComponent("fixtures/docker/\(firstDockerFixture()).out.txt"), encoding: .utf8))
        let items = SearchItems.docker(snapshot.stacks, server: lab)
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.group == .docker && $0.serverName == "homelab" })
        for stack in snapshot.stacks {
            XCTAssertTrue(items.contains { $0.target == .stack(server: "a", stack: stack.id) && $0.title == stack.name })
        }
    }

    private func firstDockerFixture() throws -> String {
        let names = try FileManager.default.contentsOfDirectory(atPath: specDir.appendingPathComponent("fixtures/docker").path)
            .filter { $0.hasSuffix(".out.txt") }.sorted()
        for name in names {
            let base = String(name.dropLast(".out.txt".count))
            if let s = try? DockerParser.parse(String(contentsOf: specDir.appendingPathComponent("fixtures/docker/\(name)"), encoding: .utf8)),
               !s.stacks.isEmpty { return base }
        }
        throw XCTSkip("no docker fixture with stacks")
    }
}
