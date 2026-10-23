import RackoonCore
import RackoonSSHEmbedded
import SwiftUI

/// A server's connection settings: its host-key standing (check, confirm a new key, or see why it is blocked), how it
/// is signed in to, and Edit.
struct ServerSettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let serverID: String
    @State private var editing = false
    @State private var confirming: HostKeyInfo?

    var body: some View {
        let t = model.tokens
        NavigationStack {
            if let server = model.servers.server(id: serverID) {
                let state = model.trust.state(for: server)
                List {
                    Section {
                        LabeledContent("Address") { Text(server.addressLine).font(.body.monospaced()) }
                        if server.user == nil {
                            Text("No user is set, so root is used.").font(.footnote).foregroundStyle(t.secondary)
                        }
                        LabeledContent("Sign-in", value: model.isDemo ? "Demo" : model.signIn.method(for: serverID).title)
                    }
                    .listRowBackground(t.card)

                    Section("Host key") {
                        HostKeySection(server: server, state: state, confirm: { confirming = $0 })
                    }
                    .listRowBackground(t.card)
                }
                .themedList(t)
                .navigationTitle(server.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Edit") { editing = true } }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
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
}

extension HostKeyInfo: @retroactive Identifiable {
    public var id: String { fingerprint }
}

struct HostKeySection: View {
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
            Button("Check Host Key") { Task { await model.checkHostKey(server) } }
        case .checking:
            HStack { ProgressView(); Text("Reading the server's key…").foregroundStyle(t.secondary) }
        case .trusted(let key):
            Label("Trusted", systemImage: "checkmark.seal.fill").foregroundStyle(t.ok)
            Fingerprint(type: key.keyType, fingerprint: key.computedFingerprint)
            Button("Check Again") { Task { await model.checkHostKey(server) } }
        case .unknown(let key):
            Label("Not trusted yet", systemImage: "questionmark.diamond.fill").foregroundStyle(t.warn)
            Fingerprint(type: key.keyType, fingerprint: key.fingerprint)
            Button("Review and Trust…") { confirm(key) }
        case .changed(let trusted, let presented):
            Label("Blocked: the host key changed", systemImage: "xmark.octagon.fill").foregroundStyle(t.danger)
            Text("This server now presents a different key than the one you trusted. That happens after a reinstall, but it is also what an impostor looks like, so Rackoon will not connect. If you reinstalled the server, remove it and add it again.")
                .font(.footnote).foregroundStyle(t.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Trusted").font(.caption.weight(.semibold))
                FingerprintText(fingerprint: trusted.computedFingerprint, font: .caption.monospaced())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Presented now").font(.caption.weight(.semibold))
                FingerprintText(fingerprint: presented.fingerprint, font: .caption.monospaced())
            }
        case .failed(let message):
            Label("Could not read the key", systemImage: "exclamationmark.triangle.fill").foregroundStyle(t.warn)
            Text(message).font(.footnote).foregroundStyle(t.secondary)
            Button("Try Again") { Task { await model.checkHostKey(server) } }
        }
    }
}

private struct Fingerprint: View {
    let type: String
    let fingerprint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(HostKeyInfo(keyType: type, blob: Data()).algorithmLabel).font(.caption.weight(.semibold))
            FingerprintText(fingerprint: fingerprint, font: .caption.monospaced())
        }
        .accessibilityIdentifier("fingerprint")
    }
}

/// A fingerprint people compare character by character, so it is never wrapped: line breaking would insert a hyphen
/// that is not part of it. The digest goes on a line of its own and shrinks to fit.
struct FingerprintText: View {
    let fingerprint: String
    let font: Font

    var body: some View {
        let parts = fingerprint.split(separator: ":", maxSplits: 1)
        VStack(alignment: .leading, spacing: 0) {
            if parts.count == 2 { Text(parts[0] + ":").font(font).foregroundStyle(.secondary) }
            Text(parts.count == 2 ? String(parts[1]) : fingerprint)
                .font(font)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
        }
        .textSelection(.enabled)
        .accessibilityLabel(fingerprint)
    }
}

/// First contact: the exact key is shown, and only that key is trusted on Trust.
struct TrustSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: Server
    let key: HostKeyInfo
    @State private var refused = false

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
                    FingerprintText(fingerprint: key.fingerprint, font: .body.monospaced())
                }
                .listRowBackground(t.card)
                if refused {
                    Section {
                        Text("This key can no longer be trusted: the server presented another key since, or one is already trusted. Close this and check again.")
                            .foregroundStyle(t.danger)
                    }
                    .listRowBackground(t.card)
                }
            }
            .themedList(t)
            .navigationTitle("Trust this server?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Trust") {
                        if model.trust(key, for: server) {
                            dismiss()
                        } else {
                            refused = true
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
