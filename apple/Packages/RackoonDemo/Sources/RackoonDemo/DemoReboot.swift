import Foundation
import RackoonCore

/// Canned answers for a fake reboot: the boot id changes about 12 seconds after the reboot command, and the
/// server "does not answer" in between. Never talks to a server.
public final class DemoRebootTransport: SSHTransport, @unchecked Sendable {
    public init() {}

    private let lock = NSLock()
    private var rebootedAt: Date?

    public func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult { answer(command) }

    private func answer(_ command: String) -> CommandResult {
        lock.withLock {
            if command == RebootSession.rebootCommand {
                rebootedAt = Date()
                return CommandResult(stdout: "##rebooting\n")
            }
            guard let at = rebootedAt else { return CommandResult(stdout: "demo-boot-1\n") }
            let age = Date().timeIntervalSince(at)
            if age < 4 { return CommandResult(stdout: "demo-boot-1\n") }          // still the old system
            if age < 12 { return CommandResult(stdout: "", stderr: "ssh: connect to host: Connection refused", exitCode: 255) }
            return CommandResult(stdout: "demo-boot-2\n")
        }
    }

    public func stream(_ command: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
}
