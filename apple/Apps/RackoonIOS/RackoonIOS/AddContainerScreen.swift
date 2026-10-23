import RackoonCore
import SwiftUI

/// SwiftUI's view of Core's `AddContainerDraft`.
@MainActor @Observable
final class AddContainerModel {
    private(set) var state: AddState
    @ObservationIgnored let draft: AddContainerDraft

    init(docker: DockerModel, safety: SafetyStore) {
        draft = AddContainerDraft(transport: docker.transport, policy: safety.policy, serverName: docker.serverName,
                                  folder: docker.suggestedStackFolder,
                                  stacks: { [weak docker] in docker?.stacks ?? [] },
                                  containers: { [weak docker] in docker?.state.snapshot?.containers ?? [] },
                                  stackBlockedReason: { [weak docker] in docker?.composeBlockedReason(for: $0) })
        state = draft.state
        draft.onChange = { [weak self] in self?.state = $0 }
    }
}

/// Add a container to a new stack or an existing one: the form (or a pasted compose.yaml for a new stack), the checks that
/// run on the server as you type (compose, the image on its registry, ports in use and by whom, the container name), the
/// files that will be written, and Save or Create and Start, which ask first. The same rules as the Mac and Android.
struct AddContainerScreen: View {
    @Environment(AppModel.self) private var model
    let docker: DockerModel
    let server: Server
    /// Called with the stack's id once it was written (and started, if asked), to open its page; nil when cancelled.
    let done: (String?) -> Void
    @State private var add: AddContainerModel?
    @State private var pending: PendingAction?
    @State private var leaving = false
    // What the fields edit. Plain state, passed on to the draft as it changes: text fields bound to computed values can
    // lose or misplace keystrokes while the draft re-renders the form.
    @State private var stackName = ""
    @State private var folder = ""
    @State private var pasteCompose = ""
    @State private var pasteEnv = ""
    @State private var spec = ContainerSpec()

    var body: some View {
        NavigationStack {
            Group {
                if let add { form(add) } else { ProgressView() }
            }
            .background(model.tokens.background)
            .navigationTitle("Add Container")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if add?.draft.isDirty == true { leaving = true } else { add?.draft.close(); done(nil) }
                    }
                }
            }
            .confirmationDialog("Discard this container?", isPresented: $leaving, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { add?.draft.close(); done(nil) }
                Button("Keep Editing", role: .cancel) {}
            }
            .confirmAction($pending)
        }
        .interactiveDismissDisabled(add?.draft.isDirty == true)
        .onAppear {
            guard add == nil else { return }
            let made = AddContainerModel(docker: docker, safety: model.safety)
            add = made
            folder = made.state.folder
            made.draft.start()
        }
        .onChange(of: stackName) { _, v in add?.draft.setStackName(v) }
        .onChange(of: folder) { _, v in if add?.state.folder != v { add?.draft.setFolder(v) } }
        .onChange(of: pasteCompose) { _, v in add?.draft.setPasteCompose(v) }
        .onChange(of: pasteEnv) { _, v in if add?.state.pasteEnv != v { add?.draft.setPasteEnv(v) } }
        .onChange(of: spec) { _, v in add?.draft.setSpec(v) }
    }

    @ViewBuilder
    private func form(_ add: AddContainerModel) -> some View {
        let t = model.tokens
        let d = add.draft
        let s = add.state
        let pasted = s.paste && s.target == .newStack
        Form {
            Section {
                Picker("Add to", selection: Binding(get: { d.state.target }, set: { d.setTarget($0) })) {
                    Text("New stack").tag(AddTarget.newStack)
                    Text("Existing stack").tag(AddTarget.existing)
                }
                .pickerStyle(.segmented)
                switch s.target {
                case .newStack:
                    TextField("Stack name", text: $stackName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("addStackName")
                    if let problem = d.newStackNameProblem() { problemText(problem) }
                    TextField("Folder", text: $folder)
                        .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("Paste a compose.yaml instead", isOn: Binding(get: { d.state.paste }, set: { d.setPaste($0) }))
                case .existing:
                    Picker("Stack", selection: Binding(get: { d.state.existingName }, set: { if let n = $0 { d.chooseExisting(n) } })) {
                        Text("Choose…").tag(String?.none)
                        ForEach(d.existingCandidates) { Text($0.name).tag(String?.some($0.name)) }
                    }
                }
            } footer: {
                if s.target == .newStack, let dir = d.plan().directory { Text("Creates \(dir) on \(server.name).") }
            }
            .listRowBackground(t.card)

            if pasted {
                Section("compose.yaml") {
                    TextEditor(text: $pasteCompose)
                        .font(.caption.monospaced()).frame(minHeight: 180)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .listRowBackground(t.card)
                Section(".env (optional)") {
                    TextEditor(text: $pasteEnv)
                        .font(.caption.monospaced()).frame(minHeight: 70)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    let missing = d.missingVariables()
                    if !missing.isEmpty {
                        Button("Add \(missing.joined(separator: ", ")) to .env") {
                            d.addMissingVariables()
                            pasteEnv = d.state.pasteEnv
                        }
                    }
                }
                .listRowBackground(t.card)
            } else {
                specSections(add)
            }

            Section("Checks on \(server.name)") {
                ForEach(d.rows()) { row in CheckRow(row: row) }
            }
            .listRowBackground(t.card)

            if !pasted {
                Section("Files that will be written") {
                    FilePreview(title: "compose.yaml", text: d.composeText(), changed: d.changedLines(env: false))
                    if !d.envText().isEmpty { FilePreview(title: ".env", text: d.envText(), changed: d.changedLines(env: true)) }
                }
                .listRowBackground(t.card)
            }

            if let notice = s.notice {
                Section { Text(notice).foregroundStyle(t.warn) }.listRowBackground(t.card)
            }

            Section {
                let blocked = d.deployBlockedReason()
                Button { ask(add, start: true) } label: {
                    HStack { Text(s.target == .newStack ? "Create and Start" : "Add and Start"); Spacer(); if s.working { ProgressView() } }
                }
                .foregroundStyle(blocked == nil ? t.accent : t.muted)
                .disabled(blocked != nil)
                .accessibilityIdentifier("addCreateStart")
                Button(s.target == .newStack ? "Create Only" : "Add Only") { ask(add, start: false) }
                    .foregroundStyle(blocked == nil ? t.accent : t.muted)
                    .disabled(blocked != nil)
            } footer: {
                if let blocked = d.deployBlockedReason() { Text(blocked) }
            }
            .listRowBackground(t.card)
        }
        .themedList(t)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func specSections(_ add: AddContainerModel) -> some View {
        let t = model.tokens
        Section("Container") {
            TextField("Container name", text: $spec.name)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("addContainerName")
            if !spec.name.isEmpty, let p = spec.nameProblem { problemText(p) }
            TextField("Image, e.g. louislam/uptime-kuma:1", text: $spec.image)
                .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("addImage")
            if !spec.image.isEmpty, let p = spec.imageProblem { problemText(p) }
            Picker("Restart", selection: $spec.restart) {
                ForEach(RestartPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        }
        .listRowBackground(t.card)
        Section("Ports (host : container)") {
            ForEach($spec.ports) { $row in
                HStack {
                    TextField("8080", text: $row.host).keyboardType(.numbersAndPunctuation)
                    Text(":").foregroundStyle(t.muted)
                    TextField("80", text: $row.container).keyboardType(.numbersAndPunctuation)
                }
                .font(.body.monospaced())
                if !row.isBlank, let p = ContainerSpec.portProblem(row) { problemText(p) }
            }
            .onDelete { spec.ports.remove(atOffsets: $0) }
            Button { spec.ports.append(PortRow()) } label: { Label("Add Port", systemImage: "plus") }
        }
        .listRowBackground(t.card)
        Section("Volumes (host path or volume : container path)") {
            ForEach($spec.volumes) { $row in
                VStack {
                    TextField("./data", text: $row.source)
                    TextField("/app/data", text: $row.target)
                }
                .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !row.isBlank, let p = ContainerSpec.volumeProblem(row) { problemText(p) }
            }
            .onDelete { spec.volumes.remove(atOffsets: $0) }
            Button { spec.volumes.append(VolumeRow()) } label: { Label("Add Volume", systemImage: "plus") }
        }
        .listRowBackground(t.card)
        Section {
            ForEach($spec.env) { $row in
                HStack {
                    TextField("NAME", text: $row.key).textInputAutocapitalization(.characters)
                    Text("=").foregroundStyle(t.muted)
                    TextField("value", text: $row.value).textInputAutocapitalization(.never)
                }
                .font(.body.monospaced()).autocorrectionDisabled()
                if !row.isBlank, let p = ContainerSpec.envProblem(row) { problemText(p) }
            }
            .onDelete { spec.env.remove(atOffsets: $0) }
            Button { spec.env.append(EnvRow()) } label: { Label("Add Variable", systemImage: "plus") }
        } header: {
            Text("Environment")
        } footer: {
            Text("Values go into the stack's .env (readable only by its owner); compose.yaml refers to them.")
        }
        .listRowBackground(t.card)
    }

    private func problemText(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(model.tokens.danger)
    }

    /// The confirmation: the files (or the diff) and, for Start, the `up -d` command.
    private func ask(_ add: AddContainerModel, start: Bool) {
        guard let request = add.draft.request(start: start) else { return }
        let up = start ? (ComposeAction.up.command(for: request.stack) ?? "") : ""
        pending = PendingAction(
            title: request.title, message: request.message, serverName: server.name, command: up, destructive: false,
            preview: request.preview, confirmLabel: start ? "Create and Start" : "Write Files",
            run: {
                add.draft.perform(request) { result in
                    docker.adopt(result.stack)
                    if result.start { docker.runDirect(.up, on: result.stack) }
                    Task { await docker.refresh() }
                    add.draft.close()
                    done(result.stack.id)
                }
            })
    }
}

private struct CheckRow: View {
    @Environment(AppModel.self) private var model
    let row: EditorCheckRow

    var body: some View {
        let t = model.tokens
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch row.state {
            case .pass: Image(systemName: "checkmark.circle.fill").foregroundStyle(t.ok)
            case .fail: Image(systemName: "xmark.circle.fill").foregroundStyle(t.danger)
            case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(t.warn)
            case .skipped: Image(systemName: "minus.circle").foregroundStyle(t.muted)
            case .running: ProgressView().controlSize(.mini)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.subheadline)
                if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(t.secondary) }
            }
        }
    }
}

/// A read-only file with its new or changed lines marked.
private struct FilePreview: View {
    @Environment(AppModel.self) private var model
    let title: String
    let text: String
    let changed: Set<Int>

    var body: some View {
        let t = model.tokens
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(t.secondary)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { i, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.caption2.monospaced())
                            .fixedSize()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(changed.contains(i + 1) ? t.ok.opacity(0.15) : .clear)
                    }
                }
            }
        }
    }
}
