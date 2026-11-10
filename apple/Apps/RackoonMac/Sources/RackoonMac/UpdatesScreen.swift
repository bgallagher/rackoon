import RackoonCore
import SwiftUI

struct UpdatesScreen: View {
    let server: Server
    /// The terminal theme, so the live output matches the terminals.
    let theme: TerminalTheme
    /// Asks to reboot the server (the same flow as the Overview: confirmation, sudo password, waiting for it to come back).
    var reboot: () -> Void = {}
    /// The reboot confirmation, shown on this screen so the user confirms where they pressed the button.
    var rebootPending: Binding<PendingAction?> = .constant(nil)
    @State private var model: UpdatesModel
    @State private var securityOnly = false
    private let safety = SafetyStore.shared

    init(server: Server, theme: TerminalTheme, reboot: @escaping () -> Void = {},
         rebootPending: Binding<PendingAction?> = .constant(nil)) {
        self.server = server
        self.theme = theme
        self.reboot = reboot
        self.rebootPending = rebootPending
        _model = State(initialValue: UpdatesModel(server: server))
    }

    var body: some View {
        let state = model.state
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(state.snapshot)
                if let run = model.output {
                    ActionOutputPanel(run: run, theme: theme, cancel: model.cancelOutput, close: model.dismissOutput)
                        .frame(height: 340)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.border))
                }
                if let error = state.actionError { ErrorBanner(message: error) }
                if let notice = model.notice { ErrorBanner(message: notice) }
                if let error = state.error { ErrorBanner(message: error) }
                if let snapshot = state.snapshot {
                    if snapshot.rebootRequired {
                        RebootBanner(readOnly: safety.readOnly, busy: model.working != nil, reboot: reboot)
                    }
                    summary(snapshot)
                    packageList
                    if !snapshot.waiting.isEmpty { waiting(snapshot) }
                } else if state.error == nil {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading updates…") }
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, 28).padding(.top, Theme.pageTop).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmAction(rebootPending)
        .foregroundStyle(Theme.textPrimary)
        // Re-reads the update list like the reload button; Refresh Lists (apt-get update) stays a deliberate button.
        .focusedSceneValue(\.screenRefresh, { model.load() })
        .onAppear { model.load() }
        .confirmAction(Binding(get: { model.pending }, set: { model.pending = $0 }))
        .sudoPassword(Binding(get: { model.sudoRequest }, set: { model.sudoRequest = $0 }))
    }

    // MARK: header

    private func header(_ snapshot: UpdatesSnapshot?) -> some View {
        let busy = model.working != nil || safety.readOnly
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Updates").font(.system(size: 26, weight: .bold)).tracking(-0.4)
                if let snapshot {
                    Text(subtitle(snapshot)).font(.system(size: 13))
                        .foregroundStyle(snapshot.securityCount > 0 ? Theme.warn : Theme.textMuted)
                    if let stale = staleness(snapshot) {
                        Text(stale).font(.system(size: 12)).foregroundStyle(Theme.warn)
                    }
                }
            }
            Spacer()
            Button { model.load() } label: {
                if model.loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .help("Read the update list again")
            .handCursor()
            .disabled(model.loading || model.working != nil)

            Button("Refresh Lists") { model.request(.refresh) }
                .help(safety.readOnly ? "Read-only mode is on" : "Run apt-get update on the server")
                .handCursor()
                .disabled(busy)
            Button("Install All") { model.request(.upgradeAll) }
                .help(safety.readOnly ? "Read-only mode is on" : "Install every available update (apt-get upgrade --with-new-pkgs: new dependencies such as a new kernel too, never removals)")
                .handCursor()
                .disabled(busy || model.packages.isEmpty)
            Button("Install Security Updates") { model.request(.upgrade(packages: model.securityNames)) }
                .buttonStyle(.borderedProminent)
                .help(safety.readOnly ? "Read-only mode is on"
                      : model.canInstallSecurity || model.securityNames.isEmpty ? "Install only the security updates"
                      : "Too many to list one by one; use Install All")
                .handCursor()
                .disabled(busy || !model.canInstallSecurity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func subtitle(_ s: UpdatesSnapshot) -> String {
        if s.packages.isEmpty { return "Everything is up to date" }
        let n = s.packages.count
        let base = "\(n) update\(n == 1 ? "" : "s") available"
        return s.securityCount > 0 ? "\(base), \(s.securityCount) security" : base
    }

    /// Updates are read from apt's local cache, so an old cache means the list may be missing newer updates.
    private func staleness(_ s: UpdatesSnapshot) -> String? {
        guard let t = s.refreshedAt else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(t))
        let age = date.formatted(.relative(presentation: .named))
        return Date().timeIntervalSince(date) > 3 * 86_400
            ? "Package lists were refreshed \(age). Refresh them to see newer updates."
            : nil
    }

    // MARK: summary + list

    private func summary(_ s: UpdatesSnapshot) -> some View {
        HStack(spacing: 14) {
            SummaryTile(title: "Available", value: "\(s.packages.count)", tint: nil)
            SummaryTile(title: "Security", value: "\(s.securityCount)", tint: s.securityCount > 0 ? Theme.warn : Theme.ok)
            SummaryTile(title: "Waiting", value: "\(s.waiting.count)", tint: nil)
            SummaryTile(title: "Lists refreshed", value: s.refreshedAt.map {
                Date(timeIntervalSince1970: TimeInterval($0)).formatted(.relative(presentation: .named))
            } ?? "unknown", tint: nil, small: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var packageList: some View {
        let shown = securityOnly ? model.packages.filter(\.isSecurity) : model.packages
        if model.packages.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                Text("No updates are waiting. This list comes from the server's last package refresh.")
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).card()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Packages").fontWeight(.semibold)
                    Spacer()
                    Picker("Show", selection: $securityOnly) {
                        Text("All").tag(false)
                        Text("Security").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                }
                .padding(14)
                Divider().overlay(Theme.border)
                ForEach(shown) { pkg in
                    PackageRow(pkg: pkg)
                    if pkg.id != shown.last?.id { Divider().overlay(Theme.border).padding(.leading, 14) }
                }
                if shown.isEmpty {
                    Text("No security updates.").foregroundStyle(Theme.textMuted).padding(14)
                }
            }
            .card()
        }
    }

    /// Upgradable, but apt will not install them now (held, phased rollout, kept back). Listed apart so the count above
    /// reaches zero once everything apt will install is installed; each says why it waits.
    private func waiting(_ s: UpdatesSnapshot) -> some View {
        let groups: [UpdatesSnapshot.WaitingReason] = [.phased, .keptBack, .held]
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Waiting (\(s.waiting.count))").fontWeight(.semibold)
                Text("apt lists these as upgradable but will not install them yet, so they are not counted above.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            .padding(14)
            ForEach(groups, id: \.label) { reason in
                let pkgs = s.waiting.filter { s.waitingReason($0) == reason }
                if !pkgs.isEmpty {
                    Divider().overlay(Theme.border)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reason.label).font(.system(size: 13, weight: .medium))
                        Text(reason.explanation).font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
                    ForEach(pkgs) { pkg in PackageRow(pkg: pkg).opacity(0.75) }
                }
            }
        }
        .card()
    }
}

private struct SummaryTile: View {
    let title: String
    let value: String
    let tint: Color?
    var small = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.textMuted)
            Text(value).font(.system(size: small ? 16 : 26, weight: .bold).monospacedDigit())
                .foregroundStyle(tint ?? Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).card()
    }
}

private struct PackageRow: View {
    let pkg: PendingUpdate

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pkg.name).fontWeight(.medium).lineLimit(1)
                Text(pkg.suite).font(.system(size: 12)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if pkg.isSecurity { Badge(text: "Security", color: Theme.warn) }
            HStack(spacing: 6) {
                if let old = pkg.oldVersion {
                    Text(old).foregroundStyle(Theme.textMuted)
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.textMuted)
                }
                Text(pkg.newVersion).foregroundStyle(Theme.textPrimary)
            }
            .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: 320, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}

private struct RebootBanner: View {
    let readOnly: Bool
    /// An update is running: rebooting in the middle of it would break the install.
    let busy: Bool
    let reboot: () -> Void

    var body: some View {
        NoticeRow(
            icon: "arrow.triangle.2.circlepath", tint: Theme.warn,
            message: "A reboot is needed to finish applying earlier updates.",
            action: AttentionAction(
                title: "Reboot…",
                help: readOnly ? "Read-only mode is on" : busy ? "Wait for the update to finish" : "Reboot the server and wait for it to come back",
                enabled: !(readOnly || busy), run: reboot))
            .noticeSurface(.warn)
    }
}
