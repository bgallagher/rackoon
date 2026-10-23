import RackoonCore
import SwiftUI

/// A root command was refused because the ssh user's sudo wants a password. `submit` gets the typed password, which the
/// caller hands to sudo and keeps nowhere (unless the user asked to remember it and the server accepted it).
struct SudoRequest: Identifiable {
    let id = UUID()
    let title: String
    let server: Server
    /// The exact command that will run (it contains no password).
    let command: String
    /// Why the previous attempt failed, if there was one.
    var problem: String?
    /// The button: "Reboot", "Install", "Unlock".
    var actionLabel = "Run"
    var destructive = false
    /// Offer "Remember on this device" (only when the vault can store passwords).
    var canRemember = false
    let submit: (String, Bool) -> Void
}

extension View {
    func sudoPassword(_ request: Binding<SudoRequest?>) -> some View {
        sheet(item: request) { r in SudoPasswordSheet(request: r, close: { request.wrappedValue = nil }) }
    }
}

struct SudoPasswordSheet: View {
    @Environment(AppModel.self) private var model
    let request: SudoRequest
    let close: () -> Void
    @State private var password = ""
    @State private var remember = false
    @FocusState private var focused: Bool

    var body: some View {
        let t = model.tokens
        NavigationStack {
            Form {
                Section {
                    Text("\(request.server.user ?? "This user") needs a password for sudo on \(request.server.name). It is typed into sudo's one prompt before the command starts, over its own SSH connection, and never written into the command.\(request.canRemember ? "" : " It is not saved.")")
                        .font(.subheadline).foregroundStyle(t.secondary)
                    SecureField("Sudo password", text: $password)
                        .textContentType(.password)   // a password manager may fill it; never .newPassword
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(send)
                        .accessibilityIdentifier("sudoPassword")
                    if request.canRemember {
                        Toggle("Remember on this \(model.deviceName)", isOn: $remember)
                    }
                } footer: {
                    if request.canRemember {
                        Text("Saved in this \(model.deviceName)'s Keychain only after the server accepts it, never synced or backed up. Each use asks for \(SudoVault.biometryName).")
                    }
                }
                .listRowBackground(t.card)
                if let problem = request.problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(t.danger) }
                        .listRowBackground(t.card)
                }
                Section("Command") {
                    Text(request.command).font(.caption.monospaced()).textSelection(.enabled)
                }
                .listRowBackground(t.card)
                Section {
                    Button(role: request.destructive ? .destructive : nil, action: send) {
                        Text(request.actionLabel).frame(maxWidth: .infinity)
                    }
                    .foregroundStyle(password.isEmpty ? t.muted : (request.destructive ? t.danger : t.accent))
                    .disabled(password.isEmpty)
                    .accessibilityIdentifier("sudoSubmit")
                }
                .listRowBackground(t.card)
            }
            .themedList(t)
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) } }
            .onAppear { focused = true }
        }
    }

    private func send() {
        guard !password.isEmpty else { return }
        let typed = password
        password = ""
        // Hand the password over first: closing first would read as Cancel to a presenter that gives up on dismissal.
        request.submit(typed, remember)
        close()
    }
}
