import RackoonCore
import SwiftTerm
import SwiftUI
import UIKit

/// The live output of an action: a read-only terminal (so compose's redrawing progress looks as it does in a shell), with
/// Cancel while it runs (Ctrl-C reaches the command on the server) and Close once it has finished.
struct OutputPanel: View {
    @Environment(AppModel.self) private var model
    let output: ActionOutput
    let cancel: () -> Void
    let close: () -> Void

    var body: some View {
        let t = model.tokens
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                phaseIcon
                VStack(alignment: .leading, spacing: 1) {
                    Text(output.title).font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle)
                    Text(phaseText).font(.caption).foregroundStyle(phaseColor(t))
                }
                Spacer()
                if output.isRunning {
                    Button("Cancel", role: .destructive, action: cancel).buttonStyle(.bordered).accessibilityIdentifier("outputCancel")
                } else {
                    Button("Close", action: close).buttonStyle(.bordered).accessibilityIdentifier("outputClose")
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
            OutputTerminal(output: output, count: output.chunks.count, theme: model.appearance.resolvedTheme)
                .padding(.horizontal, 8)
                .background(SwiftUI.Color(model.appearance.resolvedTheme.backgroundRGB))
                .accessibilityIdentifier("outputTerminal")
        }
    }

    @ViewBuilder private var phaseIcon: some View {
        switch output.phase {
        case .starting, .running: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(model.tokens.ok)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(model.tokens.danger)
        case .cancelled: Image(systemName: "stop.circle.fill").foregroundStyle(model.tokens.warn)
        }
    }

    private var phaseText: String {
        switch output.phase {
        case .starting: "Starting…"
        case .running: "Running"
        case .succeeded: "Finished"
        case .failed(let code): code.map { "Failed (exit \($0))" } ?? "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private func phaseColor(_ t: Tokens) -> SwiftUI.Color {
        switch output.phase {
        case .starting, .running: t.secondary
        case .succeeded: t.ok
        case .failed: t.danger
        case .cancelled: t.warn
        }
    }
}

/// A SwiftTerm view that only shows: it never takes the keyboard, and what is typed goes nowhere.
final class ReadOnlyTerminalView: TerminalView {
    override var canBecomeFirstResponder: Bool { false }
}

/// Feeds an action's chunks into a read-only terminal, each chunk once, and reports the terminal's size to the run so the
/// remote pty matches it.
private struct OutputTerminal: UIViewRepresentable {
    let output: ActionOutput
    /// How many chunks there are; passed in so a new chunk updates the view.
    let count: Int
    let theme: TerminalTheme

    func makeCoordinator() -> Coordinator { Coordinator(output: output) }

    func makeUIView(context: Context) -> ReadOnlyTerminalView {
        let view = ReadOnlyTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        view.terminalDelegate = context.coordinator
        view.applyRackoonTheme(theme)
        context.coordinator.feed(view)
        return view
    }

    func updateUIView(_ view: ReadOnlyTerminalView, context: Context) {
        view.applyRackoonTheme(theme)
        context.coordinator.feed(view)
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let output: ActionOutput
        private var fed = 0

        init(output: ActionOutput) { self.output = output }

        func feed(_ view: TerminalView) {
            let chunks = output.chunks
            guard fed < chunks.count else { return }
            for chunk in chunks[fed...] { view.feed(text: chunk) }
            fed = chunks.count
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { output.reportSize(cols: newCols, rows: newRows) }
        }

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        nonisolated func bell(source: TerminalView) {}
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else { return }
            MainActor.assumeIsolated { UIPasteboard.general.string = text }
        }
        nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
