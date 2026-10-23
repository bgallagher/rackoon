import Foundation
import RackoonCore

/// Demo mode's terminal: a login banner and canned answers to a few commands. It never runs what is typed, so it is
/// safe while taking screenshots. One table serves both apps: the Mac runs it as a generated bash script (through the
/// highlighting relay), iOS answers from it in-process (`DemoShellSession`).
public enum DemoShell {
    enum Pattern: Equatable {
        case exact(String)
        case prefix(String)

        func matches(_ line: String) -> Bool {
            switch self {
            case .exact(let word): line == word
            case .prefix(let start): line.hasPrefix(start)
            }
        }
    }

    enum Reply: Equatable {
        case text(String)
        case hostname
        case clear
        case logout
        case nothing
    }

    private static func columns(_ rows: [[String]]) -> String {
        rows.map { r in
            [r[0].padding(toLength: 14, withPad: " ", startingAt: 0), r[1].padding(toLength: 44, withPad: " ", startingAt: 0),
             r[2].padding(toLength: 22, withPad: " ", startingAt: 0), r[3]].joined(separator: " ")
        }.joined(separator: "\n")
    }

    static let rules: [(patterns: [Pattern], reply: Reply)] = [
        ([.exact("")], .nothing),
        ([.exact("exit"), .exact("logout")], .logout),
        ([.exact("clear")], .clear),
        ([.exact("whoami")], .text("root")),
        ([.exact("hostname")], .hostname),
        ([.exact("uptime")], .text(" 10:41:07 up 27 days,  9:36,  1 user,  load average: 0.42, 0.51, 0.48")),
        ([.prefix("docker ps")], .text(columns([
            ["CONTAINER", "IMAGE", "STATUS", "PORTS"],
            ["4f1c0a9d3b21", "jellyfin/jellyfin:10.10.3", "Up 3 days (healthy)", "100.100.40.7:8096->8096/tcp"],
            ["9a7e22c5d610", "ghcr.io/immich-app/immich-server:v1.122.0", "Up 3 days (healthy)", "100.100.40.7:2283->2283/tcp"],
            ["2b8d41e07f93", "adguard/adguardhome:v0.107.55", "Up 9 days", "100.100.40.7:3000->3000/tcp"],
            ["e03c6a1f5d48", "grafana/promtail:3.3.0", "Up 2 days (unhealthy)", ""],
        ]))),
        ([.prefix("df -h")], .text("""
            Filesystem      Size  Used Avail Use% Mounted on
            /dev/nvme0n1p2  465G  191G  255G  43% /
            /dev/nvme0n1p1  1.0G  6.1M  1.0G   1% /boot/efi
            """)),
        ([.prefix("free")], .text("""
                           total        used        free      shared  buff/cache   available
            Mem:            15Gi       6.1Gi       3.9Gi       112Mi       5.4Gi       9.4Gi
            Swap:          2.0Gi          0B       2.0Gi
            """)),
        ([.prefix("ip a"), .prefix("ip addr"), .prefix("ip -br a")], .text("""
            lo               UNKNOWN        127.0.0.1/8 ::1/128
            eno1             UP             203.0.113.24/24 2001:db8:a:1::24/64
            tailscale0       UNKNOWN        100.100.40.7/32
            docker0          DOWN           172.17.0.1/16
            """)),
        ([.prefix("ls")], .text("backups  docker-compose.yml  notes.txt  stacks")),
        ([.exact("pwd")], .text("/root")),
    ]

    static let banner = """
        Welcome to Ubuntu 24.04.2 LTS (GNU/Linux 6.8.0-52-generic x86_64)

         * Documentation:  https://help.ubuntu.com
         * Management:     https://landscape.canonical.com
         * Support:        https://ubuntu.com/pro

          System load:  0.42               Processes:             312
          Usage of /:   41.2% of 465GB     Users logged in:       1
          Memory usage: 39%                IPv4 address for eno1: 203.0.113.24
          Swap usage:   0%                 IPv4 address for tailscale0: 100.100.40.7

        5 updates can be applied immediately.
        2 of these updates are standard security updates.

        *** System restart required ***
        Last login: Sat Oct 10 09:12:44 2026 from 100.100.40.12
        """

    static func prompt(host: String) -> String { "root@\(host):~# " }

    /// What the shell answers to one typed line.
    static func reply(to line: String) -> Reply {
        rules.first { $0.patterns.contains { $0.matches(line) } }?.reply
            ?? .text("\(line): demo shell, so only a few commands are simulated")
    }

    /// The same table as a bash script, for the Mac's demo terminal (run with the server name as `$1`).
    public static var bashScript: String {
        // Our own constant text, often several lines: single quotes carry newlines in bash (ShellQuote, which is for
        // values sent to servers, rightly refuses them).
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var lines = [
            "#!/bin/bash",
            "# Demo-mode terminal: prints a login banner and answers a few commands with canned text.",
            "# It never runs what you type, so it is safe to use while taking screenshots.",
            "host=\"${1:-homelab}\"",
            "printf '%s\\n' \(quoted(banner))",
            "while true; do",
            "  IFS= read -e -r -p \"root@${host}:~# \" line || exit 0",
            "  case \"$line\" in",
        ]
        for rule in rules {
            let pattern = rule.patterns.map { p -> String in
                switch p {
                case .exact(let word): return word.isEmpty ? "\"\"" : quoted(word)
                case .prefix(let start): return quoted(start) + "*"
                }
            }.joined(separator: "|")
            let action: String = switch rule.reply {
            case .nothing: ""
            case .logout: "echo logout; exit 0"
            case .clear: "printf '\\033c'"
            case .hostname: "echo \"$host\""
            case .text(let text): "printf '%s\\n' \(quoted(text))"
            }
            lines.append("    \(pattern)) \(action) ;;")
        }
        lines += ["    *) echo \"$line: demo shell, so only a few commands are simulated\" ;;", "  esac", "done"]
        return lines.joined(separator: "\n") + "\n"
    }
}

/// The demo shell on iOS, where no process can be started: the same banner and answers, with simple line editing
/// (typed characters echo, backspace erases, Return answers, Ctrl-C drops the line, Ctrl-D or `exit` ends it).
public final class DemoShellSession: TerminalShell, @unchecked Sendable {
    public let output: AsyncStream<[UInt8]>
    private let sink: AsyncStream<[UInt8]>.Continuation
    private let host: String
    private let lock = NSLock()
    private var line: [UInt8] = []
    private var end: SessionEnd?
    private var waiters: [CheckedContinuation<SessionEnd, Never>] = []

    public init(host: String) {
        self.host = host
        (output, sink) = AsyncStream.makeStream(of: [UInt8].self)
        emit(DemoShell.banner + "\n" + DemoShell.prompt(host: host))
    }

    private func emit(_ text: String) {
        // A terminal wants CR LF; the table is written with plain line ends.
        sink.yield(Array(text.replacingOccurrences(of: "\n", with: "\r\n").utf8))
    }

    public func write(_ bytes: [UInt8]) async {
        for byte in bytes {
            let typed: [UInt8]? = lock.withLock {
                guard end == nil else { return nil }
                switch byte {
                case 0x0D, 0x0A:
                    let done = line
                    line = []
                    return done
                case 0x7F, 0x08:
                    if !line.isEmpty {
                        line.removeLast()
                        sink.yield([0x08, 0x20, 0x08])
                    }
                case 0x03:
                    line = []
                    sink.yield(Array("^C\r\n\(DemoShell.prompt(host: host))".utf8))
                case 0x04 where line.isEmpty:
                    return Array("exit".utf8)
                case 0x20...0x7E:
                    line.append(byte)
                    sink.yield([byte])
                default:
                    break   // escape sequences (arrows) and other control keys do nothing here
                }
                return nil
            }
            if let typed { answer(String(decoding: typed, as: UTF8.self).trimmingCharacters(in: .whitespaces)) }
        }
    }

    private func answer(_ text: String) {
        emit("\n")
        switch DemoShell.reply(to: text) {
        case .nothing: break
        case .hostname: emit(host + "\n")
        case .clear: sink.yield(Array("\u{1B}c".utf8))
        case .text(let reply): emit(reply + "\n")
        case .logout:
            emit("logout\n")
            finish(.remoteExit(0))
            return
        }
        emit(DemoShell.prompt(host: host))
    }

    public func resize(cols: Int, rows: Int) async {}

    public func awaitEnd() async -> SessionEnd {
        await withCheckedContinuation { c in
            let done: SessionEnd? = lock.withLock {
                if let end { return end }
                waiters.append(c)
                return nil
            }
            if let done { c.resume(returning: done) }
        }
    }

    public func close() async { finish(.closedByUser) }

    private func finish(_ reason: SessionEnd) {
        let toResume: [CheckedContinuation<SessionEnd, Never>] = lock.withLock {
            guard end == nil else { return [] }
            end = reason
            defer { waiters = [] }
            return waiters
        }
        sink.finish()
        for w in toResume { w.resume(returning: reason) }
    }
}

/// Opens demo terminals for a demo server.
public struct DemoTerminals: TerminalOpening {
    let host: String

    public init(host: String) { self.host = host }

    public func openTerminal(cols: Int, rows: Int, command: String?) async throws -> any TerminalShell {
        DemoShellSession(host: host)
    }
}
