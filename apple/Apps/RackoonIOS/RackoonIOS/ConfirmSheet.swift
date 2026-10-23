import RackoonCore
import SwiftUI

extension View {
    /// Shows the confirmation sheet for `pending`: what will happen, on which server, and the exact command (plus a diff when
    /// there is one). Nothing runs until Run Command is tapped. A destructive one is red, and Return on a hardware keyboard
    /// does not press it.
    func confirmAction(_ pending: Binding<PendingAction?>) -> some View {
        sheet(item: pending) { action in ConfirmSheet(action: action, close: { pending.wrappedValue = nil }) }
    }
}

struct ConfirmSheet: View {
    @Environment(AppModel.self) private var model
    let action: PendingAction
    let close: () -> Void
    @State private var showFull = false

    var body: some View {
        let t = model.tokens
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(action.message).foregroundStyle(t.text)
                    Label("On \(action.serverName)", systemImage: "server.rack").font(.subheadline).foregroundStyle(t.secondary)
                    if let preview = action.preview, !preview.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Changes").font(.footnote.weight(.semibold)).foregroundStyle(t.secondary)
                            DiffText(text: preview)
                        }
                    }
                    if !action.command.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Command").font(.footnote.weight(.semibold)).foregroundStyle(t.secondary)
                            let long = action.command.count > 400
                            Text(long && !showFull ? String(action.command.prefix(400)) + "…" : action.command)
                                .font(.caption.monospaced())
                                .foregroundStyle(t.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(t.card, in: RoundedRectangle(cornerRadius: 10))
                                .accessibilityIdentifier("confirmCommand")
                            if long {
                                Button(showFull ? "Show less" : "Show full command") { showFull.toggle() }.font(.footnote)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(t.background)
            .navigationTitle(action.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close).keyboardShortcut(.cancelAction) }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Text(action.title).font(.headline).multilineTextAlignment(.center).foregroundStyle(t.text)
                    runButton
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var runButton: some View {
        let button = Button(role: action.destructive ? .destructive : nil) {
            close()
            action.run()
        } label: {
            Text(action.confirmLabel).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(action.destructive ? .red : nil)
        .controlSize(.large)
        .accessibilityIdentifier("confirmRun")
        if action.destructive { button } else { button.keyboardShortcut(.defaultAction) }
    }
}

/// A unified diff (from `LineDiff.preview`), added lines green and removed lines red.
struct DiffText: View {
    @Environment(AppModel.self) private var model
    let text: String

    var body: some View {
        let t = model.tokens
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.caption.monospaced())
                        .foregroundStyle(line.hasPrefix("+") ? t.ok : line.hasPrefix("-") ? t.danger : t.text)
                        .fixedSize()
                }
            }
            .padding(10)
        }
        .background(t.card, in: RoundedRectangle(cornerRadius: 10))
        .textSelection(.enabled)
    }
}
