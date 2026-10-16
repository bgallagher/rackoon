import RackoonCore
import SwiftUI

/// The saved servers: search (every word in name, host, user or alias, as on the Mac), reorder, swipe to remove, and the
/// Read-only switch in the toolbar.
struct ServerListScreen: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var adding = false
    @State private var settings = false
    @State private var removing: Server?

    var body: some View {
        let t = model.tokens
        NavigationStack {
            List {
                if model.isDemo {
                    Label("Demo mode: made-up servers, nothing is sent anywhere.", systemImage: "theatermasks")
                        .font(.footnote)
                        .foregroundStyle(t.secondary)
                        .listRowBackground(t.card)
                }
                ForEach(model.servers.filtered(query)) { server in
                    NavigationLink(value: server.id) { ServerRow(server: server) }
                        .listRowBackground(t.card)
                        .swipeActions {
                            Button("Remove", role: .destructive) { removing = server }
                        }
                }
                .onMove(perform: query.isEmpty ? { model.servers.move(fromOffsets: $0, toOffset: $1) } : nil)
                if let error = model.servers.saveError {
                    Text(error).foregroundStyle(t.danger).listRowBackground(t.card)
                }
            }
            .themedList(t)
            .overlay {
                if model.servers.servers.isEmpty { EmptyServers(add: { adding = true }) }
            }
            .searchable(text: $query, prompt: "Search servers")
            .navigationTitle("Servers")
            .navigationDestination(for: String.self) { id in ServerDetailScreen(serverID: id) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ReadOnlyChip() }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !model.servers.servers.isEmpty { EditButton() }
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add server")
                }
            }
            .sheet(isPresented: $adding) { ServerFormScreen(editing: nil) }
            .sheet(isPresented: $settings) { SettingsScreen() }
            .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { server in
                Button("Remove", role: .destructive) { model.remove(id: server.id) }
            } message: { _ in
                Text("It is removed from this iPhone only. Nothing on the server changes.")
            }
        }
    }
}

private struct ServerRow: View {
    @Environment(AppModel.self) private var model
    let server: Server

    var body: some View {
        let t = model.tokens
        HStack(spacing: 12) {
            HostKeyDot(state: model.trust.state(for: server))
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.body.weight(.semibold)).foregroundStyle(t.text)
                Text(server.addressLine).font(.footnote.monospaced()).foregroundStyle(t.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The server's host-key standing at a glance: green trusted, grey not checked, amber asks, red blocked.
struct HostKeyDot: View {
    @Environment(AppModel.self) private var model
    let state: HostTrustModel.State

    var body: some View {
        let t = model.tokens
        let color: Color = switch state {
        case .trusted, .demo: t.ok
        case .unknown: t.warn
        case .changed, .failed: t.danger
        case .unchecked, .checking: t.idle
        }
        Circle().fill(color).frame(width: 10, height: 10).accessibilityHidden(true)
    }
}

private struct EmptyServers: View {
    @Environment(AppModel.self) private var model
    let add: () -> Void

    var body: some View {
        let t = model.tokens
        VStack(spacing: 14) {
            Image(systemName: "server.rack").font(.system(size: 44)).foregroundStyle(t.muted)
            Text("No servers yet").font(.title3.weight(.semibold)).foregroundStyle(t.text)
            Text("Add a server you reach over SSH, or try the demo to look around first.")
                .multilineTextAlignment(.center).foregroundStyle(t.secondary)
            Button("Add Server", action: add).buttonStyle(.borderedProminent)
            Button("Try the Demo") { model.setDemo(true) }
        }
        .padding(32)
    }
}

/// Read-only on/off, always visible. While on, nothing that changes a server can run (the policy refuses it too).
struct ReadOnlyChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.tokens
        let on = model.safety.readOnly
        Button {
            model.safety.setReadOnly(!on)
        } label: {
            // Spelled out while on, so it is never mistaken for decoration; just the open lock while changes are allowed.
            if on {
                // An HStack, not a Label: toolbars draw a Label as its icon alone.
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                    Text("Read-only")
                }
                .font(.footnote.weight(.semibold)).foregroundStyle(t.warn)
                .padding(.horizontal, 4)
            } else {
                Label("Changes allowed", systemImage: "lock.open").labelStyle(.iconOnly).foregroundStyle(t.secondary)
            }
        }
        .accessibilityIdentifier("readOnlyChip")
        .accessibilityValue(on ? "on" : "off")
    }
}

extension Server {
    /// `user@host[:port]`, as on the Mac's server card.
    var addressLine: String {
        let base = sshDestination
        if let port, port != 22 { return "\(base):\(port)" }
        return base
    }
}
