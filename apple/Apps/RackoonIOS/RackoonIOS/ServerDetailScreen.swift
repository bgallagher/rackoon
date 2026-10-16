import RackoonCore
import RackoonSSHEmbedded
import SwiftUI

/// One server: its host-key standing (check, confirm a new key, or see why it is blocked) and a read-only connection
/// check. The Overview, Docker and terminal screens arrive in later stages.
struct ServerDetailScreen: View {
    @Environment(AppModel.self) private var model
    let serverID: String
    @State private var editing = false
    @State private var confirming: HostKeyInfo?

    var body: some View {
        let t = model.tokens
        if let server = model.servers.server(id: serverID) {
            let state = model.trust.state(for: server)
            List {
                Section {
                    LabeledContent("Address") { Text(server.addressLine).font(.body.monospaced()) }
                    if server.user == nil {
                        Text("No user is set, so root is used.").font(.footnote).foregroundStyle(t.secondary)
                    }
                }
                .listRowBackground(t.card)

                Section("Host key") {
                    HostKeySection(server: server, state: state, confirm: { confirming = $0 })
                }
                .listRowBackground(t.card)

                Section {
                    ConnectionSection(server: server, state: state)
                } header: {
                    Text("Connection")
                } footer: {
                    Text(model.isDemo
                         ? "Demo servers answer with made-up data."
                         : "Reads the server's overview once and changes nothing. Until key sign-in arrives, servers are reached with Tailscale SSH.")
                }
                .listRowBackground(t.card)
            }
            .themedList(t)
            .navigationTitle(server.name)
            .toolbar {
                Button("Edit") { editing = true }
            }
            .sheet(isPresented: $editing) { ServerFormScreen(editing: server) }
            .sheet(item: $confirming) { key in TrustSheet(server: server, key: key) }
            .task(id: server.host + ":\(server.port ?? 22)") {
                if case .unchecked = state { await model.trust.check(server) }
            }
        } else {
            ContentUnavailableView("Server removed", systemImage: "server.rack")
        }
    }
}

extension HostKeyInfo: @retroactive Identifiable {
    public var id: String { fingerprint }
}

private struct HostKeySection: View {
    @Environment(AppModel.self) private var model
    let server: Server
    let state: HostTrustModel.State
    let confirm: (HostKeyInfo) -> Void

    var body: some View {
        let t = model.tokens
        switch state {
        case .demo:
            Label("Demo server: no key to check.", systemImage: "theatermasks").foregroundStyle(t.secondary)
        case .unchecked:
            Button("Check Host Key") { Task { await model.trust.check(server) } }
        case .checking:
            HStack { ProgressView(); Text("Reading the server's key…").foregroundStyle(t.secondary) }
        case .trusted(let key):
            Label("Trusted", systemImage: "checkmark.seal.fill").foregroundStyle(t.ok)
            Fingerprint(type: key.keyType, fingerprint: key.fingerprint)
            Button("Check Again") { Task { await model.trust.check(server) } }
        case .unknown(let key):
            Label("Not trusted yet", systemImage: "questionmark.diamond.fill").foregroundStyle(t.warn)
            Fingerprint(type: key.keyType, fingerprint: key.fingerprint)
            Button("Review and Trust…") { confirm(key) }
        case .changed(let trusted, let presented):
            Label("Blocked: the host key changed", systemImage: "xmark.octagon.fill").foregroundStyle(t.danger)
            Text("This server now presents a different key than the one you trusted. That happens after a reinstall, but it is also what an impostor looks like, so Rackoon will not connect. If you reinstalled the server, remove it and add it again.")
                .font(.footnote).foregroundStyle(t.secondary)
            LabeledContent("Trusted") { Text(trusted.fingerprint).font(.caption.monospaced()) }
            LabeledContent("Presented") { Text(presented.fingerprint).font(.caption.monospaced()) }
        case .failed(let message):
            Label("Could not read the key", systemImage: "exclamationmark.triangle.fill").foregroundStyle(t.warn)
            Text(message).font(.footnote).foregroundStyle(t.secondary)
            Button("Try Again") { Task { await model.trust.check(server) } }
        }
    }
}

private struct Fingerprint: View {
    let type: String
    let fingerprint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(HostKeyInfo(keyType: type, blob: Data()).algorithmLabel).font(.caption.weight(.semibold))
            Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled)
        }
        .accessibilityIdentifier("fingerprint")
    }
}

/// First contact: the exact key is shown, and only that key is trusted on Trust.
private struct TrustSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: Server
    let key: HostKeyInfo

    var body: some View {
        let t = model.tokens
        NavigationStack {
            List {
                Section {
                    Text("This is the first connection to \(server.name). Check that the fingerprint below is the server's own, for example with `ssh-keygen -lf /etc/ssh/ssh_host_\(key.keyType.replacingOccurrences(of: "ssh-", with: ""))_key.pub` on the server.")
                        .foregroundStyle(t.secondary)
                }
                .listRowBackground(t.card)
                Section(key.algorithmLabel) {
                    Text(key.fingerprint).font(.body.monospaced()).textSelection(.enabled)
                }
                .listRowBackground(t.card)
            }
            .themedList(t)
            .navigationTitle("Trust this server?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Trust") {
                        model.trust.trust(key, for: server)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ConnectionSection: View {
    @Environment(AppModel.self) private var model
    let server: Server
    let state: HostTrustModel.State

    private var canConnect: Bool {
        switch state {
        case .trusted, .demo: true
        default: false
        }
    }

    var body: some View {
        let t = model.tokens
        switch model.checks[server.id] {
        case .running:
            HStack { ProgressView(); Text("Connecting…").foregroundStyle(t.secondary) }
        case .answered(let hostname, let os, let uptime):
            Label(hostname, systemImage: "checkmark.circle.fill").foregroundStyle(t.ok)
                .accessibilityIdentifier("answeredHostname")
            LabeledContent("System", value: os)
            LabeledContent("Up", value: Duration.seconds(uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2)))
        case .failed(let message):
            Label("No answer", systemImage: "exclamationmark.triangle.fill").foregroundStyle(t.warn)
            Text(message).font(.footnote).foregroundStyle(t.secondary)
        case nil:
            EmptyView()
        }
        Button("Test Connection") { Task { await model.checkConnection(server) } }
            .disabled(!canConnect || model.checks[server.id] == .running)
            .accessibilityIdentifier("testConnection")
        if !canConnect {
            Text("Trust the host key first.").font(.footnote).foregroundStyle(t.secondary)
        }
    }
}
