import RackoonCore
import RackoonSSHEmbedded
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Add or edit a server: the address (checked like the Mac's forms, `ServerInput`) and how to sign in. Save stays off
/// until both are complete; a key is read (and its passphrase checked) before anything is saved.
struct ServerFormScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let editing: Server?
    @State private var draft = ServersModel.Draft()
    @State private var signIn = SignInDraft()
    @State private var loaded = false
    @State private var failure: String?

    var body: some View {
        let t = model.tokens
        let problem = draft.problem ?? (model.isDemo ? nil : signIn.problem)
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $draft.name)
                    TextField("Host or IP", text: $draft.host)
                        .textContentType(.URL)
                        .accessibilityIdentifier("hostField")
                    TextField("User (root if empty)", text: $draft.user)
                        .textContentType(.username)
                    TextField("Port (22 if empty)", text: $draft.port)
                        .keyboardType(.numberPad)
                } footer: {
                    if let problem = draft.problem, !draft.host.isEmpty { Text(problem).foregroundStyle(t.danger) }
                }
                .listRowBackground(t.card)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                if !model.isDemo {
                    SignInSection(draft: $signIn)
                }
                if let failure {
                    Section { Text(failure).foregroundStyle(t.danger) }.listRowBackground(t.card)
                }
            }
            .themedList(t)
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle(editing == nil ? "Add Server" : "Edit \(editing!.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(problem != nil)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let editing {
                    draft = ServersModel.Draft(editing)
                    signIn = SignInDraft(saved: model.signIn.method(for: editing.id), hasSecret: model.signIn.hasSecret(for: editing.id))
                }
            }
        }
    }

    private func save() {
        let choice = model.isDemo ? .keep : signIn.choice
        // Check the key before the server is saved, so a wrong passphrase never leaves a half-made server behind.
        if case .key(let text, let passphrase) = choice {
            do { _ = try SSHKeys.load(text, passphrase: passphrase) } catch {
                failure = error.localizedDescription
                return
            }
        }
        let id = editing?.id ?? UUID().uuidString
        let problem = editing == nil ? model.servers.add(draft, id: id) : model.update(id: id, with: draft)
        if let problem {
            failure = problem
            return
        }
        do {
            try model.setSignIn(choice, for: id)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// What the Sign-in section typed. A saved key or password is kept unless a new one is entered.
struct SignInDraft: Equatable {
    var method: SignInMethod = .tailscale
    var keyText = ""
    var passphrase = ""
    var password = ""
    var saved: SignInMethod?
    var hasSecret = false

    init() {}

    init(saved: SignInMethod, hasSecret: Bool) {
        method = saved
        self.saved = saved
        self.hasSecret = hasSecret
    }

    private var keepsSavedSecret: Bool { saved == method && hasSecret }

    var problem: String? {
        switch method {
        case .tailscale: nil
        case .key: keyText.isEmpty && !keepsSavedSecret ? "Choose the private key to sign in with." : nil
        case .password: password.isEmpty && !keepsSavedSecret ? "Enter the password." : nil
        }
    }

    var choice: AppModel.SignInChoice {
        switch method {
        case .tailscale: return saved == .tailscale ? .keep : .tailscale
        case .key: return keyText.isEmpty ? .keep : .key(keyText, passphrase: passphrase.isEmpty ? nil : passphrase)
        case .password: return password.isEmpty ? .keep : .password(password)
        }
    }
}

private struct SignInSection: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: SignInDraft
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        let t = model.tokens
        Section {
            Picker("Sign in with", selection: $draft.method) {
                ForEach(SignInMethod.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("signInMethod")
            switch draft.method {
            case .tailscale:
                EmptyView()
            case .key:
                if !draft.keyText.isEmpty {
                    Label(keySummary, systemImage: "key.fill").foregroundStyle(t.ok)
                } else if draft.saved == .key, draft.hasSecret {
                    Label("A key is saved on this \(model.deviceName).", systemImage: "key.fill").foregroundStyle(t.secondary)
                }
                // PasteButton, not UIPasteboard: the user's tap is the consent, so iOS shows no "Allow Paste" prompt.
                PasteButton(payloadType: String.self) { strings in
                    draft.keyText = strings.first ?? ""
                    importError = draft.keyText.isEmpty ? "The clipboard has no text." : nil
                }
                .accessibilityIdentifier("pasteKey")
                Button("Choose Key File…") { importing = true }
                SecureField("Passphrase (if the key has one)", text: $draft.passphrase)
                    .textContentType(.password)
            case .password:
                SecureField(draft.saved == .password && draft.hasSecret ? "Saved (type to replace)" : "Password", text: $draft.password)
                    .textContentType(.password)
            }
            if let importError { Text(importError).foregroundStyle(t.danger) }
        } header: {
            Text("Sign-in")
        } footer: {
            Text(footer)
        }
        .listRowBackground(t.card)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .text, .plainText]) { result in
            switch result {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                // A private key file is a few KB; refuse anything big rather than read it.
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 64 * 1024 {
                    importError = "That file is too big to be a private key."
                } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                    draft.keyText = text
                    importError = nil
                } else {
                    importError = "That file could not be read as text."
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }

    private var keySummary: String {
        let text = draft.keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("-----BEGIN"), text.contains("PRIVATE KEY") else { return "Not a private key (checked on Save)" }
        return "Key ready (checked on Save)"
    }

    private var footer: String {
        switch draft.method {
        case .tailscale: "For servers with Tailscale SSH: the tailnet identifies this \(model.deviceName), so nothing is stored."
        case .key: "Ed25519 keys in OpenSSH format. The key and its passphrase are kept in this \(model.deviceName)'s Keychain only, never synced or backed up."
        case .password: "Kept in this \(model.deviceName)'s Keychain only. Many servers turn password login off; a key is better."
        }
    }
}
