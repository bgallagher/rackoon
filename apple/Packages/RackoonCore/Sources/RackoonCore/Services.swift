import Foundation

// Service discovery: what runs on a server outside Docker. One read-only command (spec `services`) lists every loaded
// systemd service (the system's and the ssh user's own `--user` ones), the listening TCP sockets and, for each listening
// process, its command line and cgroup. The cgroup ties a port to its unit, and tells a process started by hand (in a login
// session, like `npx paperclipai`) from one a unit runs. Containers are left to the Docker screen.
//
// `ServicesParser.scan` reads the text as it is; `ServicesParser.parse` turns it into the services a person cares about
// (`ServiceDiscovery`), named from `ServiceCatalog` and with OS plumbing (dbus, getty, udev...) hidden by default.

// MARK: - The raw reading

/// One systemd service unit as `systemctl show` reports it.
public struct SystemdUnit: Sendable, Codable, Equatable {
    /// The unit's full name, `tailscaled.service` or `code-server@alice.service`.
    public var name: String
    public var description: String = ""
    public var loadState: String = ""
    /// active, reloading, inactive, failed, activating, deactivating.
    public var activeState: String = ""
    /// running, exited, dead, failed, auto-restart, ...
    public var subState: String = ""
    /// success, exit-code, signal, core-dump, timeout, ...
    public var result: String = ""
    /// enabled, disabled, static, indirect, generated, ...
    public var unitFileState: String = ""
    public var fragmentPath: String = ""
    /// simple, forking, oneshot, notify, ...
    public var type: String = ""
    public var mainPID: Int?
    /// When it last became active, in microseconds since boot (compare with the uptime).
    public var activeEnterMonotonic: UInt64?
    public var memoryBytes: Int64?
    public var restarts: Int?

    public init(name: String) { self.name = name }
}

/// A listening TCP socket from `ss -H -tlnp`. Processes are only known for the ssh user's own (all of them for root).
public struct ListeningSocket: Sendable, Codable, Equatable {
    public var address: String
    public var port: Int
    /// The processes holding it: (`comm` name, pid), in the order ss lists them.
    public var processes: [Owner]

    public struct Owner: Sendable, Codable, Equatable {
        public var name: String
        public var pid: Int
    }
}

/// A listening process: its command line (NULs as spaces, cut at 300 bytes) and its cgroup path.
public struct ListeningProcess: Sendable, Codable, Equatable {
    public var pid: Int
    public var commandLine: String
    public var cgroup: String
}

public struct ServicesScan: Sendable, Equatable {
    public var uptime: Double?
    public var isRoot = false
    public var system: [SystemdUnit] = []
    public var user: [SystemdUnit] = []
    public var sockets: [ListeningSocket] = []
    public var processes: [ListeningProcess] = []
}

// MARK: - What the app shows

/// An address and port a service listens on.
public struct ServicePort: Sendable, Codable, Equatable, Hashable {
    /// As ss reports it, without brackets or an interface: `0.0.0.0`, `::`, `*`, `127.0.0.1`, `100.64.0.10`.
    public var address: String
    public var port: Int

    public init(address: String, port: Int) {
        self.address = address
        self.port = port
    }

    public var isLoopback: Bool { address.hasPrefix("127.") || address == "::1" || address == "localhost" }
    public var isWildcard: Bool { ["0.0.0.0", "::", "*", ""].contains(address) }

    /// Ports that are almost never a web page (ssh, DNS, mail, databases, file sharing, VPN, Beszel's agent), so they get
    /// no link.
    static let nonWeb: Set<Int> = [21, 22, 23, 25, 53, 110, 111, 139, 143, 389, 445, 465, 587, 636, 853, 993, 995, 1194, 1883, 2049,
                                   3306, 3478, 5353, 5432, 6379, 8883, 11211, 27017, 41641, 45876, 51820]

    public var isLikelyWeb: Bool { !Self.nonWeb.contains(port) }

    /// The host to open this port on from the Mac: the server's preferred address (its Tailscale IP, else its LAN IP)
    /// when it listens everywhere, the address itself when it listens on one, nil when only the server can reach it.
    public func linkHost(preferred: String?) -> String? {
        if isLoopback { return nil }
        if isWildcard { return preferred }
        return address.contains(":") ? "[\(address)]" : address
    }

    /// How reachable it is, for keeping one entry per port: everywhere, then one address, then loopback.
    var reach: Int { isWildcard ? 2 : (isLoopback ? 0 : 1) }
}

/// A service found on a server: a systemd unit (system or the ssh user's), or a listening process no unit runs.
public struct DiscoveredService: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable { case system, user, process }
    public enum Status: String, Sendable, Codable { case running, starting, restarting, stopping, stopped, failed }

    /// `system/<unit>`, `user/<unit>` or `process/<name>`: stable across scans, so a choice made for it sticks.
    public var id: String
    public var kind: Kind
    /// The systemd unit (system and user kinds).
    public var unit: String?
    /// What the tile is titled: the product's name when it is a known one, else the unit or process name.
    public var name: String
    /// The unit's description, or the process's command line.
    public var detail: String
    /// The `ServiceCatalog` product it was recognised as.
    public var product: String?
    public var status: Status
    /// systemd's sub state (`running`, `auto-restart`, `dead`...); "running" for a process.
    public var subState: String
    /// systemd's result when it is not `success` (`exit-code`, `signal`, `core-dump`...).
    public var result: String?
    /// Whether it starts at boot; nil when that does not apply (static units, processes).
    public var enabledAtBoot: Bool?
    /// How long it has been running, in seconds, when known.
    public var activeSeconds: Double?
    public var memoryBytes: Int64?
    public var restarts: Int
    public var ports: [ServicePort]
    /// The unit file, or the program a process runs.
    public var path: String?
    /// Part of the operating system rather than something the user set up (dbus, getty, udev...).
    public var isPlumbing: Bool
    public var visibleByDefault: Bool

    public var isProblem: Bool { status == .failed || status == .restarting }
    public var isRunning: Bool { status == .running }

    /// The words a search matches: name, unit, product, description or command, ports.
    public func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = ([name, unit ?? "", product ?? "", detail, path ?? ""] + ports.map { String($0.port) }).joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

public struct ServicesSnapshot: Sendable, Codable, Equatable {
    /// Sorted by name.
    public var services: [DiscoveredService]
    /// The ssh user is root, so every process's ports are known (otherwise only the user's own).
    public var isRoot: Bool
    /// systemctl answered: Unraid and some containers have no systemd, and only processes are listed there.
    public var hasSystemd: Bool

    public init(services: [DiscoveredService], isRoot: Bool, hasSystemd: Bool) {
        self.services = services
        self.isRoot = isRoot
        self.hasSystemd = hasSystemd
    }
}

// MARK: - Known products and OS plumbing

/// A product Rackoon recognises by its unit or process name, with a proper name and an icon.
public struct ServiceProduct: Sendable, Equatable {
    public var id: String
    public var name: String
    /// An icon name in the icon collections (dashboard-icons or selfh.st); nil to guess from the name.
    public var icon: String?
    /// Unit or process base names (lower-case, no `.service`, no `@instance`, `_` written `-`).
    public var names: [String]
    public var prefixes: [String]
    /// Shown only when asked (always-there infrastructure such as ssh and containerd).
    public var hiddenByDefault: Bool

    public init(_ id: String, _ name: String, icon: String? = nil, names: [String], prefixes: [String] = [], hiddenByDefault: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.names = names
        self.prefixes = prefixes
        self.hiddenByDefault = hiddenByDefault
    }
}

/// Mirrors spec/service-catalog.json (the source of truth the other cores read at runtime): edit the spec first, then
/// these constants; `ServicesTests.testCatalogMatchesTheSpecFile` holds them equal.
public enum ServiceCatalog {
    public static let products: [ServiceProduct] = [
        ServiceProduct("tailscale", "Tailscale", icon: "tailscale", names: ["tailscaled", "tailscale"]),
        ServiceProduct("wazuh-agent", "Wazuh agent", icon: "wazuh", names: ["wazuh-agent"]),
        ServiceProduct("wazuh-manager", "Wazuh manager", icon: "wazuh", names: ["wazuh-manager"]),
        ServiceProduct("wazuh-indexer", "Wazuh indexer", icon: "wazuh", names: ["wazuh-indexer"]),
        ServiceProduct("wazuh-dashboard", "Wazuh dashboard", icon: "wazuh", names: ["wazuh-dashboard"]),
        ServiceProduct("beszel-agent", "Beszel agent", icon: "beszel", names: ["beszel-agent"]),
        ServiceProduct("beszel", "Beszel hub", icon: "beszel", names: ["beszel", "beszel-hub"]),
        ServiceProduct("pi-hole", "Pi-hole", icon: "pi-hole", names: ["pihole-ftl", "pihole", "pi-hole"]),
        ServiceProduct("hermes-gateway", "Hermes Agent gateway", icon: "hermes", names: ["hermes-gateway"]),
        ServiceProduct("hermes", "Hermes Agent", icon: "hermes", names: ["hermes", "hermes-agent"]),
        ServiceProduct("paperclip", "Paperclip", names: ["paperclip", "paperclipai"]),
        ServiceProduct("github-runner", "GitHub Actions runner", icon: "github", names: ["github-runner"], prefixes: ["actions.runner."]),
        ServiceProduct("gitlab-runner", "GitLab runner", icon: "gitlab", names: ["gitlab-runner"]),
        ServiceProduct("code-server", "code-server", icon: "code-server", names: ["code-server"]),
        ServiceProduct("docker", "Docker Engine", icon: "docker", names: ["docker", "dockerd"]),
        ServiceProduct("containerd", "containerd", names: ["containerd"], hiddenByDefault: true),
        ServiceProduct("ssh", "OpenSSH server", names: ["ssh", "sshd"], hiddenByDefault: true),
        ServiceProduct("nginx", "nginx", icon: "nginx", names: ["nginx"]),
        ServiceProduct("caddy", "Caddy", icon: "caddy", names: ["caddy"]),
        ServiceProduct("apache", "Apache HTTP Server", icon: "apache", names: ["apache2", "httpd"]),
        ServiceProduct("haproxy", "HAProxy", icon: "haproxy", names: ["haproxy"]),
        ServiceProduct("traefik", "Traefik", icon: "traefik", names: ["traefik"]),
        ServiceProduct("postgresql", "PostgreSQL", icon: "postgresql", names: ["postgresql", "postgres"]),
        ServiceProduct("mysql", "MySQL", icon: "mysql", names: ["mysql", "mysqld"]),
        ServiceProduct("mariadb", "MariaDB", icon: "mariadb", names: ["mariadb", "mariadbd"]),
        ServiceProduct("redis", "Redis", icon: "redis", names: ["redis-server", "redis"]),
        ServiceProduct("mongodb", "MongoDB", icon: "mongodb", names: ["mongod", "mongodb"]),
        ServiceProduct("cloudflared", "Cloudflare Tunnel", icon: "cloudflare", names: ["cloudflared"]),
        ServiceProduct("wireguard", "WireGuard", icon: "wireguard", names: ["wg-quick", "wireguard"]),
        ServiceProduct("openvpn", "OpenVPN", icon: "openvpn", names: ["openvpn-server", "openvpn-client"]),
        ServiceProduct("zerotier", "ZeroTier", icon: "zerotier", names: ["zerotier-one"]),
        ServiceProduct("netbird", "NetBird", icon: "netbird", names: ["netbird"]),
        ServiceProduct("headscale", "Headscale", icon: "headscale", names: ["headscale"]),
        ServiceProduct("crowdsec", "CrowdSec", icon: "crowdsec", names: ["crowdsec", "crowdsec-firewall-bouncer"]),
        ServiceProduct("fail2ban", "Fail2ban", icon: "fail2ban", names: ["fail2ban"]),
        ServiceProduct("netdata", "Netdata", icon: "netdata", names: ["netdata"]),
        ServiceProduct("prometheus", "Prometheus", icon: "prometheus", names: ["prometheus"]),
        ServiceProduct("node-exporter", "Node exporter", icon: "prometheus", names: ["prometheus-node-exporter", "node-exporter"]),
        ServiceProduct("grafana", "Grafana", icon: "grafana", names: ["grafana-server", "grafana"]),
        ServiceProduct("loki", "Loki", icon: "loki", names: ["loki"]),
        ServiceProduct("promtail", "Promtail", icon: "loki", names: ["promtail"]),
        ServiceProduct("uptime-kuma", "Uptime Kuma", icon: "uptime-kuma", names: ["uptime-kuma"]),
        ServiceProduct("syncthing", "Syncthing", icon: "syncthing", names: ["syncthing"]),
        ServiceProduct("samba", "Samba", names: ["smbd", "nmbd", "samba"]),
        ServiceProduct("nfs", "NFS server", names: ["nfs-server", "nfs-kernel-server"]),
        ServiceProduct("jellyfin", "Jellyfin", icon: "jellyfin", names: ["jellyfin"]),
        ServiceProduct("plex", "Plex", icon: "plex", names: ["plexmediaserver", "plex-media-server"]),
        ServiceProduct("home-assistant", "Home Assistant", icon: "home-assistant", names: ["home-assistant", "homeassistant"]),
        ServiceProduct("node-red", "Node-RED", icon: "node-red", names: ["node-red", "nodered"]),
        ServiceProduct("mosquitto", "Mosquitto", icon: "mosquitto", names: ["mosquitto"]),
        ServiceProduct("ollama", "Ollama", icon: "ollama", names: ["ollama"]),
        ServiceProduct("cockpit", "Cockpit", icon: "cockpit", names: ["cockpit"]),
        ServiceProduct("webmin", "Webmin", icon: "webmin", names: ["webmin"]),
        ServiceProduct("unbound", "Unbound", icon: "unbound", names: ["unbound"]),
        ServiceProduct("adguard-home", "AdGuard Home", icon: "adguard-home", names: ["adguardhome", "adguard-home"]),
        ServiceProduct("minio", "MinIO", icon: "minio", names: ["minio"]),
        ServiceProduct("k3s", "k3s", names: ["k3s", "k3s-agent"]),
        ServiceProduct("gitea", "Gitea", icon: "gitea", names: ["gitea"]),
        ServiceProduct("forgejo", "Forgejo", icon: "forgejo", names: ["forgejo"]),
        ServiceProduct("jenkins", "Jenkins", icon: "jenkins", names: ["jenkins"]),
        ServiceProduct("vault", "Vault", icon: "vault", names: ["vault"]),
        ServiceProduct("consul", "Consul", icon: "consul", names: ["consul"]),
        ServiceProduct("nomad", "Nomad", icon: "nomad", names: ["nomad"]),
        ServiceProduct("tor", "Tor", icon: "tor", names: ["tor"]),
        ServiceProduct("frigate", "Frigate", icon: "frigate", names: ["frigate"]),
        ServiceProduct("zigbee2mqtt", "Zigbee2MQTT", icon: "zigbee2mqtt", names: ["zigbee2mqtt"]),
        ServiceProduct("ntfy", "ntfy", icon: "ntfy", names: ["ntfy"]),
        ServiceProduct("gotify", "Gotify", icon: "gotify", names: ["gotify"]),
        ServiceProduct("authelia", "Authelia", icon: "authelia", names: ["authelia"]),
        ServiceProduct("restic", "restic", icon: "restic", names: ["restic", "restic-rest-server", "rest-server"]),
        ServiceProduct("borg", "Borg", icon: "borg", names: ["borgmatic", "borg"]),
    ]

    /// The operating system's own services: always there, rarely interesting, hidden by default (still listed under
    /// Hidden, and a failed one is always shown).
    static let plumbing: Set<String> = [
        "dbus", "dbus-broker", "getty", "serial-getty", "user", "user-runtime-dir", "polkit", "udisks2", "upower", "modemmanager",
        "networkmanager", "networkmanager-wait-online", "networkmanager-dispatcher", "networkd-dispatcher", "wpa-supplicant",
        "bluetooth", "avahi-daemon", "cups", "cups-browsed", "rtkit-daemon", "iio-sensor-proxy", "bolt", "fwupd", "thermald",
        "rsyslog", "syslog", "cron", "crond", "anacron", "atd", "chrony", "chronyd", "ntp", "ntpd", "ntpsec", "irqbalance",
        "multipathd", "snapd", "packagekit", "accounts-daemon", "colord", "gdm", "gdm3", "lightdm", "sddm", "display-manager",
        "power-profiles-daemon", "switcheroo-control", "kerneloops", "whoopsie", "apport", "unattended-upgrades", "rpcbind",
        "rpc-statd", "rpc-statd-notify", "open-vm-tools", "vgauth", "qemu-guest-agent", "console-setup", "keyboard-setup",
        "setvtrgb", "apparmor", "ufw", "mdmonitor", "pipewire", "pipewire-pulse", "wireplumber", "filter-chain", "mpris-proxy",
        "haveged", "rngd", "kdump-tools", "sysstat", "netplan-configure", "dracut-shutdown", "alsa-restore", "alsa-state",
        "tuned", "auditd", "mcelog", "acpid", "gpu-manager", "smartmontools", "smartd", "wtmpdb-update-boot", "gpg-agent",
        "ssh-agent", "p11-kit-server", "obex", "speech-dispatcher", "pulseaudio", "rtkit", "low-memory-monitor",
        "blk-availability", "emergency", "rescue", "lxd-agent", "hv-kvp-daemon", "iscsid", "open-iscsi", "finalrd",
    ]
    static let plumbingPrefixes = ["systemd-", "plymouth", "getty", "gnome-", "xdg-", "at-spi", "cloud-", "lvm2-", "apt-", "dpkg-",
                                   "snap.", "ubuntu-", "motd-", "e2scrub", "fstrim", "logrotate", "man-db", "dbus-", "evolution-",
                                   "tracker-", "gvfs-", "pipewire-", "wireplumber", "grub-", "secureboot-", "esm-"]
    /// Listening programs that belong to the system or to Docker, when no unit tells (a server without systemd).
    static let plumbingProcesses: Set<String> = ["sshd", "systemd-resolve", "systemd-resolved", "cupsd", "avahi-daemon", "rpcbind",
                                                 "chronyd", "docker-proxy", "dockerd", "containerd", "rpc.statd", "dhclient"]

    /// Programs that publish a container's ports or run it (Docker, Podman). On a server without systemd their cgroup
    /// doesn't say "docker", so they are recognised by name and left to the Docker screen.
    static let containerHelpers = ["docker-proxy", "containerd-shim", "rootlesskit", "rootlessport", "slirp4netns", "conmon"]

    static func isContainerHelper(_ name: String) -> Bool {
        let n = name.lowercased()
        return containerHelpers.contains { n.hasPrefix($0) }
    }

    /// A unit or process name in the form products are listed by: lower-case, no `.service`, no `@instance`, `_` as `-`.
    public static func baseName(_ name: String) -> String {
        var n = name.lowercased()
        if n.hasSuffix(".service") { n.removeLast(".service".count) }
        if let at = n.firstIndex(of: "@") { n = String(n[..<at]) }
        return n.replacingOccurrences(of: "_", with: "-")
    }

    public static func product(for name: String) -> ServiceProduct? {
        let base = baseName(name)
        return products.first { p in p.names.contains(base) || p.prefixes.contains { base.hasPrefix($0) } }
    }

    public static func isPlumbing(_ name: String) -> Bool {
        let base = baseName(name)
        return plumbing.contains(base) || plumbingPrefixes.contains { base.hasPrefix($0) }
    }
}

// MARK: - Parsing

public enum ServicesParser {
    public static func parse(_ output: String) -> ServicesSnapshot {
        ServiceDiscovery.discover(scan(output))
    }

    public static func scan(_ output: String) -> ServicesScan {
        let sections = OverviewParser.splitSections(output)
        var scan = ServicesScan()
        scan.uptime = sections["uptime"]?.first.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        scan.isRoot = sections["uid"]?.first?.trimmingCharacters(in: .whitespaces) == "0"
        scan.system = units(sections["system"] ?? [])
        scan.user = units(sections["user"] ?? [])
        scan.sockets = (sections["listen"] ?? []).compactMap(socket)
        scan.processes = (sections["procs"] ?? []).compactMap(process)
        return scan
    }

    /// `systemctl show` prints one `Key=value` block per unit, in its own key order; a block starts at `Id=`.
    static func units(_ lines: [String]) -> [SystemdUnit] {
        var out: [SystemdUnit] = []
        var current: SystemdUnit?
        for line in lines {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]), value = String(line[line.index(after: eq)...])
            if key == "Id" {
                if let c = current { out.append(c) }
                current = SystemdUnit(name: value)
                continue
            }
            guard current != nil else { continue }
            switch key {
            case "Description": current!.description = value
            case "LoadState": current!.loadState = value
            case "ActiveState": current!.activeState = value
            case "SubState": current!.subState = value
            case "Result": current!.result = value
            case "UnitFileState": current!.unitFileState = value
            case "FragmentPath": current!.fragmentPath = value
            case "Type": current!.type = value
            case "MainPID": current!.mainPID = Int(value).flatMap { $0 > 0 ? $0 : nil }
            case "ActiveEnterTimestampMonotonic": current!.activeEnterMonotonic = UInt64(value).flatMap { $0 > 0 ? $0 : nil }
            case "NRestarts": current!.restarts = Int(value)
            case "MemoryCurrent":
                // "[not set]" without memory accounting; UINT64_MAX ("infinity") on some versions.
                if let n = UInt64(value), n < UInt64(Int64.max) { current!.memoryBytes = Int64(n) }
            default: break
            }
        }
        if let c = current { out.append(c) }
        return out
    }

    /// `LISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=1001,fd=6),...)`. The local address is the first
    /// `address:port` column; IPv6 comes in brackets and an address may carry `%interface`.
    static func socket(_ line: String) -> ListeningSocket? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let local = fields.first(where: { $0.contains(":") && !$0.hasPrefix("users:") }),
              let colon = local.lastIndex(of: ":"), let port = Int(local[local.index(after: colon)...]) else { return nil }
        var address = String(local[..<colon])
        if address.hasPrefix("["), address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
        if let pct = address.firstIndex(of: "%") { address = String(address[..<pct]) }
        var owners: [ListeningSocket.Owner] = []
        if let users = line.range(of: "users:(") {
            let rest = String(line[users.upperBound...])
            for part in rest.components(separatedBy: "(\"").dropFirst() {
                guard let endName = part.firstIndex(of: "\"") else { continue }
                let name = String(part[..<endName])
                guard let pidRange = part.range(of: "pid=") else { continue }
                let digits = part[pidRange.upperBound...].prefix { $0.isNumber }
                if let pid = Int(digits) { owners.append(.init(name: name, pid: pid)) }
            }
        }
        return ListeningSocket(address: address, port: port, processes: owners)
    }

    /// `<pid>\t<command line>\t<cgroup>`.
    static func process(_ line: String) -> ListeningProcess? {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let pid = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        return ListeningProcess(pid: pid, commandLine: parts[1].trimmingCharacters(in: .whitespaces),
                                cgroup: parts[2].trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - From a reading to services

public enum ServiceDiscovery {
    /// Where a listening process lives, from its cgroup path.
    enum Home: Equatable {
        case container
        case systemUnit(String)
        /// A unit of a user's own systemd (`user@1000.service/app.slice/x.service`).
        case userUnit(String)
        /// Anything else: a login session (`session-12.scope`), the root cgroup on a server without systemd...
        case loose(String)
    }

    static func home(of cgroup: String) -> Home {
        let lower = cgroup.lowercased()
        if lower.contains("docker") || lower.contains("containerd") || lower.contains("libpod") || lower.contains("kubepods")
            || lower.contains("/lxc") {
            return .container
        }
        let parts = cgroup.split(separator: "/").map(String.init)
        if let unit = parts.last(where: { $0.hasSuffix(".service") }) {
            // user@1000.service is the user's systemd itself; a unit below it is one of theirs.
            if unit.hasPrefix("user@") { return .loose(cgroup) }
            let underUser = parts.contains { $0.hasPrefix("user@") && $0.hasSuffix(".service") }
            return underUser ? .userUnit(unit) : .systemUnit(unit)
        }
        return .loose(cgroup)
    }

    /// Interpreters and launchers: the program they run says more than their own name. (spec/service-catalog.json)
    static let interpreters = ["node", "nodejs", "python", "java", "ruby", "php", "perl", "bun", "deno", "sh", "bash", "dotnet",
                               "npm", "npx", "uv", "uvx", "pnpm", "yarn", "mono", "pwsh", "env"]
    /// Databases and caches an app starts for itself: grouped with that app when it is the only other thing in its session.
    static let helpers: Set<String> = ["postgres", "postgresql", "redis-server", "redis", "mysqld", "mariadbd", "mongod", "memcached"]

    /// A process's name: its own (`comm`), or for an interpreter the script it runs (`node .../paperclipai` -> paperclipai).
    static func processName(comm: String, commandLine: String) -> String {
        var name = comm.lowercased()
        if let dash = name.range(of: "-mainthread") { name.removeSubrange(dash) }
        let isInterpreter = interpreters.contains { name == $0 || (name.hasPrefix($0) && name.dropFirst($0.count).allSatisfy { $0.isNumber || $0 == "." }) }
        guard isInterpreter else { return comm }
        var args = commandLine.split(separator: " ").map(String.init)
        if !args.isEmpty { args.removeFirst() }
        for arg in args {
            if arg == "-c" || arg == "-e" { break }   // inline code: nothing to name it after
            if arg.hasPrefix("-") { continue }
            var base = (arg as NSString).lastPathComponent
            for ext in [".js", ".mjs", ".cjs", ".ts", ".py", ".rb", ".php", ".pl", ".jar", ".sh"] where base.hasSuffix(ext) {
                base.removeLast(ext.count)
            }
            if !base.isEmpty, base != "index", base != "main", base != "server" { return base }
        }
        return comm
    }

    public static func discover(_ scan: ServicesScan) -> ServicesSnapshot {
        let processByPID = Dictionary(scan.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        // Each socket's ports go to the unit or loose process that holds them.
        var unitPorts: [String: [ServicePort]] = [:]        // "system/<unit>" or "user/<unit>"
        var loose: [Int: (comm: String, ports: [ServicePort])] = [:]
        var looseOrder: [Int] = []
        for socket in scan.sockets {
            let port = ServicePort(address: socket.address, port: socket.port)
            for owner in socket.processes where !ServiceCatalog.isContainerHelper(owner.name) {
                guard let proc = processByPID[owner.pid] else { continue }
                switch home(of: proc.cgroup) {
                case .container: continue
                case .systemUnit(let u): unitPorts["system/" + u, default: []].append(port)
                case .userUnit(let u):
                    // Another user's unit (seen only as root): listed as a process named after its unit.
                    if scan.user.contains(where: { $0.name == u }) {
                        unitPorts["user/" + u, default: []].append(port)
                    } else {
                        if loose[owner.pid] == nil { looseOrder.append(owner.pid) }
                        loose[owner.pid, default: (ServicesParser.unitBase(u), [])].ports.append(port)
                    }
                case .loose:
                    if loose[owner.pid] == nil { looseOrder.append(owner.pid) }
                    loose[owner.pid, default: (owner.name, [])].ports.append(port)
                }
            }
        }

        var services: [DiscoveredService] = []
        for (kind, units) in [(DiscoveredService.Kind.system, scan.system), (.user, scan.user)] {
            for unit in units {
                guard let s = service(unit, kind: kind, uptime: scan.uptime,
                                      ports: unitPorts["\(kind.rawValue)/\(unit.name)"] ?? []) else { continue }
                services.append(s)
            }
        }
        services += processes(loose: loose, order: looseOrder, byPID: processByPID)
        services.sort { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
        return ServicesSnapshot(services: services, isRoot: scan.isRoot, hasSystemd: !scan.system.isEmpty)
    }

    /// One unit as a service, or nil when it is not worth listing: not found, masked, a one-shot that ran at boot and
    /// is done, or stopped and not meant to start at boot.
    static func service(_ unit: SystemdUnit, kind: DiscoveredService.Kind, uptime: Double?, ports: [ServicePort]) -> DiscoveredService? {
        guard unit.loadState == "loaded" else { return nil }
        let product = ServiceCatalog.product(for: unit.name)
        let status: DiscoveredService.Status
        switch unit.activeState {
        case "active", "reloading":
            if unit.subState == "exited", product == nil { return nil }
            status = .running
        case "activating": status = unit.subState == "auto-restart" ? .restarting : .starting
        case "deactivating": status = .stopping
        case "failed": status = .failed
        case "inactive":
            guard unit.unitFileState == "enabled", unit.type != "oneshot" else { return nil }
            status = .stopped
        default: return nil
        }
        let plumbing = ServiceCatalog.isPlumbing(unit.name)
        var active: Double?
        if status == .running, let uptime, let entered = unit.activeEnterMonotonic {
            active = max(0, uptime - Double(entered) / 1_000_000)
        }
        let enabled: Bool? = switch unit.unitFileState {
        case "enabled", "enabled-runtime": true
        case "disabled": false
        default: nil
        }
        let visible: Bool = if status == .failed || status == .restarting { true }
            else if let product { !product.hiddenByDefault }
            else { !plumbing }
        return DiscoveredService(
            id: "\(kind.rawValue)/\(unit.name)", kind: kind, unit: unit.name,
            name: product?.name ?? displayName(unit.name), detail: unit.description, product: product?.id,
            status: status, subState: unit.subState,
            result: unit.result.isEmpty || unit.result == "success" ? nil : unit.result,
            enabledAtBoot: enabled, activeSeconds: active, memoryBytes: unit.memoryBytes, restarts: unit.restarts ?? 0,
            ports: dedupe(ports), path: unit.fragmentPath.isEmpty ? nil : unit.fragmentPath,
            isPlumbing: plumbing && product == nil, visibleByDefault: visible)
    }

    /// `code-server@alice.service` -> "code-server (alice)", `beszel-agent.service` -> "beszel-agent".
    static func displayName(_ unit: String) -> String {
        var n = unit
        if n.hasSuffix(".service") { n.removeLast(".service".count) }
        if let at = n.firstIndex(of: "@") {
            let instance = n[n.index(after: at)...]
            n = String(n[..<at]) + (instance.isEmpty ? "" : " (\(instance))")
        }
        return n
    }

    /// Processes no unit runs. Those in one cgroup (a login session) that are only a database or cache beside one app
    /// are folded into that app, so `npx paperclipai` and its own postgres are one service.
    static func processes(loose: [Int: (comm: String, ports: [ServicePort])], order: [Int],
                          byPID: [Int: ListeningProcess]) -> [DiscoveredService] {
        struct Found { var pid: Int; var name: String; var proc: ListeningProcess; var ports: [ServicePort] }
        var found = order.compactMap { pid -> Found? in
            guard let entry = loose[pid], let proc = byPID[pid] else { return nil }
            return Found(pid: pid, name: processName(comm: entry.comm, commandLine: proc.commandLine), proc: proc, ports: entry.ports)
        }
        // Fold helpers into the one app sharing their cgroup.
        var folded = Set<Int>()
        for helper in found where helpers.contains(helper.name.lowercased()) {
            let apps = found.indices.filter { found[$0].proc.cgroup == helper.proc.cgroup && !helpers.contains(found[$0].name.lowercased()) }
            if apps.count == 1, helper.proc.cgroup != "/" {
                found[apps[0]].ports += helper.ports
                folded.insert(helper.pid)
            }
        }
        found.removeAll { folded.contains($0.pid) }
        // One program with several processes (nginx's master and workers) is one service.
        var merged: [Found] = []
        for f in found {
            if let i = merged.firstIndex(where: { $0.name.lowercased() == f.name.lowercased() && $0.proc.cgroup == f.proc.cgroup }) {
                merged[i].ports += f.ports
                // Named after the parent (the lowest pid, nginx's master), not a worker.
                if f.pid < merged[i].pid { merged[i].pid = f.pid; merged[i].proc = f.proc }
            } else {
                merged.append(f)
            }
        }
        found = merged

        var used: [String: Int] = [:]
        return found.map { f in
            let product = ServiceCatalog.product(for: f.name)
            let plumbing = ServiceCatalog.plumbingProcesses.contains(f.name.lowercased())
            let ports = dedupe(f.ports)
            var id = "process/" + f.name
            used[id, default: 0] += 1
            if used[id]! > 1 { id += ":" + (ports.first.map { String($0.port) } ?? String(f.pid)) }
            // Something started by hand in a login session is the user's own; a root-cgroup process on a server
            // without systemd is shown when it is a known product.
            let inSession = f.proc.cgroup.contains("session-") || f.proc.cgroup.contains("user.slice")
            let visible = !plumbing && (product.map { !$0.hiddenByDefault } ?? inSession)
            return DiscoveredService(
                id: id, kind: .process, unit: nil, name: product?.name ?? f.name, detail: f.proc.commandLine,
                product: product?.id, status: .running, subState: "running", result: nil, enabledAtBoot: nil,
                activeSeconds: nil, memoryBytes: nil, restarts: 0, ports: ports,
                path: f.proc.commandLine.split(separator: " ").first.map(String.init),
                isPlumbing: plumbing, visibleByDefault: visible)
        }
    }

    /// One entry per port, keeping the most reachable address, sorted by port.
    static func dedupe(_ ports: [ServicePort]) -> [ServicePort] {
        var best: [Int: ServicePort] = [:]
        for p in ports where (best[p.port]?.reach ?? -1) < p.reach { best[p.port] = p }
        return best.values.sorted { $0.port < $1.port }
    }
}

extension ServicesParser {
    /// `cloudflared.service` -> cloudflared (lower-case), "" for nil: a description that only repeats it says nothing.
    public static func displayBase(_ unit: String?) -> String { unitBase(unit ?? "").lowercased() }

    /// `hermes-gateway.service` -> hermes-gateway.
    static func unitBase(_ unit: String) -> String {
        unit.hasSuffix(".service") ? String(unit.dropLast(".service".count)) : unit
    }
}

// MARK: - Showing and hiding

/// Which services the user wants to see. Pure: the app keeps it and saves `overrides` as services/visibility.json.
/// Keys are `<server id>|<service id>` for one server and `*|<service id>` for every server; a server's own choice wins.
public struct ServiceVisibility: Sendable, Equatable {
    public private(set) var overrides: [String: Bool]
    public static let everywhere = "*"

    public init(_ overrides: [String: Bool] = [:]) { self.overrides = overrides }

    public static func key(server: String, service: String) -> String { "\(server)|\(service)" }

    public func isVisible(_ service: DiscoveredService, server: String) -> Bool {
        overrides[Self.key(server: server, service: service.id)]
            ?? overrides[Self.key(server: Self.everywhere, service: service.id)]
            ?? service.visibleByDefault
    }

    /// The user chose for this service on this server or everywhere (so "Reset" means something).
    public func isChosen(_ service: DiscoveredService, server: String) -> Bool {
        overrides[Self.key(server: server, service: service.id)] != nil
            || overrides[Self.key(server: Self.everywhere, service: service.id)] != nil
    }

    /// The choice made for this service on `server` alone (`everywhere` for the every-server rule), or nil.
    public func choice(_ service: String, server: String) -> Bool? { overrides[Self.key(server: server, service: service)] }

    /// `visible` nil goes back to the default. `everywhere` also drops each server's own choice for that service, so
    /// the new rule is what every server shows.
    public mutating func set(_ visible: Bool?, service: String, server: String, everywhere: Bool = false) {
        if everywhere {
            overrides = overrides.filter { !$0.key.hasSuffix("|" + service) }
            overrides[Self.key(server: Self.everywhere, service: service)] = visible
        } else {
            overrides[Self.key(server: server, service: service)] = visible
        }
    }

    /// A removed server's choices go with it. Returns whether anything changed.
    @discardableResult
    public mutating func forget(serverID: String) -> Bool {
        let before = overrides.count
        overrides = overrides.filter { !$0.key.hasPrefix(serverID + "|") }
        return overrides.count != before
    }
}

// MARK: - Icons

extension AppIconGuess {
    /// A service's icon: its product's icon when the collections have it, else a guess from its unit or process name.
    public static func iconID(for service: DiscoveredService, in catalog: IconCatalog?) -> String? {
        guard let catalog else { return nil }
        if let icon = service.product.flatMap({ id in ServiceCatalog.products.first { $0.id == id }?.icon }),
           let found = catalog.lookup(icon) {
            return found
        }
        if service.isPlumbing { return nil }
        let base = service.unit.map(ServiceCatalog.baseName) ?? ServiceCatalog.baseName(service.name)
        // tailscaled, sshd: a daemon is named after its product.
        var candidates = nameCandidates(base)
        if base.hasSuffix("d"), base.count > 4 { candidates.append(String(base.dropLast())) }
        return match(candidates, in: catalog)
    }
}

// MARK: - Session

public struct ServicesFailure: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Reads a server's services on demand. Keeps the last good reading when a read fails.
public actor ServicesSession {
    public static let command = #"""
    echo '##uptime'; cut -d' ' -f1 /proc/uptime; echo '##uid'; id -u; \#
    P=Id,Description,LoadState,ActiveState,SubState,Result,UnitFileState,FragmentPath,Type,MainPID,ActiveEnterTimestampMonotonic,MemoryCurrent,NRestarts; \#
    echo '##system'; systemctl show --no-pager -p "$P" '*.service' 2>/dev/null; \#
    echo '##user'; systemctl --user show --no-pager -p "$P" '*.service' 2>/dev/null; \#
    echo '##listen'; ss -H -tlnp 2>/dev/null; \#
    echo '##procs'; for p in $(ss -H -tlnp 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -un); do printf '%s\t%s\t%s\n' "$p" "$(head -c 300 /proc/$p/cmdline 2>/dev/null | tr '\0\n\t' '   ')" "$(grep -m1 -E '^0::|name=systemd:' /proc/$p/cgroup 2>/dev/null | cut -d: -f3)"; done; true
    """#

    private let transport: SSHTransport
    public private(set) var snapshot: ServicesSnapshot?
    public private(set) var error: String?
    public private(set) var updatedAt: Date?

    public init(transport: SSHTransport) { self.transport = transport }

    @discardableResult
    public func refresh() async -> (snapshot: ServicesSnapshot?, error: String?, updatedAt: Date?) {
        do {
            let result = try await transport.run(Self.command, timeout: 15)
            // The script ends in `true`, so a non-zero exit is ssh's own failure.
            guard result.exitCode == 0 else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw ServicesFailure(detail.isEmpty ? "ssh exited \(result.exitCode)" : detail)
            }
            snapshot = ServicesParser.parse(result.stdout)
            error = nil
            updatedAt = Date()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        return (snapshot, error, updatedAt)
    }
}
