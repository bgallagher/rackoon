import RackoonCore
import RackoonSSHEmbedded
import SwiftUI
import UIKit

/// One server, polled every 5 s while open: what needs attention, CPU, memory, disks, addresses and system info. Shows
/// the saved reading first (marked as such), explains a failed connection, and asks to trust a new host key first.
struct OverviewScreen: View {
    @Environment(AppModel.self) private var model
    let serverID: String
    @State private var settings = false
    @State private var editing = false
    /// Held here, not in the gate's own row: List recreates its rows, which would close the sheet as it opens.
    @State private var confirming: HostKeyInfo?

    var body: some View {
        let t = model.tokens
        if let server = model.servers.server(id: serverID) {
            let state = model.fleet.state(for: serverID)
            List {
                GateSection(server: server, edit: { editing = true }, confirm: { confirming = $0 })
                if let failure = model.failure(for: server, state: state) {
                    FailureSection(failure: failure, raw: state.error ?? "", edit: { editing = true },
                                   retry: { Task { await model.fleet.refresh(serverID) } })
                } else if let error = state.error, !model.trust.state(for: server).isChanged {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(t.warn) }
                        .listRowBackground(t.card)
                }
                if let overview = state.overview {
                    HeaderSection(overview: overview, state: state)
                    if !state.attention.isEmpty { AttentionSection(items: state.attention) }
                    UsageSection(overview: overview, state: state)
                    DisksSection(disks: overview.disks)
                    AddressSection(overview: overview)
                    SystemSection(overview: overview, state: state)
                } else if state.error == nil, model.fleet.blocked[serverID] == nil {
                    Section {
                        HStack { ProgressView(); Text("Reading the server…").foregroundStyle(t.secondary) }
                    }
                    .listRowBackground(t.card)
                }
            }
            .themedList(t)
            .navigationTitle(server.name)
            .refreshable { await model.fleet.refresh(serverID) }
            .toolbar {
                Button { settings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Server settings")
            }
            .sheet(isPresented: $settings) { ServerSettingsScreen(serverID: serverID) }
            .sheet(isPresented: $editing) { ServerFormScreen(editing: server) }
            .sheet(item: $confirming) { key in TrustSheet(server: server, key: key) }
            .task(id: server.host + ":\(server.port ?? 22)") {
                if case .unchecked = model.trust.state(for: server) { await model.trust.check(server) }
            }
            .onAppear { model.fleet.attach(serverID, fast: true) }
            .onDisappear { model.fleet.detach(serverID, fast: true) }
        } else {
            ContentUnavailableView("Server removed", systemImage: "server.rack")
        }
    }
}

/// Before anything is polled: the host key must be trusted and the sign-in must be complete.
private struct GateSection: View {
    @Environment(AppModel.self) private var model
    let server: Server
    let edit: () -> Void
    let confirm: (HostKeyInfo) -> Void

    var body: some View {
        let t = model.tokens
        let state = model.trust.state(for: server)
        switch state {
        case .trusted, .demo:
            if let reason = model.fleet.blocked[server.id] {
                Section {
                    Label(reason, systemImage: "key.slash").foregroundStyle(t.warn)
                    Button("Edit Sign-in", action: edit)
                }
                .listRowBackground(t.card)
            }
        default:
            Section("Host key") {
                HostKeySection(server: server, state: state, confirm: confirm)
            }
            .listRowBackground(t.card)
        }
    }
}

private struct FailureSection: View {
    @Environment(AppModel.self) private var model
    let failure: ConnectionFailure
    let raw: String
    let edit: () -> Void
    let retry: () -> Void

    var body: some View {
        let t = model.tokens
        Section {
            Label(failure.headline, systemImage: failure.kind == .authRefused ? "person.badge.key" : "wifi.exclamationmark")
                .font(.headline).foregroundStyle(t.danger)
                .accessibilityIdentifier("failureHeadline")
            Text(failure.advice).foregroundStyle(t.text)
            Text(raw).font(.caption.monospaced()).foregroundStyle(t.muted).textSelection(.enabled)
            HStack {
                Button("Edit", action: edit).buttonStyle(.bordered)
                Button("Try Again", action: retry).buttonStyle(.borderedProminent)
            }
        }
        .listRowBackground(t.card)
    }
}

private struct HeaderSection: View {
    @Environment(AppModel.self) private var model
    let overview: Overview
    let state: ServerState

    var body: some View {
        let t = model.tokens
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(overview.os.prettyName).font(.headline).foregroundStyle(t.text)
                if !overview.modelName.isEmpty { Text(overview.modelName).font(.subheadline).foregroundStyle(t.secondary) }
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    Label(Present.freshness(state, now: context.date), systemImage: state.isStale ? "clock.arrow.circlepath" : "dot.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(state.isStale ? t.warn : t.muted)
                        .accessibilityIdentifier("freshness")
                }
            }
        }
        .listRowBackground(t.card)
    }
}

/// The needs-attention strip: Core's attention rules over this reading. The screens that fix them come in later stages.
private struct AttentionSection: View {
    @Environment(AppModel.self) private var model
    let items: [AttentionItem]

    var body: some View {
        let t = model.tokens
        Section("Needs attention (\(items.count))") {
            ForEach(items) { item in
                Label {
                    Text(item.message).foregroundStyle(t.text)
                } icon: {
                    Image(systemName: item.severity.symbol).foregroundStyle(item.severity == .critical ? t.danger : t.warn)
                }
            }
        }
        .listRowBackground(t.card)
        .accessibilityIdentifier("attention")
    }
}

private struct Meter: View {
    @Environment(AppModel.self) private var model
    let title: String
    let value: String
    let detail: String
    let fraction: Double?

    var body: some View {
        let t = model.tokens
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(t.secondary)
                Spacer()
                Text(value).font(.body.monospacedDigit().weight(.semibold)).foregroundStyle(t.text)
            }
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .tint(fraction >= 0.95 ? t.danger : fraction >= 0.85 ? t.warn : t.accent)
            }
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(t.muted) }
        }
        .padding(.vertical, 2)
    }
}

private struct UsageSection: View {
    @Environment(AppModel.self) private var model
    let overview: Overview
    let state: ServerState

    var body: some View {
        let t = model.tokens
        Section("Usage") {
            Meter(title: "CPU", value: state.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "…",
                  detail: "\(overview.cores) cores · load \(String(format: "%.2f %.2f %.2f", overview.load1, overview.load5, overview.load15))",
                  fraction: state.cpuPercent.map { $0 / 100 })
            Meter(title: "Memory", value: Present.percent(overview.memory.usedFraction),
                  detail: "\(Present.bytes(overview.memory.usedBytes)) of \(Present.bytes(overview.memory.totalBytes))",
                  fraction: overview.memory.usedFraction)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                LabeledContent("Uptime", value: Present.uptime(overview.uptimeSeconds + (state.isStale ? 0 : context.date.timeIntervalSince(state.updatedAt ?? context.date))))
            }
        }
        .listRowBackground(t.card)
    }
}

private struct DisksSection: View {
    @Environment(AppModel.self) private var model
    let disks: [Overview.Disk]

    var body: some View {
        let t = model.tokens
        Section("Disks") {
            ForEach(disks, id: \.mount) { disk in
                Meter(title: disk.mount, value: "\(disk.usePercent)%",
                      detail: "\(Present.bytes(disk.usedBytes)) of \(Present.bytes(disk.totalBytes)) · \(disk.filesystem)",
                      fraction: Double(disk.usePercent) / 100)
            }
        }
        .listRowBackground(t.card)
    }
}

private struct AddressSection: View {
    @Environment(AppModel.self) private var model
    let overview: Overview

    var body: some View {
        let t = model.tokens
        if overview.ipAddress != nil || overview.tailscaleIP != nil {
            Section("Network") {
                if let ip = overview.ipAddress { CopyRow(title: "IP address", value: ip) }
                // Only servers with Tailscale have a Tailscale address; nothing is said about it otherwise.
                if let ts = overview.tailscaleIP { CopyRow(title: "Tailscale IP", value: ts) }
            }
            .listRowBackground(t.card)
        }
    }
}

private struct CopyRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(value).font(.body.monospaced()).textSelection(.enabled)
                Button { UIPasteboard.general.string = value } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy \(title)")
            }
        }
    }
}

/// Vendor, kernel, machine and boot ids, and the server's own clock, ticking locally from the last poll.
private struct SystemSection: View {
    @Environment(AppModel.self) private var model
    let overview: Overview
    let state: ServerState

    var body: some View {
        let t = model.tokens
        Section("System") {
            if !overview.modelName.isEmpty { LabeledContent("Model", value: overview.modelName) }
            LabeledContent("Kernel", value: overview.kernel)
            if !overview.machineID.isEmpty { LabeledContent("Machine ID") { Text(overview.machineID).font(.caption.monospaced()) } }
            if !overview.bootID.isEmpty { LabeledContent("Boot ID") { Text(overview.bootID).font(.caption.monospaced()) } }
            if overview.serverTime > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    LabeledContent("Server time") {
                        Text(Present.serverClock(overview, polledAt: state.updatedAt ?? context.date, now: state.isStale ? (state.updatedAt ?? context.date) : context.date))
                            .font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .listRowBackground(t.card)
    }
}
