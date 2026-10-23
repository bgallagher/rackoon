import RackoonCore
import SwiftUI
import UIKit

/// The server's bookmarks: every container with Homepage labels (`homepage.href` and friends), grouped by `homepage.group`,
/// with Open, Copy, Edit and Remove, and Add Bookmark. Changes are written into the stack's compose file after the diff is
/// confirmed (the Homepage convention, so Homepage itself shows the same links).
struct BookmarksScreen: View {
    @Environment(AppModel.self) private var model
    let serverID: String

    var body: some View {
        if let server = model.servers.server(id: serverID) {
            switch model.dockerModel(for: server) {
            case .success(let docker): BookmarkList(docker: docker, server: server)
            case .failure(let reason):
                ContentUnavailableView("Bookmarks can't be read yet", systemImage: "bookmark", description: Text(reason.message))
                    .navigationTitle("Bookmarks")
            }
        } else {
            ContentUnavailableView("Server removed", systemImage: "server.rack")
        }
    }
}

private struct BookmarkList: View {
    @Environment(AppModel.self) private var model
    let docker: DockerModel
    let server: Server
    @State private var query = ""
    @State private var editing: BookmarkTarget?
    @State private var adding = false

    var body: some View {
        let t = model.tokens
        let items = BookmarkItem.items(in: docker.stacks).filter { matches($0) }
        let groups = Dictionary(grouping: items) { $0.bookmark.group ?? "" }
        let names = groups.keys.sorted { a, b in
            a.isEmpty != b.isEmpty ? !a.isEmpty : a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        List {
            if docker.state.error != nil || model.elevation.isUnlocked(server.id) {
                DockerAccessNotice(server: server, error: docker.state.error).listRowBackground(t.card)
            }
            ForEach(names, id: \.self) { name in
                Section(name.isEmpty ? "Other" : name) {
                    ForEach(groups[name] ?? []) { item in
                        row(item)
                    }
                }
                .listRowBackground(t.card)
            }
            if docker.state.snapshot != nil, items.isEmpty {
                Text(query.isEmpty ? "No bookmarks yet. Add one to link a service's web page; Homepage shows it too." : "Nothing matches.")
                    .foregroundStyle(t.muted).listRowBackground(t.card)
            } else if docker.state.snapshot == nil, docker.state.error == nil {
                HStack { ProgressView(); Text("Reading Docker on \(server.name)…").foregroundStyle(t.secondary) }.listRowBackground(t.card)
            }
        }
        .themedList(t)
        .navigationTitle("Bookmarks")
        .searchable(text: $query, prompt: "Name, address, service")
        .refreshable { await docker.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .disabled(model.safety.readOnly || BookmarkItem.bookmarkableStacks(docker.stacks).isEmpty)
                    .accessibilityLabel("Add Bookmark")
            }
        }
        .sheet(item: $editing) { target in
            BookmarkSheet(docker: docker, server: server, stack: target.stack, service: target.service, close: { editing = nil })
        }
        .sheet(isPresented: $adding) {
            BookmarkSheet(docker: docker, server: server, stack: nil, service: nil, close: { adding = false })
        }
        .onAppear { docker.attach() }
        .onDisappear { docker.detach() }
        .onChange(of: items.map(\.bookmark.href)) { _, hrefs in model.favicons.ensure(hrefs) }
    }

    private func matches(_ item: BookmarkItem) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let fields = [item.title, item.bookmark.href, item.service, item.stack.name, item.bookmark.group ?? "", item.bookmark.description ?? ""]
        return words.allSatisfy { w in fields.contains { $0.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
    }

    private func row(_ item: BookmarkItem) -> some View {
        let t = model.tokens
        let editable = !model.safety.readOnly && StackFiles.editable(for: item.stack) != nil && !item.stack.isStandalone
        return HStack(spacing: 12) {
            FaviconView(href: item.bookmark.href, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(item.bookmark.shortAddress).font(.caption).foregroundStyle(t.accent).lineLimit(1).truncationMode(.middle)
                    ScopeTag(href: item.bookmark.href)
                }
                Text(item.stack.name == item.service ? item.service : "\(item.service) in \(item.stack.name)")
                    .font(.caption).foregroundStyle(t.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let url = URL(string: item.bookmark.href) {
                Link(destination: url) { Image(systemName: "safari").font(.title3) }
                    .accessibilityLabel("Open \(item.title)")
            }
        }
        .contextMenu {
            if let url = URL(string: item.bookmark.href) { Link(destination: url) { Label("Open", systemImage: "safari") } }
            Button { UIPasteboard.general.string = item.bookmark.href } label: { Label("Copy Address", systemImage: "doc.on.doc") }
            if editable {
                Button { editing = BookmarkTarget(stack: item.stack, service: item.container.service) } label: { Label("Edit…", systemImage: "pencil") }
            }
        }
        .swipeActions {
            if editable {
                Button { editing = BookmarkTarget(stack: item.stack, service: item.container.service) } label: { Label("Edit", systemImage: "pencil") }
                    .tint(t.accent)
            }
        }
    }
}

/// Add, edit or remove one service's bookmark. The labels are written into the compose file that defines the service, after
/// the diff is confirmed; the server checks the file first and the old one is kept as .rackoon.bak. Save and Apply then
/// updates the stack (the label only shows once the container is recreated); Save Only does not.
struct BookmarkSheet: View {
    @Environment(AppModel.self) private var model
    let docker: DockerModel
    let server: Server
    let close: () -> Void
    private let locked: Bool
    @State private var stackID: String?
    @State private var service = ""
    @State private var url = ""
    @State private var name = ""
    @State private var group = ""
    @State private var icon = ""
    @State private var details = ""
    @State private var busy = false
    @State private var notice: String?
    @State private var pending: PendingAction?

    init(docker: DockerModel, server: Server, stack: DockerStack?, service: String?, close: @escaping () -> Void) {
        self.docker = docker
        self.server = server
        self.close = close
        locked = stack != nil
        _stackID = State(initialValue: stack?.id)
        if let stack {
            let names = stack.serviceNames
            let chosen = service.flatMap { names.contains($0) ? $0 : nil }
                ?? names.first { n in stack.containers.first { $0.service == n }?.bookmark != nil } ?? names.first ?? ""
            _service = State(initialValue: chosen)
            let b = stack.containers.first { $0.service == chosen }?.bookmark
            _url = State(initialValue: b?.href ?? "")
            _name = State(initialValue: b?.name ?? "")
            _group = State(initialValue: b?.group ?? "")
            _icon = State(initialValue: b?.icon ?? "")
            _details = State(initialValue: b?.description ?? "")
        }
    }

    private var stack: DockerStack? { stackID.flatMap { docker.stack(id: $0) } }
    private var existing: Bookmark? { stack?.containers.first { $0.service == service }?.bookmark }
    private var normalizedURL: String { BookmarkEditor.normalizedURL(url) }
    private var bookmark: Bookmark? {
        Bookmark.isValidURL(normalizedURL) ? Bookmark(href: normalizedURL, name: name, group: group, icon: icon, description: details) : nil
    }

    private var blockedReason: String? {
        if model.safety.readOnly { return "Read-only mode is on" }
        if busy { return "Working…" }
        guard let stack else { return "Choose a stack" }
        if service.isEmpty { return "This stack has no containers to bookmark" }
        if url.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a web address" }
        if bookmark == nil { return "Enter a web address such as https://app.example.com" }
        return docker.composeBlockedReason(for: stack)
    }

    var body: some View {
        let t = model.tokens
        let choices = BookmarkItem.bookmarkableStacks(docker.stacks)
        NavigationStack {
            Form {
                Section {
                    if locked, let stack {
                        LabeledContent("Stack", value: stack.name)
                    } else {
                        Picker("Stack", selection: $stackID) {
                            Text("Choose…").tag(String?.none)
                            ForEach(choices) { Text($0.name).tag(String?.some($0.id)) }
                        }
                    }
                    if let stack, stack.serviceNames.count > 1 {
                        Picker("Service", selection: $service) {
                            ForEach(stack.serviceNames, id: \.self) { Text($0).tag($0) }
                        }
                    } else if !service.isEmpty {
                        LabeledContent("Service", value: service)
                    }
                }
                .listRowBackground(t.card)
                Section {
                    TextField("Web address", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("bookmarkURL")
                    TextField("Name (optional)", text: $name)
                    TextField("Group (optional)", text: $group).textInputAutocapitalization(.never)
                    TextField("Icon (optional, e.g. grafana.png)", text: $icon).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Description (optional)", text: $details)
                } footer: {
                    Text("Written as homepage.* labels in the compose file, the convention the Homepage dashboard reads.")
                }
                .listRowBackground(t.card)
                if let notice {
                    Section { Text(notice).foregroundStyle(t.warn) }.listRowBackground(t.card)
                }
                Section {
                    Button { prepare(apply: true, removing: false) } label: {
                        HStack { Text("Save and Apply"); Spacer(); if busy { ProgressView() } }
                    }
                    .foregroundStyle(blockedReason == nil ? t.accent : t.muted)
                    .disabled(blockedReason != nil)
                    .accessibilityIdentifier("bookmarkSaveApply")
                    Button("Save Only") { prepare(apply: false, removing: false) }
                        .foregroundStyle(blockedReason == nil ? t.accent : t.muted)
                        .disabled(blockedReason != nil)
                    if existing != nil {
                        let removeBlocked = model.safety.readOnly || busy || stack.map { docker.composeBlockedReason(for: $0) } != nil
                        Button("Remove Bookmark", role: .destructive) { prepare(apply: true, removing: true) }
                            .foregroundStyle(removeBlocked ? t.muted : t.danger)
                            .disabled(removeBlocked)
                    }
                } footer: {
                    if let blockedReason { Text(blockedReason) }
                    else { Text("Save and Apply updates the stack, which recreates \(service) for a few seconds so the change shows up.") }
                }
                .listRowBackground(t.card)
            }
            .themedList(t)
            .navigationTitle(existing == nil ? "Add Bookmark" : "Edit Bookmark")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) } }
            .confirmAction($pending)
            .onChange(of: stackID) { _, _ in
                guard !locked, let stack else { return }
                choose(stack.serviceNames.first ?? "")
            }
            .onChange(of: service) { _, new in choose(new) }
        }
    }

    private func choose(_ new: String) {
        if service != new { service = new }
        notice = nil
        let b = existing
        url = b?.href ?? ""; name = b?.name ?? ""; group = b?.group ?? ""; icon = b?.icon ?? ""; details = b?.description ?? ""
    }

    /// Reads the compose file that defines the service, edits its labels and asks the user to confirm the diff.
    private func prepare(apply: Bool, removing: Bool) {
        guard let stack else { return }
        let changes = removing ? Bookmark.removalChanges : (bookmark?.labelChanges ?? [])
        guard !changes.isEmpty else { return }
        let service = service
        let session = StackFileSession(transport: docker.transport, policy: model.safety.policy, stack: stack)
        busy = true
        notice = nil
        Task {
            defer { busy = false }
            do {
                switch try await BookmarkEditor.plan(session: session, stack: stack, service: service, changes: changes,
                                                     removing: removing, serverName: server.name) {
                case .notice(let text):
                    notice = text
                case .ready(let edit):
                    guard let intent = session.intent(for: edit) else { notice = "That change can't be saved."; return }
                    let what = removing ? "Remove the bookmark from \(service)" : "Bookmark \(service)"
                    pending = PendingAction(
                        title: apply ? "\(what) and update \(stack.name)?" : "\(what)?",
                        message: "The labels are written into \(edit.file.fileName); the server checks the file first, and the old one is kept as \(edit.file.fileName).rackoon.bak."
                            + (apply ? " Then the stack is updated, which recreates \(service) (a few seconds of downtime) so the change shows up."
                                     : " It takes effect the next time the stack is updated."),
                        serverName: server.name, command: apply ? (ComposeAction.up.command(for: stack) ?? "") : "",
                        destructive: false, preview: intent.preview, confirmLabel: apply ? "Save and Apply" : "Save",
                        run: { perform(edit, session: session, stack: stack, apply: apply) })
                }
            } catch {
                notice = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    private func perform(_ edit: FileEdit, session: StackFileSession, stack: DockerStack, apply: Bool) {
        busy = true
        Task {
            defer { busy = false }
            do {
                switch try await session.save(edit, confirmation: try session.confirm(edit)) {
                case .saved:
                    if apply { docker.runDirect(.up, on: stack) }
                    await docker.refresh()
                    close()
                case .changedOnServer:
                    notice = "\(edit.file.fileName) changed on \(server.name) after you opened this, so nothing was saved. Close this and try again."
                case .invalid(let issues):
                    notice = "\(server.name) refused the file: " + (issues.first.map(EditorChecks.describe) ?? "it did not pass the compose check")
                }
            } catch {
                notice = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }
}
