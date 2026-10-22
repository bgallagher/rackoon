import RackoonCore
import SwiftUI

/// Everything that needs the user, across every server (the Alerts tab) or on one server (from its Overview): active
/// alerts (unseen first), muted ones, and the last 7 days of resolved ones. Kept current while the app is open; an
/// iPhone can't check in the background, so nothing is noticed while Rackoon is closed.
struct AlertsScreen: View {
    @Environment(AppModel.self) private var model
    /// One server's alerts, or nil for every server.
    let serverID: String?

    var body: some View {
        let t = model.tokens
        let monitor = model.alerts!
        let book = monitor.book
        let known = Set(model.servers.servers.map(\.id))
        let active = book.active(server: serverID).filter { known.contains($0.serverID) }
            .sorted { ($0.acknowledged ? 1 : 0, -$0.severity.rank, $1.lastSeen) < ($1.acknowledged ? 1 : 0, -$1.severity.rank, $0.lastSeen) }
        let muted = book.mutedAlerts(server: serverID).filter { known.contains($0.serverID) }
        let history = book.history(server: serverID).filter { known.contains($0.serverID) }
        List {
            Section {
                if active.isEmpty, !monitor.hasLooked {
                    HStack { ProgressView(); Text("Looking at the servers…").foregroundStyle(t.secondary) }
                } else if active.isEmpty {
                    Label(serverID == nil ? "Nothing needs you on any server." : "Nothing needs you on this server.", systemImage: "checkmark.circle")
                        .foregroundStyle(t.ok)
                }
                ForEach(active) { AlertRowView(alert: $0, showServer: serverID == nil) }
            } header: {
                Text("Active")
            } footer: {
                Text(footer(monitor))
            }
            .listRowBackground(t.card)
            if !muted.isEmpty {
                Section("Muted") { ForEach(muted) { AlertRowView(alert: $0, showServer: serverID == nil) } }
                    .listRowBackground(t.card)
            }
            if !history.isEmpty {
                Section {
                    ForEach(history.prefix(50)) { AlertRowView(alert: $0, showServer: serverID == nil) }
                } header: {
                    Text("Resolved (7 days)")
                }
                .listRowBackground(t.card)
            }
        }
        .themedList(t)
        .navigationTitle(serverID.flatMap { model.servers.server(id: $0)?.name }.map { "Alerts · \($0)" } ?? "Alerts")
        .refreshable { monitor.checkNow(serverID.flatMap { model.servers.server(id: $0) }) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { monitor.checkNow(serverID.flatMap { model.servers.server(id: $0) }) } label: {
                        Label("Check Now", systemImage: "arrow.clockwise")
                    }
                    Button { monitor.acknowledgeAll(server: serverID) } label: { Label("Mark All as Seen", systemImage: "eye") }
                        .disabled(book.unseenCount(server: serverID) == 0)
                    Button(role: .destructive) { monitor.clearHistory(server: serverID) } label: {
                        Label("Clear History", systemImage: "trash")
                    }
                    .disabled(history.isEmpty)
                } label: {
                    if monitor.checking.isEmpty { Image(systemName: "ellipsis.circle") } else { ProgressView() }
                }
                .accessibilityLabel("Alert actions")
            }
        }
    }

    private func footer(_ monitor: AlertMonitor) -> String {
        let last = serverID.flatMap { monitor.lastSweep[$0] } ?? monitor.lastSweep.values.max()
        let checked = last.map { "Last full check \($0.formatted(date: .omitted, time: .shortened)). " } ?? ""
        return checked + "Checked while Rackoon is open: connection and Overview every minute, services and containers every 5 minutes."
    }
}

private struct AlertRowView: View {
    @Environment(AppModel.self) private var model
    let alert: ServerAlert
    let showServer: Bool

    var body: some View {
        let t = model.tokens
        let monitor = model.alerts!
        NavigationLink {
            AlertFixDestination(alert: alert)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).foregroundStyle(alert.isActive ? color(t) : t.muted).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(alert.title).fontWeight(alert.acknowledged || !alert.isActive ? .regular : .semibold)
                    if let detail = alert.detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(t.secondary).lineLimit(3)
                    }
                    Text(when).font(.caption2).foregroundStyle(t.muted)
                }
            }
            .opacity(alert.acknowledged && alert.isActive ? 0.7 : 1)
        }
        .swipeActions(edge: .leading) {
            if alert.isActive {
                Button { monitor.acknowledge(alert, !alert.acknowledged) } label: {
                    Label(alert.acknowledged ? "Unseen" : "Seen", systemImage: alert.acknowledged ? "eye.slash" : "eye")
                }
                .tint(t.accent)
            }
        }
        .swipeActions(edge: .trailing) {
            if alert.isActive || model.alerts.book.muted.contains(alert.id) {
                let muted = model.alerts.book.muted.contains(alert.id)
                Button { monitor.mute(alert, !muted) } label: {
                    Label(muted ? "Unmute" : "Mute", systemImage: muted ? "bell" : "bell.slash")
                }
                .tint(t.idle)
            }
        }
        .accessibilityIdentifier("alert-\(alert.key)")
    }

    private var icon: String {
        switch alert.severity {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private func color(_ t: Tokens) -> SwiftUI.Color {
        switch alert.severity {
        case .critical: t.danger
        case .warning: t.warn
        case .info: t.accent
        }
    }

    private var when: String {
        var parts: [String] = []
        if showServer { parts.append(alert.serverName) }
        parts.append(alert.category.title)
        if let resolved = alert.resolvedAt {
            parts.append("resolved \(resolved.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("since \(alert.firstSeen.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
}

/// Where an alert's fix lives: the server's Overview, Docker (its stack), Services (the service), Updates or Bookmarks.
/// Opening it marks the alert as seen.
struct AlertFixDestination: View {
    @Environment(AppModel.self) private var model
    let alert: ServerAlert

    var body: some View {
        Group {
            switch alert.fix?.screen {
            case "docker": DockerScreen(serverID: alert.serverID)
            case "services": ServicesScreen(serverID: alert.serverID, focus: serviceName)
            case "updates": UpdatesScreen(serverID: alert.serverID)
            case "bookmarks": BookmarksScreen(serverID: alert.serverID)
            default: OverviewScreen(serverID: alert.serverID)
            }
        }
        .onAppear { if alert.isActive, !alert.acknowledged { model.alerts.acknowledge(alert) } }
    }

    /// The service's name for the Services search box (the fix's target is the service id).
    private var serviceName: String? {
        guard let id = alert.fix?.target else { return nil }
        return model.existingServicesModel(alert.serverID)?.snapshot?.services.first { $0.id == id }?.name ?? id
    }
}
