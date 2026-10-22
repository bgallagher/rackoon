import RackoonCore
import SwiftUI
import UIKit

/// SwiftUI's view of one stack's Core `StackEditor`: the drafts, checks and saving of its compose and .env files.
@MainActor @Observable
final class StackEditorModel {
    private(set) var state = EditorState()
    let stackID: String
    @ObservationIgnored let editor: StackEditor

    init(stack: DockerStack, transport: SSHTransport, safety: SafetyStore, serverName: String) {
        stackID = stack.id
        let policy = safety.policy
        editor = StackEditor(session: StackFileSession(transport: transport, policy: policy, stack: stack), stack: stack,
                             serverName: serverName, isReadOnly: { policy.isReadOnly })
        editor.onChange = { [weak self] in self?.state = $0 }
    }

    func draft(_ file: EditableFile) -> FileDraft { state.drafts[file] ?? FileDraft() }
    func isDirty(_ file: EditableFile) -> Bool { draft(file).isDirty }
    var hasUnsavedChanges: Bool { state.drafts.values.contains { $0.isDirty } }
    func close() { editor.close() }
}

/// One compose or .env file: a code view (monospaced, highlighted, changed lines green, failing lines red), the checklist of
/// the server's own `docker compose config` on exactly this text, and Save / Save and Redeploy, which ask first with the
/// diff. A file changed on the server meanwhile is never overwritten: Reload from Server or Keep Editing.
struct EditorScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let editor: StackEditorModel
    let docker: DockerModel
    let stack: DockerStack
    let file: EditableFile
    let openOutput: () -> Void
    @State private var pending: PendingAction?
    @State private var leaving = false

    var body: some View {
        let t = model.tokens
        let core = editor.editor
        let draft = editor.draft(file)
        let readOnly = model.safety.readOnly
        VStack(spacing: 0) {
            if let error = draft.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(t.warn).padding(16)
            }
            if draft.original == nil, draft.loadError == nil {
                ProgressView("Reading \(file.fileName)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if draft.original != nil {
                if draft.original == .missing {
                    Text("\(file.fileName) doesn't exist yet. Saving creates it, readable only by its owner.")
                        .font(.footnote).foregroundStyle(t.secondary).padding(.horizontal, 16).padding(.top, 8)
                }
                CodeTextView(text: draft.text, isEnv: file.isEnv, editable: !readOnly, theme: model.appearance.resolvedTheme,
                             changed: draft.changedLines, errors: draft.errorLines,
                             onChange: { core.setText(file, $0) })
                    .accessibilityIdentifier("codeEditor")
                checklist(core.rows(file))
                notice
                buttons(core, draft: draft)
            }
        }
        .background(t.background)
        .navigationTitle(file.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(draft.isDirty)
        .toolbar {
            if draft.isDirty {
                ToolbarItem(placement: .topBarLeading) {
                    Button { leaving = true } label: { Label("Back", systemImage: "chevron.backward") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Revert") { core.revert(file) }
                }
            }
        }
        .confirmationDialog("Discard your changes to \(file.fileName)?", isPresented: $leaving, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { core.revert(file); dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("They have not been saved to \(docker.serverName).")
        }
        .confirmAction($pending)
        .onAppear { core.open(file) }
    }

    private func checklist(_ rows: [EditorCheckRow]) -> some View {
        let t = model.tokens
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    switch row.state {
                    case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(t.ok)
                    case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(t.danger)
                    case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(t.warn)
                    case .skipped: Image(systemName: "minus.circle").foregroundStyle(t.muted)
                    case .running: ProgressView().controlSize(.mini)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).font(.footnote.weight(.medium))
                        if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(t.secondary).lineLimit(4) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.top, rows.isEmpty ? 0 : 8)
    }

    @ViewBuilder private var notice: some View {
        let t = model.tokens
        switch editor.state.notice {
        case .saved(let name, let redeployed):
            Label(redeployed ? "Saved \(name). Updating the stack…" : "Saved \(name). It takes effect at the next Update.",
                  systemImage: "checkmark.circle.fill")
                .font(.footnote).foregroundStyle(t.ok).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 8)
        case .changedOnServer(let changed) where changed == file:
            VStack(alignment: .leading, spacing: 6) {
                Label("\(file.fileName) changed on \(docker.serverName) since you opened it, so nothing was saved.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(t.warn)
                HStack {
                    Button("Reload from Server") { editor.editor.reload(file) }.buttonStyle(.bordered)
                    Button("Keep Editing") { editor.editor.dismissNotice() }.buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 8)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").font(.footnote).foregroundStyle(t.danger)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 8)
        default:
            EmptyView()
        }
    }

    private func buttons(_ core: StackEditor, draft: FileDraft) -> some View {
        let t = model.tokens
        let blocked = core.saveBlockedReason(file)
        return VStack(spacing: 6) {
            if draft.isDirty, let blocked {
                Text(blocked).font(.caption).foregroundStyle(t.muted).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Save") { requestSave(core, redeploy: false) }
                    .buttonStyle(.bordered)
                    .disabled(!core.canSave(file))
                Button("Save and Redeploy") { requestSave(core, redeploy: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!core.canRedeploy(file) || docker.composeBlockedReason(for: stack) != nil)
                    .accessibilityIdentifier("saveAndRedeploy")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
    }

    /// Asks once (the diff, plus the `up -d` command for a redeploy), then saves; a redeploy then streams into the Output.
    private func requestSave(_ core: StackEditor, redeploy: Bool) {
        guard let edit = core.edit(for: file), let intent = core.intent(for: edit) else { return }
        let up = redeploy ? ComposeAction.up.command(for: stack) : nil
        if redeploy, up == nil { return }
        pending = PendingAction(
            title: redeploy ? "Save \(file.fileName) and update \(stack.name)?" : "Save \(file.fileName)?",
            message: "\(docker.serverName) checks the file with docker compose config first, and the old one is kept as \(file.fileName).rackoon.bak."
                + (redeploy ? " Then the stack is updated: containers whose settings changed are recreated." : " It takes effect the next time the stack is updated."),
            serverName: docker.serverName, command: up ?? "", destructive: false, preview: intent.preview,
            confirmLabel: redeploy ? "Save and Redeploy" : "Save",
            run: {
                core.save(edit, redeploy: redeploy) {
                    guard redeploy else { return }
                    docker.runDirect(.up, on: stack)
                    openOutput()
                    dismiss()
                }
            })
    }
}

/// A plain-text code view: monospaced, no autocorrection or smart punctuation, colours from the terminal theme
/// (`SyntaxHighlighter`, Core), bands behind changed (green) and failing (red) lines, Tab as two spaces and a key row with
/// the punctuation a phone keyboard hides.
struct CodeTextView: UIViewRepresentable {
    let text: String
    let isEnv: Bool
    let editable: Bool
    let theme: TerminalTheme
    let changed: Set<Int>
    let errors: Set<Int>
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: false)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.keyboardType = .asciiCapable
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        view.delegate = context.coordinator
        view.inputAccessoryView = context.coordinator.keyRow(for: view)
        context.coordinator.render(view, text: text, parent: self)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onChange = onChange
        view.isEditable = editable
        context.coordinator.render(view, text: text, parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var onChange: (String) -> Void
        private var lastKey = ""

        init(onChange: @escaping (String) -> Void) { self.onChange = onChange }

        /// Re-colours only when something that affects the colours changed, keeping the cursor where it was.
        func render(_ view: UITextView, text: String, parent: CodeTextView) {
            let key = "\(text.hashValue)|\(parent.theme.id)|\(parent.changed.sorted())|\(parent.errors.sorted())"
            guard key != lastKey else { return }
            lastKey = key
            let selection = view.selectedRange
            view.attributedText = Self.attributed(text, parent: parent)
            view.backgroundColor = UIColor(parent.theme.backgroundRGB)
            view.tintColor = UIColor(parent.theme.cursorRGB)
            view.typingAttributes = [.font: Self.font, .foregroundColor: UIColor(parent.theme.foregroundRGB)]
            let length = (text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, length), length: 0)
        }

        static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        static func attributed(_ text: String, parent: CodeTextView) -> NSAttributedString {
            let fg = UIColor(parent.theme.foregroundRGB)
            let ansi = parent.theme.ansiRGB.map { UIColor($0) }
            let out = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: fg])
            let ns = text as NSString
            // Bands behind whole lines: green for changed, red for failing (red wins).
            var lineNumber = 1
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
                if parent.errors.contains(lineNumber) {
                    out.addAttribute(.backgroundColor, value: UIColor.systemRed.withAlphaComponent(0.22), range: enclosing)
                } else if parent.changed.contains(lineNumber) {
                    out.addAttribute(.backgroundColor, value: UIColor.systemGreen.withAlphaComponent(0.16), range: enclosing)
                }
                lineNumber += 1
            }
            let tokens = parent.isEnv ? SyntaxHighlighter.env(text) : SyntaxHighlighter.yaml(text)
            for token in tokens where token.location + token.length <= ns.length && ansi.count >= 8 {
                let color: UIColor = switch token.kind {
                case .key: ansi[5]
                case .string: ansi[2]
                case .number: ansi[3]
                case .keyword: ansi[6]
                case .comment: fg.withAlphaComponent(0.45)
                case .punctuation: fg.withAlphaComponent(0.55)
                }
                out.addAttribute(.foregroundColor, value: color, range: NSRange(location: token.location, length: token.length))
            }
            return out
        }

        func textViewDidChange(_ view: UITextView) { onChange(view.text) }

        /// Return keeps the line's indentation; Tab is two spaces.
        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\t" {
                insert("  ", into: view)
                return false
            }
            guard text == "\n" else { return true }
            let ns = view.text as NSString
            let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
            let line = ns.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
            var indent = String(line.prefix { $0 == " " })
            if line.trimmingCharacters(in: .whitespaces).hasSuffix(":") { indent += "  " }
            insert("\n" + indent, into: view)
            return false
        }

        private func insert(_ text: String, into view: UITextView) {
            view.insertText(text)
        }

        func keyRow(for view: UITextView) -> UIView {
            let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            let keys = ["⇥", ":", "-", "\"", "'", "$", "{", "}", "[", "]", "#", "="]
            var items: [UIBarButtonItem] = []
            for key in keys {
                let item = UIBarButtonItem(title: key, primaryAction: UIAction { [weak view] _ in
                    view?.insertText(key == "⇥" ? "  " : key)
                })
                items.append(item)
            }
            items.append(UIBarButtonItem(systemItem: .flexibleSpace))
            items.append(UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak view] _ in view?.resignFirstResponder() }))
            bar.items = items
            return bar
        }
    }
}
