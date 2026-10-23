import Foundation
import XCTest
@testable import RackoonCore

/// Runs the language-neutral behaviour scenarios in spec/scenarios/*.json (docs/parity.md). The Kotlin core runs the same
/// files. A file with a `feature` runs only while that feature is done for the Mac in spec/features.json, so marking a
/// feature done turns its scenarios on; a file without one runs everywhere.
final class SharedScenarioTests: XCTestCase {
    private static let platform = "mac"

    private struct Scenario {
        let file: String
        let feature: String?
        let subject: String
        let cases: [[String: Any]]
    }

    private static func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private static func doneFeatures() throws -> Set<String> {
        let features = try json(specDir.appendingPathComponent("features.json"))["features"] as! [[String: Any]]
        return Set(features.compactMap { f in
            let entry = (f["platforms"] as! [String: Any])[platform] as! [String: Any]
            return entry["status"] as? String == "done" ? f["id"] as? String : nil
        })
    }

    /// Every scenario file that applies to this platform.
    private static func scenarios() throws -> [Scenario] {
        let dir = specDir.appendingPathComponent("scenarios")
        let done = try doneFeatures()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.sorted()
        return try files.compactMap { name in
            let doc = try json(dir.appendingPathComponent(name))
            let feature = doc["feature"] as? String
            if let feature, !done.contains(feature) { return nil }
            return Scenario(file: name, feature: feature, subject: doc["subject"] as! String, cases: doc["cases"] as! [[String: Any]])
        }
    }

    private func cases(_ subject: String) throws -> [(String, [String: Any])] {
        let found = try Self.scenarios().filter { $0.subject == subject }
        return found.flatMap { s in s.cases.map { ("\(s.file): \($0["name"] as! String)", $0) } }
    }

    private static let subjects: Set<String> = [
        "shell_quote", "template_fill", "action_policy", "compose_command", "stream_output", "server_input", "docker_ids",
    ]

    func testEveryApplicableScenarioHasARunner() throws {
        for s in try Self.scenarios() {
            XCTAssertTrue(Self.subjects.contains(s.subject),
                          "\(s.file): subject \(s.subject) has no Swift runner, but its feature is done on the Mac")
            XCTAssertFalse(s.cases.isEmpty, s.file)
        }
    }

    private func optionalString(_ value: Any?) -> String? { value is NSNull ? nil : value as? String }

    func testShellQuote() throws {
        for (name, c) in try cases("shell_quote") {
            let input = c["input"] as! String
            let got = c["fn"] as! String == "quotePath" ? ShellQuote.quotePath(input) : ShellQuote.quote(input)
            XCTAssertEqual(got, optionalString(c["expect"]), name)
        }
    }

    func testTemplateFill() throws {
        for (name, c) in try cases("template_fill") {
            XCTAssertEqual(Template.fill(c["template"] as! String, c["values"] as! [String: String]), c["expect"] as? String, name)
        }
    }

    private func intent(_ value: Any?) -> Intent? {
        guard let d = value as? [String: Any] else { return nil }
        return Intent(summary: d["summary"] as! String, command: d["command"] as! String,
                      risk: d["risk"] as! String == "mutate" ? .mutate : .read, preview: d["preview"] as? String)
    }

    private func outcome(_ body: () throws -> Void) -> String {
        do { try body(); return "ok" } catch PolicyError.readOnly { return "read_only" } catch PolicyError.notConfirmed {
            return "not_confirmed"
        } catch { return "\(error)" }
    }

    func testActionPolicy() throws {
        for (name, c) in try cases("action_policy") {
            let policy = ActionPolicy(readOnly: c["readOnly"] as! Bool)
            var confirmation: Confirmation?
            if let shown = intent(c["confirm"]) {
                let got = outcome { confirmation = try policy.confirm(shown) }
                XCTAssertEqual(got, c["expectConfirm"] as? String ?? "ok", "\(name) (confirm)")
            }
            if let flip = c["readOnlyAtRun"] as? Bool { policy.isReadOnly = flip }
            let run = intent(c["run"])!
            XCTAssertEqual(outcome { try policy.authorize(run, with: confirmation) }, c["expect"] as? String, name)
        }
    }

    func testComposeCommand() throws {
        for (name, c) in try cases("compose_command") {
            let s = c["stack"] as! [String: Any]
            let stackName = s["name"] as! String
            let dir = optionalString(s["workingDir"])
            let files = s["configFiles"] as! [String]
            let containers = (s["services"] as! [String]).enumerated().map { i, service in
                DockerContainer(id: String(format: "abcdef%06d", i), name: "\(stackName)-\(service)-1", image: "nginx",
                                state: "running", health: "none", status: "Up", ports: [], project: stackName,
                                service: service, workingDir: dir, configFile: files.first)
            }
            let stack = DockerStack(name: stackName, workingDir: dir, configFile: files.first, configFiles: files,
                                    containers: containers, isStandalone: s["standalone"] as? Bool ?? false)
            let action = try XCTUnwrap(ComposeAction(rawValue: c["action"] as! String), name)
            XCTAssertEqual(action.command(for: stack, service: c["service"] as? String), optionalString(c["expect"]), name)
        }
    }

    func testStreamOutput() throws {
        for (name, c) in try cases("stream_output") {
            var parser = StreamOutputParser()
            var text = (c["chunks"] as! [String]).map { parser.push($0) }.joined()
            let end = parser.finish()
            text += end.text
            XCTAssertEqual(text, c["text"] as? String, name)
            XCTAssertEqual(end.exitCode.map(Int.init), c["exitCode"] as? Int, name)
        }
    }

    func testServerInput() throws {
        for (name, c) in try cases("server_input") {
            let problem = ServerInput.problem(host: c["host"] as! String, user: c["user"] as! String,
                                              port: c["port"] as! String, identityFile: "")
            XCTAssertEqual(problem == nil, c["ok"] as! Bool, "\(name): \(problem ?? "accepted")")
        }
    }

    func testDockerIDs() throws {
        for (name, c) in try cases("docker_ids") {
            let value = c["value"] as! String
            let ok = c["kind"] as! String == "container_id" ? DockerSession.isContainerID(value) : ComposeAction.isServiceName(value)
            XCTAssertEqual(ok, c["ok"] as! Bool, name)
        }
    }
}
