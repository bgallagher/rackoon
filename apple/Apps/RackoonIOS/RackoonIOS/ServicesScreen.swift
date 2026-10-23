import RackoonCore
import SwiftUI
import UIKit

/// What runs on the server outside Docker (as on the Mac): systemd services (the system's and the ssh user's own) and
/// programs started by hand that listen on a port. OS plumbing is hidden by default; anything can be shown or hidden, on
/// this server or on every server. Tap a service for its actions (Restart/Stop/Start ask first; Status and Recent Logs
/// stream; Follow Logs opens a terminal). Read every 30 s while open.
struct ServicesScreen: View {
    @Environment(AppModel.self) private var model
    let serverID: String
    /// A search result or an alert for one service: shown in the search box.
    var focus: String?

    var body: some View {
        if let server = model.servers.server(id: serverID) {
            switch model.servicesModel(for: server) {
            case .success(let services): ServicesList(services: services, server: server, focus: focus)
            case .failure(let reason):
                ContentUnavailableView("Services can't be read yet", systemImage: "gearshape.2", description: Text(reason.message))
                    .navigationTitle("Services")
            }
        } else {
            ContentUnavailableView("Server removed", systemImage: "server.rack")
        }
    }
}

private struct ServicesList: View {
    @Environment(AppModel.self) private var model
    let services: ServicesModel
    let server: Server
    let focus: String?
    @State private var query = ""
    @State private var filter: ServiceStatusFilter?
    @AppStorage("servicesShowHidden") private var showHidden = false

    var body: some View {
        let t = model.tokens
        let visibility = model.visibility
        List {
            if let error = services.error {
                Section { Label("Could not read the services: \(error)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(t.warn) }
                    .listRowBackground(t.card)
            }
            if let snapshot = services.snapshot {
                let all = snapshot.services
                let shown = all.filter { visibility.isVisible($0, server: server.id) }
                let hidden = all.filter { !visibility.isVisible($0, server: server.id) }
                Section {
                    chips(shown)
                    Toggle("Show hidden (\(hidden.count))", isOn: $showHidden)
                } footer: {
                    Text(ServicesPresentation.subtitle(snapshot) { visibility.isVisible($0, server: server.id) }
                         + (services.updatedAt.map { " · read \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
                }
                .listRowBackground(t.card)
                if !snapshot.hasSystemd {
                    Section { Text("This server has no systemd, so only programs listening on a port are listed.").foregroundStyle(t.secondary) }
                        .listRowBackground(t.card)
                }
                let list = ServicesPresentation.sorted(shown.filter(matches))
                Section {
                    if list.isEmpty {
                        Text(shown.isEmpty ? "Nothing shown yet. Turn on Show hidden to pick services to watch." : "No services match.")
                            .foregroundStyle(t.secondary)
                    }
                    ForEach(list) { s in row(s, dimmed: false) }
                }
                .listRowBackground(t.card)
                if showHidden, !hidden.isEmpty {
                    Section {
                        ForEach(ServicesPresentation.sorted(hidden.filter(matches))) { s in row(s, dimmed: true) }
                    } header: {
                        Text("Hidden")
                    } footer: {
                        Text("Operating system services and anything you hid. Open one to show it.")
                    }
                    .listRowBackground(t.card)
                }
                if !snapshot.isRoot {
                    Section {} footer: {
                        Text("Ports are known for \(server.user ?? "your user")'s own processes only; services run by root or other users show without them.")
                    }
                }
            } else if services.error == nil {
                Section { HStack { ProgressView(); Text("Looking for services…").foregroundStyle(t.secondary) } }
                    .listRowBackground(t.card)
            }
        }
        .themedList(t)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Services, units, ports")
        .navigationTitle("Services")
        .refreshable { await services.refresh() }
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            services.attach()
            if let focus { query = focus; filter = nil }
        }
        .onDisappear { services.detach() }
    }

    private func matches(_ s: DiscoveredService) -> Bool { s.matches(query) && (filter?.includes(s) ?? true) }

    private func row(_ s: DiscoveredService, dimmed: Bool) -> some View {
        NavigationLink {
            ServiceDetailScreen(services: services, server: server, serviceID: s.id)
        } label: {
            ServiceRow(service: s, serverID: server.id)
        }
        .opacity(dimmed ? 0.6 : 1)
    }

    private func chips(_ shown: [DiscoveredService]) -> some View {
        let t = model.tokens
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", nil, shown.count, t.text)
                ForEach(ServiceStatusFilter.allCases, id: \.self) { f in
                    chip(f.title, f, shown.filter(f.includes).count, color(f, t))
                }
            }
        }
    }

    private func color(_ f: ServiceStatusFilter, _ t: Tokens) -> SwiftUI.Color {
        switch f {
        case .running: t.ok
        case .attention: t.warn
        case .stopped: t.secondary
        }
    }

    private func chip(_ title: String, _ f: ServiceStatusFilter?, _ count: Int, _ color: SwiftUI.Color) -> some View {
        let t = model.tokens
        let on = filter == f
        return Button { filter = on ? nil : f } label: {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)").monospacedDigit().foregroundStyle(on ? color : t.muted)
            }
            .font(.footnote.weight(on ? .semibold : .regular))
            .foregroundStyle(on ? color : t.secondary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(on ? color.opacity(0.14) : .clear, in: Capsule())
            .overlay(Capsule().stroke(on ? color.opacity(0.4) : t.border))
        }
        .buttonStyle(.plain)
        .disabled(f != nil && count == 0 && !on)
        .opacity(f != nil && count == 0 && !on ? 0.45 : 1)
    }
}

/// One service in the list: icon, name, status and kind, and what it is.
struct ServiceRow: View {
    @Environment(AppModel.self) private var model
    let service: DiscoveredService
    let serverID: String

    var body: some View {
        let t = model.tokens
        let status = ServicesPresentation.status(service)
        HStack(spacing: 12) {
            SystemServiceIconView(service: service, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(service.name).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Circle().fill(t.tone(status.tone)).frame(width: 7, height: 7)
                    Text(status.text).foregroundStyle(service.isProblem ? t.danger : t.secondary)
                    Text("· " + ServicesPresentation.kindLabel(service.kind)).foregroundStyle(t.muted)
                }
                .font(.caption).lineLimit(1)
                if let description = ServicesPresentation.description(service) {
                    Text(description).font(.caption).foregroundStyle(t.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if !service.ports.isEmpty {
                Text(service.ports.prefix(2).map { ":\($0.port)" }.joined(separator: " ")).font(.caption.monospaced()).foregroundStyle(t.muted)
            }
        }
        .accessibilityIdentifier("service-\(service.id)")
    }
}

/// A service's logo from the icon collections when one matches its product or name, else its letter.
struct SystemServiceIconView: View {
    @Environment(AppModel.self) private var model
    let service: DiscoveredService
    let size: CGFloat

    var body: some View {
        let store = model.icons
        let name = AppIconGuess.iconID(for: service, in: store.catalog)
        Group {
            if let name, let image = store.image(name) {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            } else {
                LetterTileView(name: service.name, size: size)
            }
        }
        .task(id: name ?? "") {
            if let name { store.ensure([name], urgent: true) } else { store.ensureCatalog() }
        }
    }
}

/// One service: what it is, how it is doing, its ports, its actions with their live output, and show/hide.
private struct ServiceDetailScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let services: ServicesModel
    let server: Server
    let serviceID: String
    @State private var terminal = false
    @State private var note: String?

    var body: some View {
        let t = model.tokens
        if let service = services.snapshot?.services.first(where: { $0.id == serviceID }) {
            let runner = services.runner
            VStack(spacing: 0) {
                List {
                    header(service)
                    if !service.ports.isEmpty { ports(service) }
                    actions(service)
                    if let message = runner.message ?? note {
                        Section { Label(message, systemImage: "info.circle.fill").foregroundStyle(t.secondary) }
                            .listRowBackground(t.card)
                    }
                    visibility(service)
                    Section {
                        Button(service.unit == nil ? "Copy Command Line" : "Copy Unit Name") {
                            UIPasteboard.general.string = service.unit ?? service.detail
                        }
                        .foregroundStyle(t.accent)
                    }
                    .listRowBackground(t.card)
                }
                .themedList(t)
                if let (key, output) = services.output(for: service) {
                    OutputPanel(output: output, cancel: { runner.cancelOutput(key) }, close: { runner.dismissOutput(key) })
                        .padding(.top, 8)
                        .frame(height: 300)
                        .background(t.background)
                }
            }
            .background(t.background)
            .navigationTitle(service.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .confirmAction(Binding(get: { runner.pending }, set: { runner.pending = $0 }))
            .sudoPassword(Binding(get: { runner.sudoRequest }, set: { runner.sudoRequest = $0 }))
            // A change finished: read again so the page shows the new state.
            .onChange(of: runner.isRunning) { _, running in if !running { Task { await services.refresh() } } }
            .navigationDestination(isPresented: $terminal) { TerminalScreen(serverID: server.id) }
        } else {
            ContentUnavailableView("Service gone", systemImage: "gearshape.2",
                                   description: Text("It is not in the latest reading of \(server.name)."))
        }
    }

    private func header(_ s: DiscoveredService) -> some View {
        let t = model.tokens
        let status = ServicesPresentation.status(s)
        let facts = ServicesPresentation.facts(s, uptime: { Present.uptime($0) }, bytes: { Present.bytes($0) })
        return Section {
            HStack(spacing: 12) {
                SystemServiceIconView(service: s, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(t.tone(status.tone)).frame(width: 8, height: 8)
                        Text(status.text).foregroundStyle(s.isProblem ? t.danger : t.text)
                    }
                    Text(ServicesPresentation.kindLabel(s.kind)).font(.caption).foregroundStyle(t.secondary)
                }
            }
            Text(ServicesPresentation.identity(s)).font(.caption.monospaced()).foregroundStyle(t.secondary).textSelection(.enabled)
            if let description = ServicesPresentation.description(s) { Text(description).foregroundStyle(t.secondary) }
            if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.caption).foregroundStyle(t.muted) }
        }
        .listRowBackground(t.card)
    }

    private func ports(_ s: DiscoveredService) -> some View {
        let t = model.tokens
        let host = model.webHost(for: server.id)
        return Section("Ports") {
            ForEach(s.ports, id: \.self) { port in
                if let url = ServicesPresentation.link(port, webHost: host) {
                    Button { openURL(url) } label: {
                        Label(url.absoluteString, systemImage: "globe").font(.callout.monospaced())
                    }
                    .foregroundStyle(t.accent)
                } else {
                    Text(verbatim: (port.isLoopback ? "\(port.address):\(port.port) (this server only)" : "\(port.address):\(port.port)"))
                        .font(.callout.monospaced()).foregroundStyle(t.secondary)
                }
            }
        }
        .listRowBackground(t.card)
    }

    @ViewBuilder private func actions(_ s: DiscoveredService) -> some View {
        let t = model.tokens
        let list = ServicesPresentation.actions(for: s)
        if !list.isEmpty {
            Section {
                ForEach(list, id: \.self) { action in
                    let blocked = services.blockedReason(action, on: s)
                    Button(role: action.isMutating && action != .start ? .destructive : nil) {
                        note = nil
                        services.run(action, on: s)
                    } label: {
                        Label(action.isMutating ? action.title + "…" : action.title, systemImage: icon(action))
                    }
                    .foregroundStyle(blocked == nil ? (action.isMutating && action != .start ? t.danger : t.accent) : t.muted)
                    .disabled(blocked != nil)
                    .accessibilityIdentifier("service-\(action.rawValue)")
                }
                if let follow = ServiceActions.followLogsCommand(for: s) {
                    Button {
                        if let problem = model.openTerminal(on: server, command: follow, title: "Logs · \(s.name)") { note = problem } else { terminal = true }
                    } label: {
                        Label("Follow Logs in Terminal", systemImage: "terminal")
                    }
                    .foregroundStyle(model.safety.readOnly ? t.muted : t.accent)
                    .disabled(model.safety.readOnly)
                }
            } footer: {
                if model.safety.readOnly { Text("Read-only is on: Restart, Stop, Start and the terminal are off.") }
            }
            .listRowBackground(t.card)
        } else {
            Section {} footer: { Text("Started by hand, not by systemd, so Rackoon can't start or stop it.") }
        }
    }

    private func icon(_ action: ServiceAction) -> String {
        switch action {
        case .start: "play"
        case .stop: "stop"
        case .restart: "arrow.clockwise"
        case .status: "info.circle"
        case .logs: "doc.plaintext"
        }
    }

    private func visibility(_ s: DiscoveredService) -> some View {
        let t = model.tokens
        let store = model.visibility
        let visible = store.isVisible(s, server: server.id)
        return Section {
            Group {
                Button(visible ? "Hide on \(server.name)" : "Show on \(server.name)") { store.set(!visible, s, server: server.id) }
                Button(visible ? "Hide on Every Server" : "Show on Every Server") { store.set(!visible, s, server: server.id, everywhere: true) }
                if store.choice(s, server: server.id) != nil {
                    Button("Reset on \(server.name)") { store.set(nil, s, server: server.id) }
                }
                if store.choice(s, server: ServiceVisibility.everywhere) != nil {
                    Button("Reset on Every Server") { store.set(nil, s, server: server.id, everywhere: true) }
                }
            }
            .foregroundStyle(t.accent)
        } footer: {
            Text("Shown services are watched for alerts: failed, crash-looping, or stopped although they start at boot.")
        }
        .listRowBackground(t.card)
    }
}

extension Tokens {
    /// A status tone from Core ("ok", "warn", "danger", "idle") as a colour.
    func tone(_ name: String?) -> SwiftUI.Color {
        switch name {
        case "ok": ok
        case "warn": warn
        case "danger": danger
        case "idle": idle
        default: muted
        }
    }
}
