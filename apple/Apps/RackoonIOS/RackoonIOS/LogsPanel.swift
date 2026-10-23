import RackoonCore
import SwiftUI
import UIKit

/// The stack's logs: every container followed at once and merged (one `docker logs -f` each, stopped with Ctrl-C when this
/// panel goes away), filtered by container, level and text. It follows new lines until the list is dragged; "Latest" goes
/// back to the end and follows again. The filters are Core's `LogView`.
struct LogsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let docker: DockerModel
    let stack: DockerStack
    @Binding var focus: String?
    @State private var level: LogLevel?
    @State private var search = ""
    @State private var following = true
    /// `logs.received` when following stopped, for "N new".
    @State private var seenAt = 0

    var body: some View {
        let t = model.tokens
        let logs = docker.logs
        let several = Set(stack.containers.map(\.logSource)).count > 1
        let shown = LogView.filtered(logs.entries, focus: focus, level: level, search: search)
        let counts = LogView.counts(logs.entries, focus: focus)
        VStack(spacing: 6) {
            if several {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip("All", selected: focus == nil) { focus = nil }
                        ForEach(Array(Set(stack.containers.map(\.logSource))).sorted(), id: \.self) { source in
                            chip(source, dot: sourceColor(source), selected: focus == source) { focus = focus == source ? nil : source }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            HStack(spacing: 6) {
                chip("All \(counts[nil] ?? 0)", selected: level == nil) { level = nil }
                chip("Error \(counts[.error] ?? 0)", dot: t.danger, selected: level == .error) { level = level == .error ? nil : .error }
                chip("Warn \(counts[.warn] ?? 0)", dot: t.warn, selected: level == .warn) { level = level == .warn ? nil : .warn }
                chip("Info \(counts[.info] ?? 0)", selected: level == .info) { level = level == .info ? nil : .info }
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = LogView.text(shown, showSource: several && focus == nil)
                } label: { Image(systemName: "doc.on.doc") }
                .accessibilityLabel("Copy visible lines")
            }
            .padding(.horizontal, 16)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(t.muted)
                TextField("Filter lines", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(t.muted) } }
                Text(logs.live ? (following ? "Following" : "Paused") : "Ended")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((logs.live && following ? t.ok : t.idle).opacity(0.18), in: Capsule())
                    .foregroundStyle(logs.live && following ? t.ok : t.secondary)
            }
            .padding(8)
            .background(t.card, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            if let error = logs.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(t.warn)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { entry in
                            LogRow(entry: entry, showSource: several && focus == nil, sourceColor: sourceColor(entry.source))
                                .id(entry.id)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 12)
                }
                .background(Color(model.appearance.resolvedTheme.backgroundRGB))
                .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in
                    if following { following = false; seenAt = logs.received }
                })
                .overlay(alignment: .bottomTrailing) {
                    if !following {
                        let fresh = logs.received - seenAt
                        Button {
                            following = true
                            proxy.scrollTo("end", anchor: .bottom)
                        } label: {
                            Label(fresh > 0 ? "Latest · \(fresh) new" : "Latest", systemImage: "arrow.down")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(t.accent, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .padding(12)
                    }
                }
                .onChange(of: logs.received) { _, _ in
                    if following { proxy.scrollTo("end", anchor: .bottom) }
                }
                .overlay {
                    if logs.entries.isEmpty {
                        Text(logs.live ? "Waiting for log lines…" : "No log lines.").font(.footnote).foregroundStyle(t.muted)
                    }
                }
            }
        }
        .onAppear { docker.followLogs(stack.containers) }
        .onChange(of: stack.containers.map(\.id)) { _, _ in docker.followLogs(stack.containers) }
        .onDisappear { docker.stopLogs() }
        .onChange(of: scenePhase) { _, phase in
            // Following runs only in the foreground; nothing is left running on the server while the app is away.
            if phase == .background { docker.stopLogs() } else if phase == .active { docker.followLogs(stack.containers) }
        }
    }

    private func chip(_ title: String, dot: Color? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        let t = model.tokens
        return Button(action: action) {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(title).font(.caption.weight(selected ? .semibold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(selected ? t.accent.opacity(0.2) : t.card, in: Capsule())
            .foregroundStyle(selected ? t.accent : t.text)
        }
        .buttonStyle(.plain)
    }

    /// A colour per container, from the theme's ANSI palette, so lines from one container are easy to follow.
    private func sourceColor(_ source: String) -> Color {
        let ansi = model.appearance.resolvedTheme.ansiRGB
        let picks = [2, 3, 4, 5, 6, 10, 11, 12, 13, 14].filter { $0 < ansi.count }
        guard !picks.isEmpty else { return model.tokens.accent }
        return Color(ansi[picks[LetterTile.slot(source, count: picks.count)]])
    }
}

private struct LogRow: View {
    @Environment(AppModel.self) private var model
    let entry: LogEntry
    let showSource: Bool
    let sourceColor: Color

    var body: some View {
        let t = model.tokens
        let theme = model.appearance.resolvedTheme
        let parts = entry.parts
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if let time = parts.time { Text(time).foregroundStyle(Color(theme.foregroundRGB).opacity(0.5)) }
                if showSource { Text(entry.source).foregroundStyle(sourceColor) }
                if let level = parts.level {
                    Text(level.rawValue.uppercased())
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(level == .error ? t.danger : level == .warn ? t.warn : t.muted)
                }
            }
            .font(.caption2.monospaced())
            Text(parts.message.isEmpty ? " " : parts.message)
                .font(.caption.monospaced())
                .foregroundStyle(parts.level == .error ? t.danger : Color(theme.foregroundRGB))
                .textSelection(.enabled)
                .lineLimit(6)
        }
        .padding(.vertical, 2)
    }
}
