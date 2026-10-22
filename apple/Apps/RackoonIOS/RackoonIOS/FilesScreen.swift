import RackoonCore
import SwiftUI
import UniformTypeIdentifiers

/// One server's files: browse its folders, upload files or whole folders picked in the Files app, download into
/// Rackoon's Downloads folder (On My iPhone › Rackoon in the Files app) and share them, and make, rename or delete items.
/// Every change asks first with its exact command; Read-only blocks them.
struct FilesScreen: View {
    @Environment(AppModel.self) private var model
    let serverID: String

    var body: some View {
        if let server = model.servers.server(id: serverID) {
            switch model.filesModel(for: server) {
            case .success(let files): FilesBrowser(files: files)
            case .failure(let reason):
                ContentUnavailableView("Files can't be read yet", systemImage: "folder", description: Text(reason.message))
                    .navigationTitle("Files")
            }
        } else {
            ContentUnavailableView("Server removed", systemImage: "server.rack")
        }
    }
}

private struct FilesBrowser: View {
    @Environment(AppModel.self) private var model
    @Bindable var files: FilesModel
    @AppStorage("filesShowHidden") private var showHidden = false
    @State private var importing = false
    @State private var confirmingDelete: [FolderEntry]?

    var body: some View {
        let t = model.tokens
        let rows = files.rows(showHidden: showHidden)
        List {
            if !files.transfers.isEmpty {
                Section {
                    ForEach(files.transfers) { TransferRow(transfer: $0) }
                    if files.hasFinished {
                        Button("Clear Finished") { files.clearFinished() }.foregroundStyle(t.accent)
                    }
                } header: {
                    Text("Transfers")
                }
                .listRowBackground(t.card)
            }
            if let notice = files.notice {
                Section { Label(notice, systemImage: "info.circle.fill").foregroundStyle(t.warn) }.listRowBackground(t.card)
            }
            if let error = files.error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(t.warn) }.listRowBackground(t.card)
            }
            Section {
                if let parent = files.parent {
                    Button { Task { await files.open(parent) } } label: {
                        Label("Up to \(parent == "/" ? "/" : (parent as NSString).lastPathComponent)", systemImage: "arrow.turn.left.up")
                    }
                    .foregroundStyle(t.accent)
                }
                ForEach(rows) { entry in
                    EntryRow(entry: entry, open: { Task { await files.open(RemotePath.join(files.path, entry.name)) } })
                        .contextMenu { menu(entry) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { files.download(entry) } label: { Label("Download", systemImage: "arrow.down.circle") }
                                .tint(t.accent)
                            Button(role: .destructive) { files.delete([entry]) } label: { Label("Delete", systemImage: "trash") }
                                .tint(t.danger)
                                .disabled(model.safety.readOnly)
                        }
                }
                if rows.isEmpty, files.listing != nil {
                    Text(files.listing?.entries.isEmpty == true ? "Empty folder" : "Only hidden items. Turn on Show Hidden to see them.")
                        .foregroundStyle(t.secondary)
                }
                if files.listing == nil, files.loading {
                    HStack { ProgressView(); Text("Reading \(files.path.isEmpty ? "the home folder" : files.path)…").foregroundStyle(t.secondary) }
                }
            } header: {
                Text(files.path).textCase(nil).font(.caption.monospaced()).lineLimit(1).truncationMode(.head)
            } footer: {
                if files.listing?.truncated == true { Text("Only the first \(RemoteFiles.maxEntries) items are listed.") }
            }
            .listRowBackground(t.card)
        }
        .themedList(t)
        .navigationTitle(files.path == "/" ? "/" : (files.path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { importing = true } label: { Label("Upload…", systemImage: "square.and.arrow.up") }
                        .disabled(model.safety.readOnly || files.preparing)
                    Button { files.newFolder() } label: { Label("New Folder…", systemImage: "folder.badge.plus") }
                        .disabled(model.safety.readOnly)
                    Divider()
                    Toggle(isOn: $showHidden) { Label("Show Hidden", systemImage: "eye") }
                    Menu("Go to") {
                        ForEach(RemotePath.crumbs(files.path).reversed(), id: \.path) { crumb in
                            Button(crumb.name.isEmpty ? "/" : crumb.name) { Task { await files.open(crumb.path) } }
                        }
                    }
                } label: {
                    if files.preparing || files.loading { ProgressView() } else { Image(systemName: "ellipsis.circle") }
                }
                .accessibilityLabel("File actions")
                .accessibilityIdentifier("filesMenu")
            }
        }
        .refreshable { await files.reload() }
        .task { await files.start() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): files.upload(urls: urls)
            case .failure(let error): files.notice = error.localizedDescription
            }
        }
        .confirmAction($files.pending)
        .confirmationDialog(conflictTitle, isPresented: Binding(get: { files.conflict != nil }, set: { if !$0 { files.conflict = nil } }),
                            titleVisibility: .visible, presenting: files.conflict) { conflict in
            Button("Replace") { files.conflict = nil; conflict.resolve(.replace) }
            Button("Keep Both") { files.conflict = nil; conflict.resolve(.keepBoth) }
            Button("Skip These") { files.conflict = nil; conflict.resolve(.skipExisting) }
            Button("Cancel", role: .cancel) { files.conflict = nil }
        } message: { conflict in
            Text(conflict.names.joined(separator: ", "))
        }
        .sheet(item: $files.namePrompt) { prompt in NamePromptSheet(prompt: prompt) }
        .sheet(item: $files.deletePrompt) { prompt in DeleteSheet(prompt: prompt, serverName: files.server.name) }
    }

    private var conflictTitle: String {
        guard let conflict = files.conflict else { return "" }
        return conflict.names.count == 1 ? "“\(conflict.names[0])” already exists here" : "\(conflict.names.count) items already exist here"
    }

    @ViewBuilder private func menu(_ entry: FolderEntry) -> some View {
        Button { files.download(entry) } label: { Label("Download", systemImage: "arrow.down.circle") }
        Button { files.rename(entry) } label: { Label("Rename…", systemImage: "pencil") }.disabled(model.safety.readOnly)
        Button { UIPasteboard.general.string = RemotePath.join(files.path, entry.name) } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        Divider()
        Button(role: .destructive) { files.delete([entry]) } label: { Label("Delete…", systemImage: "trash") }.disabled(model.safety.readOnly)
    }
}

private struct EntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: FolderEntry
    let open: () -> Void

    var body: some View {
        let t = model.tokens
        let content = HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : (entry.kind == .symlink ? "link" : "doc"))
                .foregroundStyle(entry.isDirectory ? t.accent : t.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(t.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        if entry.isDirectory {
            Button(action: open) { content }.buttonStyle(.plain).accessibilityIdentifier("folder-\(entry.name)")
        } else {
            content.accessibilityIdentifier("file-\(entry.name)")
        }
    }

    private var detail: String {
        var parts: [String] = []
        if !entry.isDirectory { parts.append(Present.bytes(entry.size)) }
        if let target = entry.linkTarget { parts.append("→ \(target)") }
        parts.append(entry.modified.formatted(date: .abbreviated, time: .shortened))
        parts.append(entry.permissions)
        return parts.joined(separator: " · ")
    }
}

private struct TransferRow: View {
    @Environment(AppModel.self) private var model
    let transfer: FileTransfer

    var body: some View {
        let t = model.tokens
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: transfer.direction == .upload ? "arrow.up.circle" : "arrow.down.circle").foregroundStyle(t.accent)
                Text(transfer.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                switch transfer.state {
                case .waiting, .running:
                    Button { transfer.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(t.muted).accessibilityLabel("Cancel \(transfer.name)")
                case .done:
                    if let url = transfer.localURL {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share \(transfer.name)")
                    } else {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(t.ok)
                    }
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(t.danger)
                case .cancelled: Image(systemName: "stop.circle").foregroundStyle(t.warn)
                }
            }
            if case .running = transfer.state {
                if let fraction = transfer.fraction { ProgressView(value: fraction) } else { ProgressView() }
            }
            Text(status).font(.caption).foregroundStyle(statusColor(t)).lineLimit(3)
        }
    }

    private var status: String {
        let moved = Present.bytes(transfer.bytes) + (transfer.total.map { " of " + Present.bytes($0) } ?? "")
        switch transfer.state {
        case .waiting: return "Waiting"
        case .running: return moved
        case .done: return transfer.direction == .upload ? "Uploaded to \(transfer.destination)" : "In Rackoon › Downloads"
        case .failed(let why): return why
        case .cancelled: return "Cancelled"
        }
    }

    private func statusColor(_ t: Tokens) -> SwiftUI.Color {
        if case .failed = transfer.state { return t.danger }
        return t.secondary
    }
}

/// One name to type (a new folder, a new name), with the exact command it will run.
private struct NamePromptSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let prompt: NamePrompt
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        let t = model.tokens
        let problem = prompt.problem(name)
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(submit)
                        .accessibilityIdentifier("fileName")
                } footer: {
                    Text(problem ?? prompt.message)
                }
                .listRowBackground(t.card)
                if problem == nil, let command = prompt.command(name) {
                    Section("Command") { Text(command).font(.caption.monospaced()).textSelection(.enabled) }
                        .listRowBackground(t.card)
                }
            }
            .themedList(t)
            .navigationTitle(prompt.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(prompt.action, action: submit).disabled(problem != nil) }
            }
            .onAppear { name = prompt.initial; focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func submit() {
        guard prompt.problem(name) == nil else { return }
        let typed = name
        dismiss()
        prompt.run(typed)
    }
}

/// Deleting from the server: what goes, the exact commands, and for a folder the typed word first.
private struct DeleteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let prompt: DeletePrompt
    let serverName: String
    @State private var typed = ""

    var body: some View {
        let t = model.tokens
        let plan = prompt.plan
        let ready = plan.problems.isEmpty && (!plan.hasFolder || typed.trimmingCharacters(in: .whitespaces).lowercased() == DeletePlan.confirmWord)
        NavigationStack {
            Form {
                Section {
                    Text("Deletes from \(prompt.directory) on \(serverName). There is no undo: the server has no Trash.")
                    ForEach(prompt.names, id: \.self) { Text("• " + $0).font(.callout.monospaced()) }
                }
                .listRowBackground(t.card)
                if !plan.problems.isEmpty {
                    Section { ForEach(plan.problems, id: \.self) { Label($0, systemImage: "hand.raised.fill").foregroundStyle(t.danger) } }
                        .listRowBackground(t.card)
                } else if plan.hasFolder {
                    Section {
                        TextField("Type \(DeletePlan.confirmWord)", text: $typed)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("deleteWord")
                    } footer: {
                        Text("A folder is deleted with everything in it. Type “\(DeletePlan.confirmWord)” to confirm.")
                    }
                    .listRowBackground(t.card)
                }
                if !plan.commands.isEmpty {
                    Section("Command") { Text(plan.commands.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled) }
                        .listRowBackground(t.card)
                }
                Section {
                    Button(role: .destructive) {
                        dismiss()
                        prompt.run()
                    } label: {
                        Text("Delete").frame(maxWidth: .infinity)
                    }
                    .foregroundStyle(ready ? t.danger : t.muted)
                    .disabled(!ready)
                    .accessibilityIdentifier("confirmDelete")
                }
                .listRowBackground(t.card)
            }
            .themedList(t)
            .navigationTitle(prompt.names.count == 1 ? "Delete “\(prompt.names[0])”?" : "Delete \(prompt.names.count) items?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
