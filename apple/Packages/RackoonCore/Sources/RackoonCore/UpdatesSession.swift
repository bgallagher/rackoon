import Foundation

public struct UpdatesState: Sendable, Equatable {
    public var snapshot: UpdatesSnapshot?
    /// Why the last refresh failed. The last good snapshot stays beside it.
    public var error: String?
    public var updatedAt: Date?
    /// An apt action is running.
    public var isWorking = false
    /// Why the last apt action failed, until the next one starts.
    public var actionError: String?
    /// Tail of the last successful action's output, for a "done" message.
    public var actionOutput: String?
    /// The last action failed because sudo wants a password (or rejected the one given): the app may ask for it.
    public var sudoPasswordNeeded = false
    /// The last action's sudo password was accepted (and sudo did not ask again for the command itself): it may be saved.
    public var sudoAccepted = false
    public init() {}
}

/// Reads one server's pending apt updates. Read-only: it reports what apt already knows from its cache (and what a
/// simulated upgrade would leave out) and never refreshes it or installs anything (that needs root and goes through `ActionPolicy`).
public actor UpdatesSession {
    public static let command = """
    echo '##apt'; if command -v apt-get >/dev/null 2>&1; then echo ok; else echo missing; fi; \
    echo '##upgradable'; apt list --upgradable 2>/dev/null; \
    echo '##deferred'; LC_ALL=C apt-get -s upgrade --with-new-pkgs 2>/dev/null | awk '/^[^ ]/{s=""} /^(The following upgrades have been deferred due to phasing|Not upgrading yet due to phasing):/{s="phased ";next} /^(The following packages have been kept back|Not upgrading):/{s="kept ";next} s!=""{for(i=1;i<=NF;i++) print s $i}'; \
    echo '##held'; apt-mark showhold 2>/dev/null; \
    echo '##refreshed'; stat -c %Y /var/lib/apt/periodic/update-success-stamp 2>/dev/null || stat -c %Y /var/lib/apt/lists 2>/dev/null; \
    echo '##reboot'; if [ -f /var/run/reboot-required ]; then echo yes; else echo no; fi
    """

    private let transport: SSHTransport
    private let policy: ActionPolicy
    public private(set) var state = UpdatesState()

    public init(transport: SSHTransport, policy: ActionPolicy = ActionPolicy()) {
        self.transport = transport
        self.policy = policy
    }

    /// With `sudoNonce`, confirms the password variant built with that nonce (the run must use the same one).
    public nonisolated func confirm(_ action: AptAction, sudoNonce: String? = nil) throws -> Confirmation {
        guard let intent = sudoNonce.map({ action.passwordIntent(nonce: $0) }) ?? action.intent else { throw PolicyError.invalidTarget }
        return try policy.confirm(intent)
    }

    /// Runs an apt action with its output streamed live (over a pty, so apt draws its normal progress), then re-reads
    /// the update list. Ignored while another action is running. Cancelling the calling task stops apt on the server.
    ///
    /// With `sudo`, the password variant with its nonce runs (`AptAction.passwordIntent(nonce:)`) and sudo's one prompt
    /// is answered over the pty. When sudo wants a password (or rejected it), `state.sudoPasswordNeeded` is set.
    public func performStreaming(_ action: AptAction, confirmation: Confirmation?, cols: Int, rows: Int,
                                 sudo: SudoCredential? = nil,
                                 onEvent: @escaping @Sendable (ActionStreamEvent) -> Void) async {
        guard !state.isWorking else { onEvent(.finished(exitCode: nil)); return }
        state.actionError = nil
        state.actionOutput = nil
        state.sudoPasswordNeeded = false
        state.sudoAccepted = false
        guard let intent = sudo.map({ action.passwordIntent(nonce: $0.nonce) }) ?? action.intent else {
            state.actionError = "Refusing to run apt: invalid package name."
            onEvent(.finished(exitCode: nil))
            return
        }
        do { try policy.authorize(intent, with: confirmation) } catch {
            state.actionError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            onEvent(.finished(exitCode: nil))
            return
        }
        state.isWorking = true
        let run = await StreamRunner.run(transport: transport, command: intent.command, cols: cols, rows: rows,
                                         sudo: sudo, onEvent: onEvent)
        state.sudoAccepted = run.sudo == .accepted && !run.sudoAsksEveryTime
        if let problem = run.sudoProblem {
            state.actionError = problem
            state.sudoPasswordNeeded = run.sudoRejected
        } else if !run.succeeded, run.needsSudoPassword {
            state.actionError = AptAction.explain(stdout: ANSI.strip(run.text), stderr: "", exitCode: run.exitCode ?? 1)
            state.sudoPasswordNeeded = true
        } else if run.succeeded {
            state.actionOutput = ANSI.strip(run.text).split(separator: "\n").suffix(5).joined(separator: "\n")
        } else if let code = run.exitCode {
            // Known causes get a readable sentence (sudo asking for a password, another apt holding the lock).
            state.actionError = AptAction.explain(stdout: ANSI.strip(run.text), stderr: "", exitCode: code)
        } else {
            state.actionError = run.failureMessage(label: "apt")
        }
        state.isWorking = false
        await refresh()
    }

    /// Runs an apt action, then re-reads the update list. Ignored while another action is running.
    public func perform(_ action: AptAction, confirmation: Confirmation?) async {
        guard !state.isWorking else { return }
        state.actionError = nil
        state.actionOutput = nil
        guard let intent = action.intent else {
            state.actionError = "Refusing to run apt: invalid package name."
            return
        }
        do { try policy.authorize(intent, with: confirmation) } catch {
            state.actionError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return
        }
        state.isWorking = true
        do {
            let result = try await transport.run(intent.command, timeout: action.timeout)
            if result.exitCode == 0 {
                state.actionOutput = result.stdout.split(separator: "\n").suffix(5).joined(separator: "\n")
            } else {
                state.actionError = AptAction.explain(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
            }
        } catch {
            state.actionError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        state.isWorking = false
        await refresh()
    }

    @discardableResult
    public func refresh() async -> UpdatesState {
        do {
            let result = try await transport.run(Self.command, timeout: 20)
            // The command ends with a conditional that always succeeds, so a non-zero exit means ssh itself failed.
            guard result.exitCode == 0 else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw UpdatesFailure(detail.isEmpty ? "ssh exited \(result.exitCode)" : detail)
            }
            state.snapshot = try UpdatesParser.parse(result.stdout)
            state.error = nil
            state.updatedAt = Date()
        } catch UpdatesParseError.notInstalled {
            state.error = "apt is not installed on this server."
        } catch {
            state.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        return state
    }

    private struct UpdatesFailure: Error, LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
