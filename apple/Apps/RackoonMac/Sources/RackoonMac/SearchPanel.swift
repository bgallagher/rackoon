import AppKit
import RackoonCore
import SwiftUI

/// Search everything (Go > Search… ⌘F, or the box at the top of the sidebar): servers, Docker stacks and containers,
/// services, bookmarks, the Commands library and alerts, across every server. It reads what the app already holds (the
/// polls, the background alert checks' container and services readings); nothing is fetched for a search.
@MainActor @Observable
final class SearchState {
    private(set) var isOpen = false
    var query = ""
    /// The highlighted row, as an index into the visible rows.
    var highlighted = 0
    /// Groups the user expanded past the first few results.
    var expanded: Set<SearchGroup> = []

    func open() {
        isOpen = true
        highlighted = 0
    }

    func close() { isOpen = false }
}

/// A service the Services screen should show when it opens (a search result was clicked): its name goes in the search box.
@MainActor @Observable
final class ServicesFocus {
    static let shared = ServicesFocus()
    var pending: [String: String] = [:]   // server id -> text for the search box
}

/// Builds the items to search from the app's models.
@MainActor
enum SearchIndex {
    static func items(rows: [FleetRow], workspace: DockerWorkspace) -> [SearchItem] {
        var items: [SearchItem] = []
        let visibility = ServiceVisibilityStore.shared
        for row in rows {
            let server = row.server
            let o = row.state.overview
            let summary = row.blocked != nil ? "Blocked" : (row.state.error != nil ? "Not answering" : (row.isOnline ? "Online" : "Not checked yet"))
            items.append(SearchItems.server(server, summary: summary, online: row.blocked != nil || row.state.error != nil ? false : (row.isOnline ? true : nil),
                                            os: o?.os.prettyName, addresses: [o?.ipAddress, o?.tailscaleIP, o?.hostname].compactMap { $0 }))
            // Docker: the full reading when the Docker screen has one, else the background check's container list.
            if let snapshot = workspace.existingModel(for: server)?.state.snapshot {
                let stacks = workspace.existingModel(for: server)?.stacks ?? snapshot.stacks
                items += SearchItems.docker(stacks, server: server)
                items += SearchItems.bookmarks(stacks.flatMap { s in s.containers.compactMap { c in c.bookmark.map { ($0, c.service ?? c.name) } } },
                                               server: server)
            } else if let reading = AlertMonitor.shared.containerReading(for: server.id) {
                items += SearchItems.docker(reading, server: server)
                items += SearchItems.bookmarks(reading.containers.filter { Bookmark.isValidURL($0.href) }.map { (Bookmark(href: $0.href), $0.name) },
                                               server: server)
            }
            if let services = ServicesStore.shared.existingModel(for: server)?.snapshot {
                items += SearchItems.services(services, server: server) { visibility.isVisible($0, server: server.id) }
            }
        }
        items += SearchItems.commands(CommandLibrary.all)
        let known = Set(rows.map(\.id))
        items += SearchItems.alerts(AlertMonitor.shared.book.active().filter { known.contains($0.serverID) })
        return items
    }
}

/// The floating search panel, drawn over the whole window like the server menu.
struct SearchPanel: View {
    let search: SearchState
    let items: () -> [SearchItem]
    let open: (SearchItem) -> Void
    @FocusState private var fieldFocused: Bool
    /// Results shown per group before "Show all".
    static let perGroup = 5

    var body: some View {
        let results = Search.run(search.query, in: Search.isSearchable(search.query) ? items() : [])
        let rows = visibleRows(results)
        ZStack(alignment: .top) {
            Color.black.opacity(0.25).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { search.close() }
            VStack(spacing: 0) {
                field(rows)
                Divider()
                content(results, rows: rows)
                Divider()
                footer(results)
            }
            .frame(width: 680)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            .padding(.top, 70)
        }
        .task { fieldFocused = true }
        .onChange(of: search.query) { _, _ in
            search.highlighted = 0
            search.expanded = []
        }
    }

    // MARK: pieces

    private func field(_ rows: [SearchItem]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(Theme.textMuted)
            TextField("Search servers, Docker, services, bookmarks, commands, alerts",
                      text: Binding(get: { search.query }, set: { search.query = $0 }))
                .textFieldStyle(.plain).font(.system(size: 17))
                .focused($fieldFocused)
                .onSubmit { if rows.indices.contains(search.highlighted) { activate(rows[search.highlighted]) } }
                .onKeyPress(.downArrow) { move(1, rows.count); return .handled }
                .onKeyPress(.upArrow) { move(-1, rows.count); return .handled }
                .onKeyPress(.escape) { search.close(); return .handled }
            if !search.query.isEmpty {
                Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textMuted) }
                    .buttonStyle(.pointer).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16).frame(height: 54)
    }

    @ViewBuilder private func content(_ results: SearchResults, rows: [SearchItem]) -> some View {
        if !Search.isSearchable(search.query) {
            hint("Type two letters or more. Results come from every server: servers, Docker stacks and containers, services, bookmarks, commands and alerts.")
        } else if results.sections.isEmpty {
            hint("Nothing matches “\(search.query.trimmingCharacters(in: .whitespaces))”.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(results.sections, id: \.group) { section in
                            Section {
                                ForEach(shown(section)) { item in
                                    let index = rows.firstIndex { $0.id == item.id } ?? -1
                                    SearchRow(item: item, highlighted: index == search.highlighted, activate: { activate(item) })
                                        .id(item.id)
                                        .onHover { if $0, index >= 0 { search.highlighted = index } }
                                }
                                if section.items.count > Self.perGroup, !search.expanded.contains(section.group) {
                                    Button("Show all \(section.items.count) \(section.group.title.lowercased())") {
                                        search.expanded.insert(section.group)
                                    }
                                    .buttonStyle(.pointer).font(.system(size: 12)).foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 20).padding(.vertical, 6)
                                }
                            } header: {
                                HStack(spacing: 6) {
                                    Image(systemName: symbol(section.group)).font(.system(size: 11))
                                    Text(section.group.title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6)
                                    Text("\(section.items.count)").font(.system(size: 11)).monospacedDigit()
                                    Spacer()
                                }
                                .foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 6)
                                .background(Theme.card)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
                // Hugs a short list, scrolls a long one.
                .frame(height: min(460, CGFloat(rows.count) * 47 + CGFloat(results.sections.count) * 40
                    + CGFloat(results.sections.filter { $0.items.count > Self.perGroup && !search.expanded.contains($0.group) }.count) * 28 + 12))
                .onChange(of: search.highlighted) { _, i in
                    if rows.indices.contains(i) { proxy.scrollTo(rows[i].id) }
                }
            }
        }
    }

    private func footer(_ results: SearchResults) -> some View {
        HStack(spacing: 14) {
            Text("↑↓ move  ·  Return open  ·  Esc close").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            Spacer()
            if results.count > 0 {
                Text("\(results.count) result\(results.count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.horizontal, 16).frame(height: 32)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
    }

    // MARK: behaviour

    private func shown(_ section: SearchResults.Section) -> [SearchItem] {
        search.expanded.contains(section.group) ? section.items : Array(section.items.prefix(Self.perGroup))
    }

    /// The rows on screen, in order, for the keyboard.
    private func visibleRows(_ results: SearchResults) -> [SearchItem] { results.sections.flatMap(shown) }

    private func move(_ delta: Int, _ count: Int) {
        guard count > 0 else { return }
        search.highlighted = (search.highlighted + delta + count) % count
    }

    private func activate(_ item: SearchItem) {
        search.close()
        open(item)
    }

    private func symbol(_ group: SearchGroup) -> String {
        switch group {
        case .servers: "server.rack"
        case .docker: "shippingbox"
        case .services: "gearshape.2"
        case .bookmarks: "bookmark"
        case .commands: "chevron.left.forwardslash.chevron.right"
        case .alerts: "bell"
        }
    }
}

private struct SearchRow: View {
    let item: SearchItem
    let highlighted: Bool
    let activate: () -> Void

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 12) {
                Circle().fill(toneColor).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(item.subtitle).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let server = item.serverName {
                    Text(server).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Theme.background, in: Capsule())
                        .overlay(Capsule().stroke(Theme.border))
                        .lineLimit(1)
                }
                if highlighted {
                    Image(systemName: "return").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 7)
            .background(highlighted ? Theme.accent.opacity(0.14) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .overlay(alignment: .trailing) {
            // A bookmark can also be opened in the browser straight away (a sibling of the row's button).
            if let link = item.link, let url = URL(string: link), highlighted {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 13)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.pointer).help("Open \(link) in the browser")
                .padding(.trailing, 44)
            }
        }
    }

    private var toneColor: Color {
        switch item.tone {
        case "ok": Theme.ok
        case "warn": Theme.warn
        case "danger": Theme.danger
        case "idle": Theme.idle
        default: Theme.textMuted.opacity(0.5)
        }
    }
}

/// The sidebar's search box: looks like a field, opens the search panel.
struct SidebarSearchButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
                Text("Search").foregroundStyle(Theme.textMuted)
                Spacer()
                Text("⌘F").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10).frame(height: 30)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .help("Search servers, Docker, services, bookmarks, commands and alerts (⌘F)")
    }
}
