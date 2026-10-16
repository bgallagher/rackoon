import RackoonCore
import SwiftUI

/// Theme (Automatic or any of the shared themes), the Read-only switch and demo mode.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let t = model.tokens
        NavigationStack {
            List {
                Section {
                    Toggle("Read-only", isOn: Binding(get: { model.safety.readOnly }, set: { model.safety.setReadOnly($0) }))
                        .accessibilityIdentifier("readOnlyToggle")
                } footer: {
                    Text("While on, nothing that changes a server can run: no restarts, installs or edits. Reading is always allowed.")
                }
                .listRowBackground(t.card)

                Section {
                    NavigationLink {
                        ThemePicker()
                    } label: {
                        LabeledContent("Theme", value: model.appearance.selectionTitle)
                    }
                    if let error = model.appearance.themeError {
                        Text(error).font(.footnote).foregroundStyle(t.danger)
                    }
                }
                .listRowBackground(t.card)

                Section {
                    Toggle("Demo Mode", isOn: Binding(get: { model.isDemo }, set: { model.setDemo($0) }))
                        .accessibilityIdentifier("demoToggle")
                } footer: {
                    Text("Shows two made-up servers instead of yours. Nothing is sent anywhere, and your servers are back when you switch it off.")
                }
                .listRowBackground(t.card)

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                }
                .listRowBackground(t.card)
            }
            .themedList(t)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

private struct ThemePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.tokens
        let appearance = model.appearance
        List {
            Section {
                row(id: ThemeCatalog.automaticID, title: "Automatic", subtitle: "Rackoon Dark or Light, following the system", swatch: nil)
            }
            .listRowBackground(t.card)
            Section("Dark") {
                ForEach(appearance.darkThemes) { theme in row(id: theme.id, title: theme.name, subtitle: theme.family, swatch: theme) }
            }
            .listRowBackground(t.card)
            Section("Light") {
                ForEach(appearance.lightThemes) { theme in row(id: theme.id, title: theme.name, subtitle: theme.family, swatch: theme) }
            }
            .listRowBackground(t.card)
        }
        .themedList(t)
        .navigationTitle("Theme")
    }

    private func row(id: String, title: String, subtitle: String, swatch: TerminalTheme?) -> some View {
        let t = model.tokens
        return Button {
            model.appearance.select(id)
        } label: {
            HStack(spacing: 12) {
                if let swatch { Swatch(theme: swatch) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(t.text)
                    Text(subtitle).font(.caption).foregroundStyle(t.secondary)
                }
                Spacer()
                if model.appearance.selectionID == id { Image(systemName: "checkmark").foregroundStyle(t.accent) }
            }
        }
    }
}

/// The theme's background with its first eight colours, like a tiny terminal.
private struct Swatch: View {
    let theme: TerminalTheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(theme.ansiRGB.prefix(8).enumerated()), id: \.offset) { _, rgb in
                RoundedRectangle(cornerRadius: 1).fill(Color(rgb)).frame(width: 4, height: 14)
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(theme.backgroundRGB)))
    }
}
