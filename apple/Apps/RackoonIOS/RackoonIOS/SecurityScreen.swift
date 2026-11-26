import RackoonCore
import SwiftUI

/// The Security screen (docs/security-plan.md), as on the Mac: a verdict with the disclaimer, what to fix, what other
/// networks can reach, the opt-in vulnerability lookup, what is worth knowing, what could not be checked and the passed
/// checks folded away. Advice only: nothing here changes the server. Check Deeper runs the same read-only checks as root,
/// only when asked: through the Docker unlock while one is active, else with the sudo password for this one reading.
struct SecurityScreen: View {
    @Environment(AppModel.self) private var model
    let serverID: String

    var body: some View {
        if let server = model.servers.server(id: serverID) {
            switch model.securityModel(for: server) {
            case .success(let security): SecurityList(security: security, server: server)
            case .failure(let reason):
                ContentUnavailableView("Security can't be checked yet", systemImage: "shield", description: Text(reason.message))
                    .navigationTitle("Security")
            }
        } else {
            ContentUnavailableView("Server removed", systemImage: "server.rack")
        }
    }
}

private struct SecurityList: View {
    @Environment(AppModel.self) private var model
    let security: SecurityModel
    let server: Server
    @State private var request: SudoRequest?
    @State private var working = false
    @State private var showLocal = false

    static let disclaimer = "These checks look for a small set of common hardening problems. They are not a complete security review and can be wrong: a setting may be overridden somewhere Rackoon does not read, and new issues appear every day. Treat a clean result as \"nothing obvious found\", not \"secure\"."
    static let limits = "Matched by package version with OSV.dev's Debian and Ubuntu data. Kernel advisories depend on how the kernel is built and used, a backported fix can make a version look affected when it is not, and software outside apt (Docker images, binaries in /opt, pip or npm installs) is not covered."
    private static let shownAsPorts: Set<String> = ["exposure.listening", "exposure.sensitive_port", "exposure.docker_bypass"]

    private var overview: Overview? { model.fleet.state(for: server.id).overview }
    private var lookupOn: Bool { model.vulnerabilityLookup.isOn(server.id) }

    var body: some View {
        let t = model.tokens
        let findings = security.findings(SecurityModel.context(overview)).filter { !Self.shownAsPorts.contains($0.check) }
        List {
            if let error = security.error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(t.warn) }.listRowBackground(t.card)
            }
            if let snapshot = security.snapshot {
                let ports = SecurityExposure.ports(snapshot, ufwOn: SecurityRules.ufwOn(snapshot))
                let toFix = sorted(findings.filter { $0.severity == .critical || $0.severity == .warning })
                let open = ports.filter(\.isExposed)
                let flagged = open.filter { !$0.flags.filter { $0 != "no TLS" }.isEmpty }.count
                Section {
                    let parts = [toFix.isEmpty ? nil : "\(toFix.count) thing\(toFix.count == 1 ? "" : "s") to fix",
                                 flagged == 0 ? nil : "\(flagged) open port\(flagged == 1 ? "" : "s") to look at"].compactMap { $0 }
                    Label(parts.isEmpty ? "Nothing obvious to fix" : parts.joined(separator: ", "),
                          systemImage: parts.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(parts.isEmpty ? t.ok : toFix.contains { $0.severity == .critical } ? t.danger : t.warn)
                        .font(.headline)
                        .accessibilityIdentifier("securityVerdict")
                } footer: {
                    Text(Self.disclaimer)
                }
                .listRowBackground(t.card)
                if !toFix.isEmpty { findingSection("To fix", toFix) }
                if !ports.isEmpty {
                    Section {
                        ForEach(open) { PortRowView(port: $0) }
                        let local = ports.filter { !$0.isExposed }
                        if !local.isEmpty {
                            DisclosureGroup("\(local.count) more only this server, the local network or Tailscale can reach", isExpanded: $showLocal) {
                                ForEach(local) { PortRowView(port: $0) }
                            }
                        }
                    } header: {
                        Text("Reachable from other networks (\(open.count))")
                    } footer: {
                        Text(open.isEmpty ? "Nothing listens on every interface." : "Any network the server is on can connect, unless a firewall stops it.")
                    }
                    .listRowBackground(t.card)
                }
                vulnerabilitySection
                let info = sorted(findings.filter { $0.severity == .info })
                if !info.isEmpty { findingSection("Worth knowing", info) }
                let unknown = sorted(findings.filter { $0.severity == .unknown })
                if !unknown.isEmpty {
                    findingSection("Could not check", unknown,
                                   footer: "Rackoon reads as \(snapshot.isRoot ? "root" : "\(server.user ?? "the ssh user"), without sudo"); these need more access, so they are not counted as passed.")
                }
                let passed = sorted(findings.filter { $0.severity == .pass })
                if !passed.isEmpty {
                    Section {
                        DisclosureGroup("\(passed.count) checks passed") {
                            ForEach(passed) { f in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(SecurityChecks.check(f.check)?.title ?? f.check).font(.subheadline.weight(.medium))
                                    Text(f.summary).font(.caption).foregroundStyle(t.secondary)
                                }
                            }
                        }
                    }
                    .listRowBackground(t.card)
                }
            } else if security.error == nil {
                Section { HStack { ProgressView(); Text("Checking…") } }.listRowBackground(t.card)
            }
        }
        .scrollContentBackground(.hidden)
        .background(t.background)
        .navigationTitle("Security")
        .refreshable { await checkNow() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Check Now") { Task { await checkNow() } }
                    if security.snapshot?.isRoot == false {
                        Button("Check Deeper with sudo…") { deeper() }.disabled(working || model.isDemo)
                    }
                } label: {
                    if security.loading || working { ProgressView() } else { Image(systemName: "ellipsis.circle") }
                }
                .accessibilityIdentifier("securityMenu")
            }
        }
        .sudoPassword($request)
        .onAppear {
            security.load()
            if lookupOn, security.vulnerabilities == nil { Task { await security.lookUpVulnerabilities() } }
        }
    }

    private func checkNow() async {
        await security.refresh()
        if lookupOn { await security.lookUpVulnerabilities() }
    }

    private func sorted(_ findings: [SecurityFinding]) -> [SecurityFinding] {
        func order(_ f: SecurityFinding) -> Int { SecurityChecks.all.firstIndex { $0.id == f.check } ?? .max }
        return findings.sorted { ($0.severity, order($0), $0.id) < ($1.severity, order($1), $1.id) }
    }

    private func findingSection(_ title: String, _ list: [SecurityFinding], footer: String? = nil) -> some View {
        Section {
            ForEach(list) { FindingRowView(finding: $0) }
        } header: {
            Text("\(title) (\(list.count))")
        } footer: {
            if let footer { Text(footer) }
        }
        .listRowBackground(model.tokens.card)
    }

    // MARK: vulnerabilities

    @ViewBuilder private var vulnerabilitySection: some View {
        let t = model.tokens
        let settings = model.vulnerabilityLookup
        Section {
            if !lookupOn {
                Text("Look up known vulnerabilities (CVEs) in this server's installed packages.").font(.subheadline.weight(.medium))
                Button("Turn On for This Server") { settings.set(true, server: server.id); Task { await security.lookUpVulnerabilities() } }
                    .accessibilityIdentifier("lookupThisServer")
                Button("Turn On for All Servers") { settings.setAll(true); Task { await security.lookUpVulnerabilities() } }
            } else if !security.lookupSupported {
                Text("The lookup supports Debian and Ubuntu releases; this server is neither (or has no release number).").foregroundStyle(t.secondary)
            } else if let error = security.vulnerabilityError {
                Label("Could not look up vulnerabilities: \(error)", systemImage: "exclamationmark.triangle").foregroundStyle(t.warn)
            } else if let list = security.vulnerabilities {
                if list.isEmpty { Text("OSV.dev knows no vulnerabilities in these package versions.") }
                ForEach(VulnerabilityFinding.Status.allCases, id: \.self) { status in
                    let group = list.filter { $0.status == status }
                    if !group.isEmpty {
                        DisclosureGroup("\(heading(status)) (\(group.count))") {
                            ForEach(group, id: \.self.rowKey) { VulnRowView(finding: $0) }
                        }
                    }
                }
                if list.contains(where: { $0.status == .fixWaiting }) {
                    NavigationLink { UpdatesScreen(serverID: server.id) } label: { Label("Updates", systemImage: "arrow.down.circle") }
                }
            } else {
                HStack { ProgressView(); Text("Asking OSV.dev…") }
            }
            if lookupOn {
                if settings.servers.contains(server.id) {
                    Button("Turn Off for This Server", role: .destructive) { settings.set(false, server: server.id); clearIfOff() }
                }
                if settings.all {
                    Button("Turn Off for All Servers", role: .destructive) { settings.setAll(false); clearIfOff() }
                }
            }
        } header: {
            Text("Known vulnerabilities")
        } footer: {
            Text(lookupOn ? Self.limits : VulnerabilityLookupSettings.privacyNote)
        }
        .listRowBackground(t.card)
    }

    private func clearIfOff() { if !lookupOn { security.clearVulnerabilities() } }

    private func heading(_ status: VulnerabilityFinding.Status) -> String {
        switch status {
        case .fixWaiting: "Fix waiting in the updates"
        case .fixReleased: "Fixed upstream: refresh the package lists"
        case .noFix: "No fix released yet"
        }
    }

    // MARK: check deeper

    private func deeper() {
        guard case .success(let base) = model.transport(for: server) else { return }
        if model.elevation.isUnlocked(server.id) {
            Task { await security.refreshDeeper(using: model.elevation.transport(for: server.id, base: base)) }
            return
        }
        ask(problem: nil)
    }

    private func ask(problem: String?) {
        let server = server
        request = SudoRequest(
            title: "Check as root", server: server, command: "sudo -S -p '' sh -c '<the Security checks>'",
            problem: problem, actionLabel: "Check", canRemember: false,
            submit: { password, _ in
                working = true
                Task {
                    defer { working = false }
                    guard case .success(let base) = model.transport(for: server) else { return }
                    if let problem = await DockerElevation.check(password, on: base) {
                        ask(problem: problem)
                        return
                    }
                    // One reading through sudo; the transport (and the password in it) goes when this returns.
                    await security.refreshDeeper(using: SudoTransport(base: base, password: password, validUntil: Date().addingTimeInterval(120)))
                }
            })
    }
}

private extension VulnerabilityFinding {
    var rowKey: String { package + "|" + id }
}

private struct FindingRowView: View {
    @Environment(AppModel.self) private var model
    let finding: SecurityFinding
    @State private var open = false

    var body: some View {
        let t = model.tokens
        let check = SecurityChecks.check(finding.check)
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                if let check {
                    detail("Why it matters", check.why)
                    detail("What you can do", check.advice)
                }
                if let evidence = finding.evidence { detail("What Rackoon read", evidence, mono: true) }
            }
        } label: {
            Label {
                Text(finding.summary).font(.subheadline)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint(t))
            }
        }
    }

    private var symbol: String {
        switch finding.severity {
        case .critical: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        case .unknown: "questionmark.circle"
        case .pass: "checkmark.circle.fill"
        }
    }

    private func tint(_ t: Tokens) -> Color {
        switch finding.severity {
        case .critical: t.danger
        case .warning: t.warn
        case .info: t.accent
        case .unknown: t.muted
        case .pass: t.ok
        }
    }

    private func detail(_ title: String, _ text: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(model.tokens.muted)
            Text(text).font(mono ? .caption.monospaced() : .caption).textSelection(.enabled)
        }
    }
}

private struct PortRowView: View {
    @Environment(AppModel.self) private var model
    let port: ExposedPort

    var body: some View {
        let t = model.tokens
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: "\(port.port)/\(port.proto)").font(.subheadline.monospacedDigit().weight(.medium))
                Text(what).font(.subheadline).lineLimit(1)
                Spacer()
            }
            Text("\(place) · \(port.addresses.joined(separator: ", "))").font(.caption).foregroundStyle(t.secondary)
            if !port.flags.isEmpty {
                HStack { ForEach(port.flags, id: \.self) { Text($0).font(.caption2.weight(.semibold)).foregroundStyle(t.warn) } }
            }
        }
    }

    private var what: String {
        let parts = [port.service, port.containers.isEmpty ? nil : "Docker: " + port.containers.joined(separator: ", ")].compactMap { $0 }
        return parts.isEmpty ? "Unknown service" : parts.joined(separator: " · ")
    }

    private var place: String {
        switch port.scope {
        case .all: "Every interface"
        case .public: "Public address"
        case .lan: "Local network"
        case .tailscale: "Tailscale only"
        case .loopback: "This server only"
        }
    }
}

private struct VulnRowView: View {
    @Environment(AppModel.self) private var model
    let finding: VulnerabilityFinding

    var body: some View {
        let t = model.tokens
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(finding.severity).font(.caption2.weight(.semibold))
                    .foregroundStyle(["critical", "high"].contains(finding.severity) ? t.danger : finding.severity == "medium" ? t.warn : t.secondary)
                Text(finding.id).font(.caption.monospaced())
                Text(finding.package).font(.caption.weight(.medium))
            }
            Text(verbatim: "\(finding.installed)\(finding.fixed.map { " → \($0)" } ?? "")").font(.caption2.monospaced()).foregroundStyle(t.secondary)
            if !finding.summary.isEmpty { Text(finding.summary).font(.caption) }
            if let url = URL(string: "https://osv.dev/vulnerability/\(finding.id)") { Link("Open on osv.dev", destination: url).font(.caption) }
        }
    }
}
