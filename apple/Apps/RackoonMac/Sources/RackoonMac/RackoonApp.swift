import RackoonCore
import SwiftUI

/// `swift run` launches a bare executable with no .app bundle, so macOS treats it as a
/// background process. Promote it so the window and Dock icon appear. Harmless in a real bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppIcon.installDockIcon()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// `rackoon://purchase-complete` (the Paddle checkout's redirect). Only the host is looked at.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == Supporter.returnScheme && $0.host == Supporter.returnHost }) else { return }
        MainActor.assumeIsolated {
            LicenceStore.shared.purchaseCompleted()
            NotificationCenter.default.post(name: .rackoonShowLicence, object: nil)
        }
    }
}

extension Notification.Name {
    static let rackoonShowLicence = Notification.Name("rackoonShowLicence")
}

@main
struct RackoonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Self.migrateLegacyDefaults()
    }

    /// Without a bundle the defaults domain is the executable name, with one it is the bundle id. Copy the keys
    /// across once from the earlier domains (`HomebaseMac`, then `RackoonMac` under `swift run`), before anything reads them.
    private static func migrateLegacyDefaults() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "selectedServerID") == nil,
              defaults.object(forKey: "appearanceSelection") == nil else { return }
        let own = Bundle.main.bundleIdentifier
        for domain in ["RackoonMac", "HomebaseMac"] where domain != own {
            guard let old = defaults.persistentDomain(forName: domain) else { continue }
            for key in ["selectedServerID", "appearanceSelection", "terminalThemeID", "terminalHighlightOutput"] {
                if let value = old[key] { defaults.set(value, forKey: key) }
            }
            return
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            AboutCommand()
            TerminalCommands()
            ViewCommands()
            GoCommands()
            ServerCommands()
        }

        Window("Rackoon Licence", id: LicenceSheetWindow.id) {
            LicenceWindowContent()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Window("About Rackoon", id: AboutView.windowID) {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

/// What the Terminal menu items act on. Published by the front window only while a terminal is showing.
struct TerminalActions {
    var newTab: () -> Void
    var closeTab: () -> Void
    var renameTab: () -> Void
    var nextTab: () -> Void
    var previousTab: () -> Void
    /// Nil while the tab is connected.
    var reconnect: (() -> Void)?
}

extension FocusedValues {
    @Entry var terminalActions: TerminalActions?
}

/// What the Go and Server menus act on. Published by the front window; every item only navigates or triggers the
/// same request a button makes, so mutations still meet the confirm sheet and the Read-only switch.
struct AppActions {
    var screen: Screen
    var go: (Screen) -> Void
    var servers: [Server]
    var selectedServerID: String?
    var selectServer: (Server) -> Void
    /// Opens the sidebar's server menu with its search field focused.
    var switchServer: () -> Void
    var addServer: () -> Void
    /// Opens the Edit Connection sheet for the selected server.
    var editServer: () -> Void
    /// Forgets the selected server's saved sudo password; nil when none is saved.
    var forgetSudoPassword: (() -> Void)?
    var refresh: () -> Void
    var openTerminalHere: () -> Void
    /// Opens the search panel.
    var search: () -> Void = {}
    var ipAddress: String?
    var tailscaleIP: String?
}

extension FocusedValues {
    @Entry var appActions: AppActions?
    /// Set by the screen that is showing, so Server > Refresh Now reloads what that screen shows.
    @Entry var screenRefresh: (() -> Void)?
    /// The "new thing" the showing screen offers (Add Container, Add Bookmark); nil when it can't be done right now.
    @Entry var screenAdd: ScreenAdd?
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct ViewCommands: Commands {
    private let appearance = AppearanceStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Menu("Theme") {
                Toggle("Automatic", isOn: Binding(get: { appearance.isAutomatic }, set: { _ in appearance.select(ThemeCatalog.automaticID) }))
                Divider()
                ForEach(appearance.themes, id: \.id) { theme in
                    Toggle(theme.name, isOn: Binding(
                        get: { !appearance.isAutomatic && appearance.selectionID == theme.id },
                        set: { _ in appearance.select(theme.id) }))
                }
            }
            Toggle("Highlight Terminal Output", isOn: Binding(get: { appearance.highlightOutput }, set: { appearance.setHighlight($0) }))
        }
        CommandGroup(replacing: .help) {
            if Supporter.menuItemsVisible {
                if LicenceStore.shared.isSupporter {
                    Text("Thanks for supporting Rackoon")
                } else if let url = Supporter.url {
                    Link("Feed the Rackoon…", destination: url)
                }
                Button("Enter Licence…") { openWindow(id: LicenceSheetWindow.id) }
                Divider()
            }
            Link("Rackoon on GitHub", destination: URL(string: "https://github.com/bgallagher/rackoon")!)
        }
    }
}

enum LicenceSheetWindow { static let id = "licence" }

/// The licence form in its own small window (Help > Enter Licence…), so it works from any screen.
struct LicenceWindowContent: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        LicenceSheet { dismissWindow(id: LicenceSheetWindow.id) }
            .background(Theme.background)
            .foregroundStyle(Theme.textPrimary)
            .tint(Theme.accent)
            .preferredColorScheme(AppearanceStore.shared.fixedColorScheme)
    }
}

struct ScreenAdd {
    var title: String
    var run: () -> Void
}

struct GoCommands: Commands {
    @FocusedValue(\.appActions) private var actions

    private static let screens: [(Screen, KeyEquivalent)] = [
        (.dashboard, "0"), (.overview, "1"), (.docker, "2"), (.updates, "3"), (.bookmarks, "4"), (.files, "5"), (.terminal, "6"), (.command, "7"), (.services, "8"), (.alerts, "9"),
    ]

    var body: some Commands {
        CommandMenu("Go") {
            ForEach(Self.screens, id: \.0) { screen, key in
                Button(screen.title) { actions?.go(screen) }
                    .keyboardShortcut(key)
                    .disabled(actions == nil || actions?.servers.isEmpty == true)
            }
            Divider()
            Button("Search…") { actions?.search() }
                .keyboardShortcut("f")
                .disabled(actions?.servers.isEmpty ?? true)
            Button("Switch Server…") { actions?.switchServer() }
                .keyboardShortcut("k")
                .disabled(actions?.servers.isEmpty ?? true)
            Button("Previous Server") { step(-1) }
                .keyboardShortcut("[")
                .disabled((actions?.servers.count ?? 0) < 2)
            Button("Next Server") { step(1) }
                .keyboardShortcut("]")
                .disabled((actions?.servers.count ?? 0) < 2)
            Menu("Servers") {
                ForEach(Array((actions?.servers ?? []).enumerated()), id: \.element.id) { index, server in
                    let item = Toggle(server.name, isOn: Binding(
                        get: { server.id == actions?.selectedServerID },
                        set: { _ in actions?.selectServer(server) }))
                    // Only the first nine get a shortcut; later ones are reachable from the menu or ⌘[ ⌘].
                    if index < 9 {
                        item.keyboardShortcut(Self.serverKey(index), modifiers: [.command, .option])
                    } else {
                        item
                    }
                }
            }
            .disabled(actions?.servers.isEmpty ?? true)
        }
    }

    private static func serverKey(_ index: Int) -> KeyEquivalent {
        let digits: [Character] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
        return KeyEquivalent(digits[index])
    }

    private func step(_ delta: Int) {
        guard let actions, actions.servers.count > 1 else { return }
        let current = actions.servers.firstIndex { $0.id == actions.selectedServerID } ?? 0
        let next = (current + delta + actions.servers.count) % actions.servers.count
        actions.selectServer(actions.servers[next])
    }
}

struct ServerCommands: Commands {
    @FocusedValue(\.appActions) private var actions
    @FocusedValue(\.screenRefresh) private var screenRefresh

    var body: some Commands {
        CommandMenu("Server") {
            let hasServer = actions?.selectedServerID != nil
            Button("Refresh Now") { if let screenRefresh { screenRefresh() } else { actions?.refresh() } }
                .keyboardShortcut("r")
                .disabled(!hasServer)
            Toggle("Read-only Mode", isOn: Binding(
                get: { SafetyStore.shared.readOnly },
                set: { SafetyStore.shared.setReadOnly($0) }))
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Copy IP Address") { if let ip = actions?.ipAddress { copyToPasteboard(ip) } }
                .disabled(actions?.ipAddress == nil)
            if let ts = actions?.tailscaleIP {
                Button("Copy Tailscale IP") { copyToPasteboard(ts) }
            }
            Divider()
            Button("Open Terminal Here") { actions?.openTerminalHere() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!hasServer)
            Button("Add Server…") { actions?.addServer() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Edit Connection…") { actions?.editServer() }
                .keyboardShortcut("i")
                .disabled(!hasServer)
            Button("Forget Saved Sudo Password") { actions?.forgetSudoPassword?() }
                .disabled(actions?.forgetSudoPassword == nil)
        }
    }
}

struct AboutCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Rackoon") { openWindow(id: AboutView.windowID) }
        }
    }
}

struct TerminalCommands: Commands {
    @FocusedValue(\.terminalActions) private var actions
    @FocusedValue(\.screenAdd) private var add

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(add?.title ?? "New…") { add?.run() }
                .keyboardShortcut("n")
                .disabled(add == nil)
        }
        CommandMenu("Terminal") {
            Button("Rename Tab…") { actions?.renameTab() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Next Tab") { actions?.nextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Previous Tab") { actions?.previousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Divider()
            Button("Reconnect") { actions?.reconnect?() }
                .disabled(actions?.reconnect == nil)
        }
        // Replace File > Close so Cmd+W closes the current tab when a terminal is showing,
        // and still closes the window everywhere else.
        CommandGroup(replacing: .saveItem) {
            Button("New Terminal Tab") { actions?.newTab() }
                .keyboardShortcut("t")
                .disabled(actions == nil)
            Button(actions == nil ? "Close Window" : "Close Tab") {
                if let actions { actions.closeTab() } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
        }
    }
}

struct ContentView: View {
    @State private var model = AppModel()
    @State private var selection: Screen = .overview
    @State private var terminals = TerminalStore()
    @State private var dockerWorkspace = DockerWorkspace()
    @State private var showingAdd = false
    @State private var switcher = ServerSwitcherState()
    @State private var search = SearchState()
    /// The server whose connection details are being edited (the Edit Connection sheet).
    @State private var editing: Server?
    @Environment(\.openWindow) private var openWindow
    private let appearance = AppearanceStore.shared

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $selection, servers: model.servers, selectedID: model.selectedID, light: light,
                    switcher: switcher, updates: updateBadge,
                    alerts: alertBadge(server: model.selectedID), allAlerts: alertBadge(server: nil),
                    hiddenScreens: model.state.overview.map { ServerKind.detect($0.os).hiddenScreens } ?? [],
                    onAddServer: { showingAdd = true }, onSearch: { switcher.close(); search.open() })
            Divider()
            // The pane takes all the room that is left, whatever it shows. Without this an empty state shrank the whole row to
            // its own size and floated it in the middle of a wider window, with the window background showing at both sides.
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1080, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .coordinateSpace(name: ServerSwitcherState.space)
        .overlay {
            if search.isOpen {
                SearchPanel(search: search,
                            items: { SearchIndex.items(rows: model.fleetRows, workspace: dockerWorkspace) },
                            open: openSearchResult)
            }
        }
        .overlay {
            // The open server menu floats over the whole window, so it can reach past the sidebar and close on any click.
            if switcher.isOpen {
                ServerSwitcherPanel(
                    switcher: switcher, servers: model.servers, selectedID: model.selectedID, light: light,
                    onSelect: { server in
                        if server.id != model.selectedID || selection == .dashboard { selection = .overview }
                        model.select(server)
                    },
                    onEdit: { editing = $0 },
                    onRemove: { server in
                        terminals.closeAll(for: server)
                        dockerWorkspace.forget(serverID: server.id)
                        AppIconStore.shared.forget(serverID: server.id)
                        ServicesStore.shared.forget(serverID: server.id)
                        ServiceVisibilityStore.shared.forget(serverID: server.id)
                        AlertMonitor.shared.forget(serverID: server.id)
                        model.remove(server)
                    },
                    onReorder: { model.reorder($0) },
                    onAddServer: { showingAdd = true })
            }
        }
        .background(Theme.background)
        // The theme drives the whole window: accent for controls, light/dark for system-drawn parts, and
        // every open terminal is recoloured when the resolved theme changes.
        .tint(Theme.accent)
        .preferredColorScheme(appearance.fixedColorScheme)
        .onChange(of: appearance.resolvedTheme) { _, theme in terminals.applyTheme(theme) }
        .onChange(of: appearance.highlightOutput) { _, _ in terminals.highlightSettingChanged() }
        .onAppear {
            appearance.applyWindowAppearance()
            model.start()
            AlertMonitor.shared.start(fleet: { [model] in model.fleetRows })
            // With no server saved the window shows the welcome page, whose Add Server button opens the sheet.
            // The app was started by the checkout's redirect: this view did not exist yet when the link arrived.
            if LicenceStore.shared.purchaseReturned { openWindow(id: LicenceSheetWindow.id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .rackoonShowLicence)) { _ in openWindow(id: LicenceSheetWindow.id) }
        // A notification was clicked: that server's Alerts (or every server's, on the Dashboard).
        .onReceive(NotificationCenter.default.publisher(for: .rackoonShowAlerts)) { note in
            if let id = note.object as? String, let server = model.servers.first(where: { $0.id == id }) {
                if server.id != model.selectedID { model.select(server) }
                selection = .alerts
            } else {
                UserDefaults.standard.set(DashboardScreen.Page.alerts.rawValue, forKey: "dashboardPage")
                selection = .dashboard
            }
        }
        .focusedSceneValue(\.terminalActions, terminalActions)
        .focusedSceneValue(\.appActions, appActions)
        .sheet(isPresented: $showingAdd) {
            AddServerSheet(existing: model.servers, canCancel: true) { server in
                showingAdd = false
                selection = .overview
                model.add(server)
            } onCancel: { showingAdd = false }
        }
        .sheet(item: $editing) { server in
            EditServerSheet(server: server, onSave: applyEdit) { editing = nil }
        }
        .sheet(isPresented: pendingTrust) {
            if case .needsTrust(let offer) = model.phase, let server = model.selected {
                HostKeySheet(server: server, offer: offer, onTrust: model.trustPending, onCancel: model.declineTrust)
            }
        }
    }

    /// The Edit Connection sheet was saved. When the connection details changed, what was open against the old address
    /// (terminal tabs, Docker and Files models) is closed; the model reconnects the selected server itself.
    private func applyEdit(_ server: Server) {
        editing = nil
        if model.update(server) {
            terminals.closeAll(for: server)
            dockerWorkspace.forget(serverID: server.id)
            ServicesStore.shared.forget(serverID: server.id)
        }
    }

    private var terminalActions: TerminalActions? {
        guard selection == .terminal, let server = model.selected else { return nil }
        return TerminalActions(
            newTab: { terminals.newTab(for: server) },
            closeTab: { if let tab = terminals.selectedTab(for: server) { terminals.close(tab, for: server) } },
            renameTab: { terminals.selectedTab(for: server)?.renameRequest += 1 },
            nextTab: { terminals.stepTab(1, for: server) },
            previousTab: { terminals.stepTab(-1, for: server) },
            reconnect: terminals.selectedTab(for: server).flatMap { tab in
                tab.isRunning || tab.reconnecting != nil ? nil : { tab.reconnect() }
            })
    }

    private var appActions: AppActions {
        AppActions(
            screen: selection,
            go: { screen in if screen.isAvailable { selection = screen } },
            servers: model.servers,
            selectedServerID: model.selectedID,
            selectServer: { server in selection = .overview; model.select(server) },
            switchServer: { switcher.open() },
            addServer: { showingAdd = true },
            editServer: { editing = model.selected },
            forgetSudoPassword: model.selected.flatMap { server in
                SudoVault.shared.remembered.contains(server.id) ? { SudoVault.shared.forget(server.id) } : nil
            },
            refresh: { model.refresh() },
            openTerminalHere: {
                guard let server = model.selected else { return }
                terminals.newTab(for: server)
                selection = .terminal
            },
            search: { switcher.close(); search.open() },
            ipAddress: model.state.overview?.ipAddress,
            tailscaleIP: model.state.overview?.tailscaleIP)
    }

    private func alertBadge(server: String?) -> AlertBadge? {
        let book = AlertMonitor.shared.book
        let count = book.unseenCount(server: server)
        return count > 0 ? AlertBadge(count: count, critical: book.worstUnseen(server: server) == .critical) : nil
    }

    /// Goes where an alert can be dealt with: its server, then the screen (and the stack) it names.
    private func openAlert(_ alert: ServerAlert) {
        guard let server = model.servers.first(where: { $0.id == alert.serverID }), let fix = alert.fix else { return }
        if server.id != model.selectedID { model.select(server) }
        if fix.screen == "docker", let stack = fix.target { dockerWorkspace.openStack[server.id] = stack }
        selection = Screen(rawValue: fix.screen).flatMap { $0.isAvailable ? $0 : nil } ?? .overview
    }

    /// Goes where a search result lives.
    private func openSearchResult(_ item: SearchItem) {
        func show(_ serverID: String, _ screen: Screen) {
            guard let server = model.servers.first(where: { $0.id == serverID }) else { return }
            if server.id != model.selectedID { model.select(server) }
            selection = screen
        }
        switch item.target {
        case .server(let id): show(id, .overview)
        case .stack(let server, let stack):
            dockerWorkspace.openStack[server] = stack
            show(server, .docker)
        case .service(let server, _):
            ServicesFocus.shared.pending[server] = item.title
            show(server, .services)
        case .bookmark(let server, _): show(server, .bookmarks)
        case .alert(let server, _): show(server, .alerts)
        case .command(let id):
            guard let server = model.selected ?? model.servers.first else { return }
            if server.id != model.selectedID { model.select(server) }
            dockerWorkspace.commandsModel(for: server).select(.library(id))
            selection = .command
        }
    }

    private var updateBadge: UpdateBadge? {
        // RACKOON_DEMO_UPDATES=1 pretends there are updates (see UpdatesModel), so the dot can be seen.
        if ProcessInfo.processInfo.environment["RACKOON_DEMO_UPDATES"] != nil { return UpdateBadge(total: 5, security: 2) }
        guard let o = model.state.overview else { return nil }
        return UpdateBadge(total: o.pendingUpdates, security: o.securityUpdates)
    }

    private var pendingTrust: Binding<Bool> {
        Binding(
            get: { if case .needsTrust = model.phase { true } else { false } },
            set: { if !$0 { model.declineTrust() } })
    }

    /// A server's status light: the selected one from its live poll, the others from the once-a-minute poll.
    private func light(_ server: Server) -> ServerLight {
        if server.id == model.selectedID {
            let summary: String = switch status {
            case .connected: "Online"
            case .failing: model.state.error.map { "Not answering: \($0)" } ?? "Not connected"
            case .connecting, .none: "Connecting…"
            }
            return ServerLight(status: status, summary: summary)
        }
        let entry = model.backgroundEntry(server.id)
        return ServerLight(status: entry?.status ?? .none, summary: entry?.summary ?? "Not checked yet")
    }

    private var status: ConnectionStatus {
        switch model.phase {
        case .blocked: .failing
        case .idle where model.state.error != nil: .failing
        case .polling:
            model.state.error != nil ? .failing : (model.state.overview == nil || model.state.isStale ? .connecting : .connected)
        default: .connecting
        }
    }

    @ViewBuilder private var detail: some View {
        if selection == .dashboard, !model.servers.isEmpty {
            DashboardScreen(model: model, workspace: dockerWorkspace, theme: appearance.resolvedTheme, openAlert: openAlert,
                            openServer: { server, screen in
                                model.select(server)
                                selection = screen
                            },
                            openStack: { server, stack in
                                model.select(server)
                                dockerWorkspace.openStack[server.id] = stack
                                selection = .docker
                            })
        } else if let server = model.selected {
            ZStack {
                switch selection {
                case .overview:
                    OverviewView(model: model, server: server, openTerminal: { selection = .terminal },
                                 openScreen: { fix in if let s = Screen(rawValue: fix), s.isAvailable { selection = s } },
                                 editServer: { editing = server })
                case .docker:
                    DockerScreen(server: server, theme: appearance.resolvedTheme, workspace: dockerWorkspace,
                                 webHost: model.state.overview?.tailscaleIP ?? model.state.overview?.ipAddress, openShell: { container in
                        guard let command = DockerSession.shellCommand(id: container.id) else { return }
                        // With Docker unlocked through sudo, the terminal asks for the password itself (sudo's prompt).
                        let shell = DockerElevation.shared.isUnlocked(server) ? "sudo " + command : command
                        terminals.newTab(for: server, title: "Shell · \(container.service ?? container.name)", command: shell)
                        selection = .terminal
                    }).id(DockerElevation.shared.key(server))
                case .alerts:
                    AlertsScreen(server: server, open: openAlert)
                case .services:
                    ServicesScreen(server: server, theme: appearance.resolvedTheme,
                                   webHost: model.state.overview?.tailscaleIP ?? model.state.overview?.ipAddress,
                                   openInTerminal: { title, command in
                                       terminals.newTab(for: server, title: title, command: command)
                                       selection = .terminal
                                   }).id(server.connectionKey)
                case .bookmarks:
                    BookmarksScreen(server: server, workspace: dockerWorkspace,
                                    openStack: { id in dockerWorkspace.openStack[server.id] = id; selection = .docker })
                        .id(DockerElevation.shared.key(server))
                case .files:
                    FilesScreen(server: server, workspace: dockerWorkspace, openTerminal: { directory in
                        guard let command = RemoteFiles.terminalCommand(in: directory) else { return }
                        terminals.newTab(for: server, title: "Files · \((directory as NSString).lastPathComponent)", command: command)
                        selection = .terminal
                    }).id(server.id)
                case .updates:
                    // Keyed by the connection, not just the id: after Edit Connection the model (and its transport)
                    // must be rebuilt, or a sudo password would go to the old address.
                    // Reboot… is confirmed right here; once confirmed, the Overview (which shows the sudo password sheet
                    // and the waiting and reconnect progress) takes over.
                    UpdatesScreen(server: server, theme: appearance.resolvedTheme,
                                  reboot: { model.requestReboot(server, then: { selection = .overview }) },
                                  rebootPending: Binding(get: { model.pending }, set: { model.pending = $0 }))
                        .id(server.connectionKey)
                case .terminal:
                    TerminalScreen(store: terminals, server: server)
                case .command:
                    CommandsScreen(server: server, theme: appearance.resolvedTheme, workspace: dockerWorkspace,
                                   openInTerminal: { title, command in
                                       terminals.newTab(for: server, title: title, command: command)
                                       selection = .terminal
                                   }).id(server.id)
                default:
                    EmptyView()
                }
            }
        } else {
            Welcome(addServer: { showingAdd = true })
        }
    }
}

/// The first screen, before any server is saved.
private struct Welcome: View {
    let addServer: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Group {
                if let icon = AppIcon.artwork {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "server.rack").resizable().scaledToFit().padding(24).foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            VStack(spacing: 6) {
                Text("Add your first server").font(.system(size: 24, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Text("Rackoon connects over SSH and runs standard commands. Nothing is installed on the server.")
                    .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            Button(action: addServer) { Text("Add Server").fontWeight(.semibold).padding(.horizontal, 10) }
                .buttonStyle(.borderedProminent).controlSize(.large).handCursor()
                .padding(.top, 4)
            Text("Pick a host from ~/.ssh/config or type one in.").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
