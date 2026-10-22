import Charts
import RackoonCore
import SwiftUI

/// The fleet at a glance, as the Mac's Dashboard: Health (totals across every server, then per server a heartbeat bar and
/// uptime over the last hour, CPU and memory sparklines, the fullest disk and what needs attention), Docker (each answering
/// server's container totals and apps) and Bookmarks. Every server is read once a minute while this screen shows; Docker
/// is read only while its page or Bookmarks shows. (The Mac's Services and Alerts pages come with those features.)
struct DashboardScreen: View {
    @Environment(AppModel.self) private var model
    @State private var settings = false
    @AppStorage("dashboardPage") private var page = DashboardPage.health

    var body: some View {
        let t = model.tokens
        let servers = model.servers.servers
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if servers.isEmpty {
                        ContentUnavailableView("No servers yet", systemImage: "server.rack",
                                               description: Text("Add one under Servers, or turn on Demo Mode in Settings."))
                    } else {
                        Picker("Page", selection: $page) {
                            ForEach(DashboardPage.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("dashboardPage")
                        switch page {
                        case .health:
                            TotalsCard(totals: FleetTotals.of(servers.map { model.fleet.state(for: $0.id) }))
                            ForEach(servers) { server in
                                NavigationLink(value: server.id) { HealthCard(server: server) }
                                    .buttonStyle(.plain)
                            }
                        case .docker:
                            DockerPage(servers: servers)
                        case .bookmarks:
                            BookmarksPage(servers: servers)
                        }
                    }
                }
                .padding(16)
            }
            .background(t.background)
            .navigationTitle("Dashboard")
            .navigationDestination(for: String.self) { id in OverviewScreen(serverID: id) }
            .refreshable {
                await withTaskGroup(of: Void.self) { group in
                    for server in servers { group.addTask { await model.fleet.refresh(server.id) } }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ReadOnlyChip() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $settings) { SettingsScreen() }
            .watching(servers.map(\.id), fast: false)
        }
    }
}

extension View {
    /// Keeps `ids` polled while this view is on screen (once a minute, or every 5 s with `fast`), following changes to the list.
    func watching(_ ids: [String], fast: Bool) -> some View { modifier(Watching(ids: ids, fast: fast)) }
}

private struct Watching: ViewModifier {
    @Environment(AppModel.self) private var model
    let ids: [String]
    let fast: Bool
    @State private var attached: Set<String> = []

    func body(content: Content) -> some View {
        content
            .onAppear { sync(Set(ids)) }
            .onDisappear { sync([]) }
            .onChange(of: ids) { _, new in sync(Set(new)) }
            .onChange(of: model.isDemo) { _, _ in
                // A new fleet: what was attached belonged to the old one.
                attached = []
                sync(Set(ids))
            }
    }

    private func sync(_ wanted: Set<String>) {
        for id in attached.subtracting(wanted) { model.fleet.detach(id, fast: fast) }
        for id in wanted.subtracting(attached) { model.fleet.attach(id, fast: fast) }
        attached = wanted
    }
}

private struct TotalsCard: View {
    @Environment(AppModel.self) private var model
    let totals: FleetTotals

    var body: some View {
        let t = model.tokens
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(totals.online) of \(totals.servers) answering").font(.headline).foregroundStyle(t.text)
                Spacer()
            }
            .accessibilityIdentifier("fleetOnline")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Stat(title: "CPU", value: totals.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "…")
                    Stat(title: "Memory", value: totals.memoryTotal > 0 ? Present.percent(Double(totals.memoryUsed) / Double(totals.memoryTotal)) : "…")
                    Stat(title: "Disk", value: totals.diskTotal > 0 ? Present.percent(Double(totals.diskUsed) / Double(totals.diskTotal)) : "…")
                }
                GridRow {
                    Stat(title: "Updates", value: "\(totals.updates)", detail: totals.securityUpdates > 0 ? "\(totals.securityUpdates) security" : nil,
                         warn: totals.securityUpdates > 0)
                    Stat(title: "Reboot", value: "\(totals.rebootRequired)", warn: totals.rebootRequired > 0)
                    Stat(title: "Unhealthy", value: "\(totals.unhealthyContainers)", warn: totals.unhealthyContainers > 0)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(t.card))
    }
}

private struct Stat: View {
    @Environment(AppModel.self) private var model
    let title: String
    let value: String
    var detail: String?
    var warn = false

    var body: some View {
        let t = model.tokens
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(t.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(warn ? t.warn : t.text)
            if let detail { Text(detail).font(.caption2).foregroundStyle(t.warn) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HealthCard: View {
    @Environment(AppModel.self) private var model
    let server: Server

    var body: some View {
        let t = model.tokens
        let state = model.fleet.state(for: server.id)
        let history = model.fleet.history[server.id] ?? HealthHistory()
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusLight(server: server, state: state)
                Text(server.name).font(.headline).foregroundStyle(t.text)
                Spacer()
                if let uptime = history.uptimeFraction {
                    Text("\(Present.percent(uptime)) up").font(.caption.monospacedDigit()).foregroundStyle(uptime < 1 ? t.warn : t.secondary)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(t.muted)
            }
            Heartbeat(samples: history.samples)
            if let overview = state.overview {
                HStack(spacing: 12) {
                    Spark(title: "CPU", value: state.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "…",
                          points: history.samples.compactMap { s in s.cpuPercent.map { (s.at, $0) } })
                    Spark(title: "Memory", value: Present.percent(overview.memory.usedFraction),
                          points: history.samples.compactMap { s in s.memoryFraction.map { (s.at, $0 * 100) } })
                }
                HStack(spacing: 6) {
                    if let disk = Present.fullestDisk(overview) {
                        Badge(text: "\(disk.mount == "/" ? "disk" : disk.mount) \(disk.usePercent)%", warn: disk.usePercent > Attention.diskThresholdPercent)
                    }
                    if overview.pendingUpdates > 0 {
                        Badge(text: "\(overview.pendingUpdates) updates", warn: overview.securityUpdates > 0)
                    }
                    if overview.rebootRequired { Badge(text: "reboot", warn: true) }
                    if !overview.unhealthyContainers.isEmpty { Badge(text: "\(overview.unhealthyContainers.count) unhealthy", warn: true) }
                }
            } else if let reason = model.fleet.blocked[server.id] {
                Text(reason).font(.caption).foregroundStyle(t.warn)
            }
            if let error = state.error {
                Text(model.failure(for: server, state: state)?.headline ?? error).font(.caption).foregroundStyle(t.danger).lineLimit(2)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(t.card))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One mark per check over the last hour, newest on the right, like Uptime Kuma: green answered, red did not.
private struct Heartbeat: View {
    @Environment(AppModel.self) private var model
    let samples: [HealthSample]

    var body: some View {
        let t = model.tokens
        let slots = HealthHistory.capacity
        HStack(spacing: 2) {
            ForEach(0..<slots, id: \.self) { i in
                let index = samples.count - slots + i
                let color: Color = index < 0 ? t.border : (samples[index].up ? t.ok : t.danger)
                Capsule().fill(color).frame(maxWidth: .infinity).frame(height: 14)
            }
        }
        .accessibilityLabel("\(samples.filter(\.up).count) of \(samples.count) checks answered")
    }
}

/// A small line over the last hour on a fixed 0–100 scale, so a busy server looks busy at a glance.
private struct Spark: View {
    @Environment(AppModel.self) private var model
    let title: String
    let value: String
    let points: [(Date, Double)]

    var body: some View {
        let t = model.tokens
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(t.secondary)
                Spacer()
                Text(value).font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(t.text)
            }
            Chart(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Time", point.0), y: .value(title, point.1)).foregroundStyle(t.accent)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 30)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct Badge: View {
    @Environment(AppModel.self) private var model
    let text: String
    let warn: Bool

    var body: some View {
        let t = model.tokens
        Text(text).font(.caption2.weight(.semibold))
            .foregroundStyle(warn ? t.warn : t.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().strokeBorder(warn ? t.warn : t.border))
    }
}
