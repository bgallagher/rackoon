import AppKit
import RackoonCore
import SwiftUI

/// What runs on the server outside Docker: systemd services (the system's and the ssh user's own) and programs started by
/// hand that listen on a port. A card per service, like the Docker screen's; OS plumbing is hidden by default and anything
/// can be shown or hidden, on this server or on every server. Actions (Start/Stop/Restart, Status, logs) live in each
/// card's ⋯ menu, and the changes ask first.
struct ServicesScreen: View {
    let server: Server
    let theme: TerminalTheme
    /// The address the Mac reaches the server on (its Tailscale IP when it has one), for port links.
    let webHost: String?
    /// Opens a terminal tab running a command (following a unit's journal).
    let openInTerminal: (String, String) -> Void
    @State private var query = ""
    @State private var filter: ServiceFilter?
    @AppStorage("servicesShowHidden") private var showHidden = false
    private let visibility = ServiceVisibilityStore.shared

    private var model: ServicesModel { ServicesStore.shared.model(for: server) }

    var body: some View {
        let model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(model)
                if let run = model.runner.output {
                    ActionOutputPanel(run: run, theme: theme, cancel: model.runner.cancelOutput, close: model.runner.dismissOutput)
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.border))
                }
                if let note = model.runner.message {
                    NoticeRow(icon: "info.circle.fill", tint: Theme.accent, message: note).noticeSurface(.info)
                }
                if let error = model.error { ErrorBanner(message: "Could not read the services: \(error)") }
                if let snapshot = model.snapshot {
                    content(snapshot, model: model)
                } else if model.error == nil {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for services…") }
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, 28).padding(.top, Theme.pageTop).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Theme.textPrimary)
        .focusedSceneValue(\.screenRefresh, { model.refresh() })
        .onAppear {
            model.attach()
            takeFocus()
        }
        // A search result for a service on this server: show it in the search box.
        .onChange(of: ServicesFocus.shared.pending[server.id]) { _, _ in takeFocus() }
        .onDisappear { model.detach() }
        // A change finished: read again so the card shows the new state.
        .onChange(of: model.runner.isRunning) { _, running in if !running { model.refresh() } }
        .confirmAction(Binding(get: { model.runner.pending }, set: { model.runner.pending = $0 }))
        .sudoPassword(Binding(get: { model.runner.sudoRequest }, set: { model.runner.sudoRequest = $0 }))
    }

    private func takeFocus() {
        guard let text = ServicesFocus.shared.pending[server.id] else { return }
        ServicesFocus.shared.pending[server.id] = nil
        query = text
        filter = nil
    }

    // MARK: header

    private func header(_ model: ServicesModel) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Services").font(.system(size: 26, weight: .bold)).tracking(-0.4)
                Text(subtitle(model)).font(.system(size: 13)).foregroundStyle(Theme.textMuted)
            }
            Spacer()
            Button { model.refresh() } label: {
                if model.loading { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            .buttonStyle(.bordered).controlSize(.large).handCursor()
            .disabled(model.loading)
            .help("Scan again (⌘R). The list also refreshes every 30 seconds while this screen is open.")
        }
    }

    private func subtitle(_ model: ServicesModel) -> String {
        guard let s = model.snapshot else { return "Systemd services and programs listening on a port, outside Docker" }
        let shown = s.services.filter { visibility.isVisible($0, server: server.id) }
        var parts = ["\(shown.count) shown", "\(s.services.count - shown.count) hidden"]
        let problems = shown.filter(\.isProblem).count
        if problems > 0 { parts.append("\(problems) need\(problems == 1 ? "s" : "") attention") }
        if let at = model.updatedAt { parts.append("read \(at.formatted(date: .omitted, time: .shortened))") }
        return parts.joined(separator: " · ")
    }

    // MARK: content

    @ViewBuilder private func content(_ snapshot: ServicesSnapshot, model: ServicesModel) -> some View {
        let all = snapshot.services
        let shown = all.filter { visibility.isVisible($0, server: server.id) }
        let hidden = all.filter { !visibility.isVisible($0, server: server.id) }
        filterBar(shown, hiddenCount: hidden.count)
        if !snapshot.hasSystemd {
            NoticeRow(icon: "info.circle.fill", tint: Theme.accent,
                      message: "This server has no systemd, so only programs listening on a port are listed.")
                .noticeSurface(.info)
        }
        let list = sorted(shown.filter { $0.matches(query) && (filter?.includes($0) ?? true) })
        if list.isEmpty {
            Text(shown.isEmpty ? "Nothing shown yet. Turn on Show hidden to pick services to watch." : "No services match.")
                .font(.system(size: 13)).foregroundStyle(Theme.textMuted).padding(.vertical, 8)
        } else {
            grid(list, model: model, hidden: false)
        }
        if showHidden, !hidden.isEmpty {
            let hiddenList = sorted(hidden.filter { $0.matches(query) && (filter?.includes($0) ?? true) })
            HStack(spacing: 8) {
                Text("HIDDEN").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.textMuted)
                Text("Operating system services and anything you hid. Use ⋯ to show one.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            .padding(.top, 8)
            if !hiddenList.isEmpty { grid(hiddenList, model: model, hidden: true) }
        }
        if !snapshot.isRoot {
            Text("Ports are known for \(server.user ?? "your user")'s own processes only; services run by root or other users show without them.")
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted).padding(.top, 4)
        }
    }

    /// Problems first, then running, then the rest; by name within each.
    private func sorted(_ list: [DiscoveredService]) -> [DiscoveredService] {
        func rank(_ s: DiscoveredService) -> Int { s.isProblem ? 0 : (s.isRunning ? 1 : 2) }
        return list.sorted { (rank($0), $0.name.lowercased()) < (rank($1), $1.name.lowercased()) }
    }

    private func grid(_ list: [DiscoveredService], model: ServicesModel, hidden: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
            ForEach(list) { service in
                ServiceCard(service: service, serverID: server.id, webHost: webHost, editable: true, dimmed: hidden) {
                    ServiceMenuItems(service: service, server: server, model: model, openInTerminal: openInTerminal)
                }
            }
        }
    }

    private func filterBar(_ shown: [DiscoveredService], hiddenCount: Int) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textMuted)
                TextField("Search services, units, ports", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textMuted) }
                        .buttonStyle(.pointer).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10).frame(width: 280, height: 30)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            chip("All", nil, shown.count, Theme.textPrimary)
            ForEach(ServiceFilter.allCases, id: \.self) { f in
                chip(f.title, f, shown.filter(f.includes).count, f.color)
            }
            Spacer()
            Toggle(isOn: $showHidden) { Text("Show hidden (\(hiddenCount))").font(.system(size: 12)) }
                .toggleStyle(.switch).controlSize(.small).tint(Theme.accent)
                .help("Also list operating system services and the ones you hid, to choose what to watch")
        }
    }

    private func chip(_ title: String, _ f: ServiceFilter?, _ count: Int, _ color: Color) -> some View {
        let on = filter == f
        return Button { filter = on ? nil : f } label: {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)").monospacedDigit().foregroundStyle(on ? color : Theme.textMuted)
            }
            .font(.system(size: 12, weight: on ? .semibold : .regular))
            .foregroundStyle(on ? color : Theme.textSecondary)
            .padding(.horizontal, 10).frame(height: 26)
            .background(on ? color.opacity(0.14) : .clear, in: Capsule())
            .overlay(Capsule().stroke(on ? color.opacity(0.4) : Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.pointer)
        .disabled(f != nil && count == 0 && !on)
        .opacity(f != nil && count == 0 && !on ? 0.45 : 1)
    }
}

/// The status chips above the cards.
enum ServiceFilter: CaseIterable {
    case running, attention, stopped

    var title: String {
        switch self {
        case .running: "Running"
        case .attention: "Needs attention"
        case .stopped: "Stopped"
        }
    }

    @MainActor var color: Color {
        switch self {
        case .running: Theme.ok
        case .attention: Theme.warn
        case .stopped: Theme.textSecondary
        }
    }

    func includes(_ s: DiscoveredService) -> Bool {
        switch self {
        case .running: s.status == .running || s.status == .starting
        case .attention: s.isProblem
        case .stopped: s.status == .stopped || s.status == .stopping
        }
    }
}

extension DiscoveredService {
    var kindLabel: String {
        switch kind {
        case .system: "System service"
        case .user: "User service"
        case .process: "Started by hand"
        }
    }

    @MainActor var statusLook: (text: String, color: Color) {
        switch status {
        case .running: ("Running", Theme.ok)
        case .starting: ("Starting", Theme.warn)
        case .restarting: ("Crash loop", Theme.danger)
        case .stopping: ("Stopping", Theme.warn)
        case .stopped: ("Stopped", Theme.idle)
        case .failed: ("Failed" + (result.map { " (\($0))" } ?? ""), Theme.danger)
        }
    }

    /// One line on how it is doing: how long it has run, memory, boot setting, restarts.
    var facts: [String] {
        var out: [String] = []
        if let up = activeSeconds { out.append("Up \(Format.uptime(up))") }
        if let mem = memoryBytes, mem > 0 { out.append(Format.bytes(mem)) }
        if let boot = enabledAtBoot { out.append(boot ? "Starts at boot" : "Not at boot") }
        if restarts > 0 { out.append("\(restarts) restart\(restarts == 1 ? "" : "s")") }
        return out
    }
}

/// One service as a card: icon, name and kind, status, what it is, how it is doing and the ports it serves.
struct ServiceCard<Menu: View>: View {
    let service: DiscoveredService
    let serverID: String
    let webHost: String?
    /// The icon opens the picker (the Services screen); the Dashboard shows it as it is.
    var editable = false
    var dimmed = false
    /// The ⋯ menu (also the right-click menu); none on the Dashboard.
    @ViewBuilder var menu: () -> Menu
    static var iconSize: CGFloat { 40 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Group {
                    if editable {
                        EditableServiceIcon(service: service, serverID: serverID, webHost: webHost, size: Self.iconSize)
                    } else {
                        SystemServiceIconView(service: service, serverID: serverID, webHost: webHost, size: Self.iconSize)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(service.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Circle().fill(service.statusLook.color).frame(width: 7, height: 7)
                        Text(service.statusLook.text).font(.system(size: 12)).foregroundStyle(service.isProblem ? Theme.danger : Theme.textSecondary)
                            .lineLimit(1).layoutPriority(1)
                        Text("· " + service.kindLabel).font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if Menu.self != EmptyView.self {
                    SwiftUI.Menu { menu() } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Actions for \(service.name)")
                    .accessibilityLabel("Actions for \(service.name)")
                }
            }
            Text(identity).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textMuted)
                .lineLimit(1).truncationMode(.middle)
                .help(service.kind == .process ? service.detail : (service.path ?? identity))
            if service.kind != .process, !service.detail.isEmpty,
               ![service.name.lowercased(), (service.unit ?? "").lowercased(), ServicesParser.displayBase(service.unit)].contains(service.detail.lowercased()) {
                Text(service.detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !service.facts.isEmpty {
                Text(service.facts.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            if !service.ports.isEmpty { ports }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(service.isProblem ? Theme.danger.opacity(0.5) : Theme.border))
        .opacity(dimmed ? 0.6 : 1)
        .contextMenu { menu() }
    }

    /// The unit, or for a process the program it runs.
    private var identity: String {
        if let unit = service.unit { return unit }
        return service.detail.isEmpty ? service.name : service.detail
    }

    private var ports: some View {
        HStack(spacing: 10) {
            ForEach(service.ports.prefix(5), id: \.self) { port in
                if port.isLikelyWeb, let host = port.linkHost(preferred: webHost), let url = URL(string: "http://\(host):\(port.port)") {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label(":" + String(port.port), systemImage: "globe").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.pointer)
                    .help("Open \(url.absoluteString)")
                } else {
                    Text(verbatim: (port.isLoopback ? "local :" : ":") + String(port.port))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textMuted)
                        .help(port.isLoopback ? "Listens on \(port.address) only, so only the server itself can reach it" : "Listens on \(port.address):\(port.port)")
                }
            }
            if service.ports.count > 5 {
                Text(verbatim: "+" + String(service.ports.count - 5)).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
        }
    }
}

extension ServiceCard where Menu == EmptyView {
    init(service: DiscoveredService, serverID: String, webHost: String?, editable: Bool = false, dimmed: Bool = false) {
        self.init(service: service, serverID: serverID, webHost: webHost, editable: editable, dimmed: dimmed, menu: { EmptyView() })
    }
}

/// A service's actions, for its ⋯ menu and right-click menu. Changes are listed but ask first (and are disabled in
/// Read-only mode); a process started by hand has only the show/hide and copy items.
struct ServiceMenuItems: View {
    let service: DiscoveredService
    let server: Server
    let model: ServicesModel
    let openInTerminal: (String, String) -> Void
    private let visibility = ServiceVisibilityStore.shared

    var body: some View {
        if service.kind != .process {
            ForEach([ServiceAction.restart, .stop, .start], id: \.self) { action in
                if action.applies(to: service) {
                    Button(action.title + "…") { model.run(action, on: service) }
                        .disabled(model.blockedReason(action, on: service) != nil)
                }
            }
            Divider()
            Button("Status") { model.run(.status, on: service) }
                .disabled(model.blockedReason(.status, on: service) != nil)
            Button("Recent Logs") { model.run(.logs, on: service) }
                .disabled(model.blockedReason(.logs, on: service) != nil)
            if let follow = ServiceActions.followLogsCommand(for: service) {
                Button("Follow Logs in Terminal") { openInTerminal("Logs · \(service.name)", follow) }
            }
            Divider()
        }
        let visible = visibility.isVisible(service, server: server.id)
        Button(visible ? "Hide on \(server.name)" : "Show on \(server.name)") {
            visibility.set(!visible, service, server: server.id)
        }
        Button(visible ? "Hide on Every Server" : "Show on Every Server") {
            visibility.set(!visible, service, server: server.id, everywhere: true)
        }
        if visibility.choice(service, server: server.id) != nil {
            Button("Reset on \(server.name)") { visibility.set(nil, service, server: server.id) }
        }
        if visibility.choice(service, server: ServiceVisibility.everywhere) != nil {
            Button("Reset on Every Server") { visibility.set(nil, service, server: server.id, everywhere: true) }
        }
        Divider()
        Button(service.unit == nil ? "Copy Command Line" : "Copy Unit Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(service.unit ?? service.detail, forType: .string)
        }
    }
}
