import Foundation
import RackoonCore

/// Canned answers to the `security` command (spec format, see spec/fixtures/security): homelab is mostly hardened with a
/// couple of things to look at, garage-nuc is a default install with no firewall. Nothing is sent anywhere.
enum DemoSecurity {
    static func output(for profile: DemoProfile) -> String {
        profile.hostname == "homelab" ? homelab : nuc
    }

    private static let homelab = """
    ##uid
    1000
    ##os
    id=ubuntu
    like=debian
    version=24.04
    ##sshd
    installed=yes
    active=1
    ##sshd_effective
    ##sshd_files
    #file /etc/ssh/sshd_config
    Include /etc/ssh/sshd_config.d/*.conf
    KbdInteractiveAuthentication no
    X11Forwarding yes
    #file /etc/ssh/sshd_config.d/10-rackoon-demo.conf
    PermitRootLogin no
    PasswordAuthentication no
    ##tailscale_ssh
    "RunSSH": true
    ##firewall
    ENABLED=yes
    ufw=active
    firewalld=inactive
    nftables=inactive
    ##guards
    fail2ban=active
    crowdsec=inactive
    sshguard=inactive
    ##listen
    udp   UNCONN 0      0       127.0.0.53%lo:53         0.0.0.0:*
    udp   UNCONN 0      0        100.100.40.7:41641      0.0.0.0:*
    tcp   LISTEN 0      4096         0.0.0.0:22          0.0.0.0:*
    tcp   LISTEN 0      4096            [::]:22             [::]:*
    tcp   LISTEN 0      4096         0.0.0.0:443         0.0.0.0:*
    tcp   LISTEN 0      4096         0.0.0.0:8096        0.0.0.0:*
    tcp   LISTEN 0      4096       127.0.0.1:5432        0.0.0.0:*
    tcp   LISTEN 0      4096    100.100.40.7:3001        0.0.0.0:*
    ##docker
    installed=yes
    traefik\t0.0.0.0:443->443/tcp
    jellyfin\t0.0.0.0:8096->8096/tcp
    immich-postgres\t127.0.0.1:5432->5432/tcp
    uptime-kuma\t100.100.40.7:3001->3001/tcp
    ##docker_inspect
    /traefik|false|proxy||/var/run/docker.sock;/opt/stacks/traefik/config;
    /jellyfin|false|media||/mnt/media;/opt/stacks/jellyfin/config;
    /immich-postgres|false|immich_default||/opt/stacks/immich/pg;
    /uptime-kuma|false|monitoring||/opt/stacks/uptime-kuma/data;
    ##unattended
    package=install ok installed
    APT::Periodic::Unattended-Upgrade "1";
    ##uid0
    root
    ##aslr
    2
    ##ntp
    yes

    """

    private static let nuc = """
    ##uid
    1000
    ##os
    id=debian
    like=
    version=12
    ##sshd
    installed=yes
    active=1
    ##sshd_effective
    ##sshd_files
    #file /etc/ssh/sshd_config
    Include /etc/ssh/sshd_config.d/*.conf
    KbdInteractiveAuthentication no
    X11Forwarding yes
    ##tailscale_ssh
    ##firewall
    ufw=inactive
    firewalld=inactive
    nftables=inactive
    ##guards
    fail2ban=inactive
    crowdsec=inactive
    sshguard=inactive
    ##listen
    tcp   LISTEN 0      128          0.0.0.0:22          0.0.0.0:*
    tcp   LISTEN 0      128             [::]:22             [::]:*
    tcp   LISTEN 0      4096         0.0.0.0:6379        0.0.0.0:*
    ##docker
    installed=yes
    redis\t0.0.0.0:6379->6379/tcp
    ##docker_inspect
    /redis|false|bridge||/srv/redis;
    ##unattended
    package=
    ##uid0
    root
    ##aslr
    2
    ##ntp
    yes

    """
}

// MARK: - Vulnerability lookup (S3)

extension DemoSecurity {
    /// Canned `security_packages` output: a few packages in step with the demo's pending updates (openssl and libc6 have
    /// updates waiting on homelab).
    public static func packages(for profile: DemoProfile) -> String {
        let homelab = profile.hostname == "homelab"
        let os = homelab ? "id=ubuntu\nlike=debian\nversion=24.04\ncodename=noble" : "id=debian\nlike=\nversion=12\ncodename=bookworm"
        let rows: [[String]] = homelab ? [
            ["curl", "8.5.0-2ubuntu10.6", "curl", "8.5.0-2ubuntu10.6"],
            ["libc6", "2.39-0ubuntu8.3", "glibc", "2.39-0ubuntu8.3"],
            ["libssl3t64", "3.0.13-0ubuntu3.4", "openssl", "3.0.13-0ubuntu3.4"],
            ["openssl", "3.0.13-0ubuntu3.4", "openssl", "3.0.13-0ubuntu3.4"],
            ["openssh-server", "1:9.6p1-3ubuntu13.5", "openssh", "1:9.6p1-3ubuntu13.5"],
        ] : [
            ["bash", "5.2.15-2+b7", "bash", "5.2.15-2"],
            ["libc6", "2.36-9+deb12u7", "glibc", "2.36-9+deb12u7"],
        ]
        return "##os\n\(os)\n##packages\n" + rows.map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
    }
}

/// Answers OSV.dev questions with made-up advisories (ids in 2099), so demo mode never sends a package list anywhere.
public struct DemoOSVClient: OSVClient {
    public init() {}

    private static let byPackage: [String: [String]] = [
        "openssl": ["DEMO-CVE-2099-0101"], "glibc": ["DEMO-CVE-2099-0102"], "openssh": ["DEMO-CVE-2099-0103"],
    ]

    private static let records: [String: (pkg: String, eco: String, fixed: String?, priority: String, summary: String)] = [
        "DEMO-CVE-2099-0101": ("openssl", "Ubuntu:24.04:LTS", "3.0.13-0ubuntu3.5", "medium", "Demo advisory: a made-up OpenSSL issue, fixed in the waiting update"),
        "DEMO-CVE-2099-0102": ("glibc", "Ubuntu:24.04:LTS", nil, "low", "Demo advisory: a made-up glibc issue with no fix released yet"),
        "DEMO-CVE-2099-0103": ("openssh", "Ubuntu:24.04:LTS", "1:9.6p1-3ubuntu13.8", "high", "Demo advisory: a made-up OpenSSH issue, fixed but not in the package lists yet"),
    ]

    public func post(_ url: URL, body: Data) async throws -> Data {
        let doc = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        let results: [[String: Any]] = (doc["queries"] as? [[String: Any]] ?? []).map { q in
            let name = (q["package"] as? [String: Any])?["name"] as? String ?? ""
            let ids = Self.byPackage[name] ?? []
            return ids.isEmpty ? [:] : ["vulns": ids.map { ["id": $0, "modified": "2099-01-01T00:00:00Z"] }]
        }
        return try JSONSerialization.data(withJSONObject: ["results": results])
    }

    public func get(_ url: URL) async throws -> Data {
        let id = url.lastPathComponent
        guard let r = Self.records[id] else { throw OSVError.http(404) }
        var events: [[String: String]] = [["introduced": "0"]]
        if let fixed = r.fixed { events.append(["fixed": fixed]) }
        let record: [String: Any] = [
            "id": id, "summary": r.summary, "modified": "2099-01-01T00:00:00Z", "aliases": [String(id.dropFirst(5))],
            "severity": [["type": "Ubuntu", "score": r.priority]],
            "affected": [["package": ["ecosystem": r.eco, "name": r.pkg], "ranges": [["type": "ECOSYSTEM", "events": events]]]],
        ]
        return try JSONSerialization.data(withJSONObject: record)
    }
}
