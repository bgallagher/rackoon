import RackoonCore
import SwiftUI

/// A server's Docker apps: one row per stack (compose project or standalone container) with its services, usage and status,
/// a search and a health filter, and Add Container. Docker is read every 10 s while this screen or a stack page shows.
struct DockerScreen: View {
    @Environment(AppModel.self) private var model
    let serverID: String

    var body: some View {
        if let server = model.servers.server(id: serverID) {
            switch model.dockerModel(for: server) {
            case .success(let docker):
                DockerList(docker: docker, server: server)
            case .failure(let reason):
                ContentUnavailableView("Docker can't be read yet", systemImage: "shippingbox", description: Text(reason.message))
                    .navigationTitle("Docker")
            }
        } else {
            ContentUnavailableView("Server removed", systemImage: "server.rack")
        }
    }
}

private struct DockerList: View {
    @Environment(AppModel.self) private var model
    let docker: DockerModel
    let server: Server
    @State private var query = ""
    @State private var filter: DockerStack.Health?
    @State private var adding = false
    @State private var bookmarking: BookmarkTarget?
    /// A stack to open: one just created from Add Container, opened on its Output.
    @State private var opened: String?

    var body: some View {
        let t = model.tokens
        let all = docker.stacks
        let shown = all.filter { (filter == nil || $0.health == filter) && $0.matches(query) }
        List {
            Section {
                if docker.state.error != nil || model.elevation.isUnlocked(server.id) {
                    DockerAccessNotice(server: server, error: docker.state.error)
                }
                if let snapshot = docker.state.snapshot {
                    Text(snapshot.summary).font(.subheadline).foregroundStyle(t.secondary)
                    if all.count > 1 {
                        Picker("Show", selection: $filter) {
                            Text("All").tag(DockerStack.Health?.none)
                            Text("Running").tag(DockerStack.Health?.some(.running))
                            Text("Attention").tag(DockerStack.Health?.some(.attention))
                            Text("Stopped").tag(DockerStack.Health?.some(.stopped))
                        }
                        .pickerStyle(.segmented)
                    }
                } else if docker.state.error == nil {
                    HStack { ProgressView(); Text("Reading Docker on \(server.name)…").foregroundStyle(t.secondary) }
                }
            }
            .listRowBackground(t.card)
            Section {
                ForEach(shown) { stack in
                    NavigationLink {
                        StackScreen(docker: docker, server: server, stackID: stack.id)
                    } label: {
                        StackRow(stack: stack, serverID: server.id, busy: docker.isBusy(stack))
                    }
                    .accessibilityIdentifier("stack-\(stack.id)")
                    .swipeActions(edge: .trailing) {
                        if canBookmark(stack) {
                            Button { bookmarking = BookmarkTarget(stack: stack, service: nil) } label: {
                                Label(stack.hasBookmark ? "Bookmark" : "Add Bookmark", systemImage: stack.hasBookmark ? "bookmark.fill" : "bookmark")
                            }
                            .tint(t.accent)
                        }
                    }
                    .contextMenu {
                        if let link = stack.bookmarkLinks.first, let url = URL(string: link.href) {
                            Link(destination: url) { Label("Open \(link.shortAddress)", systemImage: "safari") }
                        }
                        if canBookmark(stack) {
                            Button { bookmarking = BookmarkTarget(stack: stack, service: nil) } label: {
                                Label(stack.hasBookmark ? "Edit Bookmark…" : "Add Bookmark…", systemImage: "bookmark")
                            }
                        }
                    }
                }
                if docker.state.snapshot != nil, shown.isEmpty {
                    Text(all.isEmpty ? "No containers on \(server.name)." : "Nothing matches.").foregroundStyle(t.muted)
                }
            }
            .listRowBackground(t.card)
        }
        .themedList(t)
        .navigationTitle("Docker")
        .searchable(text: $query, prompt: "Stack, container, image")
        .refreshable { await docker.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { adding = true } label: { Label("Add Container…", systemImage: "plus") }
                        .disabled(model.safety.readOnly || docker.state.snapshot == nil)
                    NavigationLink { BookmarksScreen(serverID: server.id) } label: { Label("Bookmarks", systemImage: "bookmark") }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("Add")
            }
        }
        .sheet(isPresented: $adding) {
            AddContainerScreen(docker: docker, server: server) { stackID in
                adding = false
                if let stackID { opened = stackID }
            }
        }
        .sheet(item: $bookmarking) { target in
            BookmarkSheet(docker: docker, server: server, stack: target.stack, service: target.service, close: { bookmarking = nil })
        }
        .navigationDestination(item: $opened) { id in
            StackScreen(docker: docker, server: server, stackID: id, initialTab: .output)
        }
        .onAppear { docker.attach() }
        .onDisappear { docker.detach() }
        .onChange(of: bookmarkHrefs(all)) { _, hrefs in model.favicons.ensure(hrefs) }
    }

    private func canBookmark(_ stack: DockerStack) -> Bool {
        !model.safety.readOnly && !stack.isStandalone && !stack.containers.isEmpty && StackFiles.editable(for: stack) != nil
    }

    private func bookmarkHrefs(_ stacks: [DockerStack]) -> [String] { stacks.flatMap { $0.bookmarkLinks.map(\.href) } }
}

/// Which stack (and service) the bookmark sheet is for.
struct BookmarkTarget: Identifiable {
    let stack: DockerStack
    let service: String?
    var id: String { stack.id + "|" + (service ?? "") }
}

extension StackSeverity {
    @MainActor func color(_ t: Tokens) -> Color {
        switch self {
        case .ok: t.ok
        case .warning: t.warn
        case .danger: t.danger
        case .idle: t.idle
        }
    }
}

/// One stack in the list: its icon, name and kind, status, up to four services with their usage, and its site.
struct StackRow: View {
    @Environment(AppModel.self) private var model
    let stack: DockerStack
    let serverID: String
    let busy: Bool

    var body: some View {
        let t = model.tokens
        let status = stack.status
        HStack(alignment: .top, spacing: 12) {
            AppIconView(stack: stack, serverID: serverID, size: 40)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(stack.name).font(.headline).lineLimit(1).layoutPriority(1)
                    Text(stack.kindLabel).font(.caption).foregroundStyle(t.muted).lineLimit(1)
                    Spacer(minLength: 4)
                    if busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        if !status.text.isEmpty {
                            Text(status.text).font(.caption).foregroundStyle(status.severity.color(t)).lineLimit(1).fixedSize()
                        }
                        Circle().fill(status.severity.color(t)).frame(width: 7, height: 7)
                    }
                }
                let summary = stack.summaryContainers(limit: 4)
                ForEach(summary.shown) { c in
                    HStack(spacing: 8) {
                        ServiceIconView(container: c, stack: stack, serverID: serverID, size: 16)
                        Text(c.service ?? c.name).font(.subheadline).lineLimit(1)
                            .foregroundStyle(c.isUnhealthy ? t.danger : t.text)
                        Spacer(minLength: 4)
                        Text(c.usageText(formatBytes: Present.bytes)).font(.caption.monospaced())
                            .foregroundStyle(c.isUnhealthy ? t.danger : t.muted)
                    }
                }
                if summary.hidden > 0 {
                    Text("+ \(summary.hidden) more service\(summary.hidden == 1 ? "" : "s")").font(.caption).foregroundStyle(t.muted)
                }
                if let link = stack.bookmarkLinks.first {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.forward.square").font(.caption)
                        Text(link.shortAddress).font(.caption).lineLimit(1).truncationMode(.middle)
                        if stack.bookmarkLinks.count > 1 { Text("+\(stack.bookmarkLinks.count - 1)").font(.caption2).foregroundStyle(t.muted) }
                        ScopeTag(href: link.href)
                    }
                    .foregroundStyle(t.accent)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Where a link works (Local, Tailscale, Public), as a small tag.
struct ScopeTag: View {
    let href: String
    var body: some View {
        let scope = LinkScope(href: href)
        Text(scope.title).font(.caption2.weight(.medium)).foregroundStyle(scope.color)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(scope.color.opacity(0.14), in: Capsule())
            .accessibilityLabel(scope.hint)
    }
}

extension LinkScope {
    var color: Color {
        switch self {
        case .local: Color(red: 0.553, green: 0.706, blue: 0.941)
        case .tailscale: Color(red: 0.435, green: 0.827, blue: 0.659)
        case .publicWeb: Color(red: 0.941, green: 0.635, blue: 0.478)
        }
    }
}
