import RackoonCore
import SwiftUI
import UIKit

@main
struct RackoonIOSApp: App {
    @State private var model = AppModel.live(deviceName: UIDevice.current.model)

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

/// Applies the theme to the whole app and follows the system's light/dark setting while Automatic is chosen.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("rootTab") private var tab = "dashboard"

    private var unseenAlerts: Int {
        let known = Set(model.servers.servers.map(\.id))
        return model.alerts.book.active().filter { known.contains($0.serverID) && !$0.acknowledged }.count
    }

    var body: some View {
        let palette = model.appearance.palette
        TabView(selection: $tab) {
            DashboardScreen()
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2") }
                .tag("dashboard")
            ServerListScreen()
                .tabItem { Label("Servers", systemImage: "server.rack") }
                .tag("servers")
            NavigationStack { AlertsScreen(serverID: nil) }
                .tabItem { Label("Alerts", systemImage: "bell") }
                .badge(unseenAlerts)
                .tag("alerts")
            SearchScreen()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag("search")
        }
            .tint(Color(palette.accent))
            // While the app is open every server is read once a minute, so the alerts stay current.
            .watching(model.servers.servers.map(\.id), fast: false)
            .onAppear { model.alerts.start() }
            .onChange(of: scenePhase) { _, phase in
                // Polls and alert checks stop in the background (iOS suspends the app soon anyway) and resume on return.
                if phase == .background {
                    model.fleet.pause()
                    model.alerts.stop()
                } else if phase == .active {
                    model.fleet.resume()
                    model.alerts.start()
                }
            }
            .preferredColorScheme(model.appearance.fixedColorScheme)
            .onAppear { model.appearance.setSystemIsDark(colorScheme == .dark) }
            .onChange(of: colorScheme) { _, scheme in
                // While a theme is fixed the environment reports the forced scheme; only Automatic needs the system's.
                if model.appearance.fixedColorScheme == nil { model.appearance.setSystemIsDark(scheme == .dark) }
            }
    }
}

/// Theme tokens, read inside `body` so views follow theme changes.
@MainActor
struct Tokens {
    let palette: AppPalette
    var background: Color { Color(palette.background) }
    var card: Color { Color(palette.card) }
    var border: Color { Color(palette.border) }
    var text: Color { Color(palette.textPrimary) }
    var secondary: Color { Color(palette.textSecondary) }
    var muted: Color { Color(palette.textMuted) }
    var accent: Color { Color(palette.accent) }
    var ok: Color { Color(palette.ok) }
    var warn: Color { Color(palette.warn) }
    var danger: Color { Color(palette.danger) }
    var idle: Color { Color(palette.idle) }
}

extension AppModel {
    var tokens: Tokens { Tokens(palette: appearance.palette) }
}

extension View {
    /// A themed list or form: the theme's background behind it and its card colour on the rows.
    func themedList(_ t: Tokens) -> some View {
        scrollContentBackground(.hidden)
            .background(t.background)
            .foregroundStyle(t.text)
    }
}
