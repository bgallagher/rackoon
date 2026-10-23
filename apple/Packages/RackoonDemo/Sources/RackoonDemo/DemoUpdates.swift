import Foundation
import RackoonCore

/// Canned answers for the Updates screen. Never talks to a server.
public struct DemoUpdatesTransport: SSHTransport {
    public init() {}

    public func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        if command == UpdatesSession.command {
            return CommandResult(stdout: """
            ##apt
            ok
            ##upgradable
            Listing...
            openssl/noble-updates,noble-security 3.0.13-0ubuntu3.5 amd64 [upgradable from: 3.0.13-0ubuntu3.4]
            libssl3t64/noble-updates,noble-security 3.0.13-0ubuntu3.5 amd64 [upgradable from: 3.0.13-0ubuntu3.4]
            libc6/noble-updates 2.39-0ubuntu8.4 amd64 [upgradable from: 2.39-0ubuntu8.3]
            linux-image-generic/noble-updates 6.8.0-52.53 amd64 [upgradable from: 6.8.0-51.52]
            docker-ce/noble 5:27.5.1-1~ubuntu.24.04~noble amd64 [upgradable from: 5:27.4.0-1~ubuntu.24.04~noble]
            ##held
            docker-ce
            ##refreshed
            \(Int(Date().timeIntervalSince1970) - 3 * 3600)
            ##reboot
            yes
            """)
        }
        try await Task.sleep(for: .seconds(3))
        return CommandResult(stdout: "Reading package lists...\nBuilding dependency tree...\n0 upgraded (demo, nothing was run)\n")
    }

    /// Fake apt output, line by line with pauses, so the live terminal can be seen working. The exit marker at the end
    /// is what a real run prints (see StreamedCommand).
    public func stream(_ command: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let lines = ["Reading package lists... Done", "Building dependency tree... Done",
                             "The following packages will be upgraded:", "  libssl3t64 openssl", "2 upgraded, 0 newly installed, 0 to remove.",
                             "Get:1 http://archive.ubuntu.com/ubuntu noble-security/main amd64 openssl amd64 3.0.13-0ubuntu3.5 [1,005 kB]",
                             "Fetched 1,005 kB in 1s (1,100 kB/s)", "Preparing to unpack .../openssl_3.0.13-0ubuntu3.5_amd64.deb ...",
                             "Unpacking openssl (3.0.13-0ubuntu3.5) over (3.0.13-0ubuntu3.4) ...",
                             "Setting up openssl (3.0.13-0ubuntu3.5) ...", "(demo: nothing was installed)"]
                for line in lines {
                    try? await Task.sleep(for: .milliseconds(450))
                    if Task.isCancelled { break }
                    continuation.yield(line + "\r\n")
                }
                continuation.yield("\r\n##rackoon-exit:0\r\n")
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
