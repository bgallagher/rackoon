import RackoonCore
import SwiftUI

enum DashboardPage: String, CaseIterable, Identifiable {
    case health, docker, bookmarks
    var id: String { rawValue }
    var title: String {
        switch self {
        case .health: "Health"
        case .docker: "Docker"
        case .bookmarks: "Bookmarks"
        }
    }
}

extension AppModel {
    /// The Docker models of the servers that answer right now and whose host key is trusted; others are never asked.
    func answeringDocker(_ servers: [Server]) -> [(Server, DockerModel)] {
        servers.compactMap { server in
            guard Liveness(fleet.state(for: server.id)) == .up, case .success(let docker) = dockerModel(for: server) else { return nil }
            return (server, docker)
        }
    }
}

/// Keeps these Docker models polled while the view is on screen (`DockerModel.attach` is counted, so pages and screens
/// can attach the same model at once).
private struct DockerAttachment: ViewModifier {
    let models: [DockerModel]
    @State private var attached: [ObjectIdentifier: DockerModel] = [:]

    func body(content: Content) -> some View {
        content
            .onAppear { sync(models) }
            .onDisappear { sync([]) }
            .onChange(of: models.map { ObjectIdentifier($0) }) { _, _ in sync(models) }
    }

    private func sync(_ wanted: [DockerModel]) {
        let want = Dictionary(wanted.map { (ObjectIdentifier($0), $0) }, uniquingKeysWith: { a, _ in a })
        for (id, model) in attached where want[id] == nil { model.detach() }
        for (id, model) in want where attached[id] == nil { model.attach() }
        attached = want
    }
}

/// Per answering server: its containers' totals (CPU as a share of the host, memory, the disk Docker's data lives on) and a
/// tile per app; tapping one opens its page.
struct DockerPage: View {
    @Environment(AppModel.self) private var model
    let servers: [Server]

    var body: some View {
        let t = model.tokens
        let answering = model.answeringDocker(servers)
        VStack(spacing: 14) {
            if answering.isEmpty {
                Text("No server is answering right now.").foregroundStyle(t.muted).frame(maxWidth: .infinity).padding(20)
            }
            ForEach(answering, id: \.0.id) { server, docker in
                ServerDockerCard(server: server, docker: docker)
            }
            let silent = servers.filter { s in !answering.contains { $0.0.id == s.id } }
            if !silent.isEmpty {
                Text("Not shown (not answering or not trusted): " + silent.map(\.name).joined(separator: ", "))
                    .font(.caption).foregroundStyle(t.muted).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .modifier(DockerAttachment(models: answering.map(\.1)))
    }
}

private struct ServerDockerCard: View {
    @Environment(AppModel.self) private var model
    let server: Server
    let docker: DockerModel

    var body: some View {
        let t = model.tokens
        let overview = model.fleet.state(for: server.id).overview
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink { DockerScreen(serverID: server.id) } label: {
                HStack {
                    Text(server.name).font(.headline).foregroundStyle(t.text)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(t.muted)
                }
            }
            .buttonStyle(.plain)
            if let snapshot = docker.state.snapshot {
                let totals = DockerTotals.of(snapshot, host: overview)
                HStack(spacing: 12) {
                    mini("Running", "\(totals.running)/\(totals.containers)", warn: totals.running < totals.containers)
                    mini("Unhealthy", "\(totals.unhealthy)", warn: totals.unhealthy > 0)
                    mini("CPU", totals.cpuPercentOfHost.map { "\(Int($0.rounded()))%" } ?? "…")
                    mini("Memory", Present.bytes(totals.memoryBytes))
                }
                if let disk = totals.dataDisk {
                    Text("Docker data on \(disk.mount): \(disk.usePercent)% used").font(.caption)
                        .foregroundStyle(disk.usePercent > Attention.diskThresholdPercent ? t.warn : t.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                    ForEach(docker.stacks) { stack in
                        NavigationLink { StackScreen(docker: docker, server: server, stackID: stack.id) } label: {
                            HStack(spacing: 8) {
                                AppIconView(stack: stack, serverID: server.id, size: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(stack.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text("\(stack.runningCount)/\(stack.containers.count) running").font(.caption2).foregroundStyle(t.muted)
                                }
                                Spacer(minLength: 0)
                                Circle().fill(stack.status.severity.color(t)).frame(width: 7, height: 7)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(t.background))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if let error = docker.state.error {
                Text(error).font(.caption).foregroundStyle(t.warn).lineLimit(3)
            } else {
                HStack { ProgressView(); Text("Reading Docker…").font(.caption).foregroundStyle(t.secondary) }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(t.card))
    }

    private func mini(_ title: String, _ value: String, warn: Bool = false) -> some View {
        let t = model.tokens
        return VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(t.secondary)
            Text(value).font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(warn ? t.warn : t.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Per answering server, its bookmarks grouped by `homepage.group`; tapping one opens it.
struct BookmarksPage: View {
    @Environment(AppModel.self) private var model
    let servers: [Server]

    var body: some View {
        let t = model.tokens
        let answering = model.answeringDocker(servers)
        VStack(spacing: 14) {
            ForEach(answering, id: \.0.id) { server, docker in
                let items = BookmarkItem.items(in: docker.stacks)
                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink { BookmarksScreen(serverID: server.id) } label: {
                        HStack {
                            Text(server.name).font(.headline).foregroundStyle(t.text)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(t.muted)
                        }
                    }
                    .buttonStyle(.plain)
                    if docker.state.snapshot == nil {
                        HStack { ProgressView(); Text("Reading Docker…").font(.caption).foregroundStyle(t.secondary) }
                    } else if items.isEmpty {
                        Text("No bookmarks.").font(.caption).foregroundStyle(t.muted)
                    }
                    let groups = Dictionary(grouping: items) { $0.bookmark.group ?? "" }
                    ForEach(groups.keys.sorted { a, b in a.isEmpty != b.isEmpty ? !a.isEmpty : a.localizedCaseInsensitiveCompare(b) == .orderedAscending }, id: \.self) { group in
                        if !group.isEmpty || groups.count > 1 {
                            Text((group.isEmpty ? "Other" : group).uppercased()).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(t.muted)
                        }
                        ForEach(groups[group] ?? []) { item in
                            if let url = URL(string: item.bookmark.href) {
                                Link(destination: url) {
                                    HStack(spacing: 10) {
                                        FaviconView(href: item.bookmark.href, size: 22)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.title).font(.subheadline).foregroundStyle(t.text).lineLimit(1)
                                            Text(item.bookmark.shortAddress).font(.caption).foregroundStyle(t.accent).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                        ScopeTag(href: item.bookmark.href)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(t.card))
            }
            if answering.isEmpty {
                Text("No server is answering right now.").foregroundStyle(t.muted).frame(maxWidth: .infinity).padding(20)
            }
        }
        .modifier(DockerAttachment(models: answering.map(\.1)))
    }
}
