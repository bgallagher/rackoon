import Foundation

// Security screen (docs/security-plan.md, stage S0/S1): one read-only command (spec `security`) reads hardening facts as
// the ssh user, `SecurityParser` turns them into a `SecuritySnapshot`, and `SecurityRules.evaluate` turns that into
// findings. Nothing here changes a server, and a check that could not be read is `unknown`, never a pass. The checks'
// titles and advice are data in spec/security-checks.json (`SecurityChecks.all` must equal it).

// MARK: - Snapshot

public struct SecuritySnapshot: Codable, Equatable, Sendable {
    public var uid: Int?
    public var os: OS
    public var sshd: SSHD
    /// Tailscale SSH (`RunSSH` in tailscale's prefs); nil when tailscale is missing or would not say.
    public var tailscaleSSH: Bool?
    public var firewall: Firewall
    /// systemd's `is-active` answer for fail2ban, crowdsec and sshguard ("" when systemctl gave none).
    public var guards: [String: String]
    public var listeners: [Listener]
    public var docker: DockerExposure
    public var unattended: Unattended
    /// Accounts with UID 0 in /etc/passwd.
    public var rootAccounts: [String]
    /// Accounts whose /etc/shadow password field is empty; nil when it was not read (it needs root: Check Deeper).
    public var emptyPasswordAccounts: [String]?
    /// /proc/sys/kernel/randomize_va_space (2 = full).
    public var aslr: Int?
    public var ntpSynchronized: Bool?

    public var isRoot: Bool { uid == 0 }

    public struct OS: Codable, Equatable, Sendable {
        public var id: String
        public var like: String
        public var version: String
        /// Debian, Ubuntu and their derivatives: apt-based checks apply.
        public var isDebianLike: Bool { id == "debian" || id == "ubuntu" || like.split(separator: " ").contains("debian") }
    }

    public struct SSHD: Codable, Equatable, Sendable {
        public enum Source: String, Codable, Sendable {
            /// `sshd -T`: the settings sshd really uses (needs root).
            case effective
            /// The config files, read in sshd's first-value-wins order.
            case files
            /// Nothing could be read.
            case none
        }
        public var installed: Bool
        /// ssh.service, sshd.service or ssh.socket is active.
        public var active: Bool
        public var source: Source
        /// Lower-case keyword -> value (first value wins), only for the keywords Rackoon checks.
        public var settings: [String: String]
        /// Which file set each keyword (source `files` only).
        public var origin: [String: String]
        /// Config files Rackoon could not read.
        public var unreadable: [String]
        /// Keywords an unreadable file could set before what Rackoon read (so their value is not certain).
        public var uncertain: [String]
    }

    public struct Firewall: Codable, Equatable, Sendable {
        /// `ENABLED=` in /etc/ufw/ufw.conf; nil when the file is missing.
        public var ufwEnabled: Bool?
        /// systemd's `is-active` answer per firewall service (ufw, firewalld, nftables).
        public var services: [String: String]
    }

    public struct Listener: Codable, Equatable, Sendable, Hashable {
        public enum Scope: String, Codable, Sendable, Comparable {
            /// 0.0.0.0, :: or *: every interface.
            case all
            /// A specific public address.
            case `public`
            /// A private LAN address (10/8, 172.16/12, 192.168/16, fc00::/7, fe80::/10).
            case lan
            /// A Tailscale address (100.64.0.0/10, fd7a:115c:a1e0::/48).
            case tailscale
            case loopback

            private var rank: Int { [Scope.all, .public, .lan, .tailscale, .loopback].firstIndex(of: self)! }
            public static func < (a: Scope, b: Scope) -> Bool { a.rank < b.rank }
            /// Reachable from other machines.
            public var isExposed: Bool { self == .all || self == .public }
        }
        public var proto: String
        public var address: String
        public var port: Int
        public var scope: Scope
    }

    public struct DockerExposure: Codable, Equatable, Sendable {
        public var installed: Bool
        /// Docker's own error when it would not list containers (usually "permission denied"); nil when it answered.
        public var problem: String?
        public var published: [Published]
        public var containers: [Container]

        public struct Published: Codable, Equatable, Sendable, Hashable {
            public var container: String
            public var address: String
            public var port: String
            public var proto: String
            public var scope: Listener.Scope
        }

        public struct Container: Codable, Equatable, Sendable {
            public var name: String
            public var privileged: Bool
            public var hostNetwork: Bool
            public var hostPID: Bool
            /// It mounts the Docker socket (root on the host for whoever controls the container).
            public var dockerSocket: Bool
            /// It mounts the host's / .
            public var hostRoot: Bool
        }
    }

    public struct Unattended: Codable, Equatable, Sendable {
        public var installed: Bool
        /// `APT::Periodic::Unattended-Upgrade`; nil when apt does not set it.
        public var enabled: Bool?
    }
}

// MARK: - Parser

public enum SecurityParser {
    /// The sshd keywords the checks read.
    public static let sshdKeywords: Set<String> = [
        "port", "permitrootlogin", "passwordauthentication", "kbdinteractiveauthentication", "challengeresponseauthentication",
        "permitemptypasswords", "maxauthtries", "x11forwarding",
    ]

    public static func parse(_ output: String) -> SecuritySnapshot {
        let sections = Self.sections(output)
        func lines(_ name: String) -> [String] { sections[name] ?? [] }
        func keyValues(_ name: String) -> [String: String] {
            var out: [String: String] = [:]
            for line in lines(name) {
                guard let eq = line.firstIndex(of: "=") else { continue }
                out[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            }
            return out
        }

        let os = keyValues("os")
        let sshdState = keyValues("sshd")
        var snapshot = SecuritySnapshot(
            uid: lines("uid").first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
            os: .init(id: os["id"] ?? "", like: os["like"] ?? "", version: os["version"] ?? ""),
            sshd: sshd(installed: sshdState["installed"] == "yes", active: (Int(sshdState["active"] ?? "") ?? 0) > 0,
                       effective: lines("sshd_effective"), files: lines("sshd_files")),
            tailscaleSSH: nil,
            firewall: .init(ufwEnabled: nil, services: [:]),
            guards: [:],
            listeners: listeners(lines("listen")),
            docker: docker(lines("docker"), inspect: lines("docker_inspect")),
            unattended: .init(installed: false, enabled: nil),
            rootAccounts: lines("uid0").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            emptyPasswordAccounts: lines("shadow_empty").first == "checked"
                ? lines("shadow_empty").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : nil,
            aslr: lines("aslr").first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
            ntpSynchronized: lines("ntp").first.flatMap { line in
                switch line.trimmingCharacters(in: .whitespaces) { case "yes": true; case "no": false; default: nil }
            })

        if let run = lines("tailscale_ssh").first, let colon = run.lastIndex(of: ":") {
            snapshot.tailscaleSSH = run[run.index(after: colon)...].trimmingCharacters(in: .whitespaces) == "true"
        }

        var firewall = keyValues("firewall")
        if let enabled = firewall.removeValue(forKey: "ENABLED") { snapshot.firewall.ufwEnabled = enabled.lowercased() == "yes" }
        snapshot.firewall.services = firewall
        snapshot.guards = keyValues("guards")

        let unattended = lines("unattended")
        snapshot.unattended.installed = unattended.contains { $0.hasPrefix("package=") && $0.hasSuffix(" installed") }
        if let periodic = unattended.first(where: { $0.hasPrefix("APT::Periodic::Unattended-Upgrade ") }) {
            let value = periodic.dropFirst("APT::Periodic::Unattended-Upgrade ".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"; "))
            snapshot.unattended.enabled = Int(value).map { $0 > 0 }
        }
        return snapshot
    }

    /// `##name` sections, in order; lines before the first marker are dropped.
    static func sections(_ output: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var current: String?
        for raw in output.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("##") {
                current = String(line.dropFirst(2))
                out[current!, default: []] = out[current!] ?? []
            } else if let current, !line.isEmpty {
                out[current, default: []].append(line)
            }
        }
        return out
    }

    // MARK: sshd

    private struct ConfigFile {
        let path: String
        let readable: Bool
        var lines: [String]
    }

    static func sshd(installed: Bool, active: Bool, effective: [String], files: [String]) -> SecuritySnapshot.SSHD {
        var result = SecuritySnapshot.SSHD(installed: installed, active: active, source: .none, settings: [:], origin: [:],
                                           unreadable: [], uncertain: [])
        // `sshd -T` answers only as root; its lower-case output is exactly what sshd uses.
        let fromSSHDT = keywordLines(effective)
        if !fromSSHDT.isEmpty {
            result.source = .effective
            for (key, value) in fromSSHDT where result.settings[key] == nil { result.settings[key] = value }
            return result
        }

        var parsed: [ConfigFile] = []
        for line in files {
            if line.hasPrefix("#file ") {
                parsed.append(ConfigFile(path: String(line.dropFirst(6)), readable: true, lines: []))
            } else if line.hasPrefix("#unreadable ") {
                parsed.append(ConfigFile(path: String(line.dropFirst(12)), readable: false, lines: []))
            } else if !parsed.isEmpty {
                parsed[parsed.count - 1].lines.append(line)
            }
        }
        result.unreadable = parsed.filter { !$0.readable }.map(\.path)
        guard let main = parsed.first else { return result }
        result.source = .files

        // sshd reads the main file top to bottom, splicing each Include in where it appears; the first value of a keyword
        // wins, and lines after a Match apply only to some connections, so they are skipped (to the end of that file).
        var uncertain = Set<String>()
        var seen = Set<String>()
        func walk(_ file: ConfigFile, depth: Int) {
            guard depth < 4 else { return }
            if !file.readable {
                // Anything not set yet could be set here.
                uncertain.formUnion(sshdKeywords.subtracting(result.settings.keys))
                return
            }
            for line in file.lines {
                guard let (key, value) = keywordLine(line) else { continue }
                if key == "match" { return }
                if key == "include" {
                    for pattern in value.split(separator: " ").map(String.init) {
                        let full = pattern.hasPrefix("/") ? pattern : "/etc/ssh/" + pattern
                        for included in parsed.dropFirst() where !seen.contains(included.path) && globMatches(full, included.path) {
                            seen.insert(included.path)
                            walk(included, depth: depth + 1)
                        }
                    }
                    continue
                }
                if result.settings[key] == nil {
                    result.settings[key] = value
                    result.origin[key] = file.path
                }
            }
        }
        seen.insert(main.path)
        walk(main, depth: 0)
        result.uncertain = uncertain.subtracting(["port", "challengeresponseauthentication"]).sorted()
        return result
    }

    private static func keywordLines(_ lines: [String]) -> [(String, String)] { lines.compactMap(keywordLine) }

    /// `Keyword value` or `Keyword=value`, keyword lower-cased; comments and other keywords give nil.
    static func keywordLine(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let split = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return nil }
        let key = trimmed[..<split].lowercased()
        guard sshdKeywords.contains(key) || key == "include" || key == "match" else { return nil }
        let value = trimmed[trimmed.index(after: split)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
        return (key, key == "include" || key == "match" ? value : value.lowercased())
    }

    /// Shell-style glob (`*`, `?`) against a whole path.
    static func globMatches(_ pattern: String, _ path: String) -> Bool {
        let p = Array(pattern), s = Array(path)
        var memo: [Int: Bool] = [:]
        func match(_ i: Int, _ j: Int) -> Bool {
            let k = i * (s.count + 1) + j
            if let m = memo[k] { return m }
            let r: Bool
            if i == p.count { r = j == s.count }
            else if p[i] == "*" { r = match(i + 1, j) || (j < s.count && s[j] != "/" && match(i, j + 1)) }
            else { r = j < s.count && (p[i] == "?" || p[i] == s[j]) && match(i + 1, j + 1) }
            memo[k] = r
            return r
        }
        return match(0, 0)
    }

    // MARK: listeners

    /// `ss -H -tuln` lines: netid, state, queues, local address:port, peer.
    static func listeners(_ lines: [String]) -> [SecuritySnapshot.Listener] {
        var out: [SecuritySnapshot.Listener] = []
        for line in lines {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 5, let (address, port) = hostPort(String(cols[4])), let number = Int(port) else { continue }
            let listener = SecuritySnapshot.Listener(proto: String(cols[0]), address: address, port: number, scope: scope(of: address))
            if !out.contains(listener) { out.append(listener) }
        }
        return out.sorted { ($0.port, $0.proto, $0.scope, $0.address) < ($1.port, $1.proto, $1.scope, $1.address) }
    }

    /// Splits `addr:port`, `[v6]:port` or `*:port`; drops a `%interface` suffix and IPv4-mapped prefixes.
    static func hostPort(_ text: String) -> (String, String)? {
        guard let colon = text.lastIndex(of: ":") else { return nil }
        var host = String(text[..<colon])
        let port = String(text[text.index(after: colon)...])
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
        if host.lowercased().hasPrefix("::ffff:"), host.contains(".") { host = String(host.dropFirst(7)) }
        if host.isEmpty { host = "::" }   // docker's old ":::8080"
        return (host, port)
    }

    static func scope(of address: String) -> SecuritySnapshot.Listener.Scope {
        let a = address.lowercased()
        if a == "*" || a == "0.0.0.0" || a == "::" { return .all }
        if a == "::1" || a.hasPrefix("127.") || a == "localhost" { return .loopback }
        let v4 = a.split(separator: ".").compactMap { Int($0) }
        if v4.count == 4 {
            switch (v4[0], v4[1]) {
            case (100, 64...127): return .tailscale
            case (10, _), (192, 168), (172, 16...31), (169, 254): return .lan
            default: return .public
            }
        }
        if a.hasPrefix("fd7a:115c:a1e0:") { return .tailscale }
        if a.hasPrefix("fe8") || a.hasPrefix("fe9") || a.hasPrefix("fea") || a.hasPrefix("feb") || a.hasPrefix("fc") || a.hasPrefix("fd") {
            return .lan
        }
        return .public
    }

    // MARK: docker

    static func docker(_ lines: [String], inspect: [String]) -> SecuritySnapshot.DockerExposure {
        var result = SecuritySnapshot.DockerExposure(installed: false, problem: nil, published: [], containers: [])
        guard lines.first == "installed=yes" else { return result }
        result.installed = true
        var problem: [String] = []
        for line in lines.dropFirst() {
            guard let tab = line.firstIndex(of: "\t") else { problem.append(line); continue }
            let name = String(line[..<tab])
            for entry in line[line.index(after: tab)...].split(separator: ",") {
                let item = entry.trimmingCharacters(in: .whitespaces)
                guard let arrow = item.range(of: "->") else { continue }   // exposed but not published
                guard let (address, port) = hostPort(String(item[..<arrow.lowerBound])) else { continue }
                let proto = item.split(separator: "/").last.map(String.init) ?? "tcp"
                let published = SecuritySnapshot.DockerExposure.Published(container: name, address: address, port: port, proto: proto,
                                                                         scope: scope(of: address))
                if !result.published.contains(published) { result.published.append(published) }
            }
        }
        if !problem.isEmpty { result.problem = problem.joined(separator: " ") }
        for line in inspect {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5 else { continue }
            let mounts = f[4].split(separator: ";").map(String.init)
            result.containers.append(.init(
                name: f[0].hasPrefix("/") ? String(f[0].dropFirst()) : f[0],
                privileged: f[1] == "true", hostNetwork: f[2] == "host", hostPID: f[3] == "host",
                dockerSocket: mounts.contains { $0 == "/var/run/docker.sock" || $0 == "/run/docker.sock" },
                hostRoot: mounts.contains("/")))
        }
        result.containers.sort { $0.name < $1.name }
        return result
    }
}

// MARK: - Checks and findings

public struct SecurityCheck: Codable, Equatable, Sendable, Identifiable {
    public enum Group: String, Codable, Sendable, CaseIterable {
        case ssh, exposure, bruteForce = "brute_force", updates, accounts, docker, system

        public var title: String {
            switch self {
            case .ssh: "SSH"
            case .exposure: "Firewall and exposure"
            case .bruteForce: "Brute-force protection"
            case .updates: "Updates"
            case .accounts: "Accounts"
            case .docker: "Docker"
            case .system: "Kernel and time"
            }
        }
    }
    public var id: String
    public var group: Group
    public var title: String
    /// Why it matters, in a sentence.
    public var why: String
    /// What a person would do about it themselves (Rackoon never changes the server).
    public var advice: String
}

public struct SecurityFinding: Codable, Equatable, Sendable, Identifiable {
    public enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
        case critical, warning, info, unknown, pass
        private var rank: Int { Self.allCases.firstIndex(of: self)! }
        public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }
    /// The check's id, plus `:<subject>` for one finding per item (a port, a container).
    public var id: String
    public var check: String
    public var severity: Severity
    /// The finding in one line.
    public var summary: String
    /// What was read, so a person can verify it.
    public var evidence: String?
}

public enum SecurityChecks {
    public static let all: [SecurityCheck] = [
        .init(id: "ssh.server", group: .ssh, title: "SSH server",
              why: "Every other SSH check reads the OpenSSH server's settings.",
              advice: "Nothing to do if this server is reached another way (for example Tailscale SSH or a console)."),
        .init(id: "ssh.root_login", group: .ssh, title: "Root login with a password",
              why: "A root password that can be guessed over SSH gives away the whole server.",
              advice: "Set PermitRootLogin to no (or prohibit-password) in /etc/ssh/sshd_config.d/ and reload ssh."),
        .init(id: "ssh.password_auth", group: .ssh, title: "Password logins",
              why: "Passwords can be guessed by bots that scan for SSH all day; keys cannot.",
              advice: "Once your key logins work, set PasswordAuthentication no and KbdInteractiveAuthentication no, then reload ssh."),
        .init(id: "ssh.empty_passwords", group: .ssh, title: "Empty passwords",
              why: "An account without a password could log in with nothing at all.",
              advice: "Set PermitEmptyPasswords no (the default) and give every account a password or lock it."),
        .init(id: "ssh.max_auth_tries", group: .ssh, title: "Login attempts per connection",
              why: "More attempts per connection make guessing cheaper.",
              advice: "Leave MaxAuthTries at 6 or lower."),
        .init(id: "ssh.x11_forwarding", group: .ssh, title: "X11 forwarding",
              why: "Forwarding graphical programs is rarely needed on a server and widens what a login can reach.",
              advice: "Set X11Forwarding no unless you run graphical programs over SSH."),
        .init(id: "ssh.tailscale", group: .ssh, title: "Tailscale SSH",
              why: "Logins over Tailscale SSH follow your tailnet's SSH policy, not sshd's settings.",
              advice: "Review the ssh rules in your tailnet policy file; the sshd checks here cover only logins that reach sshd."),
        .init(id: "exposure.firewall", group: .exposure, title: "Firewall",
              why: "Without a firewall every listening service is reachable from any network the server is on.",
              advice: "Turn on ufw (or another firewall) with rules for only the ports you mean to offer."),
        .init(id: "exposure.listening", group: .exposure, title: "Services listening on every interface",
              why: "A service bound to every interface is reachable from every network the server is on, unless a firewall stops it.",
              advice: "Bind services to 127.0.0.1 or the Tailscale address when only you need them."),
        .init(id: "exposure.sensitive_port", group: .exposure, title: "Database or cache open to the network",
              why: "Databases and caches are often reachable without a password and are a common target.",
              advice: "Bind it to 127.0.0.1 (or a Docker network without published ports) and reach it over Tailscale or an SSH tunnel."),
        .init(id: "exposure.docker_bypass", group: .exposure, title: "Docker ports bypass ufw",
              why: "Docker writes its own iptables rules ahead of ufw's, so a port Docker publishes on every interface is open even if ufw denies it.",
              advice: "Publish ports on 127.0.0.1 or the Tailscale address (\"127.0.0.1:8080:80\"), or filter in the DOCKER-USER chain."),
        .init(id: "brute_force.guard", group: .bruteForce, title: "Brute-force protection",
              why: "fail2ban, CrowdSec or sshguard block addresses that keep failing to log in.",
              advice: "With password logins on, install fail2ban (its sshd jail is on by default on Debian and Ubuntu) or turn passwords off."),
        .init(id: "updates.security_pending", group: .updates, title: "Security updates waiting",
              why: "Known holes stay open until the fix is installed.",
              advice: "Install them from the Updates screen."),
        .init(id: "updates.automatic", group: .updates, title: "Automatic security updates",
              why: "unattended-upgrades installs security fixes without waiting for you.",
              advice: "Install unattended-upgrades and turn it on with dpkg-reconfigure unattended-upgrades."),
        .init(id: "updates.reboot", group: .updates, title: "Reboot needed",
              why: "A new kernel or system library is not in use until the server restarts.",
              advice: "Reboot when it suits you (Reboot… on the Overview)."),
        .init(id: "accounts.extra_root", group: .accounts, title: "Second root account",
              why: "Any account with user id 0 is root; an unexpected one is a classic sign of a break-in.",
              advice: "Check who created it; remove it or give it its own user id."),
        .init(id: "accounts.empty_password", group: .accounts, title: "Account with an empty password",
              why: "An account with an empty password can log in on the console, and over SSH wherever empty passwords are allowed.",
              advice: "Lock it (sudo passwd -l <name>) or give it a password."),
        .init(id: "docker.tcp_api", group: .docker, title: "Docker API on the network",
              why: "Port 2375 is Docker's API without TLS: anyone who reaches it controls the server as root.",
              advice: "Remove the -H tcp://… listener from the Docker daemon, or use 2376 with client certificates."),
        .init(id: "docker.container", group: .docker, title: "Container with host access",
              why: "Privileged containers, host networking or PID, and the Docker socket or / mounted inside give a container root on the host.",
              advice: "Drop the setting unless the app needs it; tools such as Portainer, Watchtower and Traefik need the socket by design."),
        .init(id: "docker.unchecked", group: .docker, title: "Containers not checked",
              why: "Docker would not list the containers for the ssh user.",
              advice: "Unlock Docker with sudo on the Docker screen, then check again."),
        .init(id: "system.aslr", group: .system, title: "Address space layout randomisation",
              why: "ASLR makes memory bugs much harder to exploit.",
              advice: "Set kernel.randomize_va_space = 2 in /etc/sysctl.d/ (the default)."),
        .init(id: "system.time_sync", group: .system, title: "Clock synchronised",
              why: "Certificates, logs and two-factor codes depend on the right time.",
              advice: "Turn on systemd-timesyncd or chrony (timedatectl set-ntp true)."),
    ]

    public static func check(_ id: String) -> SecurityCheck? { all.first { $0.id == id } }
}

/// What the Overview poll already knows, passed in so the Security command does not run apt again.
public struct SecurityContext: Equatable, Sendable {
    public var pendingSecurityUpdates: Int?
    public var rebootRequired: Bool?
    public init(pendingSecurityUpdates: Int? = nil, rebootRequired: Bool? = nil) {
        self.pendingSecurityUpdates = pendingSecurityUpdates
        self.rebootRequired = rebootRequired
    }
}

public enum SecurityRules {
    /// Ports that should not be open to the network: databases, caches, search engines.
    public static let sensitivePorts: [Int: String] = [
        3306: "MySQL/MariaDB", 5432: "PostgreSQL", 6379: "Redis", 27017: "MongoDB", 9200: "Elasticsearch",
        11211: "Memcached", 5984: "CouchDB", 8086: "InfluxDB",
    ]

    /// Container names (or name parts) of tools that need the Docker socket by design.
    public static let socketTools = ["portainer", "watchtower", "traefik", "homepage", "dozzle", "dockge", "diun", "autoheal",
                                     "beszel", "uptime-kuma", "socket-proxy", "cadvisor", "netdata"]

    /// ufw is the firewall in use (its service is active and ufw.conf does not say ENABLED=no).
    public static func ufwOn(_ s: SecuritySnapshot) -> Bool { s.firewall.services["ufw"] == "active" && s.firewall.ufwEnabled != false }

    public static func evaluate(_ s: SecuritySnapshot, context: SecurityContext = .init()) -> [SecurityFinding] {
        var out: [SecurityFinding] = []
        func add(_ check: String, _ severity: SecurityFinding.Severity, _ summary: String, evidence: String? = nil, subject: String? = nil) {
            out.append(.init(id: subject.map { "\(check):\($0)" } ?? check, check: check, severity: severity, summary: summary,
                             evidence: evidence))
        }

        // SSH
        let sshd = s.sshd
        let sshOn = sshd.installed && sshd.active
        let passwordsOn: Bool?
        if !sshd.installed {
            add("ssh.server", .info, "No OpenSSH server is installed.")
            passwordsOn = false
        } else if sshd.source == .none {
            add("ssh.server", .unknown, "Rackoon could not read sshd's settings.",
                evidence: sshd.unreadable.isEmpty ? nil : "Unreadable: " + sshd.unreadable.joined(separator: ", "))
            passwordsOn = nil
        } else {
            add("ssh.server", sshOn ? .pass : .info, sshOn ? "OpenSSH is running." : "OpenSSH is installed but not running.",
                evidence: sshd.source == .effective ? "From sshd -T (the settings in use)." : "From the config files (sshd -T needs root).")
            func setting(_ key: String) -> (value: String, isDefault: Bool, certain: Bool, evidence: String) {
                let certain = !sshd.uncertain.contains(key)
                if let value = sshd.settings[key] {
                    let from = sshd.origin[key].map { " in \($0)" } ?? ""
                    return (value, false, certain, "\(key) \(value)\(from)")
                }
                let value = defaults[key] ?? ""
                return (value, true, certain, "\(key) not set, so sshd uses its default: \(value)")
            }
            func unsure(_ e: String) -> String { e + ". A file Rackoon cannot read (\(sshd.unreadable.joined(separator: ", "))) may set it first." }

            let root = setting("permitrootlogin")
            if !root.certain {
                add("ssh.root_login", .unknown, "Root login could not be read for certain.", evidence: unsure(root.evidence))
            } else if root.value == "yes" {
                add("ssh.root_login", .critical, "Root can log in with a password.", evidence: root.evidence)
            } else {
                add("ssh.root_login", .pass, root.value == "no" ? "Root cannot log in over SSH." : "Root can log in with a key only.",
                    evidence: root.evidence)
            }

            let password = setting("passwordauthentication")
            let keyboard = setting("kbdinteractiveauthentication")
            let challenge = sshd.settings["challengeresponseauthentication"]
            // KbdInteractiveAuthentication's old name, ChallengeResponseAuthentication, still counts when the new one is not set.
            let keyboardOn = keyboard.isDefault ? (challenge.map { $0 == "yes" } ?? (keyboard.value == "yes")) : keyboard.value == "yes"
            let passwordEvidence = [password.evidence, keyboard.evidence].joined(separator: "; ")
            let surelyOn = (password.certain && password.value == "yes") || (keyboard.certain && keyboardOn)
            if surelyOn {
                let which = [password.certain && password.value == "yes" ? "passwords" : nil, keyboard.certain && keyboardOn ? "keyboard-interactive logins" : nil]
                    .compactMap { $0 }.joined(separator: " and ")
                add("ssh.password_auth", .warning, "SSH accepts \(which).", evidence: passwordEvidence)
                passwordsOn = true
            } else if !password.certain || !keyboard.certain {
                add("ssh.password_auth", .unknown, "Password logins could not be read for certain.", evidence: unsure(passwordEvidence))
                passwordsOn = nil
            } else {
                add("ssh.password_auth", .pass, "SSH accepts keys only.", evidence: passwordEvidence)
                passwordsOn = false
            }

            let empty = setting("permitemptypasswords")
            if !empty.certain {
                add("ssh.empty_passwords", .unknown, "Empty-password logins could not be read for certain.", evidence: unsure(empty.evidence))
            } else if empty.value == "yes" {
                add("ssh.empty_passwords", .critical, "Accounts with an empty password can log in.", evidence: empty.evidence)
            } else {
                add("ssh.empty_passwords", .pass, "Empty passwords are refused.", evidence: empty.evidence)
            }

            let tries = setting("maxauthtries")
            if let n = Int(tries.value), n > 6 {
                add("ssh.max_auth_tries", .info, "Each connection may try \(n) logins.", evidence: tries.evidence)
            } else {
                add("ssh.max_auth_tries", .pass, "At most \(tries.value) login attempts per connection.", evidence: tries.evidence)
            }

            let x11 = setting("x11forwarding")
            add("ssh.x11_forwarding", x11.value == "yes" ? .info : .pass,
                x11.value == "yes" ? "X11 forwarding is on." : "X11 forwarding is off.", evidence: x11.evidence)
        }
        if s.tailscaleSSH == true {
            add("ssh.tailscale", .info, "Tailscale SSH is on: tailnet logins follow your tailnet's SSH policy.")
        }

        // Firewall and exposure
        let active = { (unit: String) in s.firewall.services[unit] == "active" }
        let ufwOn = Self.ufwOn(s)
        if ufwOn {
            add("exposure.firewall", .pass, "ufw is on.")
        } else if active("firewalld") {
            add("exposure.firewall", .pass, "firewalld is on.")
        } else if active("nftables") {
            add("exposure.firewall", .info, "nftables rules are loaded, but reading them needs root.",
                evidence: "Debian's default nftables.conf allows everything; check it with sudo nft list ruleset.")
        } else if s.firewall.services.values.allSatisfy(\.isEmpty) {
            add("exposure.firewall", .unknown, "Rackoon could not ask systemd about firewalls.")
        } else {
            add("exposure.firewall", .warning, "No firewall is running.",
                evidence: s.firewall.services.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
        }

        let exposed = s.listeners.filter { $0.scope.isExposed }
        let exposedPorts = Array(Set(exposed.map { "\($0.port)/\($0.proto)" })).sorted { (Int($0.prefix { $0.isNumber }) ?? 0, $0) < (Int($1.prefix { $0.isNumber }) ?? 0, $1) }
        if s.listeners.isEmpty {
            add("exposure.listening", .unknown, "Rackoon could not list listening sockets.")
        } else if exposedPorts.isEmpty {
            add("exposure.listening", .pass, "Nothing listens on every interface.")
        } else {
            add("exposure.listening", .info, "\(exposedPorts.count) port\(exposedPorts.count == 1 ? "" : "s") listen on every interface.",
                evidence: exposedPorts.joined(separator: ", "))
        }
        var sensitiveSeen = Set<Int>()
        for l in exposed where l.proto == "tcp" {
            guard let name = sensitivePorts[l.port], sensitiveSeen.insert(l.port).inserted else { continue }
            add("exposure.sensitive_port", .warning, "\(name) (port \(l.port)) listens on every interface.",
                evidence: "\(l.proto) \(l.address):\(l.port)", subject: "\(l.port)")
        }

        let dockerExposed = s.docker.published.filter { $0.scope.isExposed }
        if ufwOn, !dockerExposed.isEmpty {
            let list = Array(Set(dockerExposed.map { "\($0.port)/\($0.proto) (\($0.container))" })).sorted()
            add("exposure.docker_bypass", .warning, "Docker publishes \(list.count) port\(list.count == 1 ? "" : "s") on every interface, past ufw.",
                evidence: list.joined(separator: ", "))
        }

        // Brute-force protection
        let guarding = ["fail2ban", "crowdsec", "sshguard"].filter { s.guards[$0] == "active" }
        if !guarding.isEmpty {
            add("brute_force.guard", .pass, "\(guarding.joined(separator: " and ")) is running.")
        } else if !sshOn {
            add("brute_force.guard", .pass, "No SSH server to protect.")
        } else if s.guards.values.allSatisfy(\.isEmpty) {
            add("brute_force.guard", .unknown, "Rackoon could not ask systemd about fail2ban, CrowdSec or sshguard.")
        } else {
            add("brute_force.guard", passwordsOn == false ? .info : .warning,
                passwordsOn == false ? "No fail2ban, CrowdSec or sshguard (less important with password logins off)."
                                     : "No fail2ban, CrowdSec or sshguard, and SSH may accept passwords.")
        }

        // Updates
        if s.os.isDebianLike {
            switch context.pendingSecurityUpdates {
            case .some(let n) where n > 0:
                add("updates.security_pending", .warning, "\(n) security update\(n == 1 ? " is" : "s are") waiting to be installed.")
            case .some: add("updates.security_pending", .pass, "No security updates waiting.")
            case .none: add("updates.security_pending", .unknown, "The update count is not known yet.")
            }
            if s.unattended.installed && s.unattended.enabled == true {
                add("updates.automatic", .pass, "unattended-upgrades installs security updates automatically.")
            } else if s.unattended.installed {
                add("updates.automatic", .info, "unattended-upgrades is installed but not switched on.",
                    evidence: "APT::Periodic::Unattended-Upgrade is \(s.unattended.enabled == false ? "0" : "not set").")
            } else {
                add("updates.automatic", .info, "Security updates are not installed automatically.",
                    evidence: "The unattended-upgrades package is not installed.")
            }
        }
        switch context.rebootRequired {
        case .some(true): add("updates.reboot", .warning, "The server asks for a reboot to finish updates.")
        case .some(false): add("updates.reboot", .pass, "No reboot pending.")
        case .none: break
        }

        // Accounts
        let extra = s.rootAccounts.filter { $0 != "root" }
        if s.rootAccounts.isEmpty {
            add("accounts.extra_root", .unknown, "Rackoon could not read /etc/passwd.")
        } else if extra.isEmpty {
            add("accounts.extra_root", .pass, "Only root has user id 0.")
        } else {
            add("accounts.extra_root", .critical, "Other accounts have user id 0: \(extra.joined(separator: ", ")).",
                evidence: "UID 0 in /etc/passwd: " + s.rootAccounts.joined(separator: ", "))
        }

        switch s.emptyPasswordAccounts {
        case .none:
            add("accounts.empty_password", .unknown, "Reading /etc/shadow needs root: use Check Deeper with sudo.")
        case .some(let names) where names.isEmpty:
            add("accounts.empty_password", .pass, "No account has an empty password.")
        case .some(let names):
            add("accounts.empty_password", .critical, "Accounts with an empty password: \(names.joined(separator: ", ")).",
                evidence: "Empty password field in /etc/shadow: " + names.joined(separator: ", "))
        }

        // Docker
        if let api = s.listeners.first(where: { $0.port == 2375 && $0.proto == "tcp" && $0.scope != .loopback }) {
            add("docker.tcp_api", .critical, "Docker's API answers without TLS on port 2375.", evidence: "tcp \(api.address):2375")
        } else if let tls = s.listeners.first(where: { $0.port == 2376 && $0.proto == "tcp" && $0.scope != .loopback }) {
            add("docker.tcp_api", .info, "Docker's API listens on port 2376 (TLS); make sure it requires client certificates.",
                evidence: "tcp \(tls.address):2376")
        }
        if s.docker.installed {
            if let problem = s.docker.problem {
                add("docker.unchecked", .unknown, "Docker would not list containers for this user.", evidence: problem)
            }
            for c in s.docker.containers {
                var reasons: [String] = []
                if c.privileged { reasons.append("privileged") }
                if c.hostNetwork { reasons.append("host network") }
                if c.hostPID { reasons.append("host PID namespace") }
                if c.dockerSocket { reasons.append("Docker socket mounted") }
                if c.hostRoot { reasons.append("host / mounted") }
                guard !reasons.isEmpty else { continue }
                let expected = c.dockerSocket && reasons.count == 1 && socketTools.contains { c.name.lowercased().contains($0) }
                add("docker.container", expected ? .info : .warning,
                    "\(c.name): \(reasons.joined(separator: ", "))\(expected ? " (expected for this tool)" : "").", subject: c.name)
            }
        }

        // Kernel and time
        switch s.aslr {
        case .some(2): add("system.aslr", .pass, "Full address space randomisation.")
        case .some(let n): add("system.aslr", .warning, "Address space randomisation is \(n == 0 ? "off" : "partial") (\(n)).",
                               evidence: "/proc/sys/kernel/randomize_va_space = \(n)")
        case .none: add("system.aslr", .unknown, "Rackoon could not read the ASLR setting.")
        }
        switch s.ntpSynchronized {
        case .some(true): add("system.time_sync", .pass, "The clock is synchronised.")
        case .some(false): add("system.time_sync", .info, "The clock is not synchronised.", evidence: "timedatectl: NTPSynchronized=no")
        case .none: add("system.time_sync", .unknown, "Rackoon could not ask timedatectl.")
        }
        return out
    }

    /// sshd's built-in defaults for the keywords Rackoon checks (OpenSSH 8.7 and later).
    static let defaults: [String: String] = [
        "port": "22", "permitrootlogin": "prohibit-password", "passwordauthentication": "yes", "kbdinteractiveauthentication": "yes",
        "permitemptypasswords": "no", "maxauthtries": "6", "x11forwarding": "no",
    ]

    /// Counts by severity, for the summary tiles and badges.
    public static func counts(_ findings: [SecurityFinding]) -> [SecurityFinding.Severity: Int] {
        Dictionary(grouping: findings, by: \.severity).mapValues(\.count)
    }
}

/// Runs the read-only `security` command.
public enum SecuritySession {
    public static let command = ##"PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"; echo '##uid'; id -u; echo '##os'; (. /etc/os-release 2>/dev/null; echo "id=$ID"; echo "like=$ID_LIKE"; echo "version=$VERSION_ID"); echo '##sshd'; if command -v sshd >/dev/null 2>&1; then echo installed=yes; else echo installed=no; fi; echo "active=$(systemctl is-active ssh.service sshd.service ssh.socket 2>/dev/null | grep -cx active)"; echo '##sshd_effective'; sshd -T 2>/dev/null | grep -Ei '^(port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|permitemptypasswords|maxauthtries|x11forwarding) '; echo '##sshd_files'; for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do [ -e "$f" ] || continue; if [ -r "$f" ]; then echo "#file $f"; grep -Ei '^[[:space:]]*(include|match|port|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitemptypasswords|maxauthtries|x11forwarding)([[:space:]]|=)' "$f"; else echo "#unreadable $f"; fi; done; echo '##tailscale_ssh'; timeout 3 tailscale debug prefs 2>/dev/null | grep -o '"RunSSH": *[a-z]*'; echo '##firewall'; grep -E '^ENABLED=' /etc/ufw/ufw.conf 2>/dev/null; for u in ufw firewalld nftables; do echo "$u=$(systemctl is-active $u 2>/dev/null)"; done; echo '##guards'; for u in fail2ban crowdsec sshguard; do echo "$u=$(systemctl is-active $u 2>/dev/null)"; done; echo '##listen'; ss -H -tuln 2>/dev/null; echo '##docker'; if command -v docker >/dev/null 2>&1; then echo installed=yes; docker ps --format '{{.Names}}\##t{{.Ports}}' 2>&1 | head -200; else echo installed=no; fi; echo '##docker_inspect'; docker ps -q 2>/dev/null | head -100 | xargs -r docker inspect --format '{{.Name}}|{{.HostConfig.Privileged}}|{{.HostConfig.NetworkMode}}|{{.HostConfig.PidMode}}|{{range .Mounts}}{{.Source}};{{end}}' 2>/dev/null; echo '##unattended'; echo "package=$(dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null)"; apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null; echo '##uid0'; awk -F: '$3==0{print $1}' /etc/passwd 2>/dev/null; echo '##shadow_empty'; if [ "$(id -u)" = 0 ]; then echo checked; awk -F: '$2==""{print $1}' /etc/shadow 2>/dev/null; fi; echo '##aslr'; cat /proc/sys/kernel/randomize_va_space 2>/dev/null; echo '##ntp'; timedatectl show -p NTPSynchronized --value 2>/dev/null; true"##

    public static func read(_ transport: SSHTransport) async throws -> SecuritySnapshot {
        let result = try await transport.run(command, timeout: 20)
        guard result.exitCode == 0 else {
            throw SessionError.commandFailed(code: result.exitCode, detail: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return SecurityParser.parse(result.stdout)
    }
}

// MARK: - Exposure (the Security screen's ports list)

/// One port as the Security screen shows it: IPv4 and IPv6 sockets of the same port merged, widest reach first, with what
/// listens there and why it is worth a look. Built from the snapshot alone, so it reads the same on every platform.
public struct ExposedPort: Equatable, Sendable, Identifiable {
    public var id: String { "\(port)/\(proto)" }
    public var port: Int
    public var proto: String
    /// The widest scope among its sockets.
    public var scope: SecuritySnapshot.Listener.Scope
    public var addresses: [String]
    /// The containers that published it (Docker said so).
    public var containers: [String]
    /// A well-known service for the port (SSH, HTTPS, PostgreSQL…), when it is one.
    public var service: String?
    /// Why it deserves a look, in a few words each ("database", "past ufw", "Docker API without TLS").
    public var flags: [String]

    public var isExposed: Bool { scope.isExposed }
}

public enum SecurityExposure {
    /// Well-known ports, named so a row says what it is without a process name (which needs root for other users).
    public static let knownPorts: [Int: String] = [
        22: "SSH", 53: "DNS", 80: "HTTP", 443: "HTTPS", 25: "SMTP", 111: "rpcbind", 139: "SMB", 445: "SMB", 631: "Printing (CUPS)",
        2049: "NFS", 2375: "Docker API", 2376: "Docker API (TLS)", 3389: "Remote Desktop", 5900: "VNC", 8080: "HTTP (alt)",
        8443: "HTTPS (alt)", 41641: "Tailscale", 51820: "WireGuard", 32400: "Plex",
    ].merging(SecurityRules.sensitivePorts) { a, _ in a }

    public static func ports(_ s: SecuritySnapshot, ufwOn: Bool) -> [ExposedPort] {
        var merged: [String: ExposedPort] = [:]
        for l in s.listeners {
            let key = "\(l.port)/\(l.proto)"
            var row = merged[key] ?? ExposedPort(port: l.port, proto: l.proto, scope: l.scope, addresses: [], containers: [],
                                                  service: knownPorts[l.port], flags: [])
            row.scope = min(row.scope, l.scope)
            if !row.addresses.contains(l.address) { row.addresses.append(l.address) }
            merged[key] = row
        }
        for p in s.docker.published {
            guard let port = Int(p.port), var row = merged["\(port)/\(p.proto)"] else { continue }
            if !row.containers.contains(p.container) { row.containers.append(p.container) }
            if ufwOn, p.scope.isExposed, !row.flags.contains("past ufw") { row.flags.append("past ufw") }
            merged[row.id] = row
        }
        for (key, var row) in merged where row.isExposed {
            if row.proto == "tcp", SecurityRules.sensitivePorts[row.port] != nil { row.flags.insert("database or cache", at: 0) }
            if row.proto == "tcp", row.port == 2375 { row.flags.insert("no TLS", at: 0) }
            merged[key] = row
        }
        return merged.values.sorted { ($0.scope, $0.port, $0.proto) < ($1.scope, $1.port, $1.proto) }
    }
}
