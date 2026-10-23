import Foundation
@testable import RackoonCore
import XCTest

@MainActor
final class StackEditorTests: XCTestCase {
    private let compose = EditableFile.compose("/srv/media/compose.yaml")
    private let env = EditableFile.env("/srv/media/.env")

    private func stack() -> DockerStack {
        let c = DockerContainer(id: "abcdef012345", name: "media-web-1", image: "nginx", state: "running", health: "none", status: "Up",
                                ports: [], project: "media", service: "web", workingDir: "/srv/media",
                                configFile: "/srv/media/compose.yaml", configFiles: ["/srv/media/compose.yaml"])
        return DockerStack(name: "media", workingDir: "/srv/media", configFile: "/srv/media/compose.yaml",
                           configFiles: ["/srv/media/compose.yaml"], containers: [c], isStandalone: false)
    }

    private func setup(_ server: FakeStackServer = FakeStackServer(), readOnly: Bool = false, delay: TimeInterval = 0.02)
        -> (StackEditor, FakeStackServer, ActionPolicy) {
        let policy = ActionPolicy(readOnly: readOnly)
        let editor = StackEditor(session: StackFileSession(transport: server, policy: policy, stack: stack()), stack: stack(),
                                 serverName: "hetzner", isReadOnly: { policy.isReadOnly }, checkDelay: delay)
        return (editor, server, policy)
    }

    private func opened(_ editor: StackEditor, _ file: EditableFile) async {
        editor.open(file)
        await waitFor("the file to load") { editor.state.drafts[file]?.original != nil }
    }

    private func checked(_ editor: StackEditor, _ file: EditableFile) async {
        await waitFor("the check to finish") { editor.state.drafts[file]?.checking == false }
    }

    func testOpeningReadsTheFileAndACleanDraftHasNoChecks() async {
        let (editor, _, _) = setup()
        await opened(editor, compose)
        let d = editor.draft(compose)
        XCTAssertEqual(d.text, "services:\n  web:\n    image: nginx\n")
        XCTAssertFalse(d.isDirty)
        XCTAssertEqual(editor.rows(compose), [])
        XCTAssertEqual(editor.saveBlockedReason(compose), "No changes to save")
    }

    func testAMissingEnvFileOpensEmptyAndCanBeCreated() async {
        let (editor, server, _) = setup()
        await opened(editor, env)
        XCTAssertEqual(editor.draft(env).original, .missing)
        editor.setText(env, "TZ=Europe/Dublin\n")
        await checked(editor, env)
        XCTAssertTrue(editor.canSave(env))
        let edit = try! XCTUnwrap(editor.edit(for: env))
        XCTAssertNil(edit.originalSHA, "a new file is saved with the not-exists guard")
        editor.save(edit, redeploy: false)
        await waitFor { !editor.state.saving && editor.state.notice != nil }
        XCTAssertEqual(server.envText, "TZ=Europe/Dublin\n")
        XCTAssertFalse(editor.isDirty(env), "after saving, the saved text is the new original")
    }

    func testTypingWaitsForAPauseThenChecksTheExactCurrentText() async {
        let (editor, server, _) = setup(delay: 0.3)
        await opened(editor, compose)
        editor.setText(compose, "services:\n  web:\n    image: nginx:1\n")
        XCTAssertTrue(editor.draft(compose).checking)
        XCTAssertEqual(editor.rows(compose).map(\.state), [.running])
        XCTAssertFalse(editor.canSave(compose), "not before the check passed")
        await settle(0.1)
        XCTAssertEqual(server.checks, 0, "still waiting for a pause in typing")
        await checked(editor, compose)
        XCTAssertEqual(server.checks, 1)
        XCTAssertTrue(editor.canSave(compose))
        XCTAssertNil(editor.saveBlockedReason(compose))
    }

    func testFastTypingMakesOneCheckAndTheNewestTextWins() async {
        let (editor, server, _) = setup(delay: 0.15)
        await opened(editor, compose)
        editor.setText(compose, "a: 1\n")
        await settle(0.05)
        editor.setText(compose, "a: 2\n")
        await settle(0.05)
        editor.setText(compose, "a: 3\n")
        await checked(editor, compose)
        XCTAssertEqual(server.checks, 1, "earlier keystrokes never reached the server")
        XCTAssertEqual(editor.draft(compose).validatedText, "a: 3\n")
    }

    func testEditingAfterAPassedCheckMakesTheOldResultStale() async {
        let (editor, _, _) = setup()
        await opened(editor, compose)
        editor.setText(compose, "a: 1\n")
        await checked(editor, compose)
        XCTAssertTrue(editor.canSave(compose))
        editor.setText(compose, "a: 12\n")
        XCTAssertFalse(editor.canSave(compose), "a result for older text is never the verdict on this text")
        XCTAssertEqual(editor.saveBlockedReason(compose), "Waiting for the check on hetzner")
        editor.close()
    }

    func testServerErrorsBlockSavingAndMarkTheirLines() async {
        let server = FakeStackServer()
        server.rejectWith = "yaml: line 3: mapping values are not allowed here"
        let (editor, _, _) = setup(server)
        await opened(editor, compose)
        editor.setText(compose, "services:\n  web:\n    image nginx\n")
        await checked(editor, compose)
        XCTAssertFalse(editor.canSave(compose))
        XCTAssertEqual(editor.draft(compose).errorLines, [3])
        XCTAssertEqual(editor.saveBlockedReason(compose), "Fix the errors above first")
        XCTAssertEqual(editor.rows(compose).first?.state, .fail)
    }

    func testEnvSyntaxErrorsAreFoundLocallyWithoutAskingTheServer() async {
        let (editor, server, _) = setup()
        await opened(editor, env)
        editor.setText(env, "GOOD=1\nBAD LINE\n")
        await settle(0.1)
        XCTAssertEqual(server.checks, 0)
        XCTAssertEqual(editor.saveBlockedReason(env), "Fix the syntax error first")
        XCTAssertEqual(editor.draft(env).errorLines, [2])
    }

    func testReadOnlyBlocksSavingEvenAfterAPassedCheck() async {
        let (editor, _, policy) = setup()
        await opened(editor, compose)
        editor.setText(compose, "a: 1\n")
        await checked(editor, compose)
        XCTAssertTrue(editor.canSave(compose))
        policy.isReadOnly = true
        XCTAssertFalse(editor.canSave(compose))
        XCTAssertEqual(editor.saveBlockedReason(compose), "Read-only mode is on")
        XCTAssertNil(editor.edit(for: compose))
    }

    func testASaveWritesTheFileAndRunsTheRedeployCallback() async {
        let (editor, server, _) = setup()
        await opened(editor, compose)
        editor.setText(compose, "services:\n  web:\n    image: nginx:2\n")
        await checked(editor, compose)
        let edit = try! XCTUnwrap(editor.edit(for: compose))
        XCTAssertTrue(editor.intent(for: edit)?.preview?.contains("+     image: nginx:2") == true)
        var deployed = false
        editor.save(edit, redeploy: true) { deployed = true }
        await waitFor { deployed }
        XCTAssertEqual(server.composeText, "services:\n  web:\n    image: nginx:2\n")
        XCTAssertEqual(editor.state.notice, .saved(file: "compose.yaml", redeployed: true))
        XCTAssertFalse(editor.isDirty(compose))
    }

    func testAFileChangedOnTheServerIsNotOverwrittenAndCanBeReloaded() async {
        let (editor, server, _) = setup()
        await opened(editor, compose)
        editor.setText(compose, "a: 1\n")
        await checked(editor, compose)
        let edit = try! XCTUnwrap(editor.edit(for: compose))
        server.changeUnderneath = true
        var deployed = false
        editor.save(edit, redeploy: true) { deployed = true }
        await waitFor { editor.state.notice != nil && !editor.state.saving }
        XCTAssertFalse(deployed, "no redeploy after a refused save")
        XCTAssertEqual(editor.state.notice, .changedOnServer(compose))
        XCTAssertTrue(editor.isDirty(compose), "the draft is kept (Keep Editing)")
        XCTAssertEqual(server.composeText, "services:\n  web:\n    image: nginx\n")
        // Reload from Server throws the draft away and reads again.
        server.changeUnderneath = false
        server.composeText = "services:\n  web:\n    image: nginx:from-server\n"
        editor.reload(compose)
        await waitFor { editor.draft(compose).text == "services:\n  web:\n    image: nginx:from-server\n" }
        XCTAssertFalse(editor.isDirty(compose))
        XCTAssertNil(editor.state.notice)
    }

    func testRevertGoesBackToWhatTheServerHadAndClearsTheChecks() async {
        let (editor, _, _) = setup()
        await opened(editor, compose)
        editor.setText(compose, "a: 1\n")
        await checked(editor, compose)
        XCTAssertTrue(editor.hasUnsavedChanges)
        editor.revert(compose)
        XCTAssertFalse(editor.hasUnsavedChanges)
        XCTAssertEqual(editor.rows(compose), [])
        XCTAssertNotNil(editor.state.drafts[compose])
    }

    func testAFileThatIsTooLargeIsReportedNotEdited() async {
        let server = FakeStackServer()
        server.tooLarge = true
        let (editor, _, _) = setup(server)
        await opened(editor, compose)
        XCTAssertEqual(editor.draft(compose).loadError, StackFileError.tooLarge.errorDescription)
        XCTAssertEqual(editor.saveBlockedReason(compose), "No changes to save")
    }
}

final class BookmarkEditorTests: XCTestCase {
    private func container(_ service: String, _ bookmark: Bookmark? = nil, project: String? = "media", id: String = "abcdef012345") -> DockerContainer {
        DockerContainer(id: id, name: "media-\(service)-1", image: "img", state: "running", health: "none", status: "Up", ports: [],
                        project: project, service: service, workingDir: "/srv/media", configFile: "/srv/media/compose.yaml",
                        configFiles: ["/srv/media/compose.yaml"], bookmark: bookmark)
    }

    private func stack(_ cs: DockerContainer...) -> DockerStack {
        DockerStack(name: "media", workingDir: "/srv/media", configFile: "/srv/media/compose.yaml", configFiles: ["/srv/media/compose.yaml"],
                    containers: cs, isStandalone: false)
    }

    private func plan(_ text: String?, changes: [(key: String, value: String?)], removing: Bool = false) async throws -> BookmarkPlan {
        let s = stack(container("web"))
        let server = FakeStackServer(compose: text ?? "")
        if text == nil { server.envText = nil }
        let transport: SSHTransport = text == nil ? FakeTransport([.success(CommandResult(stdout: "##missing\n"))]) : server
        return try await BookmarkEditor.plan(session: StackFileSession(transport: transport, stack: s), stack: s, service: "web",
                                             changes: changes, removing: removing, serverName: "homelab")
    }

    private let yaml = "services:\n  web:\n    image: nginx\n"

    func testPlansAnEditForTheService() async throws {
        guard case .ready(let edit) = try await plan(yaml, changes: Bookmark(href: "http://web").labelChanges) else { return XCTFail() }
        XCTAssertEqual(edit.file.path, "/srv/media/compose.yaml")
        XCTAssertEqual(edit.content.hasSuffix("\n") ? edit.content : edit.content + "\n", yaml + "    labels:\n      - homepage.href=http://web\n")
        XCTAssertEqual(edit.originalSHA, FakeStackServer.sha(yaml))
    }

    func testSaysSoWhenNothingWouldChange() async throws {
        let p = try await plan(yaml, changes: Bookmark.removalChanges, removing: true)
        XCTAssertEqual(p, .notice("web has no bookmark labels to remove."))
    }

    func testSaysWhyWhenTheFileCannotBeEditedOrRead() async throws {
        let inline = try await plan("services: {}\n", changes: Bookmark(href: "http://web").labelChanges)
        XCTAssertEqual(inline, .notice("No compose file of media defines a service called web."))
        let missing = try await plan(nil, changes: Bookmark(href: "http://web").labelChanges)
        XCTAssertEqual(missing, .notice("Couldn't read the stack's compose file: compose.yaml is missing on homelab."))
        guard case .notice(let merge) = try await plan("services:\n  web:\n    <<: *base\n    image: x\n",
                                                        changes: Bookmark(href: "http://web").labelChanges) else { return XCTFail() }
        XCTAssertTrue(merge.contains("merge key"), merge)
    }

    func testBookmarkListsComeFromTheStacks() {
        let a = container("web", Bookmark(href: "http://web", name: "Web", group: "Media"), id: "aaaaaaaaaaaa")
        let b = container("db", id: "bbbbbbbbbbbb")
        let c = container("solo", Bookmark(href: "https://solo.example.com", group: "apps"), project: nil, id: "cccccccccccc")
        let stacks = DockerSnapshot(containers: [a, b, c]).stacks
        XCTAssertEqual(BookmarkItem.items(in: stacks).map(\.title), ["Web", "solo"])
        XCTAssertEqual(BookmarkItem.groups(in: stacks), ["apps", "Media"])
        XCTAssertEqual(stacks.first { $0.name == "media" }?.serviceNames, ["db", "web"])
        XCTAssertEqual(BookmarkItem.bookmarkableStacks(stacks).map(\.name), ["media"])
        XCTAssertEqual(BookmarkEditor.normalizedURL(" app.example.com "), "https://app.example.com")
        XCTAssertEqual(BookmarkEditor.normalizedURL("http://x"), "http://x")
    }
}
