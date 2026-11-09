import RackoonCore
import SwiftUI

struct OverviewView: View {
    let model: AppModel
    let server: Server
    let openTerminal: () -> Void
    let openScreen: (String) -> Void
    let editServer: () -> Void

    var body: some View {
        let state = model.state
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if case .needsTrust = model.phase {
                    Text("Waiting for you to confirm the host key…").foregroundStyle(Theme.textMuted)
                } else if let o = state.overview {
                    header(o, stale: state.isStale ? state.updatedAt : nil)
                    if let flow = model.reboots[server.id] {
                        RebootProgressBanner(flow: flow, name: server.name) { model.dismissReboot(server) }
                    }
                    let kind = ServerKind.detect(o.os)
                    let attention = attentionItems(state.attention, kind: kind)
                    if !attention.isEmpty {
                        AttentionStrip(items: attention, open: openScreen, action: attentionAction)
                    }
                    // While it reboots the failing polls are expected, not news.
                    if let error = state.error, model.reboots[server.id]?.isActive != true {
                        ConnectionProblem(raw: error, attempt: model.authAttempt, edit: editServer)
                    }
                    if kind == .unraid {
                        NASSections(o: o, cpu: state.cpuPercent, nas: NASStore.shared.model(for: server), polledAt: state.updatedAt)
                            .task(id: server.connectionKey) { await NASStore.shared.model(for: server).poll() }
                    } else {
                        cards(o, cpu: state.cpuPercent)
                        SystemInfoCard(o: o, polledAt: state.updatedAt)
                    }
                } else if let error = state.error {
                    // Never connected (or nothing cached): the problem is the whole page, with the way out of it.
                    Text(server.name).font(.system(size: 26, weight: .bold)).tracking(-0.4)
                    ConnectionProblem(raw: error, attempt: model.authAttempt, retry: model.refresh, retrying: model.refreshing, edit: editServer)
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Connecting to \(server.name)…") }
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, 28).padding(.top, Theme.pageTop).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Theme.textPrimary)
        .confirmAction(Binding(get: { model.pending }, set: { model.pending = $0 }))
        .sheet(isPresented: needsSudoPassword) {
            if let flow = model.reboots[server.id], case .needsPassword(let problem) = flow.phase {
                SudoPasswordSheet(request: SudoRequest(
                    title: "Reboot \(server.name) with sudo", server: server, command: RebootSession.sudoRebootCommand,
                    problem: problem, actionLabel: "Reboot", destructive: true, canRemember: SudoVault.shared.canRemember,
                    submit: { flow.submitPassword($0, remember: $1) }),
                                  close: { model.dismissReboot(server) }, closesItself: false)
            }
        }
    }

    /// The reboot sheet asking for the sudo password. Closing it any other way gives up on the reboot; a phase change
    /// (the password was sent) just takes the sheet down.
    private var needsSudoPassword: Binding<Bool> {
        Binding(
            get: { if case .needsPassword = model.reboots[server.id]?.phase { true } else { false } },
            set: { shown in
                if !shown, case .needsPassword = model.reboots[server.id]?.phase { model.dismissReboot(server) }
            })
    }

    /// On a NAS, `df`'s view of the array (one line per ZFS dataset, each "1%" full) is replaced by the array's own
    /// checks: disk status, errors, temperatures, fill and pool health.
    private func attentionItems(_ base: [AttentionItem], kind: ServerKind) -> [AttentionItem] {
        UnraidAttention.merge(base, kind: kind, snapshot: kind == .unraid ? NASStore.shared.model(for: server).snapshot : nil,
                              sustainedCPU: kind == .unraid ? NASStore.shared.model(for: server).sustainedCPU : nil)
    }

    /// A button next to a chip whose problem can be fixed from here. The reboot chip gets Reboot…, which goes through
    /// the same confirmation (and Read-only check) as the header's button.
    private func attentionAction(_ item: AttentionItem) -> AttentionAction? {
        guard Attention.offersReboot(item) else { return nil }
        let busy = model.reboots[server.id]?.isActive == true
        return AttentionAction(
            title: "Reboot…",
            help: SafetyStore.shared.readOnly ? "Read-only mode is on" : "Reboot \(server.name) and wait for it to come back",
            enabled: !SafetyStore.shared.readOnly && !busy,
            run: { model.requestReboot(server) })
    }

    private func header(_ o: Overview, stale: Date?) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(o.hostname).font(.system(size: 26, weight: .bold)).tracking(-0.4)
                    if ServerKind.detect(o.os) == .unraid {
                        Badge(text: "Unraid NAS", color: Theme.accent).offset(y: 2)
                    }
                }
                Text("\(o.os.prettyName) · up \(Format.uptime(o.uptimeSeconds)) · \(o.cores) cores")
                    .font(.system(size: 13)).foregroundStyle(Theme.textMuted)
                if let stale {
                    Text("Showing data from \(stale.formatted(.relative(presentation: .named))) · refreshing…")
                        .font(.system(size: 12)).foregroundStyle(Theme.warn)
                }
            }
            Spacer()
            Button(action: model.refresh) {
                if model.refreshing { Label { Text("Refreshing…") } icon: { ProgressView().controlSize(.small) } }
                else { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            .buttonStyle(.bordered).controlSize(.large).handCursor()
            .disabled(model.refreshing)
            Button("Reboot…") { model.requestReboot(server) }
                .buttonStyle(.bordered).controlSize(.large).handCursor()
                .disabled(SafetyStore.shared.readOnly || model.reboots[server.id]?.isActive == true)
                .help(SafetyStore.shared.readOnly ? "Read-only mode is on" : "Reboot \(server.name) and wait for it to come back")
            Button(action: openTerminal) {
                Text("Open Terminal").fontWeight(.semibold)
                    .padding(.horizontal, 16).frame(height: 34)
                    .foregroundStyle(Theme.accentText)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.pointer)
        }
    }

    private func cards(_ o: Overview, cpu: Double?) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
            StatCard(title: "CPU", trailing: "\(o.cores) cores · load \(Format.load(o.load1))",
                     value: cpu.map { Format.percent($0) } ?? "—",
                     valueTint: cpu == nil ? Theme.textMuted : nil,
                     detail: "load \(Format.load(o.load1)) · \(Format.load(o.load5)) · \(Format.load(o.load15))",
                     fraction: (cpu ?? 0) / 100)  // empty bar until the second reading, so the card keeps its height
            StatCard(title: "Memory", trailing: Format.bytes(o.memory.totalBytes),
                     value: Format.bytes(o.memory.usedBytes), unit: "used",
                     detail: "\(Format.bytes(o.memory.availableBytes)) available",
                     fraction: o.memory.usedFraction)
            ForEach(o.disks, id: \.mount) { d in
                let over = d.usePercent > Attention.diskThresholdPercent
                StatCard(title: "Disk \(d.mount)", trailing: Format.bytes(d.totalBytes),
                         value: "\(d.usePercent)%", valueTint: over ? Theme.danger : nil,
                         detail: "\(Format.bytes(d.usedBytes)) used",
                         fraction: Double(d.usePercent) / 100,
                         tint: over ? Theme.danger : Theme.accent)
            }
        }
    }
}

/// Cockpit-style identity of the server: model, hostname, OS, kernel, machine id, uptime and its own clock.
/// Uptime and the clock tick locally from the last poll, so they move every second without extra requests.
struct SystemInfoCard: View {
    let o: Overview
    let polledAt: Date?
    var cpuModel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("System information").fontWeight(.semibold)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, polledAt.map { context.date.timeIntervalSince($0) } ?? 0)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 28, alignment: .top)], alignment: .leading, spacing: 12) {
                    if !o.modelName.isEmpty { row("Model", o.modelName) }
                    row("Hostname", o.hostname)
                    if let cpuModel, !cpuModel.isEmpty { row("CPU", cpuModel) }
                    if let ip = o.ipAddress { row("IP address", ip, mono: true, copy: ip) }
                    // Only when the server has Tailscale up: nothing is shown or mentioned otherwise.
                    if let ts = o.tailscaleIP { row("Tailscale IP", ts, mono: true, copy: ts) }
                    row("Operating system", o.os.prettyName)
                    if !o.kernel.isEmpty { row("Kernel", o.kernel) }
                    if !o.machineID.isEmpty { row("Machine ID", o.machineID, mono: true) }
                    row("Uptime", Format.uptime(o.uptimeSeconds + elapsed))
                    if o.serverTime > 0 { row("Server time", serverTime(o.serverTime + Int64(elapsed))) }
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func row(_ label: String, _ value: String, mono: Bool = false, copy: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(Theme.textMuted).frame(width: 130, alignment: .leading)
            Text(value).font(mono ? .system(size: 12, design: .monospaced) : .body)
                .foregroundStyle(Theme.textPrimary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            if let copy { CopyButton(text: copy, what: label) }
            Spacer(minLength: 0)
        }
    }

    /// The server's clock in the server's own zone, so it reads like `date` there.
    private func serverTime(_ epoch: Int64) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: o.utcOffsetSeconds)
        formatter.dateFormat = "MMM d, yyyy, h:mm:ss a"
        let text = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
        return o.timeZoneName.isEmpty ? text : "\(text) \(o.timeZoneName)"
    }
}

/// Progress of a reboot started from the app: waiting, back, timed out, or failed.
struct RebootProgressBanner: View {
    let flow: RebootFlow
    let name: String
    let dismiss: () -> Void

    var body: some View {
        switch flow.phase {
        case .requesting:
            box(tone: .info, symbol: nil, title: "Asking \(name) to reboot…", detail: nil, dismissible: false)
        case .needsPassword:
            box(tone: .info, symbol: "key.fill", title: "\(name) needs a password for sudo",
                detail: "Enter it in the sheet to reboot, or dismiss this to leave the server running.", dismissible: true)
        case .waiting(let since):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                box(tone: .info, symbol: nil, title: "Rebooting \(name)…",
                    detail: "Waiting for it to come back · \(Format.duration(context.date.timeIntervalSince(since))) so far", dismissible: false)
            }
        case .back(let after):
            box(tone: .ok, symbol: "checkmark.circle.fill", title: "\(name) is back",
                detail: "It restarted and answered again after \(Format.duration(after)).", dismissible: true)
        case .timedOut:
            box(tone: .warn, symbol: "exclamationmark.triangle.fill", title: "\(name) has not come back",
                detail: "No answer after 10 minutes. Check the machine or the provider's console.", dismissible: true)
        case .failed(let message):
            box(tone: .danger, symbol: "xmark.octagon.fill", title: "Could not reboot \(name)", detail: message, dismissible: true)
        }
    }

    private func box(tone: NoticeTone, symbol: String?, title: String, detail: String?, dismissible: Bool) -> some View {
        let color = tone.tint
        return HStack(alignment: .top, spacing: 10) {
            if let symbol { Image(systemName: symbol).foregroundStyle(color) } else { ProgressView().controlSize(.small) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textMuted) }
            }
            Spacer()
            if dismissible {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 11)).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.pointer).foregroundStyle(Theme.textMuted).help("Dismiss")
            }
        }
        .noticeSurface(tone)
    }
}

struct StatCard: View {
    let title: String
    var trailing: String = ""
    var trailingTint: Color?
    let value: String
    var unit: String?
    var valueTint: Color?
    let detail: String
    var fraction: Double?
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(trailing).foregroundStyle(trailingTint ?? Theme.textMuted).fontWeight(trailingTint == nil ? .regular : .semibold)
            }
            .font(.system(size: 13)).foregroundStyle(Theme.textMuted)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(size: 30, weight: .bold)).tracking(-0.5).monospacedDigit()
                    .foregroundStyle(valueTint ?? Theme.textPrimary)
                if let unit { Text(unit).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.textMuted) }
            }
            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.border)
                        Capsule().fill(tint).frame(width: geo.size.width * min(max(fraction, 0), 1))
                    }
                }
                .frame(height: 8).padding(.top, 8)
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textMuted).padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// The connection failed: ssh's own message, what it means and what to do (`ConnectionFailure`, Core), with the way to
/// the Edit Connection sheet. With `retry` it also offers Try Again (the page with nothing else on it).
struct ConnectionProblem: View {
    let raw: String
    var attempt: SSHAttempt?
    var retry: (() -> Void)?
    var retrying = false
    let edit: () -> Void

    var body: some View {
        let failure = ConnectionFailure.explain(raw, attempt: attempt)
        VStack(alignment: .leading, spacing: 10) {
            Label(failure?.headline ?? "Not connected", systemImage: "wifi.exclamationmark")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.danger)
            Text(raw).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let advice = failure?.advice {
                Text(advice).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Edit Connection…", action: edit).buttonStyle(.borderedProminent).handCursor()
                if let retry {
                    Button(action: retry) {
                        if retrying { Label { Text("Trying…") } icon: { ProgressView().controlSize(.small) } }
                        else { Label("Try Again", systemImage: "arrow.clockwise") }
                    }
                    .buttonStyle(.bordered).handCursor().disabled(retrying)
                }
            }
            .controlSize(.large).padding(.top, 2)
        }
        .noticeSurface(.danger)
    }
}

enum Format {
    /// "3d 4h", "2h 5m", "7m": uptime at the resolution that matters. Zero trailing units are dropped ("1h", not "1h 0m").
    static func uptime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return abbreviated(s, units: s >= 86400 ? [.day, .hour] : s >= 3600 ? [.hour, .minute] : [.minute], fallback: "\(s / 60)m")
    }

    /// "45s", "1m 12s", "1h 5m": for short waits, where uptime's minute resolution would read "0m".
    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return abbreviated(s, units: s >= 3600 ? [.hour, .minute] : s >= 60 ? [.minute, .second] : [.second], fallback: "\(s)s")
    }

    private static func abbreviated(_ seconds: Int, units: NSCalendar.Unit, fallback: String) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        formatter.allowedUnits = units
        return formatter.string(from: TimeInterval(seconds)) ?? fallback
    }
    static func percent(_ v: Double) -> String { String(format: "%.0f%%", v) }
    static func load(_ v: Double) -> String { String(format: "%.2f", v) }
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .binary)
    }
    /// Drive and array sizes in decimal units ("12 TB"), as drives are sold and as Unraid shows them.
    static func storage(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .decimal)
    }
    static func celsius(_ v: Double) -> String { String(format: "%.0f °C", v) }
}

/// A small copy-to-clipboard button: the icon turns into a tick for a moment after copying.
struct CopyButton: View {
    let text: String
    /// What is being copied, for the tooltip ("Copy IP address").
    let what: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: copied ? .bold : .regular))
                .foregroundStyle(copied ? Theme.ok : Theme.textMuted)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.pointer)
        .help(copied ? "Copied" : "Copy \(what)")
        .accessibilityLabel(copied ? "Copied" : "Copy \(what)")
    }
}
