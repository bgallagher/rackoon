import CryptoKit
import Foundation
import RackoonCore

/// The made-up servers of demo mode, shared by every Apple app (Mac, iOS): a store-ready server list and one canned
/// transport per server. Nothing here touches the network.
public enum DemoFleet {
    public static let servers: [Server] = [
        Server(id: "demo-homelab", name: "homelab", host: "homelab.demo"),
        Server(id: "demo-nuc", name: "garage-nuc", host: "garage-nuc.demo"),
    ]

    private static let transports: [String: DemoTransport] = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, DemoTransport(profile: $0.id == "demo-nuc" ? .nuc : .homelab)) })

    /// The demo server's transport; a server the user added in demo mode answers like homelab.
    public static func transport(for server: Server) -> SSHTransport { transports[server.id] ?? DemoTransport(profile: .homelab) }

    /// The fake shell a terminal runs in demo mode: a login banner and canned answers to a few commands.
    public static var shellScript: String { DemoData.shellScript }
}

// MARK: - The fake server

public struct DemoProfile: Sendable {
    var hostname: String
    var prettyName: String
    var versionID: String
    var codename: String
    var vendor: String
    var product: String
    var kernel: String
    var cores: Int
    var memTotalKB: Int
    var memUsedFraction: Double
    var diskTotal: Int64
    var diskUsedFraction: Double
    var uptimeDays: Double
    var ip: String
    var tailscaleIP: String?
    var updates: Int
    var security: Int
    var rebootRequired: Bool
    var stacks: [DemoStack]
    var machineID: String
    /// Containers started with `docker run` (no compose labels); `service` is the container's name.
    var standalone: [DemoContainer] = []

    public static let homelab = DemoProfile(
        hostname: "homelab", prettyName: "Ubuntu 24.04.2 LTS", versionID: "24.04", codename: "noble", vendor: "Intel Corporation",
        product: "NUC13ANHi5", kernel: "6.8.0-52-generic", cores: 8, memTotalKB: 16_384_000, memUsedFraction: 0.39,
        diskTotal: 500_107_862_016, diskUsedFraction: 0.41, uptimeDays: 27.4, ip: "203.0.113.24", tailscaleIP: "100.100.40.7",
        updates: 5, security: 2, rebootRequired: true, stacks: DemoData.homelabStacks, machineID: "8c2f4e61b0a94d37a1c5d2e9f7b3a608",
        standalone: DemoData.homelabStandalone)

    public static let nuc = DemoProfile(
        hostname: "garage-nuc", prettyName: "Debian GNU/Linux 12 (bookworm)", versionID: "12", codename: "bookworm", vendor: "Raspberry Pi",
        product: "Pi 5 Model B", kernel: "6.6.62+rpt-rpi-2712", cores: 4, memTotalKB: 8_388_608, memUsedFraction: 0.22,
        diskTotal: 256_060_514_304, diskUsedFraction: 0.18, uptimeDays: 61.2, ip: "192.168.1.52", tailscaleIP: nil,
        updates: 0, security: 0, rebootRequired: false, stacks: DemoData.nucStacks, machineID: "1d5b9e0c47a24f6e8b3a7c1f2e9d4a65")
}

struct DemoContainer: Sendable {
    var service: String
    var image: String
    var health = "none"
    var cpu: Double
    var memMB: Double
    var ports = ""
    var running = true
    var status: String { running ? "Up \(Int.random(in: 2...400)) hours" + (health == "none" ? "" : " (\(health))") : "Exited (0) 2 days ago" }
}

struct DemoStack: Sendable {
    var name: String
    var containers: [DemoContainer]
    var bookmark: Bookmark?
    var dir: String { "/opt/stacks/\(name)" }
}

enum DemoData {
    static let homelabStacks: [DemoStack] = [
        DemoStack(name: "jellyfin", containers: [DemoContainer(service: "jellyfin", image: "jellyfin/jellyfin:10.10.3", health: "healthy", cpu: 1.4, memMB: 612, ports: "100.100.40.7:8096->8096/tcp")],
                  bookmark: Bookmark(href: "https://jellyfin.org/", name: "Jellyfin", group: "Media", icon: "jellyfin.png", description: "Movies and shows")),
        DemoStack(name: "immich", containers: [
            DemoContainer(service: "immich-server", image: "ghcr.io/immich-app/immich-server:v1.122.0", health: "healthy", cpu: 2.1, memMB: 880, ports: "100.100.40.7:2283->2283/tcp"),
            DemoContainer(service: "immich-machine-learning", image: "ghcr.io/immich-app/immich-machine-learning:v1.122.0", health: "healthy", cpu: 0.3, memMB: 1420),
            DemoContainer(service: "redis", image: "redis:7-alpine", health: "healthy", cpu: 0.2, memMB: 14),
            DemoContainer(service: "database", image: "tensorchord/pgvecto-rs:pg14-v0.2.0", health: "healthy", cpu: 0.9, memMB: 310)],
                  bookmark: Bookmark(href: "https://immich.app/", name: "Immich", group: "Media", icon: "immich.png", description: "Photos and videos")),
        DemoStack(name: "nextcloud", containers: [
            DemoContainer(service: "app", image: "nextcloud:30-apache", cpu: 0.8, memMB: 340, ports: "100.100.40.7:8080->80/tcp"),
            DemoContainer(service: "db", image: "mariadb:11", health: "healthy", cpu: 0.6, memMB: 220)],
                  bookmark: Bookmark(href: "https://nextcloud.com/", name: "Nextcloud", group: "Files", icon: "nextcloud.png", description: "Files, calendar, contacts")),
        DemoStack(name: "paperless-ngx", containers: [
            DemoContainer(service: "webserver", image: "ghcr.io/paperless-ngx/paperless-ngx:2.14", health: "healthy", cpu: 0.4, memMB: 760, ports: "100.100.40.7:8000->8000/tcp"),
            DemoContainer(service: "broker", image: "redis:7", cpu: 0.1, memMB: 9),
            DemoContainer(service: "db", image: "postgres:16", health: "healthy", cpu: 0.2, memMB: 85)],
                  bookmark: Bookmark(href: "https://docs.paperless-ngx.com/", name: "Paperless", group: "Files", icon: "paperless-ngx.png", description: "Scanned documents")),
        DemoStack(name: "homeassistant", containers: [DemoContainer(service: "homeassistant", image: "ghcr.io/home-assistant/home-assistant:2025.1", cpu: 3.2, memMB: 540)],
                  bookmark: Bookmark(href: "https://www.home-assistant.io/", name: "Home Assistant", group: "Home", icon: "home-assistant.png", description: "Lights, heating, sensors")),
        DemoStack(name: "adguardhome", containers: [DemoContainer(service: "adguardhome", image: "adguard/adguardhome:v0.107.55", cpu: 0.5, memMB: 76, ports: "100.100.40.7:3000->3000/tcp, 100.100.40.7:53->53/tcp")],
                  bookmark: Bookmark(href: "https://adguard.com/", name: "AdGuard Home", group: "Home", icon: "adguard-home.png", description: "Network-wide ad blocking")),
        DemoStack(name: "vaultwarden", containers: [DemoContainer(service: "vaultwarden", image: "vaultwarden/server:1.32.7", health: "healthy", cpu: 0.1, memMB: 24, ports: "127.0.0.1:8081->80/tcp")],
                  bookmark: Bookmark(href: "https://bitwarden.com/", name: "Vaultwarden", group: "Tools", icon: "vaultwarden.png", description: "Passwords")),
        DemoStack(name: "uptime-kuma", containers: [DemoContainer(service: "uptime-kuma", image: "louislam/uptime-kuma:1", health: "healthy", cpu: 0.7, memMB: 142, ports: "100.100.40.7:3001->3001/tcp")],
                  bookmark: Bookmark(href: "https://uptime.kuma.pet/", name: "Uptime Kuma", group: "Monitoring", icon: "uptime-kuma.png", description: "Status checks")),
        DemoStack(name: "monitoring", containers: [
            DemoContainer(service: "grafana", image: "grafana/grafana:11.4.0", health: "healthy", cpu: 0.6, memMB: 190, ports: "100.100.40.7:3030->3000/tcp"),
            DemoContainer(service: "prometheus", image: "prom/prometheus:v2.55.1", cpu: 0.9, memMB: 330),
            DemoContainer(service: "promtail", image: "grafana/promtail:3.3.0", health: "unhealthy", cpu: 0.0, memMB: 41)],
                  bookmark: Bookmark(href: "https://grafana.com/", name: "Grafana", group: "Monitoring", icon: "grafana.png", description: "Dashboards")),
        DemoStack(name: "traefik", containers: [DemoContainer(service: "traefik", image: "traefik:v3.2", cpu: 0.4, memMB: 58, ports: "0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp")], bookmark: nil),
        DemoStack(name: "watchtower", containers: [DemoContainer(service: "watchtower", image: "containrrr/watchtower:1.7.1", cpu: 0.0, memMB: 18)], bookmark: nil),
        DemoStack(name: "dockge", containers: [DemoContainer(service: "dockge", image: "louislam/dockge:1", health: "healthy", cpu: 0.3, memMB: 120, ports: "100.100.40.7:5001->5001/tcp")], bookmark: nil),
    ]

    /// Started with `docker run`, so each is its own Standalone card.
    static let homelabStandalone: [DemoContainer] = [
        DemoContainer(service: "portainer", image: "portainer/portainer-ce:2.21.5", cpu: 0.2, memMB: 48, ports: "100.100.40.7:9443->9443/tcp"),
        DemoContainer(service: "speedtest-tracker", image: "lscr.io/linuxserver/speedtest-tracker:0.24.2", cpu: 0.1, memMB: 95, running: false),
    ]

    static let nucStacks: [DemoStack] = [
        DemoStack(name: "pihole", containers: [DemoContainer(service: "pihole", image: "pihole/pihole:2024.07.0", health: "healthy", cpu: 0.6, memMB: 96, ports: "192.168.1.52:80->80/tcp")],
                  bookmark: Bookmark(href: "https://pi-hole.net/", name: "Pi-hole", group: "Home", description: "DNS filtering")),
        DemoStack(name: "homebridge", containers: [DemoContainer(service: "homebridge", image: "homebridge/homebridge:2024-12-01", cpu: 1.1, memMB: 210)], bookmark: nil),
    ]

    // MARK: composing compose files

    static func compose(for stack: DemoStack) -> String {
        var lines = ["services:"]
        for c in stack.containers {
            lines += ["  \(c.service):", "    image: \(c.image)", "    restart: unless-stopped"]
            if !c.ports.isEmpty {
                lines.append("    ports:")
                for p in c.ports.components(separatedBy: ", ") {
                    // "100.100.40.7:8096->8096/tcp" -> "${TS_IP}:8096:8096"
                    let parts = p.replacingOccurrences(of: "/tcp", with: "").components(separatedBy: "->")
                    if parts.count == 2 { lines.append("      - \"\(parts[0].replacingOccurrences(of: "100.100.40.7", with: "${TS_IP}")):\(parts[1])\"") }
                }
            }
            lines += ["    volumes:", "      - ./data/\(c.service):/data"]
            lines += ["    environment:", "      TZ: ${TZ}"]
            if let b = stack.bookmark, c.service == stack.containers.first?.service {
                lines.append("    labels:")
                for change in b.labelChanges { if let v = change.value { lines.append("      - \(change.key)=\(v)") } }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static let env = "TZ=Europe/Dublin\nTS_IP=100.100.40.7\nPUID=1000\nPGID=1000\n"

    // MARK: the fake shell

    /// The Mac's demo terminal script, generated from `DemoShell`'s table (iOS answers from the same table in-process).
    static var shellScript: String { DemoShell.bashScript }
}

// MARK: - The transport

/// Answers every command the app sends with canned, realistic data, and streams fake progress. Never touches the network.
public final class DemoTransport: SSHTransport, @unchecked Sendable {
    private let profile: DemoProfile
    private let updates = DemoUpdatesTransport()
    private let lock = NSLock()
    private var lastPoll = Date()
    private var cpuTotal: Int64 = 3_400_000_000
    private var cpuIdle: Int64 = 2_300_000_000
    private let started = Date()

    public init(profile: DemoProfile) { self.profile = profile }

    public func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        if command == ServerSession.overviewCommand { return CommandResult(stdout: overview()) }
        if command == DockerSession.command { return CommandResult(stdout: docker()) }
        if command == ServicesSession.command { return CommandResult(stdout: DemoServices.output(for: profile)) }
        if command == DockerStatesSession.command { return CommandResult(stdout: dockerStates()) }
        if let status = DemoServices.read(command) { return CommandResult(stdout: status) }
        if command == UpdatesSession.command || command.contains("apt-get") && !command.contains("autoremove") { return try await updates.run(command, timeout: timeout) }
        if command.contains("/proc/sys/kernel/random/boot_id") && command.count < 80 { return CommandResult(stdout: "demo-boot-1\n") }
        // A save also starts with F='...', so it is recognised first; nothing is kept, the editor takes the new text as saved.
        if command.contains("##saved") { return CommandResult(stdout: "##saved\n" + sha(DemoData.env) + "\n") }
        if command.hasPrefix("F='") || command.contains("F='") && command.contains("##meta") { return fileRead(command) }
        if command.contains("##created") { return CommandResult(stdout: "##created\n") }
        if command.contains("docker compose") && command.contains("config -q") { return CommandResult(stdout: "") }
        if command.contains("docker manifest inspect") { return CommandResult(stdout: "found\n") }
        if command == RemoteFiles.homeCommand { return CommandResult(stdout: DemoFiles.home + "\n") }
        if let listing = DemoFiles.answer(for: command) { return CommandResult(stdout: listing) }
        if command.contains("ss -H -tln") { return CommandResult(stdout: DemoLibrary.listening) }
        if let output = DemoLibrary.output(for: command, profile: profile) { return CommandResult(stdout: output) }
        return CommandResult(stdout: "")
    }

    public func stream(_ command: String) -> AsyncThrowingStream<String, Error> {
        if command.contains("apt-get") { return updates.stream(command) }
        let lines: [String]
        let live: Bool
        if command.contains("docker logs -f") {
            lines = DemoLibrary.logLines(count: 90)
            live = true
        } else {
            lines = DemoServices.streamLines(command) ?? DemoLibrary.streamLines(for: command, profile: profile)
            live = false
        }
        let wrapped = command.contains(StreamedCommand.marker)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for line in lines {
                    try? await Task.sleep(for: .milliseconds(live ? 4 : 140))
                    if Task.isCancelled { break }
                    continuation.yield(line + "\r\n")
                }
                if live {
                    // Keep following: one new line a second until the log view is closed.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(1100))
                        if Task.isCancelled { break }
                        continuation.yield(DemoLibrary.logLines(count: 1)[0] + "\r\n")
                    }
                } else if wrapped {
                    continuation.yield("\r\n\(StreamedCommand.marker)0\r\n")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: pieces

    private func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    private func fileRead(_ command: String) -> CommandResult {
        guard let start = command.range(of: "F='"), let end = command[start.upperBound...].firstIndex(of: "'") else { return CommandResult(stdout: "##missing\n") }
        let path = String(command[start.upperBound..<end])
        let content: String
        if path.hasSuffix("/.env") {
            content = DemoData.env
        } else if let stack = profile.stacks.first(where: { path.hasPrefix($0.dir + "/") }) {
            content = DemoData.compose(for: stack)
        } else {
            return CommandResult(stdout: "##missing\n")
        }
        let b64 = Data(content.utf8).base64EncodedString()
        return CommandResult(stdout: "##meta\n1791615000 644 root:root\n##sha256\n\(sha(content))\n##content\n\(b64)\n")
    }

    private func overview() -> String {
        let now = Date()
        let busy = 0.26 + 0.14 * sin(now.timeIntervalSince(started) / 7)
        let (total, idle): (Int64, Int64) = lock.withLock {
            let dt = max(0.1, now.timeIntervalSince(lastPoll))
            lastPoll = now
            let ticks = Int64(dt * Double(profile.cores) * 100)
            cpuTotal += ticks
            cpuIdle += Int64(Double(ticks) * (1 - busy))
            return (cpuTotal, cpuIdle)
        }
        let user = Int64(Double(total - idle) * 0.7), system = (total - idle) - user
        let memAvail = Int(Double(profile.memTotalKB) * (1 - profile.memUsedFraction - 0.01 * sin(now.timeIntervalSince(started) / 11)))
        let used = Int64(Double(profile.diskTotal) * profile.diskUsedFraction)
        let unhealthy = profile.stacks.flatMap { s in s.containers.filter { $0.health == "unhealthy" }.map(\.service) }
        let t = Int64(now.timeIntervalSince1970)
        return """
        ##hostname
        \(profile.hostname)
        ##os
        PRETTY_NAME="\(profile.prettyName)"
        NAME="\(profile.prettyName.hasPrefix("Debian") ? "Debian GNU/Linux" : "Ubuntu")"
        VERSION_ID="\(profile.versionID)"
        ID=\(profile.prettyName.hasPrefix("Debian") ? "debian" : "ubuntu")
        ##uptime
        \(profile.uptimeDays * 86400 + now.timeIntervalSince(started)) 1000000.00
        ##loadavg
        \(String(format: "%.2f", busy * Double(profile.cores) * 0.6)) 0.51 0.48 1/312 12345
        ##nproc
        \(profile.cores)
        ##stat
        cpu  \(user) 0 \(system) \(idle) 0 0 0 0 0 0
        ##meminfo
        MemTotal:        \(profile.memTotalKB) kB
        MemAvailable:    \(memAvail) kB
        ##df
        Filesystem        1-blocks        Used   Available Capacity Mounted on
        /dev/nvme0n1p2 \(profile.diskTotal) \(used) \(profile.diskTotal - used) \(Int(profile.diskUsedFraction * 100))% /
        /dev/nvme0n1p1    1073741824     6291456  1067450368       1% /boot/efi
        ##system
        vendor=\(profile.vendor)
        product=\(profile.product)
        machine_id=\(profile.machineID)
        kernel=\(profile.kernel)
        boot_id=demo-boot-1
        time=\(t) +0000 UTC
        ip=\(profile.ip)
        tailscale_ip=\(profile.tailscaleIP ?? "")
        ##reboot
        \(profile.rebootRequired ? "yes" : "no")
        ##updates
        \(profile.updates)
        ##security
        \(profile.security)
        ##unhealthy
        \(unhealthy.joined(separator: "\n"))
        """
    }

    /// The light container check for alerts, from the same made-up containers as the Docker poll.
    private func dockerStates() -> String {
        var rows: [String] = []
        for stack in profile.stacks {
            for c in stack.containers {
                let id = String(SHA256.hash(data: Data("\(stack.name)/\(c.service)".utf8)).map { String(format: "%02x", $0) }.joined())
                rows.append([id, "\(stack.name)-\(c.service)-1", c.running ? "running" : "exited", c.status, stack.name,
                             c.service == stack.containers.first?.service ? (stack.bookmark?.href ?? "") : ""].joined(separator: "\t"))
            }
        }
        for c in profile.standalone {
            let id = String(SHA256.hash(data: Data("standalone/\(c.service)".utf8)).map { String(format: "%02x", $0) }.joined())
            rows.append([id, c.service, c.running ? "running" : "exited", c.status, "", ""].joined(separator: "\t"))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private func docker() -> String {
        func id(_ stack: String, _ service: String) -> String {
            String(SHA256.hash(data: Data("\(stack)/\(service)".utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
        }
        let phase = Date().timeIntervalSince(started) / 5
        var ps: [String] = [], stats: [String] = []
        for stack in profile.stacks {
            for c in stack.containers {
                let cid = id(stack.name, c.service)
                var labels = ["com.docker.compose.project=\(stack.name)", "com.docker.compose.project.working_dir=\(stack.dir)",
                              "com.docker.compose.project.config_files=\(stack.dir)/compose.yaml", "com.docker.compose.service=\(c.service)"]
                if let b = stack.bookmark, c.service == stack.containers.first?.service {
                    labels += b.labelChanges.compactMap { change in change.value.map { "\(change.key)=\($0)" } }
                }
                let row: [String: Any] = ["ID": cid, "Image": c.image, "Names": "\(stack.name)-\(c.service)-1", "State": c.running ? "running" : "exited",
                                          "Status": c.status, "HealthStatus": c.health == "none" ? "" : c.health, "Ports": c.ports,
                                          "Labels": labels.joined(separator: ",")]
                ps.append(json(row))
                let cpu = max(0, c.cpu * (1 + 0.3 * sin(phase + Double(cid.hashValue % 7))))
                stats.append(json(["ID": cid, "Name": "\(stack.name)-\(c.service)-1", "CPUPerc": String(format: "%.2f%%", cpu),
                                   "MemUsage": String(format: "%.1fMiB / %.2fGiB", c.memMB, Double(profile.memTotalKB) / 1_048_576)]))
            }
        }
        for c in profile.standalone {
            let cid = id("standalone", c.service)
            ps.append(json(["ID": cid, "Image": c.image, "Names": c.service, "State": c.running ? "running" : "exited", "Status": c.status,
                            "HealthStatus": c.health == "none" ? "" : c.health, "Ports": c.ports, "Labels": ""]))
            if c.running {
                stats.append(json(["ID": cid, "Name": c.service, "CPUPerc": String(format: "%.2f%%", c.cpu),
                                   "MemUsage": String(format: "%.1fMiB / %.2fGiB", c.memMB, Double(profile.memTotalKB) / 1_048_576)]))
            }
        }
        return "##docker\nok\n##ps\n" + ps.joined(separator: "\n") + "\n##stats\n" + stats.joined(separator: "\n") + "\n"
    }

    private func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
    }
}
