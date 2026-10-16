import RackoonCore
import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    /// Every server at once; not one of a server's screens.
    case dashboard
    case overview, docker, services, updates, bookmarks, files, terminal, command, alerts, security

    /// The screens listed under the selected server.
    static var serverScreens: [Screen] { allCases.filter { $0 != .dashboard } }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .overview: "Overview"
        case .docker: "Docker"
        case .services: "Services"
        case .updates: "Updates"
        case .bookmarks: "Bookmarks"
        case .files: "Files"
        case .terminal: "Terminals"
        case .command: "Commands"
        case .alerts: "Alerts"
        case .security: "Security"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "rectangle.3.group"
        case .overview: "square.grid.2x2"
        case .docker: "shippingbox"
        case .services: "gearshape.2"
        case .updates: "arrow.down.circle"
        case .bookmarks: "bookmark"
        case .files: "folder"
        case .terminal: "terminal"
        case .command: "chevron.left.forwardslash.chevron.right"
        case .alerts: "bell"
        case .security: "shield"
        }
    }

    /// Screens that exist today. The rest are shown as "Soon" so the layout matches the design.
    var isAvailable: Bool {
        switch self {
        case .dashboard, .overview, .docker, .services, .updates, .bookmarks, .files, .terminal, .command, .alerts: true
        default: false
        }
    }
}

/// Pending package updates for the selected server, from the Overview poll. Drives the dot on the Updates row.
struct UpdateBadge: Equatable {
    var total: Int
    var security: Int
    var isVisible: Bool { total > 0 || security > 0 }
    var help: String {
        let base = "\(total) update\(total == 1 ? "" : "s") pending"
        return security > 0 ? "\(base), \(security) security" : base
    }
}

enum ConnectionStatus { case connecting, connected, failing, none }

struct Sidebar: View {
    @Binding var selection: Screen
    let servers: [Server]
    let selectedID: String?
    /// Each server's status light: the selected one from its live poll, the others from the once-a-minute poll.
    let light: (Server) -> ServerLight
    let switcher: ServerSwitcherState
    var updates: UpdateBadge?
    /// Unseen alerts on the selected server, and on every server (beside Dashboard).
    var alerts: AlertBadge?
    var allAlerts: AlertBadge?
    /// Screens that mean nothing on the selected server (Updates on Unraid, which has no apt).
    var hiddenScreens: Set<String> = []
    let onAddServer: () -> Void
    var onSearch: () -> Void = {}

    private var selected: Server? { servers.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The screens scroll when the window is short; Safety and Appearance stay put at the bottom.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    if servers.count > 0 {
                        SidebarSearchButton(action: onSearch).padding(.bottom, 8)
                        NavRow(screen: .dashboard, selected: selection == .dashboard, alerts: allAlerts) { selection = .dashboard }
                            .help("Every server at once: health, servers, Docker, services, alerts and bookmarks (⌘0)")
                            .padding(.bottom, 10)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        SectionLabel("Servers")
                        Spacer()
                        FleetSummary(lights: servers.map(light)).padding(.trailing, 8)
                    }
                    if let server = selected {
                        ServerSwitcherCard(server: server, light: light(server), switcher: switcher)
                    } else {
                        Button(action: onAddServer) {
                            Label("Add server", systemImage: "plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 9)
                                .foregroundStyle(Theme.textMuted)
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.pointer)
                    }

                    if let name = selected?.name {
                        Divider().padding(.vertical, 12)
                        SectionLabel(name)
                        ForEach(Screen.serverScreens.filter { !hiddenScreens.contains($0.rawValue) }) { screen in
                            NavRow(screen: screen, selected: selection == screen,
                                   badge: screen == .updates ? updates : nil, alerts: screen == .alerts ? alerts : nil) {
                                if screen.isAvailable { selection = screen }
                            }
                        }
                    }
                }
            }
            SafetySection()
            AppearanceSection()
        }
        .padding(.top, Theme.pageTop).padding(.bottom, 16).padding(.horizontal, 12) // below the title-bar safe area, where the traffic lights are
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .foregroundStyle(Theme.textPrimary)
    }
}

/// Beside the Servers heading: how many servers there are, or how many are not answering.
private struct FleetSummary: View {
    let lights: [ServerLight]

    var body: some View {
        let down = lights.filter { $0.status == .failing }.count
        if down > 0 {
            HStack(spacing: 4) {
                Circle().fill(Theme.danger).frame(width: 6, height: 6)
                Text("\(down) down").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.danger)
            }
            .help("\(down) of \(lights.count) servers are not answering")
        } else if lights.count > 1 {
            Text("\(lights.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textMuted)
                .help("\(lights.count) servers")
        }
    }
}

/// Read-only switch. While on, no screen can change anything on a server (the service layer refuses too).
private struct SafetySection: View {
    private let safety = SafetyStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.bottom, 8)
            SectionLabel("Safety")
            HStack(spacing: 10) {
                Image(systemName: safety.readOnly ? "lock.fill" : "lock.open")
                    .frame(width: 18)
                    .foregroundStyle(safety.readOnly ? Theme.accent : Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read-only").fontWeight(.medium)
                    Text(safety.readOnly ? "On: changes are blocked" : "Off: changes ask first")
                        .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 0)
                Toggle("Read-only mode", isOn: Binding(get: { safety.readOnly }, set: { safety.setReadOnly($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
            }
            .padding(8)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(safety.readOnly ? Theme.accent.opacity(0.6) : Theme.border))
            .padding(.bottom, 10)
        }
    }
}

/// Fixed section at the bottom of the sidebar: shows the current theme and opens the picker.
private struct AppearanceSection: View {
    @State private var open = false
    private let appearance = AppearanceStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.bottom, 8)
            SectionLabel("Appearance")
            Button { open.toggle() } label: {
                HStack(spacing: 10) {
                    ThemeThumbnail(theme: appearance.resolvedTheme, compact: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appearance.selectionTitle).fontWeight(.medium).lineLimit(1)
                        Text("Theme and terminal").font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textMuted)
                }
                .padding(8)
                .background(open ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.pointer)
            .popover(isPresented: $open, arrowEdge: .trailing) { AppearancePicker(appearance: appearance) }
        }
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, 8).padding(.bottom, 6)
    }
}

private struct NavRow: View {
    let screen: Screen
    let selected: Bool
    var badge: UpdateBadge?
    var alerts: AlertBadge?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: screen.symbol)
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                Text(screen.title).fontWeight(selected ? .semibold : .regular)
                Spacer()
                if let badge, badge.isVisible {
                    // Amber when any pending update is a security one, otherwise the accent colour.
                    Circle().fill(badge.security > 0 ? Theme.warn : Theme.accent)
                        .frame(width: 8, height: 8)
                        .help(badge.help)
                        .accessibilityLabel(badge.help)
                }
                if let alerts, alerts.count > 0 {
                    Text("\(alerts.count)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 16)
                        .background(alerts.critical ? Theme.danger : Theme.warn, in: Capsule())
                        .help("\(alerts.count) alert\(alerts.count == 1 ? "" : "s") not seen yet")
                        .accessibilityLabel("\(alerts.count) alerts not seen yet")
                }
                if !screen.isAvailable {
                    Text("Soon").font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.border, in: Capsule())
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .foregroundStyle(screen.isAvailable ? Theme.textPrimary : Theme.textMuted)
            .background(selected ? Theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .disabled(!screen.isAvailable)
    }
}

struct StatusDot: View {
    let status: ConnectionStatus
    var glow = false

    var body: some View {
        let color: Color = switch status {
        case .connected: Theme.ok
        case .failing: Theme.danger
        case .connecting, .none: Theme.idle
        }
        Circle().fill(color).frame(width: 8, height: 8)
            .shadow(color: glow && status == .connected ? color.opacity(0.5) : .clear, radius: 3)
    }
}
