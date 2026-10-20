import Foundation

/// One file's draft: what the server had, what the user has typed, and the checks of exactly that text.
public struct FileDraft: Sendable, Equatable {
    /// What the server had when the file was opened. Nil until loaded.
    public var original: RemoteFileState?
    public var text = ""
    public var loading = false
    public var loadError: String?
    public var validation: ValidationResult?
    /// The text `validation` belongs to, so a result for older text is never shown as current.
    public var validatedText: String?
    public var checkError: String?
    /// Instant local checks (`.env` syntax).
    public var local: [ComposeIssue] = []
    public var checking = false

    public init() {}

    public var originalText: String { original?.content ?? "" }
    public var isDirty: Bool { original != nil && !loading && text != originalText }
    public var changeCount: Int { LineDiff.changeCount(old: originalText, new: text) }
    public var changedLines: Set<Int> { LineDiff.changedLineNumbers(old: originalText, new: text) }

    /// Lines to mark in the editor: the local and server errors that belong to this exact text.
    public var errorLines: Set<Int> {
        guard isDirty else { return [] }
        let server = validatedText == text ? (validation?.errors ?? []) : []
        return Set((local + server).filter { $0.severity == .error }.compactMap(\.line))
    }

    /// Saving needs the current text to have passed the server check, and nothing to have changed after it.
    public var passedCheck: Bool { local.isEmpty && validatedText == text && validation?.isValid == true }
}

public enum EditorNotice: Sendable, Equatable {
    case saved(file: String, redeployed: Bool)
    case changedOnServer(EditableFile)
    case failed(String)
}

public struct EditorState: Sendable, Equatable {
    public var drafts: [EditableFile: FileDraft] = [:]
    public var saving = false
    public var notice: EditorNotice?
    public init() {}
}

/// The compose/.env editor for one stack: the files opened so far (each with the user's draft), the server-side checks of
/// those drafts, and saving. Reads and checks change nothing on the server; a save is a `.mutate` intent that the caller
/// must have confirmed. The rules of `StackEditorModel` on the Mac, in Core so the phone apps share them with tests
/// (the same as `StackEditor` in the Kotlin core).
@MainActor
public final class StackEditor {
    public private(set) var state = EditorState() { didSet { onChange?(state) } }
    /// Called after every change of `state`.
    public var onChange: ((EditorState) -> Void)?

    private let session: StackFileSession
    private let stack: DockerStack
    private let serverName: String
    private let isReadOnly: () -> Bool
    private let checkDelay: TimeInterval
    private var checks: [EditableFile: Task<Void, Never>] = [:]
    private var generations: [EditableFile: Int] = [:]

    public init(session: StackFileSession, stack: DockerStack, serverName: String, isReadOnly: @escaping () -> Bool,
                checkDelay: TimeInterval = 0.6) {
        self.session = session
        self.stack = stack
        self.serverName = serverName
        self.isReadOnly = isReadOnly
        self.checkDelay = checkDelay
    }

    public var files: [EditableFile] { session.files }

    public func draft(_ file: EditableFile) -> FileDraft { state.drafts[file] ?? FileDraft() }
    private func update(_ file: EditableFile, _ change: (inout FileDraft) -> Void) {
        var d = draft(file)
        change(&d)
        state.drafts[file] = d
    }

    // MARK: reading

    public func open(_ file: EditableFile) {
        let d = draft(file)
        if d.original == nil, !d.loading { load(file) }
    }

    private func load(_ file: EditableFile) {
        update(file) { $0.loading = true; $0.loadError = nil }
        Task {
            do {
                let read = try await session.read(file)
                update(file) {
                    $0 = FileDraft()
                    $0.original = read
                    $0.text = read.content ?? ""
                    $0.loadError = read == .tooLarge ? StackFileError.tooLarge.errorDescription : nil
                }
            } catch {
                update(file) { $0.loading = false; $0.loadError = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            }
        }
    }

    /// Throws away the draft and re-reads the file (after a conflict, or on request).
    public func reload(_ file: EditableFile) {
        checks[file]?.cancel()
        state.notice = nil
        update(file) { $0.original = nil; $0.checking = false }
        load(file)
    }

    // MARK: editing

    public func setText(_ file: EditableFile, _ text: String) {
        let d = draft(file)
        guard d.original != nil, d.text != text else { return }
        update(file) { $0.text = text; $0.local = file.isEnv ? EnvSyntax.check(text) : [] }
        state.notice = nil
        scheduleCheck(file)
    }

    public func revert(_ file: EditableFile) {
        if let original = draft(file).original { setText(file, original.content ?? "") }
    }

    public func isDirty(_ file: EditableFile) -> Bool { draft(file).isDirty }
    public var hasUnsavedChanges: Bool { files.contains { isDirty($0) } }

    public func dismissNotice() { state.notice = nil }

    // MARK: checking

    private func scheduleCheck(_ file: EditableFile) {
        checks[file]?.cancel()
        let generation = (generations[file] ?? 0) + 1
        generations[file] = generation
        let d = draft(file)
        // Nothing to check when it matches the server, and a syntax error found locally needs no round trip.
        guard d.isDirty, d.local.isEmpty else {
            update(file) { $0.validation = nil; $0.validatedText = nil; $0.checkError = nil; $0.checking = false }
            return
        }
        update(file) { $0.checking = true }
        let text = d.text
        let session = session
        let delay = checkDelay
        checks[file] = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))   // wait for a pause in typing
            guard !Task.isCancelled else { return }
            var outcome: ValidationResult?
            var failure: String?
            do { outcome = try await session.validate(file, content: text) } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            // Only the newest check for this file may report.
            guard generations[file] == generation else { return }
            update(file) {
                $0.validation = outcome
                $0.validatedText = outcome == nil ? nil : text
                $0.checkError = failure
                $0.checking = false
            }
        }
    }

    /// The checklist under the editor (YAML syntax, schema, docker compose config; or .env syntax and the compose check).
    public func rows(_ file: EditableFile) -> [EditorCheckRow] {
        guard let d = state.drafts[file], d.original != nil, d.isDirty else { return [] }
        return EditorChecks.rows(isEnv: file.isEnv, serverName: serverName, local: d.local, checkError: d.checkError,
                                 validation: d.validation, validatedText: d.validatedText, text: d.text)
    }

    // MARK: saving

    public func canSave(_ file: EditableFile) -> Bool {
        guard let d = state.drafts[file] else { return false }
        return d.isDirty && !state.saving && !isReadOnly() && d.passedCheck
    }

    public func canRedeploy(_ file: EditableFile) -> Bool { canSave(file) && ComposeAction.up.command(for: stack) != nil }

    /// Why Save is off, or nil when it can go ahead.
    public func saveBlockedReason(_ file: EditableFile) -> String? {
        guard let d = state.drafts[file] else { return "Not loaded yet" }
        if isReadOnly() { return "Read-only mode is on" }
        if state.saving { return "Saving…" }
        if !d.isDirty { return "No changes to save" }
        if !d.local.isEmpty { return "Fix the syntax error first" }
        if d.checking || d.validatedText != d.text { return d.checkError ?? "Waiting for the check on \(serverName)" }
        if d.validation?.isValid == false { return "Fix the errors above first" }
        return nil
    }

    /// The edit to confirm for a save (what was opened, and what it should become), or nil when it can't be saved now.
    public func edit(for file: EditableFile) -> FileEdit? {
        guard canSave(file) else { return nil }
        let d = draft(file)
        return FileEdit(file: file, original: d.original?.content, originalSHA: d.original?.sha256, content: d.text)
    }

    public func intent(for edit: FileEdit) -> Intent? { session.intent(for: edit) }

    /// Saves a confirmed edit. `onSaved` runs after a successful save (the redeploy).
    public func save(_ edit: FileEdit, redeploy: Bool, onSaved: @escaping @MainActor () -> Void = {}) {
        guard !state.saving else { return }
        state.saving = true
        state.notice = nil
        let session = session
        Task {
            defer { state.saving = false }
            do {
                switch try await session.save(edit, confirmation: try session.confirm(edit)) {
                case .saved(let sha):
                    update(edit.file) { d in
                        let old: RemoteFile? = if case .file(let f) = d.original { f } else { nil }
                        d.original = .file(RemoteFile(content: edit.content, sha256: sha, mode: old?.mode ?? "600",
                                                      owner: old?.owner ?? "", modifiedAt: Int64(Date().timeIntervalSince1970)))
                        d.validation = nil
                        d.validatedText = nil
                        d.checkError = nil
                    }
                    state.notice = .saved(file: edit.file.fileName, redeployed: redeploy)
                    onSaved()
                case .changedOnServer:
                    state.notice = .changedOnServer(edit.file)
                case .invalid(let issues):
                    update(edit.file) { $0.validation = ValidationResult(issues: issues); $0.validatedText = edit.content }
                }
            } catch {
                state.notice = .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
    }

    public func close() {
        for task in checks.values { task.cancel() }
        checks = [:]
    }
}
