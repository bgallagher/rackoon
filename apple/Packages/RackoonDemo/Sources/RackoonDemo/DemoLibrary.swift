import Foundation
import RackoonCore

/// Canned output for demo mode: what the Commands library prints, the compose progress of stack actions, and live log lines.
enum DemoLibrary {
    static let listening = """
    LISTEN 0      4096         0.0.0.0:22         0.0.0.0:*
    LISTEN 0      4096         0.0.0.0:80         0.0.0.0:*
    LISTEN 0      4096         0.0.0.0:443        0.0.0.0:*
    LISTEN 0      4096   100.100.40.7:8096        0.0.0.0:*
    LISTEN 0      4096   100.100.40.7:3001        0.0.0.0:*
    """ + "\n"

    // MARK: log lines

    private static let templates: [(level: String, text: String)] = [
        ("info", "GET /api/server/ping 200 3ms"), ("info", "GET /web/index.html 200 11ms"), ("info", "POST /api/sessions 201 48ms"),
        ("info", "scheduled task finished in 212ms"), ("info", "cache refreshed (1,284 items)"), ("info", "GET /api/items?limit=50 200 27ms"),
        ("info", "client 100.100.40.12 connected"), ("warn", "slow response from upstream: 1.2s"), ("info", "GET /health 200 1ms"),
        ("warn", "certificate for app.example.com expires in 14 days"), ("info", "metrics scraped (36 series)"),
        ("error", "upstream timeout after 5s, retrying (2/3)"), ("info", "retry succeeded"), ("info", "GET /static/app.js 304 2ms"),
    ]

    static func logLines(count: Int) -> [String] {
        let now = Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return (0..<count).map { i in
            let t = templates[(i * 7 + Int(now.timeIntervalSince1970)) % templates.count]
            let ts = f.string(from: now.addingTimeInterval(-Double(count - i) * 1.7))
            return "\(ts) [\(t.level)] \(t.text)"
        }
    }

    // MARK: streamed commands (stack actions and library commands)

    static func streamLines(for command: String, profile: DemoProfile) -> [String] {
        if command.contains("docker compose") {
            let project = command.range(of: #"-p ([a-z0-9_-]+)"#, options: .regularExpression).map {
                String(command[$0]).replacingOccurrences(of: "-p ", with: "")
            } ?? ""
            let services = profile.stacks.first { $0.name == project }?.containers.map { "\(project)-\($0.service)-1" } ?? ["\(project)-app-1"]
            return composeLines(command, project: project, containers: services)
        }
        for verb in ["start", "stop", "restart"] where command.contains("docker \(verb) ") {
            let id = command.components(separatedBy: "docker \(verb) ").last?.split(separator: " ").first.map(String.init) ?? ""
            return [id]
        }
        if command.contains("docker pull ") {
            return ["2.21.5: Pulling from portainer/portainer-ce", "Digest: sha256:5f3c8d1b0e7a", "Status: Image is up to date"]
        }
        if command.contains("docker rm -f") {
            return [command.range(of: #"[0-9a-f]{12,64}"#, options: .regularExpression).map { String(command[$0]) } ?? ""]
        }
        if command.contains("docker system prune") {
            return ["Deleted Containers:", "4c0e1f2a9b11", "", "Deleted Networks:", "aiostreams_default", "", "Deleted Images:", "deleted: sha256:9f0b6c2d1e7a",
                    "", "Total reclaimed space: 1.24GB"]
        }
        if command.contains("systemctl restart tailscaled") { return ["tailscaled restarted: back online in 3s"] }
        if command.contains("systemctl restart docker") { return ["docker restarted: 20 containers started"] }
        if command.contains("apt-get clean") { return ["130M\t/var/cache/apt/archives → 4.0K\t/var/cache/apt/archives"] }
        if command.contains("journalctl --vacuum") { return ["Vacuuming done, freed 96.0M of archived journals from /var/log/journal."] }
        if let text = libraryOutput(for: command, profile: profile) { return text.components(separatedBy: "\n") }
        return ["(demo) done"]
    }

    private static func composeLines(_ command: String, project: String, containers: [String]) -> [String] {
        var out: [String] = []
        if command.hasSuffix(" pull") || command.contains(" pull ") {
            out.append("[+] Pulling \(containers.count)/\(containers.count)")
            out += containers.map { " ✔ \($0.replacingOccurrences(of: "\(project)-", with: "").replacingOccurrences(of: "-1", with: "")) Pulled" }
        } else if command.contains(" down") {
            out += containers.map { " ✔ Container \($0)  Stopped" } + containers.map { " ✔ Container \($0)  Removed" } + [" ✔ Network \(project)_default  Removed"]
        } else if command.contains("--build") {
            out += ["[+] Building 0.9s (9/9) FINISHED", " => [internal] load build definition from Dockerfile", " => CACHED [2/3] COPY nginx.conf /etc/nginx/conf.d/default.conf",
                    " => exporting to image"] + containers.map { " ✔ Container \($0)  Started" }
        } else if command.contains(" restart") {
            out += containers.map { " ✔ Container \($0)  Started" }
        } else {
            out.append("[+] Running \(containers.count)/\(containers.count)")
            out += containers.map { " ✔ Container \($0)  Started" }
        }
        return out
    }

    // MARK: library output

    /// What a library command prints, matched by its script (or its dry-run preview) inside the command that was sent.
    static func output(for command: String, profile: DemoProfile) -> String? {
        for entry in CommandLibrary.all {
            if let preview = entry.preview, command.contains(preview) { return previewText(entry.id, profile: profile) }
        }
        return libraryOutput(for: command, profile: profile)
    }

    private static func previewText(_ id: String, profile: DemoProfile) -> String {
        switch id {
        case "docker_prune":
            return "Stopped container: old-test-1\nUnused network: aiostreams_default\nDangling image: 9f0b6c2d1e7a (412MB)\n\nBuild cache and totals:\n" + dockerDf
        case "apt_clean": return "130M\t/var/cache/apt/archives\n42 cached packages"
        case "journal_vacuum": return "Archived and active journals take up 170.3M in the file system."
        case "restart_tailscale": return "\(profile.tailscaleIP ?? "100.100.40.7")  \(profile.hostname)  you@  linux  idle"
        case "restart_docker": return profile.stacks.flatMap(\.containers).prefix(4).map { "Will be interrupted: \($0.service)" }.joined(separator: "\n")
        default: return ""
        }
    }

    private static let dockerDf = """
    TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
    Images          23        20        9.84GB    1.24GB (12%)
    Containers      20        19        1.2GB     0B (0%)
    Local Volumes   14        12        3.1GB     210MB (6%)
    Build Cache     41        0         642MB     642MB
    """

    private static func libraryOutput(for command: String, profile: DemoProfile) -> String? {
        for entry in CommandLibrary.all where !entry.script.isEmpty {
            let needle = entry.script.components(separatedBy: "{")[0]
            guard !needle.isEmpty, command.contains(needle) else { continue }
            return text(for: entry.id, profile: profile)
        }
        return nil
    }

    private static func text(for id: String, profile: DemoProfile) -> String? {
        let containers = profile.stacks.flatMap { s in s.containers.map { (s, $0) } }
        switch id {
        case "disk_usage": return """
            Filesystem     Type  Size  Used Avail Use% Mounted on
            /dev/nvme0n1p2 ext4  465G  191G  255G  43% /
            /dev/nvme0n1p1 vfat  1.0G  6.1M  1.0G   1% /boot/efi

            Inodes:
            Filesystem      Inodes  IUsed   IFree IUse% Mounted on
            /dev/nvme0n1p2 30498816 412987 30085829    2% /
            """
        case "biggest_folders": return "191G\t/\n98G\t/mnt/media\n41G\t/var\n38G\t/var/lib\n37G\t/var/lib/docker\n21G\t/home\n9.6G\t/opt\n2.1G\t/usr\n1.3G\t/swap.img"
        case "docker_disk": return dockerDf
        case "journal_size": return "Archived and active journals take up 170.3M in the file system."
        case "top_cpu": return [
            "  PID USER     %CPU %MEM     ELAPSED COMMAND",
            " 2210 root      3.2  3.4 27-09:12:14 hass",
            "18873 root      2.1  5.3  3-02:40:11 node",
            "17412 999       1.4  3.7  3-02:40:48 jellyfin",
            " 1021 root      0.9  1.1 27-09:36:01 dockerd",
            " 2988 root      0.5  0.9 27-09:35:40 containerd"].joined(separator: "\n")
        case "top_memory": return [
            "  PID USER     %CPU %MEM     RSS COMMAND",
            "19411 root      0.3  9.1 1492012 python3",
            "18873 root      2.1  5.3  880114 node",
            " 2210 root      3.2  3.4  556772 hass",
            "17412 999       1.4  3.7  612008 jellyfin"].joined(separator: "\n")
        case "memory": return """
                           total        used        free      shared  buff/cache   available
            Mem:            15Gi       6.1Gi       3.9Gi       112Mi       5.4Gi       9.4Gi
            Swap:          2.0Gi          0B       2.0Gi

            Swap devices:
            NAME      TYPE SIZE USED PRIO
            /swap.img file   2G   0B   -2
            """
        case "load": return " 10:41:07 up 27 days,  9:36,  1 user,  load average: 0.42, 0.51, 0.48\n\ncores: \(profile.cores)"
        case "container_stats":
            return "CONTAINER ID   NAME                       CPU %     MEM USAGE / LIMIT     MEM %     NET I/O           BLOCK I/O\n"
                + containers.prefix(8).map { s, c in
                    String(format: "%@   %@   %.2f%%     %.1fMiB / 15.6GiB     %.2f%%     1.2MB / 340kB     0B / 0B", String(c.service.hashValue, radix: 16).prefix(12).padding(toLength: 12, withPad: "0", startingAt: 0),
                           "\(s.name)-\(c.service)-1".padding(toLength: 25, withPad: " ", startingAt: 0), c.cpu, c.memMB, c.memMB / 156)
                }.joined(separator: "\n")
        case "containers_all":
            return "NAMES                          STATUS                   IMAGE\n" + containers.map { s, c in
                "\("\(s.name)-\(c.service)-1".padding(toLength: 30, withPad: " ", startingAt: 0)) \(c.status.padding(toLength: 24, withPad: " ", startingAt: 0)) \(c.image)"
            }.joined(separator: "\n")
        case "containers_problems": return "NAMES     STATUS    IMAGE\n\nUnhealthy:\nNAMES                  STATUS                   IMAGE\nmonitoring-promtail-1  Up 2 days (unhealthy)    grafana/promtail:3.3.0"
        case "restart_counts": return containers.map { s, c in "\(s.name)-\(c.service)-1: \(c.health == "unhealthy" ? 14 : 0) restarts (running)" }.joined(separator: "\n")
        case "container_logs": return logLines(count: 30).joined(separator: "\n")
        case "images": return """
            REPOSITORY                               TAG        SIZE      CREATED
            jellyfin/jellyfin                        10.10.3    1.3GB     3 weeks ago
            ghcr.io/immich-app/immich-server         v1.122.0   1.8GB     5 days ago
            louislam/uptime-kuma                     1          564MB     2 months ago
            adguard/adguardhome                      v0.107.55  64.2MB    4 weeks ago

            Dangling images: 2
            """
        case "volumes": return "DRIVER    VOLUME NAME\nlocal     immich_pgdata\nlocal     nextcloud_db\nlocal     grafana_data\nlocal     paperless_data"
        case "docker_events": return logLines(count: 6).map { $0.replacingOccurrences(of: "[info]", with: "container exec_start:") }.joined(separator: "\n")
        case "listening_ports": return """
            Netid State  Recv-Q Send-Q   Local Address:Port  Peer Address:Port Process
            tcp   LISTEN 0      4096           0.0.0.0:22         0.0.0.0:*     users:(("sshd",pid=902,fd=3))
            tcp   LISTEN 0      4096           0.0.0.0:443        0.0.0.0:*     users:(("docker-proxy",pid=3120,fd=7))
            tcp   LISTEN 0      4096      100.100.40.7:8096       0.0.0.0:*     users:(("docker-proxy",pid=3188,fd=7))
            udp   UNCONN 0      0         100.100.40.7:53         0.0.0.0:*     users:(("docker-proxy",pid=3301,fd=7))
            """
        case "addresses": return """
            lo               UNKNOWN        127.0.0.1/8 ::1/128
            eno1             UP             203.0.113.24/24 2001:db8:a:1::24/64
            tailscale0       UNKNOWN        100.100.40.7/32
            docker0          DOWN           172.17.0.1/16

            default via 203.0.113.1 dev eno1 proto dhcp src 203.0.113.24 metric 100
            """
        case "tailscale_status": return "100.100.40.7   homelab      you@   linux   -\n100.100.40.12  macbook      you@   macOS   active; direct 192.168.1.20:41641\n100.100.40.31  phone        you@   iOS     idle"
        case "public_ip": return "203.0.113.24"
        case "dns_check": return "nameserver 127.0.0.53\noptions edns0 trust-ad\n\ngithub.com -> 140.82.121.4    github.com\ncloudflare.com -> 104.16.133.229 cloudflare.com"
        case "cert_expiry": return "subject=CN = example.com\nissuer=C = US, O = Let's Encrypt, CN = R11\nnotBefore=Sep 22 04:11:09 2026 GMT\nnotAfter=Dec 21 04:11:08 2026 GMT"
        case "recent_errors": return "Oct 10 06:12:41 homelab kernel: nvme nvme0: missing or invalid SUBNQN field.\nOct 10 08:03:17 homelab dockerd[1021]: level=error msg=\"promtail healthcheck failed\""
        case "failed_services": return "  UNIT LOAD ACTIVE SUB DESCRIPTION\n0 loaded units listed."
        case "kernel_messages": return "[Sat Oct 10 10:27:44 2026] eth0: renamed from veth75ac460\n[Sat Oct 10 10:27:44 2026] br-3f1a: port 4(veth02c1) entered forwarding state"
        case "logins": return " 10:41:07 up 27 days,  9:36,  1 user,  load average: 0.42, 0.51, 0.48\nUSER     TTY      FROM             LOGIN@   IDLE WHAT\nroot     pts/0    100.100.40.12    09:12    0.00s w\n\nroot     pts/0        100.100.40.12    Sat Oct 10 09:12   still logged in"
        case "fail2ban": return "Status\n|- Number of jail:\t1\n`- Jail list:\tsshd\n\nStatus for the jail: sshd\n|- Currently failed:\t0\n|- Total failed:\t41\n`- Currently banned:\t2"
        case "firewall": return "Status: active\n\nTo                         Action      From\n--                         ------      ----\n22/tcp                     ALLOW IN    Anywhere\n443/tcp                    ALLOW IN    Anywhere\nAnywhere on tailscale0     ALLOW IN    Anywhere"
        case "failed_ssh": return "Oct 10 03:21:09 homelab sshd[28811]: Invalid user admin from 45.141.84.10\nOct 10 03:21:12 homelab sshd[28811]: Failed password for invalid user admin from 45.141.84.10\n\n(last 24 hours; nothing above means none)"
        case "security_updates": return "openssl/noble-updates,noble-security 3.0.13-0ubuntu3.5 amd64 [upgradable from: 3.0.13-0ubuntu3.4]\nlibssl3t64/noble-updates,noble-security 3.0.13-0ubuntu3.5 amd64 [upgradable from: 3.0.13-0ubuntu3.4]"
        case "autoremove_preview": return "Remv linux-image-6.8.0-45-generic [6.8.0-45.45]\n1 upgraded, 0 newly installed, 1 to remove and 4 not upgraded."
        default: return nil
        }
    }
}

/// A small made-up file tree for the Files screen in demo mode, answered in the format of spec `files_list`.
enum DemoFiles {
    static let home = "/home/demo"

    private struct Item { let name: String; let dir: Bool; let size: Int; let mode: String; let ago: Double }
    private static let tree: [String: [Item]] = [
        "/": [Item(name: "home", dir: true, size: 4096, mode: "drwxr-xr-x", ago: 90 * 86400),
              Item(name: "opt", dir: true, size: 4096, mode: "drwxr-xr-x", ago: 40 * 86400),
              Item(name: "srv", dir: true, size: 4096, mode: "drwxr-xr-x", ago: 120 * 86400),
              Item(name: "etc", dir: true, size: 12288, mode: "drwxr-xr-x", ago: 2 * 86400)],
        "/home": [Item(name: "demo", dir: true, size: 4096, mode: "drwxr-x---", ago: 3600)],
        "/home/demo": [Item(name: "backups", dir: true, size: 4096, mode: "drwxr-xr-x", ago: 86400),
                       Item(name: ".bashrc", dir: false, size: 3771, mode: "-rw-r--r--", ago: 200 * 86400),
                       Item(name: "notes.txt", dir: false, size: 812, mode: "-rw-r--r--", ago: 5 * 86400),
                       Item(name: "docker-cleanup.sh", dir: false, size: 1290, mode: "-rwxr-xr-x", ago: 12 * 86400)],
        "/home/demo/backups": [Item(name: "photos-2026-09.tar.gz", dir: false, size: 482_344_192, mode: "-rw-r--r--", ago: 30 * 86400),
                               Item(name: "stacks-2026-10-01.tar.gz", dir: false, size: 3_145_728, mode: "-rw-r--r--", ago: 9 * 86400)],
        "/opt": [Item(name: "stacks", dir: true, size: 4096, mode: "drwxr-xr-x", ago: 3600)],
        "/opt/stacks": ["jellyfin", "immich", "homepage", "uptime-kuma", "vaultwarden", "adguard", "paperless", "traefik"]
            .enumerated().map { Item(name: $1, dir: true, size: 4096, mode: "drwxr-xr-x", ago: Double($0 + 1) * 86400) },
        "/opt/stacks/jellyfin": [Item(name: "compose.yaml", dir: false, size: 1432, mode: "-rw-r--r--", ago: 4 * 86400),
                                 Item(name: ".env", dir: false, size: 96, mode: "-rw-------", ago: 4 * 86400),
                                 Item(name: "config", dir: true, size: 4096, mode: "drwxr-xr-x", ago: 86400)],
    ]

    static func answer(for command: String) -> String? {
        guard command.hasPrefix("cd -P -- '") else { return nil }
        let rest = command.dropFirst("cd -P -- '".count)
        guard let end = rest.firstIndex(of: "'") else { return nil }
        let path = String(rest[..<end])
        guard let items = tree[path] else { return path + "\0" }
        let now = Date().timeIntervalSince1970
        var out = path + "\0"
        for i in items {
            out += ["\(i.dir ? "d" : "f")", "\(i.dir ? "d" : "f")", "\(i.size)", String(format: "%.1f", now - i.ago), i.mode, "demo", i.name, ""]
                .joined(separator: "\0") + "\0"
        }
        return out
    }
}
