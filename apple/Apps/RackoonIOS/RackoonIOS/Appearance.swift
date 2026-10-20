import Foundation
import Observation
import RackoonCore
import SwiftUI

/// The app's look, as on the Mac: one theme from the shared themes.json (or Automatic, following the system) drives the
/// whole UI through the `AppPalette` that Core derives from it.
@MainActor @Observable
final class AppearanceStore {
    let themes: [TerminalTheme]
    /// Set when themes.json could not be loaded; Settings shows it and a plain built-in theme is used.
    let themeError: String?
    private(set) var selectionID: String
    private(set) var systemIsDark: Bool
    private(set) var resolvedTheme: TerminalTheme
    private(set) var palette: AppPalette
    /// Colour IPs, errors, warnings and high percentages in terminal output (the Mac's switch, same key).
    private(set) var highlightOutput: Bool

    @ObservationIgnored private let defaults: UserDefaults
    static let selectionKey = "appearanceSelection"
    static let highlightKey = "terminalHighlightOutput"

    static let fallback = TerminalTheme(
        id: ThemeCatalog.defaultID, name: "Default", family: "Rackoon", appearance: "dark",
        background: "#000000", foreground: "#E5E5E5",
        ansi: ["#000000", "#CD3131", "#0DBC79", "#E5E510", "#2472C8", "#BC3FBC", "#11A8CD", "#E5E5E5",
               "#666666", "#F14C4C", "#23D18B", "#F5F543", "#3B8EEA", "#D670D6", "#29B8DB", "#FFFFFF"])

    /// `themesData` is the bundled themes.json (the Mac's own file, referenced by the Xcode project, not copied).
    init(themesData: Data?, defaults: UserDefaults = .standard, systemIsDark: Bool = true) {
        var loaded: [TerminalTheme] = []
        var loadError: String?
        do {
            guard let themesData else { throw ThemeCatalogError.invalid("themes.json is missing from the app bundle") }
            loaded = try ThemeCatalog.load(from: themesData)
        } catch {
            loadError = error.localizedDescription
        }
        let all = loaded.isEmpty ? [Self.fallback] : loaded
        let saved = defaults.string(forKey: Self.selectionKey) ?? ThemeCatalog.automaticID
        // A saved id that no longer exists (a theme removed from the bundle) becomes Automatic.
        let valid = saved == ThemeCatalog.automaticID || all.contains { $0.id == saved }
        let selection = valid ? saved : ThemeCatalog.automaticID
        let resolved = ThemeCatalog.resolve(selection: selection, systemIsDark: systemIsDark, in: all) ?? Self.fallback
        themes = all
        themeError = loadError
        selectionID = selection
        self.systemIsDark = systemIsDark
        resolvedTheme = resolved
        palette = AppPalette.derive(from: resolved)
        self.defaults = defaults
        highlightOutput = defaults.object(forKey: Self.highlightKey) as? Bool ?? true
        if !valid { defaults.set(ThemeCatalog.automaticID, forKey: Self.selectionKey) }
    }

    static func bundled(defaults: UserDefaults = .standard) -> AppearanceStore {
        let data = Bundle.main.url(forResource: "themes", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        return AppearanceStore(themesData: data, defaults: defaults)
    }

    var isAutomatic: Bool { selectionID == ThemeCatalog.automaticID }

    /// nil while following the system (so the environment reports the real system setting), otherwise forced to match.
    var fixedColorScheme: ColorScheme? {
        isAutomatic && themeError == nil ? nil : (resolvedTheme.isDark ? .dark : .light)
    }

    var selectionTitle: String { isAutomatic ? "Automatic · \(resolvedTheme.name)" : resolvedTheme.name }

    var darkThemes: [TerminalTheme] { themes.filter(\.isDark) }
    var lightThemes: [TerminalTheme] { themes.filter { !$0.isDark } }

    /// Picks a theme by id, or `ThemeCatalog.automaticID`.
    func select(_ id: String) {
        guard id == ThemeCatalog.automaticID || themes.contains(where: { $0.id == id }), id != selectionID else { return }
        selectionID = id
        defaults.set(id, forKey: Self.selectionKey)
        recompute()
    }

    func setHighlight(_ on: Bool) {
        guard on != highlightOutput else { return }
        highlightOutput = on
        defaults.set(on, forKey: Self.highlightKey)
    }

    /// The system's light/dark setting, read by the root view while nothing overrides it.
    func setSystemIsDark(_ dark: Bool) {
        guard dark != systemIsDark else { return }
        systemIsDark = dark
        recompute()
    }

    private func recompute() {
        if let theme = ThemeCatalog.resolve(selection: selectionID, systemIsDark: systemIsDark, in: themes), theme != resolvedTheme {
            resolvedTheme = theme
            palette = AppPalette.derive(from: theme)
        }
    }
}

extension Color {
    init(_ rgb: RGB) {
        self.init(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }
}
