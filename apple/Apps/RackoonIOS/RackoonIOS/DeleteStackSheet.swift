import RackoonCore
import SwiftUI

/// Deleting a stack or a standalone container, as on the Mac: what is removed, the opt-in extras that lose data, the exact
/// command, and a typed name whenever data would be lost (always for a standalone container), so a stray tap can't wipe data.
struct DeleteStackSheet: View {
    @Environment(AppModel.self) private var model
    let docker: DockerModel
    let stack: DockerStack
    let close: () -> Void
    @State private var removeVolumes = false
    /// On by default, so a deleted stack leaves nothing behind; off when the folder can't safely be deleted.
    @State private var deleteFolder: Bool
    @State private var typed = ""

    init(docker: DockerModel, stack: DockerStack, close: @escaping () -> Void) {
        self.docker = docker
        self.stack = stack
        self.close = close
        _deleteFolder = State(initialValue: !stack.isStandalone && StackRemoval.folderProblem(for: stack) == nil)
    }

    private var removal: StackRemoval { StackRemoval(removeVolumes: removeVolumes, deleteFolder: deleteFolder) }
    private var command: String {
        stack.isStandalone ? (StandaloneAction.remove(volumes: removeVolumes).command(for: stack) ?? "") : (removal.command(for: stack) ?? "")
    }
    /// A standalone container always needs the name: nothing on the server can create it again.
    private var needsName: Bool { stack.isStandalone || removal.losesData }
    private var confirmed: Bool { !needsName || typed == stack.name }
    private var canRun: Bool { confirmed && !command.isEmpty && docker.working == nil && !model.safety.readOnly }

    var body: some View {
        let t = model.tokens
        let n = stack.containers.count
        NavigationStack {
            Form {
                Section {
                    Text(stack.isStandalone
                         ? "Stops and removes the container \(stack.name). Its image is kept. It was started with docker run, so nothing here can create it again."
                         : n == 0
                         ? "Removes the stack's networks. It has no containers right now. Images are kept. Its folder is deleted too unless you turn that off below."
                         : "Stops and removes its \(n) container\(n == 1 ? "" : "s") and the networks Compose made for it. Images are kept. Its folder is deleted too unless you turn that off below.")
                        .foregroundStyle(t.secondary)
                }
                .listRowBackground(t.card)
                Section {
                    Toggle(isOn: $removeVolumes) {
                        option(stack.isStandalone ? "Also delete its anonymous volumes" : "Also delete its named volumes",
                               "Data kept in Docker volumes is lost for good.")
                    }
                    if !stack.isStandalone {
                        Toggle(isOn: $deleteFolder) {
                            option("Also delete its folder on \(docker.serverName)",
                                   StackRemoval.folderProblem(for: stack)
                                       ?? "\(stack.workingDir ?? "") and everything in it: compose.yaml, .env and bind-mounted data such as ./data.")
                        }
                        .disabled(StackRemoval.folderProblem(for: stack) != nil)
                    }
                }
                .listRowBackground(t.card)
                Section("Runs on \(docker.serverName)") {
                    Text(command).font(.caption.monospaced()).textSelection(.enabled)
                }
                .listRowBackground(t.card)
                if needsName {
                    Section("Type \(stack.name) to confirm") {
                        TextField(stack.name, text: $typed)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("deleteTypedName")
                    }
                    .listRowBackground(t.card)
                }
                Section {
                    Button(role: .destructive) {
                        close()
                        if stack.isStandalone { docker.delete(stack, volumes: removeVolumes) } else { docker.delete(stack, removal) }
                    } label: {
                        Text(stack.isStandalone ? "Delete Container" : "Delete Stack").frame(maxWidth: .infinity)
                    }
                    .foregroundStyle(canRun ? t.danger : t.muted)
                    .disabled(!canRun)
                    .accessibilityIdentifier("deleteRun")
                }
                .listRowBackground(t.card)
            }
            .themedList(t)
            .navigationTitle("Delete \(stack.name)?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) } }
        }
    }

    private func option(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(model.tokens.secondary)
        }
    }
}
