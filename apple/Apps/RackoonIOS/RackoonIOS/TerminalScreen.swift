import RackoonCore
import SwiftTerm
import SwiftUI
import UIKit

/// A server's terminal tabs: a strip of tabs with + to open another, the selected tab's terminal, and a banner while it
/// reconnects or after it ended. Tabs keep running when this screen is left.
struct TerminalScreen: View {
    @Environment(AppModel.self) private var model
    let serverID: String
    @State private var refusal: String?

    var body: some View {
        let t = model.tokens
        let store = model.terminals
        let tabs = store.tabs(for: serverID)
        VStack(spacing: 0) {
            if let server = model.servers.server(id: serverID) {
                TabStrip(serverID: serverID, tabs: tabs, add: { refusal = model.openTerminal(on: server) })
                if let refusal {
                    Label(refusal, systemImage: "lock.fill").font(.footnote).foregroundStyle(t.warn)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let tab = store.selectedTab(for: serverID) {
                    ZStack(alignment: .bottom) {
                        TerminalHost(tab: tab, theme: model.appearance.resolvedTheme)
                            .id(tab.id)
                        StatusBanner(tab: tab)
                    }
                } else {
                    ContentUnavailableView {
                        Label("No terminal open", systemImage: "terminal")
                    } description: {
                        Text("Open a shell on \(server.name).")
                    } actions: {
                        Button("Open Terminal") { refusal = model.openTerminal(on: server) }
                            .buttonStyle(.borderedProminent)
                    }
                    .background(t.background)
                }
            }
        }
        .background(Color(model.appearance.resolvedTheme.backgroundRGB))
        .navigationTitle(model.servers.server(id: serverID)?.name ?? "Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)   // the terminal and the keyboard need the room
        .onAppear {
            // Opening the screen with no tab opens one, like the Mac's Terminal screen.
            if tabs.isEmpty, let server = model.servers.server(id: serverID) { refusal = model.openTerminal(on: server) }
        }
    }
}

private struct TabStrip: View {
    @Environment(AppModel.self) private var model
    let serverID: String
    let tabs: [TerminalTab]
    let add: () -> Void

    var body: some View {
        let t = model.tokens
        let store = model.terminals
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        let selected = store.selectedTab(for: serverID)?.id == tab.id
                        HStack(spacing: 6) {
                            Circle().fill(tab.isLive ? t.ok : t.idle).frame(width: 7, height: 7)
                            Text(tab.title).font(.footnote.weight(selected ? .semibold : .regular))
                            Button { store.close(tab) } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                                .accessibilityLabel("Close \(tab.title)")
                        }
                        .foregroundStyle(selected ? t.text : t.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(selected ? t.card : .clear))
                        .contentShape(Capsule())
                        .onTapGesture { store.selected[serverID] = tab.id }
                    }
                }
            }
            Button(action: add) { Image(systemName: "plus") }
                .accessibilityLabel("New terminal tab")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(t.background)
    }
}

/// Reconnecting with a countdown, or ended, with what can be done about it.
private struct StatusBanner: View {
    @Environment(AppModel.self) private var model
    let tab: TerminalTab

    var body: some View {
        let t = model.tokens
        switch tab.phase {
        case .reconnecting(let attempt, let of, let at):
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Reconnecting in \(max(0, Int(at.timeIntervalSince(context.date).rounded(.up)))) s (attempt \(attempt) of \(of))")
                        .font(.footnote.monospacedDigit())
                }
                Spacer()
                Button("Now") { tab.reconnectNow() }
                Button("Cancel") { tab.cancelReconnect() }
            }
            .banner(t)
        case .ended(let reason):
            HStack {
                Text(reason).font(.footnote)
                Spacer()
                Button("Reconnect") { tab.reconnectNow() }
                Button("Close") { model.terminals.close(tab) }
            }
            .banner(t)
        case .connecting:
            HStack { ProgressView(); Text("Connecting…").font(.footnote) }.banner(t)
        case .waitingForSize, .live:
            EmptyView()
        }
    }
}

private extension View {
    func banner(_ t: Tokens) -> some View {
        padding(10)
            .foregroundStyle(t.text)
            .background(RoundedRectangle(cornerRadius: 12).fill(t.card).shadow(radius: 4))
            .padding(10)
    }
}

/// The tab's SwiftTerm view. The view is created once per tab and kept by the tab's `TerminalViewBox`, so scrollback
/// survives leaving the screen.
private struct TerminalHost: UIViewRepresentable {
    let tab: TerminalTab
    let theme: TerminalTheme

    func makeUIView(context: Context) -> TerminalView {
        let box = TerminalViewBox.box(for: tab)
        box.view.applyRackoonTheme(theme)
        return box.view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        view.applyRackoonTheme(theme)
    }
}

/// Owns one tab's `TerminalView` and turns its delegate calls into the tab's size and keystrokes.
@MainActor
final class TerminalViewBox: NSObject, TerminalViewDelegate, TerminalDisplay {
    private static var boxes: [UUID: TerminalViewBox] = [:]

    static func box(for tab: TerminalTab) -> TerminalViewBox {
        if let box = boxes[tab.id] { return box }
        let box = TerminalViewBox(tab: tab)
        boxes[tab.id] = box
        // Drop boxes of tabs that were closed.
        boxes = boxes.filter { $0.value.tab != nil }
        return box
    }

    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
    private weak var tab: TerminalTab?

    private init(tab: TerminalTab) {
        self.tab = tab
        super.init()
        view.terminalDelegate = self
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tab.display = self
    }

    func feed(_ bytes: ArraySlice<UInt8>) { view.feed(byteArray: bytes) }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { tab?.setSize(cols: newCols, rows: newRows) }
    }

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        MainActor.assumeIsolated { tab?.send(bytes) }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        MainActor.assumeIsolated { UIApplication.shared.open(url) }
    }
    nonisolated func bell(source: TerminalView) {}
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        MainActor.assumeIsolated { UIPasteboard.general.string = text }
    }
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

extension TerminalView {
    /// The active theme's terminal colours, as on the Mac (`applyRackoonTheme` there). Highlighting uses the ANSI colours,
    /// so it follows the theme too.
    func applyRackoonTheme(_ theme: TerminalTheme) {
        installColors(theme.ansiRGB.map { SwiftTerm.Color(red: UInt16($0.r) * 257, green: UInt16($0.g) * 257, blue: UInt16($0.b) * 257) })
        nativeBackgroundColor = UIColor(theme.backgroundRGB)
        nativeForegroundColor = UIColor(theme.foregroundRGB)
        caretColor = UIColor(theme.cursorRGB)
        selectedTextBackgroundColor = theme.selection == nil ? UIColor(theme.foregroundRGB).withAlphaComponent(0.3) : UIColor(theme.selectionRGB)
    }
}

extension UIColor {
    convenience init(_ rgb: RGB) {
        self.init(red: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}
