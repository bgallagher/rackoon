import RackoonCore
import SwiftUI

/// A server's pending apt updates (security first), held packages, how fresh apt's lists are, the server's own
/// reboot-required flag with Reboot…, and Refresh Lists / Install All / Install Security Updates, each confirmed with its
/// exact command and streamed live. Read from apt's local cache when the screen opens and after each action.
struct UpdatesScreen: View {
    @Environment(AppModel.self) private var model
    let serverID: String

    var body: some View {
        if let server = model.servers.server(id: serverID) {
            switch model.updatesModel(for: server) {
            case .success(let updates): UpdatesList(updates: updates, server: server)
            case .failure(let reason):
                ContentUnavailableView("Updates can't be read yet", systemImage: "arrow.down.circle", description: Text(reason.message))
                    .navigationTitle("Updates")
            }
        } else {
            ContentUnavailableView("Server removed", systemImage: "server.rack")
        }
    }
}

private struct UpdatesList: View {
    @Environment(AppModel.self) private var model
    @Bindable var updates: UpdatesModel
    let server: Server

    var body: some View {
        let t = model.tokens
        let snapshot = updates.state.snapshot
        let now = Int64(Date().timeIntervalSince1970)
        VStack(spacing: 0) {
            List {
                RebootSection(server: server)
                Section {
                    if let snapshot {
                        Text(UpdatesPresentation.subtitle(snapshot)).font(.headline)
                            .accessibilityIdentifier("updatesSubtitle")
                        Text("Lists refreshed \(UpdatesPresentation.refreshedText(snapshot, now: now))").font(.caption).foregroundStyle(t.secondary)
                        if let stale = UpdatesPresentation.staleness(snapshot, now: now) {
                            Label(stale, systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(t.warn)
                        }
                    } else if let error = updates.state.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(t.warn)
                    } else {
                        HStack { ProgressView(); Text("Reading apt on \(server.name)…").foregroundStyle(t.secondary) }
                    }
                    if let error = updates.state.error, snapshot != nil {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(t.warn)
                    }
                }
                .listRowBackground(t.card)
                if snapshot?.rebootRequired == true {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(t.warn)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(server.name) asks for a reboot").font(.subheadline.weight(.medium))
                                Text("Installed updates (a kernel, libc or systemd) take effect after a restart.").font(.caption).foregroundStyle(t.secondary)
                            }
                            Spacer(minLength: 0)
                            Button("Reboot…") { updates.pending = model.rebootRequest(server) }
                                .buttonStyle(.bordered).tint(t.danger)
                                .disabled(model.safety.readOnly || model.reboots[server.id]?.isActive == true)
                                .accessibilityIdentifier("updatesReboot")
                        }
                    }
                    .listRowBackground(t.card)
                }
                actions
                if let notice = updates.notice {
                    Section { Text(notice).foregroundStyle(t.secondary) }.listRowBackground(t.card)
                }
                if let error = updates.state.actionError {
                    Section { Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(t.danger) }.listRowBackground(t.card)
                } else if let done = updates.state.actionOutput, !done.isEmpty {
                    Section("Last run") { Text(done).font(.caption.monospaced()).foregroundStyle(t.secondary) }.listRowBackground(t.card)
                }
                if let snapshot, !snapshot.packages.isEmpty {
                    Section("Packages") {
                        ForEach(updates.packages) { p in PackageRow(package: p) }
                    }
                    .listRowBackground(t.card)
                }
                if let held = snapshot?.held, !held.isEmpty {
                    Section {
                        Text(held.joined(separator: ", ")).font(.caption.monospaced())
                    } header: {
                        Text("Held (kept at their version)")
                    }
                    .listRowBackground(t.card)
                }
            }
            .themedList(t)
            .refreshable { await updates.load() }
            if let output = updates.output {
                OutputPanel(output: output, cancel: updates.cancelOutput, close: updates.dismissOutput)
                    .padding(.top, 8)
                    .frame(height: 300)
                    .background(t.background)
            }
        }
        .background(t.background)
        .navigationTitle("Updates")
        .confirmAction($updates.pending)
        .sudoPassword($updates.sudoRequest)
        .task { await updates.load() }
    }

    @ViewBuilder private var actions: some View {
        let t = model.tokens
        let blocked = updates.blockedReason
        let packages = updates.packages
        let securityHint = UpdatesPresentation.installSecurityHint(packages, readOnly: model.safety.readOnly)
        Section {
            Button { updates.request(.refresh) } label: { Label("Refresh Lists", systemImage: "arrow.triangle.2.circlepath") }
                .foregroundStyle(blocked == nil ? t.accent : t.muted)
                .disabled(blocked != nil)
            Button { updates.request(.upgradeAll) } label: { Label("Install All (\(packages.count))", systemImage: "arrow.down.circle") }
                .foregroundStyle(blocked == nil && !packages.isEmpty ? t.accent : t.muted)
                .disabled(blocked != nil || packages.isEmpty)
                .accessibilityIdentifier("installAll")
            Button { updates.request(.upgrade(packages: updates.securityNames)) } label: {
                Label("Install Security Updates (\(updates.securityNames.count))", systemImage: "lock.shield")
            }
            .foregroundStyle(blocked == nil && securityHint == nil ? t.accent : t.muted)
            .disabled(blocked != nil || securityHint != nil)
        } footer: {
            if let working = updates.working {
                Text(working)
            } else if let blocked {
                Text(blocked)
            } else {
                Text("Held packages stay as they are and existing config files are kept. Nothing is removed.")
            }
        }
        .listRowBackground(t.card)
    }
}

private struct PackageRow: View {
    @Environment(AppModel.self) private var model
    let package: PendingUpdate

    var body: some View {
        let t = model.tokens
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(package.name).font(.body.weight(.medium))
                if package.isSecurity {
                    Text("security").font(.caption2.weight(.semibold)).foregroundStyle(t.warn)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(t.warn.opacity(0.15), in: Capsule())
                }
            }
            Text("\(package.oldVersion ?? "?") → \(package.newVersion)").font(.caption.monospaced()).foregroundStyle(t.secondary)
                .lineLimit(1).truncationMode(.middle)
            Text(package.suite).font(.caption2).foregroundStyle(t.muted)
        }
    }
}

/// The server's reboot in progress (if any), and the sudo password sheet when the reboot needs one. Presented only by the
/// screen on top, so the Overview and the Updates screen don't both ask.
struct RebootSection: View {
    @Environment(AppModel.self) private var model
    let server: Server
    @State private var visible = false
    @State private var request: SudoRequest?

    var body: some View {
        let t = model.tokens
        Group {
            if let flow = model.reboots[server.id] {
                Section { RebootBanner(flow: flow) }
                    .listRowBackground(t.card)
                    .onChange(of: flow.phase) { _, _ in sync(flow) }
                    .onAppear { sync(flow) }
            }
        }
        .onAppear { visible = true; if let flow = model.reboots[server.id] { sync(flow) } }
        .onDisappear { visible = false }
        .sudoPassword(Binding(get: { request }, set: { new in
            if new == nil, let flow = model.reboots[server.id], case .needsPassword = flow.phase, request != nil {
                request = nil
                flow.giveUp()
            } else {
                request = new
            }
        }))
    }

    private func sync(_ flow: RebootFlow) {
        guard visible, case .needsPassword(let problem) = flow.phase else {
            if case .needsPassword = flow.phase {} else { request = nil }
            return
        }
        guard request == nil || request?.problem != problem else { return }
        request = SudoRequest(
            title: "Reboot with sudo", server: server, command: RebootSession.sudoRebootCommand, problem: problem,
            actionLabel: "Reboot", destructive: true, canRemember: model.vault.canRemember,
            submit: { password, remember in
                request = nil
                flow.submitPassword(password, remember: remember)
            })
    }
}
