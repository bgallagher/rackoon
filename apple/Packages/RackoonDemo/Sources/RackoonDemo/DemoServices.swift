import Foundation
import RackoonCore

/// Demo answers for the Services screen: the `services` scan and the status, logs and start/stop/restart output of a unit.
/// Made-up but in the exact formats the parser reads (checked by building a `ServicesSnapshot` from them in demo mode).
enum DemoServices {
    private struct Unit {
        var name: String
        var description: String
        var active = "active", sub = "running", result = "success", file = "enabled", type = "simple"
        var path: String
        var pid = 0
        var startedSecondsAgo: Double = 7 * 86400
        var memory: Int64?
        var restarts = 0
    }

    private static func block(_ u: Unit, uptime: Double) -> String {
        let entered = u.active == "active" ? UInt64(max(1, uptime - u.startedSecondsAgo) * 1_000_000) : 0
        return """
        Id=\(u.name)
        Description=\(u.description)
        LoadState=loaded
        ActiveState=\(u.active)
        SubState=\(u.sub)
        Result=\(u.result)
        FragmentPath=\(u.path)
        UnitFileState=\(u.file)
        Type=\(u.type)
        MainPID=\(u.pid)
        ActiveEnterTimestampMonotonic=\(entered)
        NRestarts=\(u.restarts)
        MemoryCurrent=\(u.memory.map(String.init) ?? "[not set]")

        """
    }

    private static let plumbing: [Unit] = [
        Unit(name: "dbus.service", description: "D-Bus System Message Bus", file: "static", path: "/usr/lib/systemd/system/dbus.service", pid: 610, memory: 4_632_576),
        Unit(name: "cron.service", description: "Regular background program processing daemon", path: "/usr/lib/systemd/system/cron.service", pid: 640, memory: 540_672),
        Unit(name: "ssh.service", description: "OpenBSD Secure Shell server", path: "/usr/lib/systemd/system/ssh.service", pid: 700, memory: 6_385_664),
        Unit(name: "systemd-journald.service", description: "Journal Service", file: "static", path: "/usr/lib/systemd/system/systemd-journald.service", pid: 300, memory: 93_319_168),
        Unit(name: "systemd-resolved.service", description: "Network Name Resolution", path: "/usr/lib/systemd/system/systemd-resolved.service", pid: 520, memory: 9_342_976),
        Unit(name: "getty@tty1.service", description: "Getty on tty1", path: "/usr/lib/systemd/system/getty@.service", pid: 760, memory: 667_648),
        Unit(name: "containerd.service", description: "containerd container runtime", path: "/usr/lib/systemd/system/containerd.service", pid: 900, memory: 76_017_664),
    ]

    static func output(for profile: DemoProfile) -> String {
        let uptime = 12 * 86400.0
        let homelab = profile.hostname == "homelab"
        var units = plumbing + [
            Unit(name: "tailscaled.service", description: "Tailscale node agent", type: "notify", path: "/usr/lib/systemd/system/tailscaled.service",
                 pid: 812, startedSecondsAgo: 9 * 86400, memory: 41_943_040),
            Unit(name: "docker.service", description: "Docker Application Container Engine", type: "notify", path: "/usr/lib/systemd/system/docker.service",
                 pid: 1100, startedSecondsAgo: 12 * 86400 - 40, memory: 62_914_560),
            Unit(name: "beszel-agent.service", description: "Beszel Agent Service", path: "/etc/systemd/system/beszel-agent.service",
                 pid: 1300, startedSecondsAgo: 3 * 86400, memory: 9_728_000),
        ]
        var user: [Unit] = []
        var listen = """
        LISTEN 0      128          0.0.0.0:22        0.0.0.0:*    users:(("sshd",pid=700,fd=3))
        LISTEN 0      4096   100.100.40.7:41641     0.0.0.0:*    users:(("tailscaled",pid=812,fd=9))
        LISTEN 0      4096         0.0.0.0:45876     0.0.0.0:*    users:(("beszel-agent",pid=1300,fd=7))

        """
        var procs = """
        700\tsshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups \t/system.slice/ssh.service
        812\t/usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state --port=41641 \t/system.slice/tailscaled.service
        1300\t/opt/beszel-agent/beszel-agent \t/system.slice/beszel-agent.service

        """
        if homelab {
            units += [
                Unit(name: "wazuh-agent.service", description: "Wazuh agent", type: "forking", path: "/usr/lib/systemd/system/wazuh-agent.service",
                     pid: 1400, startedSecondsAgo: 12 * 86400 - 60, memory: 852_054_016),
                Unit(name: "pihole-FTL.service", description: "Pi-hole FTL", path: "/etc/systemd/system/pihole-FTL.service",
                     pid: 901, startedSecondsAgo: 2 * 86400 + 3600, memory: 52_428_800),
                Unit(name: "cloudflared.service", description: "cloudflared", active: "activating", sub: "auto-restart", result: "exit-code",
                     type: "notify", path: "/etc/systemd/system/cloudflared.service", restarts: 14),
                Unit(name: "backup-sync.service", description: "Nightly offsite backup (restic to B2)", active: "failed", sub: "failed",
                     result: "exit-code", path: "/etc/systemd/system/backup-sync.service", restarts: 0),
                Unit(name: "code-server@demo.service", description: "code-server", path: "/usr/lib/systemd/system/code-server@.service",
                     pid: 1500, startedSecondsAgo: 5 * 3600, memory: 209_715_200, restarts: 2),
            ]
            user = [
                Unit(name: "hermes-gateway.service", description: "Hermes Agent Gateway - Messaging Platform Integration",
                     path: "/home/demo/.config/systemd/user/hermes-gateway.service", pid: 2100, startedSecondsAgo: 26 * 3600,
                     memory: 333_389_824, restarts: 1),
                Unit(name: "pipewire.service", description: "PipeWire Multimedia Service", path: "/usr/lib/systemd/user/pipewire.service",
                     pid: 1312, memory: 15_380_480),
            ]
            listen += """
            LISTEN 0      32           0.0.0.0:53        0.0.0.0:*    users:(("pihole-FTL",pid=901,fd=5))
            LISTEN 0      32           0.0.0.0:8053      0.0.0.0:*    users:(("pihole-FTL",pid=901,fd=6))
            LISTEN 0      4096       127.0.0.1:8443      0.0.0.0:*    users:(("node",pid=1500,fd=20))
            LISTEN 0      2048       127.0.0.1:38165     0.0.0.0:*    users:(("hermes",pid=2100,fd=4))
            LISTEN 0      2048    100.100.40.7:9119      0.0.0.0:*    users:(("hermes",pid=2200,fd=12))
            LISTEN 0      511          0.0.0.0:3100      0.0.0.0:*    users:(("node-MainThread",pid=2300,fd=32))
            LISTEN 0      200        127.0.0.1:54329     0.0.0.0:*    users:(("postgres",pid=2310,fd=8))

            """
            procs += """
            901\t/usr/bin/pihole-FTL -f \t/system.slice/pihole-FTL.service
            1500\t/usr/lib/code-server/lib/node /usr/lib/code-server --bind-addr 127.0.0.1:8443 \t/system.slice/system-code\\x2dserver.slice/code-server@demo.service
            2100\t/home/demo/.hermes/bin/python3 -I -c import hermes \t/user.slice/user-1000.slice/user@1000.service/app.slice/hermes-gateway.service
            2200\t/home/demo/.hermes/bin/hermes dashboard --port 9119 \t/user.slice/user-1000.slice/session-12.scope
            2300\tnode /home/demo/.npm/_npx/4341/node_modules/.bin/paperclipai onboard --yes \t/user.slice/user-1000.slice/session-15.scope
            2310\t/home/demo/.npm/_npx/4341/node_modules/@embedded-postgres/bin/postgres -D /home/demo/.paperclip/db -p 54329 \t/user.slice/user-1000.slice/session-15.scope

            """
        }
        return "##uptime\n\(uptime)\n##uid\n1000\n##system\n" + units.map { block($0, uptime: uptime) }.joined()
            + "##user\n" + user.map { block($0, uptime: uptime) }.joined()
            + "##listen\n" + listen + "##procs\n" + procs
    }

    /// The status preview, Status and Recent Logs of a unit (reads), or nil when `command` is not one of them.
    static func read(_ command: String) -> String? {
        guard command.contains("systemctl") || command.contains("journalctl"),
              let unit = command.range(of: #"'[A-Za-z0-9:_.@\\-]+\.service'"#, options: .regularExpression).map({ String(command[$0].dropFirst().dropLast()) })
        else { return nil }
        if command.contains("journalctl") {
            return (0..<12).map { i in "Oct 15 09:\(String(format: "%02d", 10 + i)):04 homelab \(unit.replacingOccurrences(of: ".service", with: ""))[812]: demo log line \(i + 1)" }
                .joined(separator: "\n") + "\n"
        }
        let failed = unit.hasPrefix("backup-sync") || unit.hasPrefix("cloudflared")
        return """
        ● \(unit)
             Loaded: loaded (/etc/systemd/system/\(unit); enabled; preset: enabled)
             Active: \(failed ? "failed (Result: exit-code) since Wed 2026-10-15 03:00:12 UTC; 6h ago" : "active (running) since Mon 2026-10-13 08:12:40 UTC; 2 days ago")
           Main PID: \(failed ? "4021 (code=exited, status=1/FAILURE)" : "812")

        """
    }

    /// The streamed output of a start, stop or restart, or nil.
    static func streamLines(_ command: String) -> [String]? {
        for verb in ["start", "stop", "restart"] where command.contains("systemctl \(verb) ") || command.contains("systemctl --user \(verb) ") {
            return ["Now: \(verb == "stop" ? "inactive" : "active")"]
        }
        if command.contains("journalctl") || command.contains("systemctl status") || command.contains("systemctl --user status") {
            return read(command)?.components(separatedBy: "\n")
        }
        return nil
    }
}
