import RackoonCore
import SwiftUI

/// The Security screen (docs/security-plan.md, S1). It answers one question first ("is there anything I should fix?") and
/// says everything once: a verdict with the disclaimer beside it, then only the findings that need the user, what other
/// machines can reach, what is merely worth knowing, what could not be read, and the passed checks folded away.
/// Advice only: nothing here changes the server.
struct SecurityScreen: View {
    let server: Server
    /// The Overview's last reading, for the update and reboot checks (no second apt run).
    let overview: Overview?
    var openScreen: (Screen) -> Void = { _ in }

    @State private var model: SecurityModel
    @State private var expanded: Set<String> = []
    @State private var showingPassed = false
    @State private var showingLocalPorts = false
    @State private var showingAbout = false

    init(server: Server, overview: Overview?, openScreen: @escaping (Screen) -> Void = { _ in }) {
        self.server = server
        self.overview = overview
        self.openScreen = openScreen
        _model = State(initialValue: SecurityStore.shared.model(for: server))
    }

    static let disclaimer = "These checks look for a small set of common hardening problems. They are not a complete security review and can be wrong: a setting may be overridden somewhere Rackoon does not read, and new issues appear every day. Treat a clean result as \"nothing obvious found\", not \"secure\"."

    /// Findings the ports list already says (a port on every interface, a database reachable, Docker past ufw): shown there,
    /// not twice.
    private static let shownAsPorts: Set<String> = ["exposure.listening", "exposure.sensitive_port", "exposure.docker_bypass"]

    var body: some View {
        let findings = model.findings(SecurityModel.context(overview)).filter { !Self.shownAsPorts.contains($0.check) }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let error = model.error { ErrorBanner(message: error) }
                if let snapshot = model.snapshot {
                    let ports = SecurityExposure.ports(snapshot, ufwOn: SecurityRules.ufwOn(snapshot))
                    let toFix = sorted(findings.filter { $0.severity == .critical || $0.severity == .warning })
                    // Docker's API port is already a finding ("no TLS"); every other flagged open port counts once, here.
                    let exposedFlagged = ports.filter { $0.isExposed && !$0.flags.filter { $0 != "no TLS" }.isEmpty }.count
                    verdict(toFix: toFix.count, ports: exposedFlagged, critical: toFix.contains { $0.severity == .critical })
                    if !toFix.isEmpty { section("To fix", count: toFix.count) { rows(toFix) } }
                    reachable(ports)
                    VulnerabilitySection(server: server, model: model, openUpdates: { openScreen(.updates) })
                    let info = sorted(findings.filter { $0.severity == .info })
                    if !info.isEmpty { section("Worth knowing", count: info.count) { rows(info) } }
                    let unknown = sorted(findings.filter { $0.severity == .unknown })
                    if !unknown.isEmpty {
                        section("Could not check", count: unknown.count,
                                note: "Rackoon reads as \(snapshot.isRoot ? "root" : "\(server.user ?? "the ssh user"), without sudo"); these need more access, so they are not counted as passed.") {
                            rows(unknown)
                        }
                    }
                    passed(sorted(findings.filter { $0.severity == .pass }))
                } else if model.error == nil {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking…") }
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, 28).padding(.top, Theme.pageTop).padding(.bottom, 24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Theme.textPrimary)
        .focusedSceneValue(\.screenRefresh, { checkNow() })
        .onAppear {
            model.load()
            if lookupOn, model.vulnerabilities == nil || model.vulnerabilitiesCheckedAt.map({ Date().timeIntervalSince($0) > SecurityModel.freshFor }) == true {
                Task { await model.lookUpVulnerabilities() }
            }
        }
    }


    private var lookupOn: Bool { VulnerabilityLookupSettings.shared.isOn(server.id) }

    /// Reads the settings again and, when the user turned it on, looks up vulnerabilities again.
    private func checkNow() {
        model.load(force: true)
        if lookupOn { Task { await model.lookUpVulnerabilities() } }
    }

    /// Worst first, then the checklist's own order.
    private func sorted(_ findings: [SecurityFinding]) -> [SecurityFinding] {
        func order(_ f: SecurityFinding) -> Int { SecurityChecks.all.firstIndex { $0.id == f.check } ?? .max }
        return findings.sorted { ($0.severity, order($0), $0.id) < ($1.severity, order($1), $1.id) }
    }

    // MARK: header and verdict

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Security").font(.system(size: 26, weight: .bold)).tracking(-0.4)
                Text(model.checkedAt.map { "Checked \($0.formatted(.relative(presentation: .named)))\(model.deep ? " with sudo" : "")" } ?? "Not checked yet")
                    .font(.system(size: 13)).foregroundStyle(Theme.textMuted)
            }
            Spacer()
            if model.snapshot?.isRoot == false {
                DeepCheckButton(server: server, model: model)
            }
            Button {
                checkNow()
            } label: {
                if model.loading { ProgressView().controlSize(.small).frame(width: 74) } else { Text("Check Now") }
            }
            .buttonStyle(.bordered).controlSize(.large)
            .help("Read the settings again (read-only)")
            .handCursor()
            .disabled(model.loading)
        }
    }

    /// One line that says where things stand, with the disclaimer right under it: a clean result must never read as "secure".
    private func verdict(toFix: Int, ports: Int, critical: Bool) -> some View {
        let tone: NoticeTone = toFix + ports == 0 ? .ok : critical ? .danger : .warn
        let parts = [toFix > 0 ? "\(toFix) thing\(toFix == 1 ? "" : "s") to fix" : nil,
                     ports > 0 ? "\(ports) open port\(ports == 1 ? "" : "s") to look at" : nil].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: parts.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 18)).foregroundStyle(tone.tint)
                Text(parts.isEmpty ? "Nothing obvious to fix" : parts.joined(separator: ", "))
                    .font(.system(size: 15, weight: .semibold))
            }
            HStack(spacing: 6) {
                Text("A short list of common checks, not a complete security review, and it can be wrong.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Button("About these checks") { showingAbout = true }
                    .buttonStyle(.pointer).font(.system(size: 12)).foregroundStyle(Theme.accent)
                    .popover(isPresented: $showingAbout, arrowEdge: .bottom) {
                        Text(Self.disclaimer).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                            .frame(width: 360).padding(16)
                    }
            }
            .padding(.leading, 28)
        }
        .noticeSurface(tone)
    }

    // MARK: sections

    private func section<Content: View>(_ title: String, count: Int, note: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: title, count: count, note: note)
            VStack(alignment: .leading, spacing: 0) { content() }.card()
        }
    }

    @ViewBuilder private func rows(_ findings: [SecurityFinding]) -> some View {
        ForEach(Array(findings.enumerated()), id: \.element.id) { index, finding in
            if index > 0 { Divider().overlay(Theme.border) }
            FindingRow(finding: finding, check: SecurityChecks.check(finding.check),
                       expanded: Binding(get: { expanded.contains(finding.id) },
                                         set: { if $0 { expanded.insert(finding.id) } else { expanded.remove(finding.id) } }),
                       link: link(for: finding))
        }
    }

    /// The screen that helps with a finding, when Rackoon has one.
    private func link(for f: SecurityFinding) -> (title: String, run: () -> Void)? {
        switch f.check {
        case "updates.security_pending": ("Updates", { openScreen(.updates) })
        case "updates.reboot": ("Overview", { openScreen(.overview) })
        case "docker.unchecked", "docker.container": ("Docker", { openScreen(.docker) })
        default: nil
        }
    }

    /// What other machines can reach: only ports on every interface or a public address, each once, with what it is and
    /// why it is worth a look. Ports only this server, the LAN or the tailnet can reach are one line, opened on demand.
    @ViewBuilder private func reachable(_ ports: [ExposedPort]) -> some View {
        let open = ports.filter(\.isExposed)
        let local = ports.filter { !$0.isExposed }
        if !ports.isEmpty {
            section("Reachable from other networks", count: open.count,
                    note: open.isEmpty ? "Nothing listens on every interface." : "Listening on every interface: any network the server is on can connect, unless a firewall stops it.") {
                ForEach(Array(open.enumerated()), id: \.element.id) { index, port in
                    if index > 0 { Divider().overlay(Theme.border) }
                    PortRow(port: port)
                }
                if !local.isEmpty {
                    if !open.isEmpty { Divider().overlay(Theme.border) }
                    Button { withAnimation(.easeOut(duration: 0.15)) { showingLocalPorts.toggle() } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(showingLocalPorts ? 90 : 0))
                            Text("\(local.count) more only this server, the local network or Tailscale can reach")
                                .font(.system(size: 12))
                            Spacer()
                        }
                        .foregroundStyle(Theme.textSecondary).padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
                    }
                    .buttonStyle(.pointer)
                    if showingLocalPorts {
                        ForEach(local) { port in
                            Divider().overlay(Theme.border).padding(.leading, 14)
                            PortRow(port: port)
                        }
                    }
                }
            }
        }
    }

    /// Passed checks, folded into one line; opened, a compact list of what was checked.
    @ViewBuilder private func passed(_ findings: [SecurityFinding]) -> some View {
        if !findings.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button { withAnimation(.easeOut(duration: 0.15)) { showingPassed.toggle() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                        Text("\(findings.count) checks passed").font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(showingPassed ? "Hide" : "Show").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(14).contentShape(Rectangle())
                }
                .buttonStyle(.pointer)
                if showingPassed {
                    Divider().overlay(Theme.border)
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                              alignment: .leading, spacing: 10) {
                        ForEach(findings) { f in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(SecurityChecks.check(f.check)?.title ?? f.check).font(.system(size: 12, weight: .medium))
                                Text(f.summary).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .help(f.evidence ?? "")
                        }
                    }
                    .padding(14)
                }
            }
            .card()
        }
    }
}

private struct SectionTitle: View {
    let title: String
    let count: Int
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text("\(count)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textMuted)
            }
            if let note {
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension SecurityFinding.Severity {
    var symbol: String {
        switch self {
        case .critical: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        case .unknown: "questionmark.circle"
        case .pass: "checkmark.circle.fill"
        }
    }
    @MainActor var tint: Color {
        switch self {
        case .critical: Theme.danger
        case .warning: Theme.warn
        case .info: Theme.accent
        case .unknown: Theme.textMuted
        case .pass: Theme.ok
        }
    }
}

/// One finding: icon, the check, what was found. Click to open what Rackoon read, why it matters and what to do.
private struct FindingRow: View {
    let finding: SecurityFinding
    let check: SecurityCheck?
    @Binding var expanded: Bool
    var link: (title: String, run: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: finding.severity.symbol).font(.system(size: 13)).foregroundStyle(finding.severity.tint).frame(width: 18)
                Text(finding.summary).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    .help(check?.title ?? "")
                Spacer(minLength: 12)
                if let link { NoticeLink(title: link.title, run: link.run) }
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textMuted)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }
            if expanded, let check {
                VStack(alignment: .leading, spacing: 8) {
                    detail("Why it matters", check.why)
                    detail("What you can do", check.advice)
                    if let evidence = finding.evidence { detail("What Rackoon read", evidence, mono: true) }
                }
                .padding(.leading, 30)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private func detail(_ title: String, _ text: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.textMuted)
            Text(text).font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .foregroundStyle(Theme.textPrimary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One port: number, what it is (well-known service or the container that published it), where it listens, and flags.
private struct PortRow: View {
    let port: ExposedPort

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: port.flags.isEmpty ? "circle" : "exclamationmark.triangle.fill").font(.system(size: 11))
                .foregroundStyle(port.flags.isEmpty ? Theme.textMuted.opacity(0.6) : Theme.warn).frame(width: 18)
            Text(verbatim: "\(port.port)/\(port.proto)").font(.system(size: 13, weight: .medium).monospacedDigit())
                .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(what).font(.system(size: 13)).lineLimit(1)
                Text(reach).font(.system(size: 11)).foregroundStyle(Theme.textMuted).lineLimit(1)
            }
            Spacer(minLength: 12)
            ForEach(port.flags, id: \.self) { Badge(text: $0, color: Theme.warn).help(Self.why[$0] ?? "") }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    static let why: [String: String] = [
        "past ufw": "Docker writes its own firewall rules ahead of ufw's, so this port is open even if ufw denies it. Publish it on 127.0.0.1 or the Tailscale address instead.",
        "database or cache": "Databases and caches are often reachable without a password. Bind it to 127.0.0.1 and reach it over Tailscale or an SSH tunnel.",
        "no TLS": "Docker's API without TLS: anyone who reaches it controls the server as root.",
    ]

    private var what: String {
        let docker = port.containers.isEmpty ? nil : "Docker: " + port.containers.joined(separator: ", ")
        return [port.service, docker].compactMap { $0 }.joined(separator: " · ").isEmpty
            ? "Unknown service" : [port.service, docker].compactMap { $0 }.joined(separator: " · ")
    }

    private var reach: String {
        let place = switch port.scope {
        case .all: "Every interface"
        case .public: "Public address"
        case .lan: "Local network"
        case .tailscale: "Tailscale only"
        case .loopback: "This server only"
        }
        return "\(place) · \(port.addresses.joined(separator: ", "))"
    }
}

/// Runs the same read-only checks as root, only when pressed (docs/security-plan.md: sudo is never used on its own). While
/// Docker is unlocked for the server it reuses that; otherwise it asks: a saved password with Touch ID / Apple Watch /
/// the login password, or the password sheet. That password is used for this one reading and then dropped.
private struct DeepCheckButton: View {
    let server: Server
    let model: SecurityModel
    @State private var request: SudoRequest?
    @State private var working = false

    var body: some View {
        Button(working ? "Unlocking…" : "Check Deeper with sudo…", action: start)
            .buttonStyle(.bordered).controlSize(.large)
            .help("Run the same read-only checks as root: sshd's settings in use, every container and /etc/shadow. Nothing on the server is changed.")
            .handCursor()
            .disabled(working || model.loading || Demo.isOn)
            .sudoPassword($request)
    }

    private func start() {
        let server = server
        if DockerElevation.shared.isUnlocked(server) {
            Task { await model.refreshDeeper(using: DockerElevation.shared.transport(for: server)) }
            return
        }
        guard SudoVault.shared.isRemembered(server) else { ask(problem: nil); return }
        working = true
        Task {
            defer { working = false }
            switch await SudoVault.shared.unlock(server, reason: SudoVault.reason(server, doing: "check security as root")) {
            case .success(let password):
                if let problem = await DockerElevation.check(password, on: server) {
                    if problem == DockerElevation.rejected { SudoVault.shared.forget(server.id) }
                    ask(problem: problem == DockerElevation.rejected ? "The saved sudo password was not accepted, so it was forgotten." : problem)
                } else {
                    await run(password)
                }
            case .failure(.cancelled):
                break
            case .failure(let error):
                ask(problem: error.sheetProblem)
            }
        }
    }

    private func ask(problem: String?) {
        let server = server
        request = SudoRequest(
            title: "Check \(server.name) as root", server: server,
            command: "sudo -S -p '' sh -c '<the Security checks>'",
            problem: problem, actionLabel: "Check", canRemember: SudoVault.shared.canRemember,
            submit: { password, remember in
                working = true
                Task {
                    defer { working = false }
                    if let problem = await DockerElevation.check(password, on: server) {
                        ask(problem: problem)
                        return
                    }
                    await run(password)
                    if remember { await SudoVault.shared.remember(password, for: server) }
                }
            })
    }

    /// One reading through sudo; the transport (and the password in it) goes when this returns.
    private func run(_ password: String) async {
        let sudo = SudoTransport(base: makeTransport(for: server), password: password, validUntil: Date().addingTimeInterval(120))
        await model.refreshDeeper(using: sudo)
    }
}
