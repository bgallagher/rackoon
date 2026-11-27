import CryptoKit
import LocalAuthentication
import Security
import Foundation
import RackoonCore
import RackoonSSHSystem

// Headless check of OpenSSHTransport: `swift run rackoon-probe <host> [command]`
let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: rackoon-probe <host> [command]\n".utf8))
    exit(2)
}
if args.count > 2, args[2] == "auth-methods" {
    // Which ways of approving macOS offers right now. Never prompts. usage: rackoon-probe local auth-methods
    let probe = LAContext()
    print("biometry type: \(probe.biometryType == .touchID ? "Touch ID" : probe.biometryType == .none ? "none" : "\(probe.biometryType.rawValue)")")
    var policies: [(String, LAPolicy)] = [("Touch ID (biometrics)", .deviceOwnerAuthenticationWithBiometrics)]
    if #available(macOS 15.0, *) {
        policies += [("Apple Watch (companion)", .deviceOwnerAuthenticationWithCompanion),
                     ("Touch ID or Apple Watch", .deviceOwnerAuthenticationWithBiometricsOrCompanion)]
    }
    policies.append(("any: Touch ID, Watch or password", .deviceOwnerAuthentication))
    for (name, policy) in policies {
        var error: NSError?
        let ok = LAContext().canEvaluatePolicy(policy, error: &error)
        print("\(ok ? "yes" : "no ") \(name)\(error.map { "  (\(LAError.Code(rawValue: $0.code).map { "\($0)" } ?? "\($0.code)"): \($0.localizedDescription))" } ?? "")")
    }
    exit(0)
}
if args.count > 2, args[2] == "watch-check" {
    // Two ways to get approval BEFORE using a Secure Enclave key, to see which one offers the Apple Watch (lid closed).
    // Throwaway in-memory keys only: nothing is written to the keychain or to disk.
    // usage: rackoon-probe local watch-check
    var flags: SecAccessControlCreateFlags = [.privateKeyUsage, .or, .biometryAny, .devicePasscode]
    if #available(macOS 15.0, *) { flags.insert(.companion) }
    guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, nil) else { exit(1) }
    func trial(_ name: String, _ approve: (LAContext) async throws -> Void) async {
        do {
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
            let ephemeral = P256.KeyAgreement.PrivateKey()
            func symmetric(_ secret: SharedSecret) -> SymmetricKey {
                secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("rackoon-watch-check".utf8), outputByteCount: 32)
            }
            let sealed = try AES.GCM.seal(Data("dummy".utf8), using: symmetric(try ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey)))
            print("\n\(name): approve with your Watch if it offers it...")
            let context = LAContext()
            try await approve(context)
            print("   approved; now using the key (if a SECOND prompt appears, note it)")
            let unlocked = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: key.dataRepresentation, authenticationContext: context)
            let opened = try AES.GCM.open(sealed, using: symmetric(try unlocked.sharedSecretFromKeyAgreement(with: ephemeral.publicKey)))
            print(String(decoding: opened, as: UTF8.self) == "dummy" ? "   PASS" : "   FAIL: wrong plaintext")
        } catch {
            print("   FAIL or cancelled: \(error)")
        }
    }
    await trial("B. macOS's own approval policy (Touch ID, Watch or password)") { context in
        _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "test approval B (Rackoon check)")
    }
    await trial("C. approval for the key's own access rule") { context in
        _ = try await context.evaluateAccessControl(access, operation: .useKeyKeyExchange, localizedReason: "test approval C (Rackoon check)")
    }
    // D. The app's own unlock path (RackoonSSHSystem.SecureEnclaveSealer): the one that matters.
    print("\nD. Rackoon's real unlock path: approve with your Watch (lid closed) or Touch ID...")
    do {
        let sealer = SecureEnclaveSealer()
        let sealed = try sealer.seal(Data("dummy".utf8), authenticating: Data("aad".utf8))
        let started = Date()
        let opened = try await sealer.open(sealed, authenticating: Data("aad".utf8), reason: "test Rackoon's real unlock path")
        print("   \(String(decoding: opened, as: UTF8.self) == "dummy" ? "PASS" : "FAIL: wrong plaintext") in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        print("   (how many prompts appeared, and was the Watch offered?)")
    } catch {
        print("   FAIL or cancelled: \(error)")
    }
    exit(0)
}
if args.count > 2, args[2] == "policy-check" {
    // Which approval policy offers the Apple Watch (lid closed) AND leaves a context the Secure Enclave key accepts.
    // Throwaway in-memory keys only. usage: rackoon-probe local policy-check [companion|either|any]...
    var flags: SecAccessControlCreateFlags = [.privateKeyUsage, .or, .biometryAny, .devicePasscode]
    if #available(macOS 15.0, *) { flags.insert(.companion) }
    guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, nil) else { exit(1) }
    var trials: [(String, LAPolicy)] = [("any", .deviceOwnerAuthentication)]
    if #available(macOS 15.0, *) {
        trials = [("companion", .deviceOwnerAuthenticationWithCompanion), ("either", .deviceOwnerAuthenticationWithBiometricsOrCompanion)] + trials
    }
    let wanted = Set(args.dropFirst(3))
    for (name, policy) in trials where wanted.isEmpty || wanted.contains(name) {
        print("\n\(name): approve with your Watch if it is offered, else cancel")
        let started = Date()
        do {
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let context = LAContext()
            _ = try await context.evaluatePolicy(policy, localizedReason: "test approval '\(name)' (Rackoon check)")
            print("   approved after \(String(format: "%.1f", Date().timeIntervalSince(started))) s; using the key")
            let unlocked = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: key.dataRepresentation, authenticationContext: context)
            let a = try unlocked.sharedSecretFromKeyAgreement(with: ephemeral.publicKey)
            let b = try ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey)
            print(a == b ? "   PASS (no second prompt expected)" : "   FAIL: secrets differ")
        } catch {
            let ns = error as NSError
            print("   FAIL or cancelled after \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        }
    }
    exit(0)
}
if args.count > 2, args[2] == "unlock-check" {
    // Only the app's real unlock path (SecureEnclaveSealer): one prompt expected. usage: rackoon-probe local unlock-check
    do {
        let sealer = SecureEnclaveSealer()
        let sealed = try sealer.seal(Data("dummy".utf8), authenticating: Data("aad".utf8))
        print("approve with your Watch (lid closed), Touch ID or your password...")
        let started = Date()
        let opened = try await sealer.open(sealed, authenticating: Data("aad".utf8), reason: "test Rackoon's real unlock path")
        print(String(decoding: opened, as: UTF8.self) == "dummy" ? "PASS" : "FAIL: wrong plaintext", "in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
    } catch {
        print("FAIL or cancelled: \(error)")
    }
    exit(0)
}
if args.count > 2, args[2] == "secure-enclave-check" {
    // Can this unsigned-for-distribution build unlock a Secure Enclave key with Touch ID OR Apple Watch OR the login
    // password? Uses a THROWAWAY key that lives only in memory: nothing is written to the keychain or to disk.
    // usage: rackoon-probe local secure-enclave-check   (run it in a terminal; a system prompt appears)
    guard SecureEnclave.isAvailable else { print("FAIL: no Secure Enclave on this Mac"); exit(1) }
    var flags: SecAccessControlCreateFlags = [.privateKeyUsage, .or, .biometryAny, .devicePasscode]
    if #available(macOS 15.0, *) { flags.insert(.companion) }
    var cfError: Unmanaged<CFError>?
    guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &cfError) else {
        print("FAIL: access control: \(cfError!.takeRetainedValue())"); exit(1)
    }
    do {
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        print("1. Secure Enclave key created (no prompt expected)")
        // Seal: needs only the public key, so no prompt.
        let ephemeral = P256.KeyAgreement.PrivateKey()
        func symmetric(_ secret: SharedSecret) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("rackoon-se-check".utf8), outputByteCount: 32)
        }
        let sealed = try AES.GCM.seal(Data("dummy-not-a-password".utf8),
                                      using: symmetric(try ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey)))
        print("2. sealed a dummy value (no prompt expected)")
        print("3. opening it now: approve with Touch ID, your Apple Watch, or your login password...")
        let context = LAContext()
        context.localizedReason = "test unlocking a throwaway key (Rackoon check)"
        let unlocked = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: key.dataRepresentation, authenticationContext: context)
        let opened = try AES.GCM.open(sealed, using: symmetric(try unlocked.sharedSecretFromKeyAgreement(with: ephemeral.publicKey)))
        print(String(decoding: opened, as: UTF8.self) == "dummy-not-a-password" ? "PASS: unlocked and opened" : "FAIL: wrong plaintext")
        exit(0)
    } catch {
        print("FAIL or cancelled: \(error)")
        exit(1)
    }
}
if args.count > 2, args[2] == "hostkey" {
    // Uses a throwaway known_hosts file, never ~/.ssh/known_hosts.
    let path = NSTemporaryDirectory() + "probe-known-hosts-\(getpid())"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let verifier = HostKeyVerifier(knownHostsPath: path)
    let server = Server(name: args[1], host: args[1])
    func show(_ s: HostKeyStatus) -> String {
        switch s {
        case .trusted: "trusted"
        case .unknown(let o): "unknown, \(o.hostname):\(o.port)\n  " + o.fingerprints.joined(separator: "\n  ")
        case .changed(let m): "CHANGED: \(m)"
        case .authFailed(let m): "login refused (host key fine): \(m)"
        case .failed(let m): "failed: \(m)"
        }
    }
    let first = await verifier.check(server)
    print("1. empty known_hosts -> \(show(first))")
    guard case .unknown(let offer) = first else { exit(1) }
    try verifier.trust(offer)
    print("2. after trust       -> \(show(await verifier.check(server)))")
    // Tamper: replace the stored key with a different one; must be reported as changed, never offered.
    let tampered = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map { line -> String in
        var f = line.split(separator: " ").map(String.init)
        guard f.count >= 3 else { return String(line) }
        var chars = Array(f[2])
        let i = chars.count - 6                      // inside the key blob, clear of any padding
        chars[i] = chars[i] == "A" ? "B" : "A"
        f[2] = String(chars)
        return f.joined(separator: " ")
    }.joined(separator: "\n") + "\n"
    try tampered.write(toFile: path, atomically: true, encoding: .utf8)
    print("3. tampered key      -> \(show(await verifier.check(server)))")
    exit(0)
}
// RACKOON_PROBE_KEY=~/.ssh/key picks the key file, like a saved server's key file (`user@host` works as the host).
let transport = OpenSSHTransport(server: Server(name: args[1], host: args[1],
                                                identityFile: ProcessInfo.processInfo.environment["RACKOON_PROBE_KEY"]))
if args.count > 2, args[2] == "docker-sudo-check" || args[2] == "docker-sudo-reject-check" {
    // Docker through sudo (SudoTransport), read-only: the Docker poll (`docker ps`/`stats`) and a short stream.
    // docker-sudo-check asks for the real password on this terminal (not echoed, not stored); the reject variant uses a
    // deliberately wrong one and must lock without running anything.
    let password: String
    if args[2] == "docker-sudo-check" {
        var buffer = [CChar](repeating: 0, count: 1024)
        guard let typed = readpassphrase("sudo password for \(args[1]) (not echoed, not stored): ", &buffer, buffer.count, RPP_REQUIRE_TTY) else { exit(2) }
        password = String(cString: typed)
        buffer.withUnsafeMutableBufferPointer { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
    } else {
        password = "rackoon-probe-not-the-password"
    }
    let locked = TypedCounter()
    let sudo = SudoTransport(base: transport, password: password, validUntil: Date().addingTimeInterval(120), onRejected: { locked.add() })
    let docker = DockerSession(transport: sudo)
    await docker.refresh()
    let state = await docker.state
    print("1. poll through sudo  -> \(state.snapshot.map { "\($0.containers.count) containers" } ?? "error: \(state.error ?? "?")")")
    var streamed = ""
    var streamError: String?
    do { for try await chunk in sudo.stream("docker ps --format '{{.Names}}' | head -3") { streamed += chunk } }
    catch { streamError = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
    let shownLines = ANSI.strip(streamed).replacingOccurrences(of: "\r", with: "").split(separator: "\n").joined(separator: " | ")
    print("2. stream through sudo -> \(streamError ?? "ok"): \(shownLines)")
    let leaked = streamed.contains(password) || streamed.contains("*") || streamed.contains("##rackoon-sudo")
    let ok: Bool
    if args[2] == "docker-sudo-check" {
        ok = state.snapshot != nil && streamError == nil && locked.count == 0 && !leaked
    } else {
        ok = state.snapshot == nil && locked.count >= 1 && !leaked
        print("   locked \(locked.count) time(s) (expected: at least once, nothing ran)")
    }
    print(ok ? "PASS" : "FAIL (leaked: \(leaked))")
    exit(ok ? 0 : 1)
}
if args.count > 2, args[2] == "sudo-reject-check" || args[2] == "sudo-check" {
    // The sudo password path over a real pty, with harmless commands only (`true`, `id -u`).
    // sudo-reject-check: a deliberately WRONG password. sudo must prompt once, the password must be typed once and be
    //   rejected, never show, and the run must stop without the script running.
    // sudo-check: asks for the real password on this terminal (not echoed, not stored) and checks that `sudo -v` makes
    //   the script's own `sudo -n` work, and that a fake prompt printed by the script afterwards is NOT answered.
    let script = #"if [ "$(id -u)" -eq 0 ]; then S=; else S='sudo -n'; fi; $S true"#
    let plain = await StreamRunner.run(transport: transport, command: script, cols: 100, rows: 24, onEvent: { _ in })
    print("1. sudo -n            -> exit \(plain.exitCode.map(String.init) ?? "none"), needs password: \(plain.needsSudoPassword)")
    guard plain.needsSudoPassword else { print("this user has passwordless sudo (or is root): nothing to check"); exit(0) }
    let nonce = SudoElevation.makeNonce()
    let password: String
    if args[2] == "sudo-check" {
        var buffer = [CChar](repeating: 0, count: 1024)
        guard let typed = readpassphrase("sudo password for \(args[1]) (not echoed, not stored): ", &buffer, buffer.count, RPP_REQUIRE_TTY) else { exit(2) }
        password = String(cString: typed)
        buffer.withUnsafeMutableBufferPointer { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
    } else {
        password = "rackoon-probe-not-the-password"
    }
    // The script prints a fake prompt carrying the real nonce AFTER the ok marker: it must not be answered.
    let body = #"if [ "$(id -u)" -eq 0 ]; then S=; else S='sudo -n'; fi; echo "uid as root: $($S id -u)"; echo '##rackoon-sudo-\#(nonce):'; sleep 1; echo after"#
    let elevated = SudoElevation.withPassword(body, nonce: nonce)!
    let typedIn = TypedCounter()
    let started = Date()
    let run = await StreamRunner.run(transport: CountingTransport(base: transport, counter: typedIn), command: elevated, cols: 100, rows: 24,
                                     sudo: SudoCredential(password: password, nonce: nonce), onEvent: { _ in })
    let shown = ANSI.strip(run.text).replacingOccurrences(of: "\r", with: "").split(separator: "\n").joined(separator: " | ")
    print("2. password run       -> outcome \(run.sudo.map { "\($0)" } ?? "none"), exit \(run.exitCode.map(String.init) ?? "none"), typed \(typedIn.count) time(s), \(Int(Date().timeIntervalSince(started))) s")
    print("   output: \(shown)")
    let leaked = run.text.contains(password) || run.text.contains("*")
    let ok: Bool
    if args[2] == "sudo-check" {
        ok = run.sudo == .accepted && !run.sudoAsksEveryTime && shown.contains("uid as root: 0") && typedIn.count == 1 && !leaked
        if run.sudoAsksEveryTime { print("   sudo kept no session record: the script's sudo -n still wanted a password") }
    } else {
        ok = run.sudo == .rejected && typedIn.count == 2 && !leaked   // the password once, then one Ctrl-C
    }
    print(ok ? "PASS" : "FAIL (leaked: \(leaked))")
    exit(ok ? 0 : 1)
}

/// Counts what is typed into a stream (never records the text itself).
final class TypedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

struct CountingTransport: SSHTransport {
    let base: OpenSSHTransport
    let counter: TypedCounter
    func run(_ command: String, timeout: TimeInterval) async throws -> CommandResult { try await base.run(command, timeout: timeout) }
    func stream(_ command: String) -> AsyncThrowingStream<String, Error> { base.stream(command) }
    func stream(_ command: String, input: AsyncStream<String>) -> AsyncThrowingStream<String, Error> {
        let (counted, forward) = AsyncStream<String>.makeStream()
        let counter = counter
        Task { for await text in input { counter.add(); forward.yield(text) }; forward.finish() }
        return base.stream(command, input: counted)
    }
}
if args.count > 2, args[2] == "file-test" {
    // Exercises the REAL file read / validate / save on a throwaway stack that this probe creates and removes.
    let project = "rackoon-probe-files"
    let dir = "/tmp/rackoon-probe-files"
    let compose = "\(dir)/compose.yaml"
    func sh(_ script: String, timeout: TimeInterval = 300) async -> CommandResult {
        (try? await transport.run(script, timeout: timeout)) ?? CommandResult(stdout: "", stderr: "ssh failed", exitCode: 255)
    }
    func teardown() async {
        _ = await sh("cd \(dir) 2>/dev/null && docker compose -p \(project) -f \(compose) down -v --remove-orphans 2>&1; cd /; rm -rf \(dir)")
    }
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL") \(what)"); if !ok { failures += 1 } }
    func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    await teardown()
    let original = "services:\n  web:\n    image: busybox:${TAG:?TAG is required}\n    command: sleep 3600\n"
    let setup = await sh("""
    mkdir -p \(dir) && cd \(dir) && printf '%s' 'TAG=1.36' > .env && \
    printf 'services:\\n  web:\\n    image: busybox:${TAG:?TAG is required}\\n    command: sleep 3600\\n' > compose.yaml && \
    chown nobody:nogroup compose.yaml && chmod 640 compose.yaml && docker compose -p \(project) -f \(compose) up -d 2>&1
    """, timeout: 600)
    check(setup.exitCode == 0, "setup stack (exit \(setup.exitCode)) \(setup.exitCode == 0 ? "" : setup.stdout.suffix(300))")
    guard setup.exitCode == 0 else { await teardown(); exit(1) }
    // The env file exists in this stack, so remove it for the "new file" scenario later.
    _ = await sh("rm -f \(dir)/.env")

    let policy = ActionPolicy()
    let docker = DockerSession(transport: transport, policy: policy)
    await docker.refresh()
    guard let stack = await docker.state.snapshot?.stacks.first(where: { $0.name == project }) else {
        check(false, "probe stack is listed"); await teardown(); exit(1)
    }
    let session = StackFileSession(transport: transport, policy: policy, stack: stack)
    let envFile = EditableFile.env(dir + "/.env"), composeFile = EditableFile.compose(compose)
    check(session.files == [composeFile, envFile], "editable files are compose.yaml then .env: \(session.files.map(\.fileName))")

    // --- read
    var composeState = try? await session.read(composeFile)
    guard case .file(let f)? = composeState else { check(false, "read compose.yaml"); await teardown(); exit(1) }
    check(f.content == original, "read returns the exact content")
    check(f.sha256 == sha(original), "sha256 matches a local hash")
    check(f.mode == "640" && f.owner == "nobody:nogroup", "mode and owner reported: \(f.mode) \(f.owner)")
    let envState = try? await session.read(envFile)
    check(envState == .missing, "missing .env is reported as missing")

    // --- validate (changes nothing)
    var r = try? await session.validate(envFile, content: "TAG=1.36")
    check(r?.isValid == true, "env with TAG validates: \(r?.issues.map(\.message) ?? [])")
    r = try? await session.validate(envFile, content: "")
    check(r?.isValid == false && r?.errors.first?.message.contains("TAG is required") == true, "env without TAG is rejected via compose interpolation: \(r?.errors.map(\.message) ?? [])")
    // --- create .env (new file)
    let envEdit = FileEdit(file: envFile, original: nil, originalSHA: nil, content: "TAG=1.36\n")
    var outcome = try? await session.save(envEdit, confirmation: try? session.confirm(envEdit))
    check({ if case .saved(let h)? = outcome { return h == sha("TAG=1.36\n") }; return false }(), "new .env saved, hash returned: \(String(describing: outcome))")
    let envInfo = await sh("stat -c '%a' \(dir)/.env; cat \(dir)/.env")
    check(envInfo.stdout.hasPrefix("600\n") && envInfo.stdout.hasSuffix("TAG=1.36\n"), "new .env is mode 600 with the content")
    outcome = try? await session.save(envEdit, confirmation: try? session.confirm(envEdit))
    check(outcome == .changedOnServer, "saving a 'new' file that now exists is refused as changed")

    let good = original.replacingOccurrences(of: "sleep 3600", with: "sleep 7200")
    r = try? await session.validate(composeFile, content: good)
    check(r?.isValid == true, "edited compose validates against the .env saved above: \(r?.errors.map(\.message) ?? [])")
    let badYAML = "services:\n  web:\n    image busybox\n    command: sleep 3600\n"
    r = try? await session.validate(composeFile, content: badYAML)
    check(r?.isValid == false && r?.errors.first?.line != nil && r?.errors.first?.message.contains(".rackoon-") == false, "YAML syntax error reports a line and names the real file: \(r?.errors.map { "\($0.line.map(String.init) ?? "-"): \($0.message)" } ?? [])")
    let badSchema = "services:\n  web:\n    imagee: busybox\n"
    r = try? await session.validate(composeFile, content: badSchema)
    check(r?.isValid == false, "unknown key is rejected: \(r?.errors.map(\.message) ?? [])")
    let afterValidate = await sh("ls -A \(dir); stat -c '%a %U:%G' \(compose); sha256sum \(compose) | cut -d' ' -f1")
    check(!afterValidate.stdout.contains("rackoon-") && afterValidate.stdout.contains(sha(original)), "validation left no temp files and changed nothing")

    // --- save compose: success keeps owner/mode, writes backup
    let edit = FileEdit(file: composeFile, original: original, originalSHA: f.sha256, content: good)
    let intent = session.intent(for: edit)
    check(intent?.preview?.contains("+     command: sleep 7200") == true, "confirmation preview is a readable diff")
    outcome = try? await session.save(edit, confirmation: try? session.confirm(edit))
    check({ if case .saved(let h)? = outcome { return h == sha(good) }; return false }(), "compose saved, new hash returned: \(String(describing: outcome))")
    let saved = await sh("cat \(compose); echo ---; cat \(compose).rackoon.bak; echo ---; stat -c '%a %U:%G' \(compose); ls -A \(dir)")
    let parts = saved.stdout.components(separatedBy: "---\n")
    check(parts.count == 3 && parts[0] == good, "file on the server has the new content")
    check(parts.count == 3 && parts[1] == original, "previous version kept as compose.yaml.rackoon.bak")
    check(parts.count == 3 && parts[2].hasPrefix("640 nobody:nogroup"), "mode and owner preserved: \(parts.last?.prefix(20) ?? "")")
    check(!saved.stdout.contains(".rackoon-save") && !saved.stdout.contains(".rackoon-check"), "no temp files left behind")

    // --- stale hash is refused, file unchanged
    let stale = FileEdit(file: composeFile, original: original, originalSHA: f.sha256, content: good + "# stale\n")
    outcome = try? await session.save(stale, confirmation: try? session.confirm(stale))
    check(outcome == .changedOnServer, "save against an outdated hash is refused: \(String(describing: outcome))")
    check((await sh("sha256sum \(compose) | cut -d' ' -f1")).stdout.hasPrefix(sha(good)), "refused save changed nothing")

    // --- invalid content is refused by the server's own check, file unchanged
    let invalid = FileEdit(file: composeFile, original: good, originalSHA: sha(good), content: badYAML)
    outcome = try? await session.save(invalid, confirmation: try? session.confirm(invalid))
    check({ if case .invalid(let issues)? = outcome { return !issues.isEmpty }; return false }(), "invalid content refused with issues: \(String(describing: outcome))")
    check((await sh("sha256sum \(compose) | cut -d' ' -f1")).stdout.hasPrefix(sha(good)), "invalid save changed nothing")

    // --- read-only mode and missing confirmation
    policy.isReadOnly = true
    check((try? session.confirm(edit)) == nil, "read-only refuses to confirm a save")
    policy.isReadOnly = false
    do { _ = try await session.save(invalid, confirmation: nil); check(false, "save without confirmation is refused") }
    catch { check(error as? PolicyError == .notConfirmed, "save without confirmation is refused") }

    await teardown()
    let leftover = await sh("ls \(dir) 2>&1 | head -1; docker ps -a --filter label=com.docker.compose.project=\(project) -q | wc -l")
    check(leftover.stdout.contains("No such file") && leftover.stdout.hasSuffix("0\n"), "teardown removed everything")
    print(failures == 0 ? "file-test: all passed" : "file-test: \(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
if args.count > 2, args[2] == "library-check" {
    // Runs every READ entry of the Commands library through the real streaming path, and only the dry-run PREVIEW of the
    // maintenance ones. The commands that change the server (prune, clean, restart) are never run by the probe.
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func add(_ e: ActionStreamEvent) { if case .output(let t) = e { lock.withLock { text += t } } }
        var output: String { lock.withLock { text } }
    }
    let session = CommandLibrarySession(transport: transport, policy: ActionPolicy())
    // Parameters: a real container name, and a host that is not ours to probe for the certificate check.
    let containers = ((try? await transport.run("docker ps --format '{{.Names}}' 2>/dev/null | head -1", timeout: 15))?.stdout ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let values = ["container": containers.isEmpty ? "none" : containers, "host": "example.com"]
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL") \(what)"); if !ok { failures += 1 } }
    for command in CommandLibrary.all {
        if command.interactive { print("SKIP \(command.id) (interactive: opens in a terminal tab)"); continue }
        if command.isMutating {
            let preview = await session.preview(for: command, params: values)
            check(!preview.contains("Could not read"), "preview of \(command.id): \(preview.split(separator: "\n").first.map(String.init) ?? "(empty)")")
            continue
        }
        guard let intent = session.intent(for: command, params: values) else { check(false, "\(command.id): could not build the command"); continue }
        let sink = Sink()
        let t0 = Date()
        let run = await StreamRunner.run(transport: transport, command: intent.command, cols: 100, rows: 24, onEvent: { sink.add($0) })
        let plain = ANSI.strip(sink.output).trimmingCharacters(in: .whitespacesAndNewlines)
        let first = plain.split(separator: "\n").first.map { String($0.prefix(70)) } ?? "(no output)"
        // `grep` finding nothing exits 1 in a few entries on purpose; what matters is a result, no marker leak and no stray error text.
        check(run.exitCode != nil && !sink.output.contains("##rackoon-exit"),
              "\(command.id) exit \(run.exitCode.map(String.init) ?? "none") \(String(format: "%.1f", Date().timeIntervalSince(t0)))s: \(first)")
    }
    print(failures == 0 ? "library-check: all passed" : "library-check: \(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
if args.count > 2, args[2] == "newstack-test" {
    // Exercises the REAL new-stack check and create scripts under one throwaway folder in /tmp, and removes it.
    let project = "rackoon-probe-newstack"
    let parent = "/tmp/rackoon-probe-newstack"
    func sh(_ script: String, timeout: TimeInterval = 300) async -> CommandResult {
        (try? await transport.run(script, timeout: timeout)) ?? CommandResult(stdout: "", stderr: "ssh failed", exitCode: 255)
    }
    func teardown() async {
        _ = await sh("cd \(parent)/\(project) 2>/dev/null && docker compose -p \(project) down -v --remove-orphans 2>&1; cd /; rm -rf \(parent)")
    }
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL") \(what)"); if !ok { failures += 1 } }

    await teardown()
    let policy = ActionPolicy()
    let session = NewStackSession(transport: transport, policy: policy)
    let good = NewStackPlan(name: project, parentDirectory: parent,
                            compose: "services:\n  web:\n    image: busybox:${TAG:?TAG is required}\n    command: sleep 3600\n", env: "TAG=1.36\n")
    let dir = good.directory!

    // --- check: changes nothing in the real folder
    let ok = try? await session.check(good)
    check(ok?.isValid == true, "valid files pass the server check: \(String(describing: ok))")
    var noEnv = good; noEnv.env = ""
    let missingVar = try? await session.check(noEnv)
    check(missingVar?.isValid == false, "a required variable with no .env fails the check: \(String(describing: missingVar?.errors.first?.message))")
    var broken = good; broken.compose = "services:\n  web:\n    image: busybox\n   command: x\n"
    let bad = try? await session.check(broken)
    check(bad?.isValid == false && bad?.errors.first?.message.contains("/tmp/") == false, "broken YAML fails with a readable message: \(String(describing: bad?.errors.first))")
    check((await sh("ls \(parent) 2>&1")).stdout.contains("No such file"), "checking created nothing under the target folder")

    // --- create: files, modes, refusal without confirmation
    do { _ = try await session.create(good, confirmation: nil); check(false, "create without confirmation is refused") }
    catch { check(error as? PolicyError == .notConfirmed, "create without confirmation is refused") }
    policy.isReadOnly = true
    check((try? session.confirm(good)) == nil, "read-only refuses to confirm a create")
    policy.isReadOnly = false
    let made = try? await session.create(good, confirmation: try? session.confirm(good))
    check(made == .created, "created: \(String(describing: made))")
    let files = await sh("cat \(dir)/compose.yaml; echo ---; cat \(dir)/.env; echo ---; stat -c '%a' \(dir)/.env")
    check(files.stdout.contains("busybox:${TAG") && files.stdout.contains("TAG=1.36") && files.stdout.hasSuffix("600\n"), ".env and compose.yaml written, .env mode 600: \(files.stdout.suffix(40))")
    let again = try? await session.create(good, confirmation: try? session.confirm(good))
    check(again == .exists, "same name again is refused: \(String(describing: again))")

    // --- create with files the server rejects leaves nothing behind
    var rejected = good; rejected.name = "rackoon-probe-newstack-bad"; rejected.compose = "services:\n  web:\n    image: busybox\n   command: x\n"
    let invalid = try? await session.create(rejected, confirmation: try? session.confirm(rejected))
    check({ if case .invalid(let issues)? = invalid { return !issues.isEmpty }; return false }(), "rejected files report issues: \(String(describing: invalid))")
    check((await sh("ls \(parent)")).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == project, "the rejected stack left no folder behind")

    // --- it starts with the normal stack action
    let docker = DockerSession(transport: transport, policy: policy)
    let stack = good.stack!
    await docker.perform(.up, stack: stack, confirmation: try? docker.confirm(.up, stack: stack))
    let running = await sh("docker ps --filter label=com.docker.compose.project=\(project) --filter status=running -q | wc -l")
    check(running.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1", "up -d on the new stack started its container")

    await teardown()
    let leftover = await sh("ls \(parent) 2>&1 | head -1; docker ps -a --filter label=com.docker.compose.project=\(project) -q | wc -l")
    check(leftover.stdout.contains("No such file") && leftover.stdout.hasSuffix("0\n"), "teardown removed everything")
    print(failures == 0 ? "newstack-test: all passed" : "newstack-test: \(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
if args.count > 2, args[2] == "delete-test" {
    // Exercises the REAL stack delete (compose down + folder removal) on throwaway stacks this probe creates under one temp
    // directory. It never touches your own stacks. The data folder is bind-mounted and written to BY THE CONTAINER, so its files
    // are owned by root: the case a non-root ssh user would trip over.
    let parent = "/tmp/rackoon-probe-delete"
    func sh(_ script: String, timeout: TimeInterval = 300) async -> CommandResult {
        (try? await transport.run(script, timeout: timeout)) ?? CommandResult(stdout: "", stderr: "ssh failed", exitCode: 255)
    }
    func teardown() async {
        _ = await sh("for d in \(parent)/*/; do [ -f \"$d/compose.yaml\" ] && (cd \"$d\" && docker compose -p \"rackoon-probe-del-$(basename \"$d\")\" down -v --remove-orphans 2>&1); done; rm -rf \(parent)")
    }
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL") \(what)"); if !ok { failures += 1 } }
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func add(_ e: ActionStreamEvent) { if case .output(let t) = e { lock.withLock { text += t } } }
        var output: String { lock.withLock { text } }
    }
    func make(_ name: String) async -> Bool {
        let dir = "\(parent)/\(name)"
        let r = await sh("""
        mkdir -p \(dir) && cd \(dir) && printf 'services:\\n  web:\\n    image: busybox\\n    command: sh -c "echo hi > /data/made-by-container; sleep 3600"\\n    volumes:\\n      - ./data:/data\\n' > compose.yaml && docker compose -p rackoon-probe-del-\(name) up -d 2>&1
        """, timeout: 600)
        return r.exitCode == 0
    }
    await teardown()
    let policy = ActionPolicy()
    let docker = DockerSession(transport: transport, policy: policy)
    check(await make("full"), "setup: stack with a container-written bind mount")
    check(await make("keep"), "setup: second stack that must be left alone")
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    await docker.refresh()
    let snapshot = await docker.state.snapshot
    let full = snapshot?.stacks.first { $0.name == "rackoon-probe-del-full" }
    check(full != nil, "docker reports the stack by its real labels")
    guard let full else { await teardown(); exit(1) }
    check(StackRemoval.folderProblem(for: full) == nil, "folder deletion is offered for it: \(StackRemoval.folderProblem(for: full) ?? "yes")")
    let owner = await sh("stat -c %U \(parent)/full/data/made-by-container")
    print("data file owner on the server: \(owner.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")

    // The stack's own working_dir label is /tmp/rackoon-probe-delete/full, and the project name is rackoon-probe-del-full.
    let removal = StackRemoval(removeVolumes: false, deleteFolder: true)
    let sink = Sink()
    let confirmation = try? docker.confirm(removal, stack: full)
    await docker.performStreaming(removal, stack: full, confirmation: confirmation, cols: 100, rows: 24, onEvent: { sink.add($0) })
    let after = await sh("docker ps -a --filter label=com.docker.compose.project=rackoon-probe-del-full -q | wc -l; ls \(parent) 2>&1")
    print(ANSI.strip(sink.output).split(separator: "\n").suffix(4).joined(separator: "\n"))
    check(after.stdout.hasPrefix("0\n"), "its container is gone")
    check(!after.stdout.contains("full") && after.stdout.contains("keep"), "its folder, with the root-owned data, is gone and the other stack's is not: \(after.stdout.replacingOccurrences(of: "\n", with: " "))")
    let keepRunning = await sh("docker ps --filter label=com.docker.compose.project=rackoon-probe-del-keep --filter status=running -q | wc -l")
    check(keepRunning.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1", "the other stack still runs")

    // Without confirmation, or in read-only mode, nothing runs.
    let keep = (await { await docker.refresh(); return await docker.state.snapshot?.stacks.first { $0.name == "rackoon-probe-del-keep" } }())
    if let keep {
        policy.isReadOnly = true
        check((try? docker.confirm(removal, stack: keep)) == nil, "read-only refuses to confirm a delete")
        policy.isReadOnly = false
        await docker.performStreaming(removal, stack: keep, confirmation: nil, cols: 100, rows: 24, onEvent: { _ in })
        let still = await sh("ls \(parent)/keep/compose.yaml 2>&1")
        check(still.stdout.contains("compose.yaml") && !still.stdout.contains("No such"), "a delete without confirmation changed nothing")
    }
    await teardown()
    let leftover = await sh("ls \(parent) 2>&1 | head -1; docker ps -a --filter label=com.docker.compose.project=rackoon-probe-del-keep -q | wc -l")
    check(leftover.stdout.contains("No such file") && leftover.stdout.hasSuffix("0\n"), "teardown removed everything")
    print(failures == 0 ? "delete-test: all passed" : "delete-test: \(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
if args.count > 2, args[2] == "compose-test" {
    // Exercises the REAL compose actions end to end on a throwaway stack that this probe creates and removes.
    // It never touches your own stacks: everything lives under one temp directory and one project name.
    let project = "rackoon-probe-test"
    let dir = "/tmp/rackoon-probe-stack"
    let file = "\(dir)/compose.yaml"
    func sh(_ script: String, timeout: TimeInterval = 300) async -> CommandResult {
        (try? await transport.run(script, timeout: timeout)) ?? CommandResult(stdout: "", stderr: "ssh failed", exitCode: 255)
    }
    func teardown() async {
        _ = await sh("cd \(dir) 2>/dev/null && docker compose -p \(project) -f \(file) down -v --remove-orphans --rmi local 2>&1; cd /; rm -rf \(dir)")
    }
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL") \(what)"); if !ok { failures += 1 } }

    await teardown()
    let setup = await sh("""
    mkdir -p \(dir)/b && cd \(dir) && \
    printf 'FROM busybox:1.36\\nRUN echo built > /built.txt\\nCMD sleep 3600\\n' > b/Dockerfile && \
    printf 'services:\\n  web:\\n    image: busybox:1.36\\n    command: sleep 3600\\n  built:\\n    build: ./b\\n' > compose.yaml && \
    docker compose -p \(project) -f \(file) up -d --build 2>&1
    """, timeout: 600)
    check(setup.exitCode == 0, "setup stack up (exit \(setup.exitCode)) \(setup.exitCode == 0 ? "" : setup.stdout.suffix(300))")
    guard setup.exitCode == 0 else { await teardown(); exit(1) }

    let policy = ActionPolicy()
    let session = DockerSession(transport: transport, policy: policy)
    func theStack() async -> DockerStack? {
        await session.refresh()
        return await session.state.snapshot?.stacks.first { $0.name == project }
    }
    func ids(_ s: DockerStack?) -> Set<String> { Set((s?.containers ?? []).map(\.id)) }

    var stack = await theStack()
    check(stack?.containers.count == 2, "probe stack is listed with 2 containers")
    check(stack?.configFiles == [file], "config file label parsed: \(stack?.configFiles ?? [])")
    guard var current = stack else { await teardown(); exit(1) }
    let original = ids(current)

    func run(_ action: ComposeAction) async -> String? {
        let t0 = Date()
        await session.perform(action, stack: current, confirmation: try? session.confirm(action, stack: current))
        let state = await session.state
        print("   \(action.rawValue) took \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        check(state.busyStacks.isEmpty && state.busy.isEmpty, "\(action.rawValue): busy cleared afterwards")
        return state.actionError
    }

    // Live output: a real compose run over a pty, with the exit code coming back in-band.
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var text = "", code: Int32??
        func add(_ e: ActionStreamEvent) { lock.withLock { switch e { case .output(let t): text += t; case .finished(let c): code = .some(c) } } }
        var output: String { lock.withLock { text } }
        var exitCode: Int32?? { lock.withLock { code } }
    }
    for action in [ComposeAction.restart, .up] {
        let sink = Sink()
        let t0 = Date()
        await session.performStreaming(action, stack: current, confirmation: try? session.confirm(action, stack: current),
                                       cols: 100, rows: 24, onEvent: { sink.add($0) })
        let out = sink.output
        print("   streamed \(action.rawValue) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s, \(out.count) chars")
        check(sink.exitCode == .some(0), "streamed \(action.rawValue) finishes with exit 0: \(String(describing: sink.exitCode))")
        check(out.contains("Container") || out.contains("web"), "streamed \(action.rawValue) shows compose's own progress text")
        check(!out.contains("##rackoon-exit"), "the exit marker is never shown")
        check(out.contains("\u{1B}["), "output arrives with its terminal escapes (progress redraws), not stripped")
        check(!out.contains("\u{FFFD}"), "no multi-byte character was cut in two (no U+FFFD); saw \(Set(out.filter { !$0.isASCII }).count) kinds of non-ASCII characters")
        let after = await session.state
        check(after.busyStacks.isEmpty && after.actionError == nil, "\(action.rawValue): busy cleared, no error")
        if let refreshed = await theStack() { current = refreshed }
    }
    // One container's own restart streams too (so every action shows up in the same Output tab).
    if let container = current.containers.first {
        let sink = Sink()
        await session.performStreaming(.restart, containerID: container.id, confirmation: try? session.confirm(.restart, containerID: container.id),
                                       cols: 100, rows: 24, onEvent: { sink.add($0) })
        check(sink.exitCode == .some(0), "streamed container restart finishes with exit 0: \(String(describing: sink.exitCode))")
        check(sink.output.contains(container.id.prefix(12)) || sink.output.contains(container.name), "its output names the container: \(sink.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))")
        check(!sink.output.contains("##rackoon-exit"), "no marker leaks into a container run either")
        if let refreshed = await theStack() { current = refreshed }
    }
    // A failing command reports its real exit code.
    do {
        let sink = Sink()
        var broken = current
        broken.configFile = "/tmp/rackoon-probe-stack/does-not-exist.yaml"; broken.configFiles = [broken.configFile!]
        await session.performStreaming(.up, stack: broken, confirmation: try? session.confirm(.up, stack: broken),
                                       cols: 100, rows: 24, onEvent: { sink.add($0) })
        let code: Int32? = sink.exitCode ?? nil
        check((code ?? 0) != 0, "a failing run reports a non-zero exit code: \(String(describing: sink.exitCode))")
        check((await session.state.actionError ?? "").contains("failed (exit"), "and an error that points at the output")
    }

    check(await run(.pull) == nil, "pull succeeds")
    stack = await theStack(); current = stack ?? current
    check(ids(stack) == original, "pull leaves containers untouched")

    check(await run(.up) == nil, "update (up -d) succeeds")
    stack = await theStack(); current = stack ?? current
    check(ids(stack) == original, "update with nothing changed keeps the same containers")

    check(await run(.rebuild) == nil, "rebuild succeeds")
    stack = await theStack(); current = stack ?? current
    check(stack?.containers.count == 2 && stack?.containers.allSatisfy(\.isRunning) == true, "rebuild leaves 2 running containers")

    let beforeRecreate = ids(stack)
    check(await run(.recreate) == nil, "recreate succeeds")
    stack = await theStack(); current = stack ?? current
    check(ids(stack).isDisjoint(with: beforeRecreate) && ids(stack).count == 2, "recreate gives every container a new id")
    check(stack?.containers.allSatisfy(\.isRunning) == true, "recreated containers are running")

    policy.isReadOnly = true
    let blocked = await run(.recreate)
    check(blocked == PolicyError.readOnly.errorDescription, "read-only mode refuses a real stack action: \(blocked ?? "nil")")
    policy.isReadOnly = false
    check(ids(await theStack()) == ids(stack), "nothing changed while read-only")

    await teardown()
    let leftover = await sh("docker ps -a --filter label=com.docker.compose.project=\(project) -q | wc -l; ls \(dir) 2>&1 | head -1")
    check(leftover.stdout.hasPrefix("0"), "teardown removed the containers and directory (\(leftover.stdout.replacingOccurrences(of: "\n", with: " | ")))")
    print(failures == 0 ? "compose-test: all passed" : "compose-test: \(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
if args.count > 2, args[2] == "files-test" {
    // REAL uploads, downloads, listings and a cancel on a throwaway folder under /tmp (removed at the end).
    let remoteDir = "/tmp/rackoon-files-test-\(getpid())"
    let localDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rackoon-files-test-\(getpid())")
    try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL") \(what)"); if !ok { failures += 1 } }
    func sh(_ script: String) async -> CommandResult { (try? await transport.run(script, timeout: 60)) ?? CommandResult(stdout: "", stderr: "failed to run", exitCode: -1) }
    func sha(_ url: URL) -> String { SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined() }
    final class Counter: @unchecked Sendable { private let l = NSLock(); private var v: Int64 = 0; func set(_ x: Int64) { l.withLock { v = max(v, x) } }; var value: Int64 { l.withLock { v } } }

    _ = await sh("mkdir -p \(remoteDir)")
    let policy = ActionPolicy()
    let session = FilesSession(transport: transport, transfers: OpenSSHTransport(host: args[1]), policy: policy)
    func fileSource(_ url: URL) -> LocalSource { .file(url, bytes: Int64((try? Data(contentsOf: url).count) ?? 0)) }
    func folderSource(_ url: URL) async -> LocalSource { .folder(url, bytes: (try? await LocalArchive.size(of: url)) ?? 0) }
    func up(_ source: LocalSource, as name: String, progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws {
        guard let intent = session.uploadIntent(source, toDirectory: remoteDir, as: name) else { throw TransferError.badName(name) }
        try await session.upload(source, toDirectory: remoteDir, as: name, confirmation: try session.confirm(intent), progress: progress)
    }

    // 1. a 3 MB binary file with an awkward name
    let big = localDir.appendingPathComponent("my file; $(touch pwned) 'q'.bin")
    try Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: big)
    let counter = Counter()
    do { try await up(fileSource(big), as: big.lastPathComponent, progress: { counter.set($0) }) } catch { check(false, "upload failed: \(error)") }
    let remoteSum = await sh("sha256sum \(ShellQuote.quotePath(remoteDir + "/" + big.lastPathComponent) ?? "") | cut -d' ' -f1")
    check(remoteSum.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == sha(big), "uploaded file has the same SHA-256 on the server")
    check(counter.value == 3_000_000, "progress reached the file size: \(counter.value)")
    check((await sh("ls \(remoteDir)/pwned 2>&1 | head -1")).stdout.contains("No such file"), "the shell metacharacters in the name did nothing")
    check((await sh("ls -A \(remoteDir) | grep -c rackoon-part")).stdout.hasPrefix("0"), "no .rackoon-part left")

    // 2. overwrite keeps owner and mode
    _ = await sh("chmod 600 \(ShellQuote.quotePath(remoteDir + "/" + big.lastPathComponent) ?? "")")
    try Data("replaced".utf8).write(to: big)
    do { try await up(fileSource(big), as: big.lastPathComponent) } catch { check(false, "overwrite failed: \(error)") }
    let mode = await sh("stat -c %a \(ShellQuote.quotePath(remoteDir + "/" + big.lastPathComponent) ?? "")")
    check(mode.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "600", "overwriting keeps mode 600: \(mode.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")

    // 3. download and compare
    let back = localDir.appendingPathComponent("back")
    try? FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
    do { try await session.download(name: big.lastPathComponent, isDirectory: false, from: remoteDir, toLocalDirectory: back, as: big.lastPathComponent, replacing: false, progress: { _ in }) }
    catch { check(false, "download failed: \(error)") }
    check(sha(back.appendingPathComponent(big.lastPathComponent)) == sha(big), "downloaded file matches")

    // 4. a folder with nested and odd names, both ways
    let tree = localDir.appendingPathComponent("tree dir")
    try FileManager.default.createDirectory(at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try Data("one".utf8).write(to: tree.appendingPathComponent("a b.txt"))
    try Data("two".utf8).write(to: tree.appendingPathComponent("sub/it's.txt"))
    do { try await up(await folderSource(tree), as: "tree dir") } catch { check(false, "folder upload failed: \(error)") }
    let listing = try? await session.list(remoteDir + "/tree dir")
    check(Set(listing?.entries.map(\.name) ?? []) == ["a b.txt", "sub"], "the server lists the uploaded folder: \(listing?.entries.map(\.name) ?? [])")
    check((await sh("ls -A \(remoteDir) | grep -c '^.rackoon-'")).stdout.hasPrefix("0"), "scratch folder removed")
    do { try await session.download(name: "tree dir", isDirectory: true, from: remoteDir, toLocalDirectory: back, as: "tree dir", replacing: false, progress: { _ in }) }
    catch { check(false, "folder download failed: \(error)") }
    check((try? String(contentsOf: back.appendingPathComponent("tree dir/sub/it's.txt"), encoding: .utf8)) == "two", "folder came back intact")
    check(!FileManager.default.fileExists(atPath: back.appendingPathComponent("tree dir/._a b.txt").path), "no ._ files in the archive")

    // 4b. a symlink to a folder downloads the folder it points to
    _ = await sh("cd \(remoteDir) && ln -s 'tree dir' current")
    let linkBack = localDir.appendingPathComponent("linkback")
    try? FileManager.default.createDirectory(at: linkBack, withIntermediateDirectories: true)
    do { try await session.download(name: "current", isDirectory: true, from: remoteDir, toLocalDirectory: linkBack, as: "current", replacing: false, progress: { _ in }) }
    catch { check(false, "link download failed: \(error)") }
    check((try? String(contentsOf: linkBack.appendingPathComponent("current/sub/it's.txt"), encoding: .utf8)) == "two", "a link to a folder downloads the folder's contents")
    var isLinkDir: ObjCBool = false
    _ = FileManager.default.fileExists(atPath: linkBack.appendingPathComponent("current").path, isDirectory: &isLinkDir)
    check(isLinkDir.boolValue, "and it arrives as a real folder, not a link")

    // 5. cancel mid-upload leaves nothing behind
    let huge = localDir.appendingPathComponent("huge.bin")
    try Data(count: 80_000_000).write(to: huge)
    let task = Task { try await up(fileSource(huge), as: "huge.bin") }
    try? await Task.sleep(for: .milliseconds(700))
    task.cancel()
    let outcome = await task.result
    if case .failure = outcome { check(true, "a cancelled upload ends with an error") } else { check(false, "a cancelled upload should not succeed") }
    try? await Task.sleep(for: .seconds(1))
    let listed = await sh("ls -A \(remoteDir)")
    check(!listed.stdout.contains("huge.bin") && !listed.stdout.contains("rackoon-part"), "no huge.bin or .rackoon-part on the server")
    check((await sh("pgrep -f 'rackoon-files-test-\(getpid())/\\.huge' | wc -l")).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0", "no leftover remote process")

    // 5b. a stream cut short (what a dropped connection looks like to the server) must not replace the real file
    let cut = await sh("printf 'ORIGINAL' > \(remoteDir)/cut.txt; printf 'abc' | (\(FileTransferCommands.uploadFile(directory: remoteDir, newName: "cut.txt", bytes: 999) ?? "false")); echo rc=$?; cat \(remoteDir)/cut.txt; ls -A \(remoteDir) | grep -c part")
    check(cut.stdout.contains("rc=1") && cut.stdout.contains("ORIGINAL"), "a short stream is refused and the old file is untouched: \(cut.stdout.replacingOccurrences(of: "\n", with: " | "))")

    // 5c. new folder, rename, delete on the server
    func change(_ op: FileOperation) async -> String? {
        guard let intent = session.intent(for: op) else { return "refused locally" }
        do { try await session.perform(op, confirmation: try session.confirm(intent)); return nil } catch { return "\(error)" }
    }
    check(await change(.makeFolder(in: remoteDir, name: "made dir 'x'")) == nil, "new folder")
    check((await change(.makeFolder(in: remoteDir, name: "made dir 'x'"))) != nil, "a taken folder name is refused")
    check(await change(.rename(in: remoteDir, from: "made dir 'x'", to: "renamed")) == nil, "rename")
    check((await change(.rename(in: remoteDir, from: "renamed", to: "tree dir"))) != nil, "rename onto an existing name is refused")
    check((await sh("test -d \(remoteDir)/renamed && test -d '\(remoteDir)/tree dir/sub' && echo ok")).stdout.contains("ok"), "the existing folder was not touched")
    check(await change(.delete(in: remoteDir, name: "cut.txt", isFolder: false)) == nil, "delete a file")
    check(await change(.delete(in: remoteDir, name: "tree dir", isFolder: true)) == nil, "delete a folder with contents")
    check((await sh("ls \(remoteDir)")).stdout.contains("tree dir") == false, "the folder is gone")
    check(await change(.delete(in: "/opt", name: "stacks", isFolder: true)) != nil, "deleting /opt/stacks is refused before anything runs")

    // 6. read-only blocks uploads, and a missing confirmation does too
    policy.isReadOnly = true
    do { try await up(fileSource(big), as: "blocked.txt"); check(false, "read-only should refuse") } catch { check((error as? PolicyError) == .readOnly, "read-only refuses an upload") }
    policy.isReadOnly = false
    do { try await session.upload(fileSource(big), toDirectory: remoteDir, as: "blocked.txt", confirmation: nil, progress: { _ in }); check(false, "needs confirmation") }
    catch { check((error as? PolicyError) == .notConfirmed, "an unconfirmed upload is refused") }
    check((await sh("ls \(remoteDir)/blocked.txt 2>&1 | head -1")).stdout.contains("No such file"), "nothing was written")

    _ = await sh("rm -rf \(remoteDir)")
    try? FileManager.default.removeItem(at: localDir)
    check((await sh("ls \(remoteDir) 2>&1 | head -1")).stdout.contains("No such file"), "teardown removed the remote folder")
    print(failures == 0 ? "files-test: all passed" : "files-test: \(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
if args.count > 2, args[2] == "apt-stream-check" {
    // Streams apt through the app's own wrapper and runner. `-s` SIMULATES: nothing is installed or changed.
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func add(_ e: ActionStreamEvent) { if case .output(let t) = e { lock.withLock { text += t } } }
        var output: String { lock.withLock { text } }
    }
    let sink = Sink()
    let command = #"if [ "$(id -u)" -eq 0 ]; then S=; else S='sudo -n'; fi; $S env DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get -s upgrade -y -o Dpkg::Options::=--force-confold"#
    let run = await StreamRunner.run(transport: transport, command: command, cols: 100, rows: 24, onEvent: { sink.add($0) })
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL") \(what)"); if !ok { failures += 1 } }
    let plain = ANSI.strip(sink.output)
    check(run.exitCode == 0, "apt-get -s upgrade finishes with exit 0: \(String(describing: run.exitCode))")
    check(plain.contains("Reading package lists"), "apt's own output arrives: \(plain.split(separator: "\n").first.map(String.init) ?? "(none)")")
    check(!sink.output.contains("##rackoon-exit"), "no marker leaks")
    check(!sink.output.contains("\u{FFFD}"), "no broken characters")
    check(plain.contains("upgraded,"), "apt prints its summary line: \(plain.split(separator: "\n").last { $0.contains("upgraded,") }.map(String.init) ?? "(missing)")")
    // The friendly-failure path: a stream that prints sudo's message and exits 1.
    let bad = await StreamRunner.run(transport: transport, command: "echo 'sudo: a password is required'; exit 1", cols: 100, rows: 24, onEvent: { _ in })
    check(bad.exitCode == 1, "a failing command reports its exit code through the same runner: \(String(describing: bad.exitCode))")
    check(AptAction.explain(stdout: ANSI.strip(bad.text), stderr: "", exitCode: 1).contains("passwordless sudo"), "and its streamed text is recognised as the sudo failure")
    print(failures == 0 ? "apt-stream-check: all passed" : "apt-stream-check: \(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
if args.count > 2, args[2] == "alerts" {
    // Read-only: the background alert checks (services, containers, Unraid) and the signals they raise.
    var signals: [AlertSignal] = []
    let services = await ServicesSession(transport: transport).refresh()
    if let snap = services.snapshot { signals += AlertRules.services(snap) { $0.visibleByDefault } } else { print("services: \(services.error ?? "?")") }
    if let reading = await DockerStatesSession(transport: transport).read() {
        print("containers: \(reading.containers.count)\(reading.problem.map { ", problem \($0)" } ?? "")")
        signals += AlertRules.containers(reading)
        let hrefs = CertificateCheck.targets(reading.containers.map(\.href))
        if !hrefs.isEmpty { print("https bookmarks to check from the Mac: \(hrefs)") }
    } else { print("containers: ssh failed") }
    let nas = await UnraidSession(transport: transport).refresh()
    if let snap = nas.snapshot { signals += AlertRules.storage(snap) }
    print(signals.isEmpty ? "no alerts" : "\(signals.count) alert(s):")
    for s in signals { print("   [\(s.severity.rawValue)] \(s.title): \(s.detail ?? "")") }
    exit(0)
}
if args.count > 2, args[2] == "services" {
    // Read-only: the Services screen's scan, shown the way the screen sorts it (shown first, then hidden).
    let session = ServicesSession(transport: transport)
    let t0 = Date()
    let result = await session.refresh()
    print("services scan: \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    if let e = result.error { print("error: \(e)"); exit(1) }
    guard let snap = result.snapshot else { exit(1) }
    print("root: \(snap.isRoot), systemd: \(snap.hasSystemd), \(snap.services.count) services")
    for shown in [true, false] {
        print(shown ? "SHOWN" : "HIDDEN")
        for s in snap.services where s.visibleByDefault == shown {
            let ports = s.ports.map { "\($0.address):\($0.port)" }.joined(separator: " ")
            print("   \(s.name) [\(s.kind.rawValue), \(s.status.rawValue)] \(s.unit ?? s.detail.prefix(60).description) \(ports)")
        }
    }
    exit(0)
}
if args.count > 2, args[2] == "updates" {
    let session = UpdatesSession(transport: transport)
    let t0 = Date()
    let state = await session.refresh()
    print("updates poll: \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    if let e = state.error { print("error: \(e)"); exit(1) }
    guard let snap = state.snapshot else { exit(1) }
    print("\(snap.packages.count) upgradable, \(snap.securityCount) security, \(snap.held.count) held, reboot required: \(snap.rebootRequired)")
    if let t = snap.refreshedAt { print("package lists refreshed \(Date(timeIntervalSince1970: TimeInterval(t)))") }
    for p in snap.packages.prefix(10) { print("   \(p.isSecurity ? "SEC" : "   ") \(p.name) \(p.oldVersion ?? "?") -> \(p.newVersion)") }
    exit(0)
}
if args.count > 2, args[2] == "docker" {
    let session = DockerSession(transport: transport)
    let t0 = Date()
    await session.refresh()
    print("docker poll: \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    var state = await session.state
    if let e = state.error { print("error: \(e)"); exit(1) }
    guard let snap = state.snapshot else { exit(1) }
    for stack in snap.stacks {
        print("\(stack.name) (\(stack.configFileName ?? "-")): \(stack.runningCount) running, \(stack.unhealthyCount) unhealthy, \(stack.stoppedCount) stopped")
        for c in stack.containers {
            print("   \(c.service ?? c.name) [\(c.state)/\(c.health)] cpu \(c.cpuPercent.map { String(format: "%.1f", $0) } ?? "-")% mem \(c.memoryUsedBytes.map { "\($0 / 1_048_576)MiB" } ?? "-") ports \(c.ports.map { "\($0.hostPort)->\($0.containerPort)" })")
        }
    }
    // Harmless: starting an already-running container is a no-op that echoes its id.
    if let running = snap.containers.first(where: { $0.isRunning }) {
        await session.perform(.start, containerID: running.id, confirmation: try? session.confirm(.start, containerID: running.id))
        state = await session.state
        print("no-op start of \(running.name): actionError=\(state.actionError ?? "none"), busy=\(state.busy.count)")
    }
    // Harmless: prove the compose command (cd, quoting, -p, -f) resolves on this host with `config -q`, which
    // validates the file and changes nothing. The real pull/up/recreate commands are never run by the probe.
    for stack in snap.stacks where !stack.isStandalone {
        guard let pull = ComposeAction.pull.command(for: stack) else { print("compose \(stack.name): no usable command"); continue }
        let check = pull.replacingOccurrences(of: " pull", with: " config -q", options: .backwards)
        let r = try? await transport.run(check, timeout: 30)
        print("compose \(stack.name): config check exit \(r.map { String($0.exitCode) } ?? "failed")\((r?.stderr.isEmpty ?? true) ? "" : " " + r!.stderr.prefix(120))")
    }
    await session.perform(.start, containerID: "0123456789ab", confirmation: try? session.confirm(.start, containerID: "0123456789ab"))
    state = await session.state
    print("start of nonexistent id: actionError=\(state.actionError ?? "none")")
    await session.perform(.restart, containerID: "x; reboot", confirmation: try? session.confirm(.restart, containerID: "x; reboot"))
    state = await session.state
    print("injection attempt: actionError=\(state.actionError ?? "none")")
    exit(0)
}
if args.count > 3, args[2] == "logs" {
    // Stream a container's logs for 4 s, cancel, then check nothing is left running on the server.
    let name = args[3]
    let task = Task {
        var bytes = 0
        do {
            for try await chunk in transport.stream("docker logs -f --tail 3 \(name)") {
                bytes += chunk.utf8.count
                print("chunk:", chunk.replacingOccurrences(of: "\r", with: "<CR>").prefix(120))
            }
        } catch { print("stream error: \(error)") }
        return bytes
    }
    try await Task.sleep(nanoseconds: 4_000_000_000)
    task.cancel()
    _ = await task.value
    try await Task.sleep(nanoseconds: 1_500_000_000)
    let r = try await transport.run("pgrep -af 'docker logs' | grep -v pgrep | wc -l", timeout: 10)
    print("remote 'docker logs' processes still running: \(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
    exit(0)
}
if args.count > 2, args[2] == "overview" {
    // Two polls through the real ServerSession, so CPU% (needs two readings) is exercised.
    let session = ServerSession(transport: transport)
    let t0 = Date()
    await session.refresh()
    print("first poll: \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
    try await Task.sleep(nanoseconds: 3_000_000_000)
    let t1 = Date()
    await session.refresh()
    print("second poll: \(String(format: "%.2f", Date().timeIntervalSince(t1)))s")
    let state = await session.state
    if let e = state.error { print("error: \(e)"); exit(1) }
    if let o = state.overview {
        print("\(o.hostname) · \(o.os.prettyName) · cores \(o.cores) · load \(o.load1) · up \(Int(o.uptimeSeconds / 3600))h")
        print("cpu \(state.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "n/a") · mem \(o.memory.usedBytes / 1_048_576) / \(o.memory.totalBytes / 1_048_576) MiB")
        for d in o.disks { print("disk \(d.mount) \(d.usePercent)%") }
        print("reboot required: \(o.rebootRequired) · attention: \(state.attention.map(\.message))")
    print("system: \(state.overview?.modelName ?? "-") · kernel \(state.overview?.kernel ?? "-") · machine-id \(state.overview?.machineID.prefix(8) ?? "-")… · boot \(state.overview?.bootID.prefix(8) ?? "-")… · server time \(state.overview?.serverTime ?? 0) offset \(state.overview?.utcOffsetSeconds ?? 0) \(state.overview?.timeZoneName ?? "")")
    }
    exit(0)
}
let command = args.count > 2 ? args[2] : "uname -a"
do {
    let start = Date()
    let first = try await transport.run(command, timeout: 15)
    let t1 = Date().timeIntervalSince(start)
    print("exit \(first.exitCode) in \(String(format: "%.2f", t1))s")
    print(first.stdout, terminator: "")
    if !first.stderr.isEmpty { print("stderr: \(first.stderr)") }

    let start2 = Date()
    _ = try await transport.run(command, timeout: 15)
    print("second call (multiplexed): \(String(format: "%.2f", Date().timeIntervalSince(start2)))s")

    var lines = 0
    for try await chunk in transport.stream("for i in 1 2 3; do echo tick $i; sleep 0.3; done") {
        lines += chunk.split(separator: "\n").count
        print("stream:", chunk.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    print("stream lines: \(lines)")
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
