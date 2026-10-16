# iOS Stage I0: spike results

This is the decision record for the iOS stack: a native SwiftUI app on the shared `RackoonCore`, with an embedded SSH transport, because iOS has no `/usr/bin/ssh`. Spikes are throwaway: the transport is kept, the terminal spike app is not. Everything ran against the integration lab (`test/lab`). Nothing was run against a real server.

## S1: SSH transport on SwiftNIO SSH: PASS against the lab (16 Oct 2026)

`RackoonSSHEmbedded` (`apple/Packages/RackoonSSHEmbedded`) is a new SwiftPM library. `EmbeddedSSHTransport` implements all four `SSHTransport` methods (`run`, `run(_:input:timeout:)`, `stream`, `stream(_:input:)`) and adds `connect()`, `openShell(cols:rows:command:)`, `close()` and `scanHostKey`. It follows Android's `SshjTransport`:

- **One shared connection for `run`.** Each command gets its own session channel on it, like a ControlMaster. A command with no input gets EOF at once, like `ssh -n`. If the connection has died, the transport reconnects once, but only when the channel could not be opened. A command that already started is never re-run, which is stricter than the Kotlin version, because re-running a half-finished `sudo -S` must not happen.
- **One pty connection per `stream`.** On cancel it sends Ctrl-C (0x03) through the pty, waits up to two seconds for the channel to close, then closes it. The two-second grace runs on NIO's event loop, because `Task.sleep` returns at once in a task that is already cancelled.
- **`openShell`** uses the shared connection: an `xterm-256color` pty of the size the caller gives, then a shell or a command. It supports `write`, `resize` (window-change) and `awaitEnd() -> ShellEnd` (`closedByUser` / `remoteExit(n)` / `connectionLost`, Android's `SessionEnd`).
- **Host keys** use `KnownHostsStore` (`InMemoryKnownHosts`, `JSONFileKnownHosts`, the same JSON shape as Android's `known_hosts.json`). The check happens in the key exchange, before any credentials are sent. An unknown key throws `hostKeyUnknown(presented)` so the UI can show its fingerprint. A changed key throws `hostKeyChanged` and is never offered for acceptance. `scanHostKey` stops the handshake as soon as the key is presented.
- **Sign-in** is `SSHAuth.none` (Tailscale SSH), `.password` or `.privateKey(text, passphrase:)`. Exactly one method is offered. A refusal says which methods the server accepts.

Stack: **SwiftNIO SSH, through Citadel pinned to exactly 0.12.0.** Citadel's own client API is not used. Its `executeCommand` treats any stderr as a failure and reports no exit code on success, and its pty API cannot run a command on a pty or close stdin. The transport therefore drives NIOSSH channels directly: `NIOSSHHandler.createChannel`, exec / pty-req / window-change requests, and `ExitStatus` / `ExitSignal` events. Citadel is kept for OpenSSH private-key parsing, including bcrypt-encrypted keys.

**Supply-chain note.** Citadel 0.12.1, the latest release, moved its NIOSSH dependency from the Citadel author's fork (`Joannis/swift-nio-ssh`) to a fork owned by an unrelated individual (`Wellz26/swift-nio-ssh`, merged in Citadel PR #127). 0.12.0 still uses the author's fork. Hence `exact: "0.12.0"`. Revisit before any upgrade.

### Lab checks (`RackoonSSHEmbeddedTests.LabIntegrationTests`)

Results were the same on macOS (arm64, Swift 6.4, five consecutive runs) and on Linux (`swift:6.2`, as in CI):

| Check (spec/integration/checks.json) | Result |
|---|---|
| `overview_parses`: overview script runs and parses (hostname, disks, CPU, reboot flag, stub Tailscale IP, update counts) | PASS |
| `updates_parse`: exactly the lab's two pending packages, one security, reboot flag | PASS |
| `docker_parses`: labstack found, ticker running, compose command resolves | PASS |
| `stream_exit_status`: `stream_wrap` over a pty ends with exit 3 and the output | PASS |
| `logs_cancel_leaves_nothing`: follow ticker logs, break, 0 `docker logs` left on the server | PASS |
| `hostkey_mismatch_blocked`: different key recorded, connection refused with `hostKeyChanged`, marker file not created | PASS |
| `stdin_exact_bytes`: 1 MiB through stdin counted exactly by `wc -c` | PASS |
| `sudo_password_checked`: wrong password classified `.badPassword`, right one runs as root, password only on stdin | PASS |
| Extra: unknown host key reported (not trusted), and `scanHostKey` returns the lab's key | PASS |
| Extra: shell pty 100x30, resize to 132x40 seen by `stty size`, `exit 7` reported as `remoteExit(7)` | PASS |
| Extra: Ctrl-C typed into a shell interrupts `sleep 30` | PASS |

Unit tests run in the main suite, with no network. `HostKeyTests` covers the fingerprint (the same `ssh-keygen` vector as Android), verdicts, the JSON store and key-line parsing. `KeyLoadingTests` loads Android's own `ssh-keygen` fixtures from `android/ssh/src/test/resources/keys`.

Every check runs on this transport, ignoring the iOS column of `features.json`. The checks prove the transport and the shared core, which exist now. The iOS screens that will use them come in later stages, and the feature matrix gates those.

Found on the way:
- `ChannelOptions.socketOption(.tcp_nodelay)` sets option 1 at `SOL_SOCKET` level, which is `SO_DEBUG`. macOS accepted it silently and Linux refused it with EACCES. The option is gone: NIO's `ClientBootstrap` already sets TCP_NODELAY.
- With `--parallel`, the Mac and embedded Swift lab suites together open more connections than the lab sshd's `MaxStartups` allows, so sshd dropped some of them. That broke the Mac's own checks too. CI now runs them as two steps: the Mac filter is `RackoonSSHSystemTests.LabIntegrationTests`, and the new iOS step runs with `--num-workers 4` and uploads `junit-ios-lab`.

## S2: Tailscale SSH `none` auth: NOT RUN

No real server was supplied for this check. `SSHAuth.none` sends the `none` method, which Tailscale SSH accepts; this is the same approach proven with sshj on Android (docs/android-spikes.md S1). It still needs a read-only run against a real Tailscale SSH host, either from the Mac (`swift test` with a host given) or from the simulator, which shares the Mac's tailnet routing.

## S3: SwiftTerm iOS `TerminalView` fed by `openShell`: PASS in the simulator (16 Oct 2026)

Throwaway SwiftUI app: a SwiftPM executable built with `xcodebuild` for the iOS Simulator and wrapped in a hand-made `.app`. It ran on an iPhone 17 simulator (iOS 27.1 SDK, Xcode 27.1) with SwiftTerm 1.99.0's `TerminalView` and `TerminalViewDelegate` (`send` to `shell.write`, `sizeChanged` to `shell.resize`). It connected to the lab with the key and known_hosts that `tools/lab` wrote. A script typed the commands through the same write path as the keyboard, and the results were checked from screenshots. htop and vim were installed temporarily in the disposable lab container, and the lab was rebuilt afterwards.

| Check | Result |
|---|---|
| Prompt, colours, `stty size` matches the view | 53 x 48 in portrait at the default font; `stty size` = `48 53` |
| `htop` (alternate screen, coloured meters, highlighted row, F-key bar on the last row) | renders correctly |
| `vim -c 'syntax on' /etc/ssh/sshd_config` (alternate screen, syntax colours, status line, soft wrap at 53 columns) | renders correctly; quit leaves the shell intact |
| Resize: the view shrinks to 45% height while running | `sizeChanged 53x22` reaches the server; htop redraws with its key bar on the new last row |
| Resize back | `sizeChanged 53x48`; `stty size` = `48 53` |

Findings to carry into I3:
- **SwiftTerm's iOS view does not expose its `Terminal` (`getTerminal()` is macOS only).** Its grid size arrives only through `sizeChanged`, which fires on layout, sometimes several times (53x47, then 53x48). Open the pty after the first `sizeChanged`, falling back to 80x24, then forward and debounce every later change. This is the same lesson as on Android: allocate the pty at the emulator's size.
- Portrait gives 53 columns at the default font, which is tighter than Android's 64. Font size, pinch zoom and landscape matter here too.
- `xcodebuild` refuses SwiftTerm's build-tool plugin unless it is trusted. CI needs `-skipPackagePluginValidation`, and the checked-in Xcode project in I1 will hit the same.
- Building with the iOS 27 SDK requires the scene lifecycle. A SwiftUI `App` provides it.
- Not tested yet: soft keyboard and the extra-keys row, hardware keyboard, selection and copy, background and foreground behaviour (iOS suspends sockets; I3 reconnect), and `TerminalOutputFilter` in-process (I3).

## Decision so far

- **SSH: SwiftNIO SSH, with Citadel pinned to exactly 0.12.0 for key parsing.** Proven against every lab check on macOS and on Linux, so the transport joins the CI `lab` job.
- **Terminal: SwiftTerm 1.99 `TerminalView` (iOS)**, the same library as the Mac.
- `RackoonCore`, `RackoonSSHEmbedded`, Citadel, NIO and SwiftTerm all compile for the iOS Simulator.

## Still open before or during I1 to I3

- **Key types.** Only Ed25519 private keys load. Citadel's RSA signs with `ssh-rsa` (SHA-1), which OpenSSH 8.8 and later refuse, and it does not parse ECDSA keys in OpenSSH format. NIOSSH itself supports ECDSA P-256/384/521. Add an OpenSSH ECDSA parser (small), and either RSA with `rsa-sha2-256/512` or a plain note that RSA keys are not supported. Android loads all three.
- RSA-only servers: NIOSSH offers Ed25519/ECDSA host keys and curve25519/ECDH key exchange. A server with only an RSA host key would fail to negotiate. Rare, but untested.
- Keepalive: NIOSSH has no built-in keepalive (Android uses 15 s). Send `keepalive@openssh.com` global requests, or rely on reconnect, in I3.
- Network.framework (`NIOTransportServices`) instead of POSIX sockets on iOS, for better behaviour on VPN and cellular changes. POSIX works in the simulator. Decide when testing on a device with Tailscale.
- S2 (Tailscale SSH `none` auth) against a real server, read-only, once the user supplies a host.
- On-device run with free personal-team signing (no paid Apple Developer account), including the phone's Tailscale routing.

## Stage I1 result: the app shell (16 Oct 2026)

`apple/Apps/RackoonIOS` is a checked-in Xcode project (objectVersion 77, folder-synchronised groups) on the local package: RackoonCore, RackoonSSHEmbedded and the new shared `RackoonDemo`. It is SwiftUI, iOS 17, Swift 6.

| Feature (spec/features.json) | iOS | Proven by |
|---|---|---|
| `themes` | done | `RackoonCoreTests.TerminalThemeTests`, `AppPaletteTests` (run on iOS), `RackoonIOSTests.ThemeTests` (bundled themes.json loads all 45, Automatic follows the system, a choice is kept and forces its appearance, a broken file falls back) |
| `servers.edit` | done | `RackoonCoreTests.ServerInputTests`, scenario `testServerInput`, `RackoonIOSTests.SavedServersTests` |
| `servers.menu` | done | `RackoonCoreTests.ServerListTests`, `RackoonIOSTests.SavedServersTests/testReorderAndSearch` |
| `connect.hostkey` | done | `RackoonSSHEmbeddedTests.HostKeyTests`, `RackoonIOSTests.HostTrustTests` (only the key shown can be trusted; a changed key is blocked and cannot be trusted), lab checks `testHostKeyMismatchBlocked` and `testUnknownHostKeyIsReportedNotTrusted` |
| `safety.read-only` | done | `RackoonCoreTests.ActionPolicyTests`, `RackoonIOSTests.ReadOnlyTests` (the switch reaches the shared policy, which refuses a confirmed change again at run time) |
| `demo` | done | `RackoonDemoTests.DemoDataTests` (every canned answer goes through the real parsers), `RackoonIOSTests.DemoModeTests` (demo changes never reach servers.json) |
| `core.shell-safety` | done | `RackoonCoreTests.ShellQuoteTests` and the shell-quote and template scenarios, run on iOS |
| `servers.saved` | planned I2 | The saved list is done, but painting the cached snapshot needs the Overview |
| `connect.keys` | planned I2 | Key import into the Keychain |
| `safety.confirm` | planned I4 | The first iOS action that changes a server |

How the tests run: the project alone cannot see a local package's test targets (`-only-testing` says the target "isn't a member of the test plan"). `RackoonIOS.xcworkspace` adds the package beside the project, and the test plan then runs `RackoonIOSTests`, `RackoonCoreTests`, `RackoonSSHEmbeddedTests` (lab checks skipped; they run in the Linux lab job) and `RackoonDemoTests` on the simulator: 509 tests. The package's own `Rackoon-Package` scheme cannot be built for iOS, because it includes the Mac-only targets. RackoonCore has 20 tests that prove a command in a real `/bin/sh`, and iOS has neither `Process` nor a shell. `Support.swift` therefore stubs `Process` on iOS so that `run()` skips the test, and the six tests that call the shell inside an `XCTAssert` start with `try requireShell()`. They are reported as skipped on iOS, and still run on macOS and Linux. `tools/xcresult-junit` converts the result bundle into the `<bundle>.<Class>` JUnit naming that SwiftPM uses, so features.json references mean the same tests on mac and ios.

Demo data moved into the `RackoonDemo` library (CryptoKit, so Apple platforms only): `DemoFleet` (servers, transports, fake shell script), `DemoTransport`, `DemoUpdatesTransport`, DemoLibrary/DemoFiles/DemoServices. The Mac keeps only its `enum Demo` wiring (temp folders, terminal script file), its views are untouched, and its demo tests now also `@testable import RackoonDemo`.

Checked by hand in the simulator: demo list (Rackoon Light following the system), a fixed theme (Dracula) driving the whole UI, the empty state, and the Read-only chip. The toolbar draws a `Label` as its icon alone, so the chip is an icon plus "Read-only" text. Not checked by hand: tapping through Add/Edit/Trust (the simulator tool needed the user's approval). Those flows are unit-tested, and XCUITest flows are stage I7.

Not built in I1: an app icon (needs an asset catalog), key sign-in, and anything that reads a server beyond the one-off Test Connection.
