import RackoonCore
import SwiftUI
import UIKit

enum StackTab: String, CaseIterable, Identifiable {
    case containers = "Containers", logs = "Logs", files = "Files", output = "Output"
    var id: String { rawValue }
}

/// One stack: its containers (with Shell, Restart, Stop/Start, Rebuild), merged logs, its compose and .env files, and the
/// live Output of the last action. Every change is in the Stack Actions menu or a container's menu and asks first, showing
/// the exact command; nothing that changes the server is one tap away.
struct StackScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var docker: DockerModel
    let server: Server
    let stackID: String
    var initialTab: StackTab = .containers
    @State private var tab: StackTab?
    @State private var logFocus: String?
    @State private var deleting: DockerStack?
    @State private var bookmarking: BookmarkTarget?
    @State private var shellProblem: String?
    @State private var showTerminal = false

    var body: some View {
        let t = model.tokens
        Group {
            if let stack = docker.stack(id: stackID) {
                content(stack)
            } else {
                ContentUnavailableView("\(stackID) is gone", systemImage: "shippingbox",
                                       description: Text("Docker no longer lists it on \(server.name)."))
            }
        }
        .background(t.background)
        .navigationTitle(docker.stack(id: stackID)?.name ?? "Stack")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)   // the logs and the output need the room
        .confirmAction($docker.pending)
        .sheet(item: $deleting) { stack in DeleteStackSheet(docker: docker, stack: stack, close: { deleting = nil }) }
        .sheet(item: $bookmarking) { target in
            BookmarkSheet(docker: docker, server: server, stack: target.stack, service: target.service, close: { bookmarking = nil })
        }
        .navigationDestination(isPresented: $showTerminal) { TerminalScreen(serverID: server.id) }
        .onAppear {
            docker.attach()
            if tab == nil { tab = initialTab }
        }
        .onDisappear { docker.detach() }
        .onChange(of: docker.output?.id) { _, _ in
            // A run started for this stack: show it, so its terminal reports its size and the run can begin.
            if docker.output?.scope == stackID { tab = .output }
        }
        .onChange(of: docker.removedStack) { _, removed in if removed == stackID { dismiss() } }
    }

    private func content(_ stack: DockerStack) -> some View {
        let t = model.tokens
        let tabs = availableTabs(stack)
        let current = tab.flatMap { tabs.contains($0) ? $0 : nil } ?? .containers
        return VStack(spacing: 0) {
            StackHeader(stack: stack, serverID: server.id, working: docker.working, busy: docker.isBusy(stack))
                .padding(.horizontal, 16).padding(.top, 8)
            if model.safety.readOnly {
                Label("Read-only is on, so actions are off.", systemImage: "lock.fill")
                    .font(.footnote).foregroundStyle(t.warn).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 6)
            }
            if let error = docker.state.actionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(t.danger).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 6)
            }
            if let shellProblem {
                Label(shellProblem, systemImage: "lock.fill").font(.footnote).foregroundStyle(t.warn)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 6)
            }
            Picker("Show", selection: Binding(get: { current }, set: { tab = $0 })) {
                ForEach(tabs) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 10)
            switch current {
            case .containers: containers(stack)
            case .logs: LogsPanel(docker: docker, stack: stack, focus: $logFocus)
            case .files: files(stack)
            case .output:
                if let output = docker.output, output.scope == stackID {
                    OutputPanel(output: output, cancel: docker.cancelOutput, close: {
                        docker.dismissOutput()
                        tab = .containers
                    })
                } else {
                    ContentUnavailableView("No output", systemImage: "text.alignleft")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { actionsMenu(stack) }
        }
    }

    private func availableTabs(_ stack: DockerStack) -> [StackTab] {
        var tabs: [StackTab] = [.containers, .logs]
        if StackFiles.editable(for: stack) != nil { tabs.append(.files) }
        if docker.output?.scope == stackID { tabs.append(.output) }
        return tabs
    }

    // MARK: containers

    private func containers(_ stack: DockerStack) -> some View {
        let t = model.tokens
        return List {
            ForEach(stack.containers) { c in
                ContainerRow(container: c, stack: stack, serverID: server.id, busy: docker.state.busy.contains(c.id))
                    .listRowBackground(t.card)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        logFocus = c.logSource
                        tab = .logs
                    }
                    .contextMenu { containerMenu(c, stack) }
                    .overlay(alignment: .topTrailing) {
                        Menu { containerMenu(c, stack) } label: {
                            Image(systemName: "ellipsis.circle").font(.title3).frame(width: 36, height: 36).contentShape(Rectangle())
                        }
                        .accessibilityLabel("Actions for \(c.service ?? c.name)")
                    }
            }
            if stack.containers.isEmpty {
                Text("Not started. Use Stack Actions › Update to start it.").foregroundStyle(t.muted).listRowBackground(t.card)
            }
        }
        .themedList(t)
        .refreshable { await docker.refresh() }
    }

    @ViewBuilder
    private func containerMenu(_ c: DockerContainer, _ stack: DockerStack) -> some View {
        let blocked = docker.containerBlockedReason()
        Button { logFocus = c.logSource; tab = .logs } label: { Label("Logs", systemImage: "text.alignleft") }
        Button { openShell(c) } label: { Label("Shell", systemImage: "terminal") }
            .disabled(DockerSession.shellCommand(id: c.id) == nil || model.safety.readOnly || !c.isRunning)
        Section(blocked ?? "") {
            if c.isRunning {
                Button { docker.request(.restart, on: c) } label: { Label("Restart…", systemImage: "arrow.clockwise") }
                Button(role: .destructive) { docker.request(.stop, on: c) } label: { Label("Stop…", systemImage: "stop.fill") }
            } else {
                Button { docker.request(.start, on: c) } label: { Label("Start", systemImage: "play.fill") }
            }
            if ActionPrompts.canRebuild(c, in: stack) {
                Button { docker.requestRebuild(of: c, in: stack) } label: { Label("Rebuild from Dockerfile…", systemImage: "hammer") }
                    .disabled(docker.composeBlockedReason(for: stack) != nil)
            }
        }
        .disabled(blocked != nil)
        if canBookmark(stack), let service = c.service {
            Button { bookmarking = BookmarkTarget(stack: stack, service: service) } label: {
                Label(c.bookmark == nil ? "Add Bookmark…" : "Edit Bookmark…", systemImage: "bookmark")
            }
        }
        Button { UIPasteboard.general.string = c.name } label: { Label("Copy Name", systemImage: "doc.on.doc") }
    }

    private func openShell(_ c: DockerContainer) {
        guard let command = DockerSession.shellCommand(id: c.id) else { return }
        if let problem = model.openTerminal(on: server, command: command, title: c.service ?? c.name) {
            shellProblem = problem
        } else {
            shellProblem = nil
            showTerminal = true
        }
    }

    // MARK: files

    private func files(_ stack: DockerStack) -> some View {
        let t = model.tokens
        let editor = docker.editor(for: stack)
        return List {
            Section {
                ForEach(StackFiles.editable(for: stack) ?? [], id: \.self) { file in
                    NavigationLink {
                        EditorScreen(editor: editor, docker: docker, stack: stack, file: file, openOutput: { tab = .output })
                    } label: {
                        HStack {
                            Image(systemName: file.isEnv ? "key" : "doc.text")
                            VStack(alignment: .leading) {
                                Text(file.fileName)
                                Text(file.path).font(.caption.monospaced()).foregroundStyle(t.muted).lineLimit(1).truncationMode(.middle)
                            }
                            if editor.isDirty(file) {
                                Spacer()
                                Text("Edited").font(.caption).foregroundStyle(t.warn)
                            }
                        }
                    }
                }
            } footer: {
                Text("Checked on \(server.name) with docker compose config before saving. The old file is kept as .rackoon.bak.")
            }
        }
        .themedList(t)
    }

    // MARK: actions

    private func canBookmark(_ stack: DockerStack) -> Bool {
        !model.safety.readOnly && !stack.isStandalone && !stack.containers.isEmpty && StackFiles.editable(for: stack) != nil
    }

    @ViewBuilder
    private func actionsMenu(_ stack: DockerStack) -> some View {
        Menu {
            if stack.isStandalone {
                let blocked = docker.standaloneBlockedReason(for: stack)
                Section(blocked ?? "") {
                    Button { docker.requestPull(of: stack) } label: {
                        Label("Pull Latest Image", systemImage: "arrow.down.circle")
                        Text("Download a newer copy of its image; the container keeps running the old one")
                    }
                    .disabled(StandaloneAction.pullableImage(of: stack) == nil)
                    if let c = stack.containers.first {
                        if c.isRunning {
                            Button { docker.request(.restart, on: c) } label: {
                                Label("Restart Container…", systemImage: "arrow.clockwise")
                                Text("Stop and start it again")
                            }
                        } else {
                            Button { docker.request(.start, on: c) } label: { Label("Start Container", systemImage: "play.fill") }
                        }
                    }
                    Button(role: .destructive) { deleting = stack } label: {
                        Label("Delete Container…", systemImage: "trash")
                        Text("Remove the container, optionally its anonymous volumes")
                    }
                }
                .disabled(blocked != nil)
                Section(StandaloneAction.needsComposeReason) {
                    Button("Update") {}.disabled(true)
                    Button("Rebuild") {}.disabled(true)
                    Button("Recreate") {}.disabled(true)
                }
            } else {
                let blocked = docker.composeBlockedReason(for: stack)
                Section(blocked ?? "") {
                    composeItem(.up, stack, "Update", "arrow.triangle.2.circlepath", "Recreate what changed, start what is stopped")
                    composeItem(.pull, stack, "Pull Latest Images", "arrow.down.circle", "Download newer images; nothing restarts")
                    composeItem(.rebuild, stack, "Rebuild", "hammer", "Build images from the Dockerfiles, then update")
                    composeItem(.restart, stack, "Restart All…", "arrow.clockwise", "Restart every container in place")
                    composeItem(.recreate, stack, "Recreate…", "exclamationmark.arrow.triangle.2.circlepath", "Stop and recreate every container")
                    Button(role: .destructive) { deleting = stack } label: {
                        Label("Delete Stack…", systemImage: "trash")
                        Text("compose down, optionally volumes and the folder")
                    }
                }
                .disabled(blocked != nil)
                if canBookmark(stack) {
                    Button { bookmarking = BookmarkTarget(stack: stack, service: nil) } label: {
                        Label(stack.hasBookmark ? "Edit Bookmark…" : "Add Bookmark…", systemImage: "bookmark")
                    }
                }
            }
        } label: {
            Label("Stack Actions", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("stackActions")
    }

    private func composeItem(_ action: ComposeAction, _ stack: DockerStack, _ title: String, _ icon: String, _ detail: String) -> some View {
        Button(role: action == .recreate ? .destructive : nil) { docker.request(action, on: stack) } label: {
            Label(title, systemImage: icon)
            Text(detail)
        }
    }
}

/// The stack's icon (tap to change it), name, kind, status, folder and site links.
private struct StackHeader: View {
    @Environment(AppModel.self) private var model
    let stack: DockerStack
    let serverID: String
    let working: String?
    let busy: Bool

    var body: some View {
        let t = model.tokens
        let status = stack.status
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                EditableIcon(stack: stack, serverID: serverID, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(stack.name).font(.title3.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(stack.kindLabel).foregroundStyle(t.muted)
                        if busy {
                            ProgressView().controlSize(.mini)
                            if let working { Text(working).foregroundStyle(t.secondary).lineLimit(1) }
                        } else {
                            Circle().fill(status.severity.color(t)).frame(width: 7, height: 7)
                            Text(status.text.isEmpty ? "Running" : status.text).foregroundStyle(status.severity.color(t))
                        }
                    }
                    .font(.footnote)
                    if let dir = stack.workingDir {
                        Text(dir).font(.caption.monospaced()).foregroundStyle(t.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            ForEach(Array(stack.bookmarkLinks.enumerated()), id: \.offset) { _, link in
                if let url = URL(string: link.href) {
                    Link(destination: url) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.forward.square")
                            Text(link.shortAddress).lineLimit(1).truncationMode(.middle)
                            ScopeTag(href: link.href)
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
    }
}

/// One container: its icon (tap to change it), service and container name, image, state, ports and usage.
private struct ContainerRow: View {
    @Environment(AppModel.self) private var model
    let container: DockerContainer
    let stack: DockerStack
    let serverID: String
    let busy: Bool

    var body: some View {
        let t = model.tokens
        let c = container
        let image = ImageName.parse(c.image)
        HStack(alignment: .top, spacing: 12) {
            EditableIcon(stack: stack, container: c, serverID: serverID, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(c.isUnhealthy ? t.danger : c.isRunning ? t.ok : t.idle).frame(width: 7, height: 7)
                    Text(c.service ?? c.name).font(.headline).lineLimit(1)
                    if busy { ProgressView().controlSize(.mini) }
                }
                .padding(.trailing, 36)
                if c.service != nil { Text(c.name).font(.caption).foregroundStyle(t.muted).lineLimit(1) }
                HStack(spacing: 0) {
                    Text(image.repository).lineLimit(1).truncationMode(.middle)
                    if let tag = image.tag { Text(tag).lineLimit(1).fixedSize() }
                }
                .font(.caption.monospaced()).foregroundStyle(t.secondary)
                Text(c.status).font(.caption).foregroundStyle(c.isUnhealthy ? t.danger : t.secondary).lineLimit(1)
                HStack(spacing: 10) {
                    if !c.ports.isEmpty {
                        Text(c.ports.map { "\($0.hostPort)→\($0.containerPort)" }.joined(separator: " ")).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(c.usageText(formatBytes: Present.bytes))
                }
                .font(.caption.monospaced()).foregroundStyle(t.muted)
            }
        }
        .padding(.vertical, 4)
    }
}
