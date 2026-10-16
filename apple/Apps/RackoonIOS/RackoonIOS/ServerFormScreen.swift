import RackoonCore
import SwiftUI

/// Add or edit a server. The fields are checked like the Mac's forms (`ServerInput`), and Save stays off until they pass.
struct ServerFormScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let editing: Server?
    @State private var draft = ServersModel.Draft()
    @State private var loaded = false

    var body: some View {
        let t = model.tokens
        let problem = draft.problem
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
                    if let problem, !draft.host.isEmpty { Text(problem).foregroundStyle(t.danger) }
                }
                .listRowBackground(t.card)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            .themedList(t)
            .navigationTitle(editing == nil ? "Add Server" : "Edit \(editing!.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let failure = editing.map { model.update(id: $0.id, with: draft) } ?? model.servers.add(draft)
                        if failure == nil { dismiss() }
                    }
                    .disabled(problem != nil)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let editing { draft = ServersModel.Draft(editing) }
            }
        }
    }
}
