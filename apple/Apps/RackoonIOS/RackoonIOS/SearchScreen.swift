import RackoonCore
import SwiftUI

/// Builds what search looks through from what the app already holds; nothing is fetched for a search (as on the Mac).
@MainActor
enum SearchIndex {
    static func items(_ model: AppModel) -> [SearchItem] {
        var items: [SearchItem] = []
        let servers = model.servers.servers
        for server in servers {
            let state = model.fleet.state(for: server.id)
            let o = state.overview
            let blocked = model.fleet.blocked[server.id]
            let online = blocked == nil && state.error == nil && o != nil
            let summary = blocked != nil ? "Blocked" : (state.error != nil ? "Not answering" : (online ? "Online" : "Not checked yet"))
            items.append(SearchItems.server(server, summary: summary, online: blocked != nil || state.error != nil ? false : (online ? true : nil),
                                            os: o?.os.prettyName, addresses: [o?.ipAddress, o?.tailscaleIP, o?.hostname].compactMap { $0 }))
            // Docker: the full reading when a Docker screen has one, else the alert check's container list.
            if let docker = model.docker.existing(server.id), docker.state.snapshot != nil {
                let stacks = docker.stacks
                items += SearchItems.docker(stacks, server: server)
                items += SearchItems.bookmarks(stacks.flatMap { s in s.containers.compactMap { c in c.bookmark.map { ($0, c.service ?? c.name) } } },
                                               server: server)
            } else if let reading = model.alerts.containerReading(for: server.id) {
                items += SearchItems.docker(reading, server: server)
                items += SearchItems.bookmarks(reading.containers.filter { Bookmark.isValidURL($0.href) }.map { (Bookmark(href: $0.href), $0.name) },
                                               server: server)
            }
            if let services = model.existingServicesModel(server.id)?.snapshot {
                items += SearchItems.services(services, server: server) { model.visibility.isVisible($0, server: server.id) }
            }
        }
        items += SearchItems.commands(CommandLibrary.all)
        let known = Set(servers.map(\.id))
        items += SearchItems.alerts(model.alerts.book.active().filter { known.contains($0.serverID) })
        return items
    }
}

/// Search every server at once: servers, Docker stacks and containers, services, bookmarks, the Commands library and
/// alerts. Two letters or more; five results per group with Show All. A command opens on the server chosen below.
struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var query = ""
    @State private var expanded: Set<SearchGroup> = []
    @AppStorage("searchCommandServer") private var commandServer = ""

    var body: some View {
        let t = model.tokens
        NavigationStack {
            let results = Search.isSearchable(query) ? Search.run(query, in: SearchIndex.items(model)) : nil
            List {
                if let results {
                    if results.sections.isEmpty {
                        Section { Text("Nothing matches “\(query)”.").foregroundStyle(t.secondary) }.listRowBackground(t.card)
                    }
                    ForEach(results.sections, id: \.group) { section in
                        Section(section.group.title) {
                            let shown = expanded.contains(section.group) ? section.items : Array(section.items.prefix(5))
                            ForEach(shown) { item in row(item) }
                            if section.items.count > 5 {
                                Button(expanded.contains(section.group) ? "Show Fewer" : "Show All \(section.items.count)") {
                                    if expanded.contains(section.group) { expanded.remove(section.group) } else { expanded.insert(section.group) }
                                }
                                .foregroundStyle(t.accent)
                            }
                        }
                        .listRowBackground(t.card)
                    }
                } else {
                    Section {
                        Text("Search servers, Docker apps and containers, services, bookmarks, commands and alerts on every server.")
                            .foregroundStyle(t.secondary)
                    } footer: {
                        Text("Docker and services show up once they have been read: open their screens, or wait for the first alert check a few seconds after launch.")
                    }
                    .listRowBackground(t.card)
                }
                if !model.servers.servers.isEmpty {
                    Section {
                        Picker("Run commands on", selection: $commandServer) {
                            ForEach(model.servers.servers) { Text($0.name).tag($0.id) }
                        }
                    }
                    .listRowBackground(t.card)
                }
            }
            .themedList(t)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search every server")
            .navigationTitle("Search")
            .onAppear {
                if model.servers.server(id: commandServer) == nil { commandServer = model.servers.servers.first?.id ?? "" }
            }
        }
    }

    private func row(_ item: SearchItem) -> some View {
        let t = model.tokens
        return HStack(spacing: 10) {
            NavigationLink { destination(item) } label: {
                HStack(spacing: 10) {
                    Circle().fill(t.tone(item.tone)).frame(width: 8, height: 8).opacity(item.tone == nil ? 0 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).lineLimit(1)
                        Text([item.subtitle, item.serverName].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(t.secondary).lineLimit(1)
                    }
                }
            }
            if let link = item.link, let url = URL(string: link) {
                Button { openURL(url) } label: { Image(systemName: "safari") }
                    .buttonStyle(.borderless).foregroundStyle(t.accent).accessibilityLabel("Open \(link)")
            }
        }
        .accessibilityIdentifier("result-\(item.id)")
    }

    @ViewBuilder private func destination(_ item: SearchItem) -> some View {
        switch item.target {
        case .server(let id): OverviewScreen(serverID: id)
        case .stack(let server, _): DockerScreen(serverID: server)
        case .service(let server, _): ServicesScreen(serverID: server, focus: item.title)
        case .bookmark(let server, _): BookmarksScreen(serverID: server)
        case .command(let id):
            if model.servers.server(id: commandServer) != nil {
                CommandsScreen(serverID: commandServer, open: id)
            } else {
                ContentUnavailableView("No server", systemImage: "server.rack", description: Text("Add a server to run commands on."))
            }
        case .alert(let server, let id):
            if let alert = model.alerts.book.alerts.first(where: { $0.id == id }) {
                AlertFixDestination(alert: alert)
            } else {
                AlertsScreen(serverID: server)
            }
        }
    }
}
