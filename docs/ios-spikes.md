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

## Stage I2 result: Overview, attention, dashboard, key sign-in (18 Oct 2026)

| Feature | iOS | Proven by |
|---|---|---|
| `overview` | done | Core `OverviewTests`, `OverviewIPTests`, `ServerSessionTests` (run on iOS), lab `testOverviewParses`, `RackoonIOSTests.FleetTests` |
| `overview.system-info` | done | Core `SystemInfoParserTests`, `RackoonIOSTests.PresentTests` (the server's clock ticks on in its own zone) |
| `attention` | done | Core `OverviewTests`, `RackoonDemoTests` (the demo's reading raises attention items), `RackoonIOSTests.DemoModeTests` |
| `connect.failure-explained` | done | Core `EmbeddedConnectionFailureTests`, `RackoonSSHEmbeddedTests.ErrorExplanationTests`, lab `testARefusedKeyIsExplained`, `RackoonIOSTests.FleetTests` |
| `servers.saved` | done | Core store tests, `RackoonIOSTests.SavedServersTests`, and the cached snapshot painted first and marked stale (`FleetTests`) |
| `connect.keys` | done (Ed25519 only) | `RackoonSSHEmbeddedTests.KeyLoadingTests`, `RackoonIOSTests.SignInTests` (Keychain round trip included), lab `testOverviewParses` (signs in with the lab's key) |
| `fleet.dashboard` | planned I4 | The health and server pages are built; the Docker and bookmark pages need Docker |

- **Polling (`FleetModel`)** runs one Core `ServerSession` per watched server: every 5 s while its Overview is open, once a minute for the dashboard and the server list, with a second reading 3 s after a slow session starts so CPU shows at once. It stops in the background. The cached snapshot is painted first (marked "Saved reading from …"), and every good reading replaces it. `HealthHistory` feeds the heartbeat bar and sparklines.
- **Host-key gate.** A server is polled only once its host key is trusted. A server not checked yet this run is checked first (like the Mac's `FleetMonitor`). A poll that hits a changed key stops polling, re-checks, and the Overview shows "Blocked" with both fingerprints. The trusted fingerprint is computed from the stored key, never taken from the stored text. Checked by hand: an edited known_hosts.json blocked the lab exactly so.
- **Sign-in (`SignInStore`).** Tailscale SSH (`none`, the default), a private key (pasted with SwiftUI's `PasteButton`, which shows no "Allow Paste" prompt, or chosen from Files, with an optional passphrase), or a password. The method goes in `sign-in.json` beside servers.json. The key, passphrase or password goes in the Keychain only: generic password, `AfterFirstUnlockThisDeviceOnly`, never synced or backed up. A key is read and its passphrase checked before anything is saved, and a missing secret blocks polling with a reason instead of trying something else.
- **Failures** are explained by a new Core rule, `ConnectionFailure.explain(_:signIn:device:)`. It is the Kotlin rule set, since both apps have an embedded client and no `ssh -v`, worded for "this iPhone"/"iPad". The Mac's OpenSSH explanation is unchanged.
- **Checked by hand in the simulator against the lab.** Add Server, then paste the lab key, Save, open it: the first-contact sheet showed SHA256:ebrZ+…S3c4, the same as `ssh-keygen -lf`. Trust, and the live Overview came up (Ubuntu 24.04.5, 18 cores, 1 security update, reboot required). The demo's dashboard and Overview were checked too.
- **Fixed along the way.**
  - The trust sheet closed itself as it opened, because its state lived in a List row that SwiftUI recreates. It is now held by the screen.
  - The fingerprint wrapped with an inserted hyphen, a fake character in a value people compare by eye. It is now kept on one line and shrunk to fit.
  - Trusting no longer depends on the screen's momentary state, only on the key last read from the server.
- **Not built:** reboot from the attention strip (I5), the attention items' links to Docker/Updates (those screens come in I4/I5), RSA/ECDSA keys, and the dashboard's Docker and bookmark pages.

## Stage I3 result: terminal tabs, highlighting, reconnect (20 Oct 2026)

| Feature | iOS | Proven by |
|---|---|---|
| `terminal.tabs` | done | `RackoonIOSTests.TerminalStoreTests` (tabs per server, outliving screens, closed with their server; Read-only and an untrusted key keep terminals closed), `TerminalTabTests` (the pty opens at the view's first size, resizes are debounced, keystrokes arrive in order), lab `testShellSizeResizeAndExit` |
| `terminal.highlight` | done | Core `TerminalOutputFilterTests`, `OutputHighlighterTests`, `TerminalTabTests/testOutputIsHighlightedInProcessAndTheSwitchTurnsItOff` |
| `terminal.reconnect` | done | Core `ReconnectPolicyTests` (the Kotlin rule, ported), `TerminalTabTests` (backoff 1/2/4/8/15 s, an exit or a refused sign-in is never retried, Reconnect Now starts fresh), lab `testADroppedTerminalIsALostConnection` (the session's sshd killed: `connectionLost`, retried) |

- **Model.** `TerminalStore` and `TerminalTab` (`Terminals.swift`) are owned by `AppModel`, so tabs survive moving between screens and servers. They are closed when their server is removed or its address or sign-in changes, and when demo mode switches. A tab opens its pty only once SwiftTerm reports its grid (the I0 lesson). Output passes through Core's `TerminalOutputFilter` in-process, since iOS needs no pty relay, and the Highlight switch in Settings applies to open tabs at once (Mac key `terminalHighlightOutput`). Keystrokes go through one ordered queue per session. A task per keystroke reordered them: typing "docker" arrived as "docerk", caught in the simulator.
- **Core** gained `TerminalShell` and `TerminalOpening`, implemented by `EmbeddedSSHTransport`/`EmbeddedShell` (`ShellEnd` became Core's `SessionEnd`) and by the demo.
- **Demo shell.** The canned banner and answers are now one table, `DemoShell` in RackoonDemo. The Mac's demo terminal runs the bash script generated from it, and iOS answers in-process (`DemoShellSession`, simple line editing). `DemoShellTests` checks both, the bash half on macOS only.
- **View** (`TerminalScreen.swift`). SwiftTerm's iOS `TerminalView` is kept per tab, so scrollback survives leaving the screen, and themed from the active theme like the Mac's `applyRackoonTheme`. SwiftTerm's own key bar provides esc/ctrl/tab/arrows. A tab strip with + and ×, and a banner while reconnecting (countdown, Now, Cancel) or after the session ended (Reconnect, Close). The tab bar is hidden on this screen. Read-only keeps terminals closed, as on Android.
- **Checked by hand in the simulator.**
  - Demo shell: banner, IPs highlighted, `docker ps`.
  - The lab over SSH with the saved Ed25519 key: login banner, coloured prompt, `top` on the alternate screen (left unhighlighted).
  - Killing the session's sshd on the lab showed "Reconnecting in 1 s (attempt 1 of 5)", then a fresh login under the kept scrollback.
- **Not built:** renaming tabs; a font-size control or pinch zoom (portrait gives about 49 columns at 13 pt); keepalive (a dead link is noticed when iOS reports it, or on the next write); opening a container shell (I4).

## Stage I4 result: Docker D1 to D7 (22 Oct 2026)

| Feature | iOS | Proven by |
|---|---|---|
| `safety.confirm` | done | Core `ActionPolicyTests`, `ActionPromptsTests`; `RackoonIOSTests.DockerModelTests` (every change asks with its exact command, Start runs directly, Read-only refuses) |
| `docker.overview` | done | Core `DockerParserTests`, `DockerSessionTests`, `DockerPresentationTests`; lab `testDockerParses`; `DockerModelTests` |
| `docker.container-actions`, `docker.stack-actions`, `docker.rebuild-service`, `docker.standalone` | done | Core `ActionPromptsTests` and the existing action tests; lab `testStreamExitStatus`, `testAStackRestartStreamsWithItsExitCode` (a real streamed `compose restart` on the lab stack, exit 0); `DockerModelTests` |
| `docker.logs` | done | Core `LogFollowerTests`, `LogViewTests` (ported from Kotlin); lab `testLogsCancelLeavesNothing` |
| `docker.shell` | done | lab `testAContainerShellRunsInAPty` (`docker exec -it` in a terminal pty, exit 0) |
| `docker.editor` | done | Core `StackEditorTests` (ported); lab `testTheStackFileReadsAndIsCheckedOnTheServer`; `DockerScreenModelTests` |
| `docker.delete-stack`, `docker.add-container`, `docker.bookmarks` | done | Core `StackRemovalTests`, `AddContainerDraftTests`, `BookmarkEditorTests` (ported); `DockerModelTests`, `DockerScreenModelTests` |
| `docker.favicons`, `docker.app-icons` | done | Core `FaviconLinksTests`, `AppIconsTests`, `IconChoicesTests`, `IconFetchQueueTests`; `RackoonIOSTests.IconStoreTests` (choices kept and forgotten, a picked photo redrawn at 256 px and deletable, nothing fetched without the network) |
| `fleet.dashboard` | done | the Docker and Bookmarks pages; `FleetTests`, `DockerModelTests` |
| `docker.sudo` | planned | stage I5 |

- **Core first.** The Kotlin core's Docker rules were ported to Swift so iOS shares them with tests: `ActionPrompts` (the Mac's wording; restarts count as destructive, as on the Mac, while Android marks them non-destructive), `DockerPresentation` (`LinkScope`, stack status, summary, `LetterTile`, `ImageName`), `LogFollower`/`LogView`, `StackEditor`, `BookmarkEditor` and `AddContainerDraft` (51 Core tests). They are `@MainActor` classes that publish through `onChange`; the iOS `@Observable` models mirror their state. The Mac keeps its own models and views (one private `bookmarkLinks` copy was replaced by Core's identical one).
- **App.** `DockerModel` (per server, kept by `DockerStore` in `AppModel`, polled every 10 s only while a Docker screen, a stack page or a Dashboard page is attached; dropped on edit, removal, sign-in change and demo switch). The Docker list (search, health filter, summary, swipe to bookmark), the stack page (Containers / Logs / Files / Output, one Stack Actions menu with a reason when disabled, a container menu with Logs, Shell, Restart…, Stop…/Start, Rebuild…), `ConfirmSheet` (exact command, diff, a red button that Return does not press), the read-only SwiftTerm Output with Cancel/Close, the logs panel (container and level chips with counts, filter, Following/Paused, "Latest · N new", copy), the editor (a TextKit 1 `UITextView`: highlighting from the theme, green/red line bands, auto-indent, a key row), the delete sheet (typed name whenever data is lost), Add Container (form or pasted compose, server checks, files preview), Bookmarks (grouped list, add/edit/remove sheet), app icons with the picker (search both collections, Automatic, letter, your own photo) and site icons, and the Dashboard's Docker and Bookmarks pages. Icons and favicons are fetched from the phone; `Info.plist` allows plain http (as the Mac bundle does) because many bookmarks are `http://`.
- **Found on the way.**
  - The shared demo answered a file save as if it were a read (both commands start with `F='`), so Save never worked in demo mode on the Mac either. Fixed in `DemoTransport`, with a test.
  - Text fields bound to computed values over the draft dropped or misplaced keystrokes while the form re-rendered; the Add Container form now edits plain state that is passed on to the draft.
  - `SwiftTerm` exports its own `Color`; qualify SwiftUI's in files that import both.
- **Checked in the simulator (demo mode):** Docker list with icons; immich's stack page; Update through the confirm sheet into a live Output; merged logs; editing compose.yaml with the green band, passing checks and Save and Redeploy; Add Container creating and starting a new stack and opening it on its Output; the Dashboard's Docker and Bookmarks pages with fetched site icons.
- **Not built / not tried:** sudo for Docker (I5); line numbers and horizontal scrolling in the editor (long lines wrap); the two-way compose editing of the Mac's Add Container (a pasted file replaces the form, as on Android); a tablet two-pane layout. Not tried on a device or against a real server from the phone (only the lab, through the same transport).

## Stage I5 result: updates, reboot, sudo (Keychain + Face ID) (22 Oct 2026)

| Feature | iOS | Proven by |
|---|---|---|
| `updates.list` | done | Core `UpdatesParserTests`, `UpdatesPresentationTests` (ported from Kotlin); lab `testUpdatesParse`; `RackoonIOSTests.UpdatesModelTests` |
| `updates.install` | done | Core `AptActionTests`, `UpdatesSessionActionTests`, `AptStreamingTests`; `UpdatesModelTests` (each install asks with its exact command and streams) |
| `reboot` | done | Core `RebootSessionTests`, `RebootOfferTests`; `RebootFlowTests` (new boot id, password asked and asked again after a wrong one, a rejected saved password forgotten, giving up leaves the server running, Read-only offers nothing) |
| `sudo.password` | done | Core `SudoElevationTests`, `SudoHandshakeTests`, `SudoStreamTests`, `SudoAuthFailureTests`; lab `testSudoPasswordChecked`, `testAPasswordStreamIsAnsweredOnce` (the nonce prompt answered once over the embedded pty, a wrong password rejected); `UpdatesModelTests`, `RebootFlowTests` |
| `sudo.remember` | done | `SudoVaultTests` (scope check before any prompt, cancel keeps it, edit/removal forget it), `UpdatesModelTests/testASavedPasswordIsConfirmedAsThePasswordCommand`, `RebootFlowTests/testARejectedSavedPasswordIsForgottenAndTheSheetAsks` |
| `docker.sudo` | done | Core `DockerAccessTests`, `ElevationWindowTests`, `SudoTransportTests`; lab `testASudoTransportRunsAsRoot` (run and stream as root through the embedded transport, a wrong password locks); `DockerElevationTests` |

- **Updates.** `UpdatesModel` (per server, kept by `AppModel`) and `UpdatesScreen`: subtitle, list age and staleness, the server's own reboot-required flag with Reboot…, Refresh Lists / Install All / Install Security Updates (each confirmed with its exact command, streamed into the read-only Output), packages security first, held packages. The words are Core's new `UpdatesPresentation` (the Kotlin rules with their tests). The Overview links to it with a count badge, and attention items now link to their screen (Docker, Updates).
- **Reboot.** `RebootFlow` (the Mac's flow on the shared `RebootSession`), offered on the attention row and on the Updates screen, never decided by Rackoon. `RebootSection` shows its progress (asking, needs password, rebooting with a timer, back, not back, failed) and owns the password sheet, presented only by the screen on top. The Mac's fake reboot transport moved to RackoonDemo (`DemoRebootTransport`), so demo mode reboots on both apps.
- **Sudo.** `SudoPasswordSheet` (the exact command, a `.password` field a password manager can fill, Remember). `SudoVault` stores a remembered password in the Keychain: the password item is `WhenPasscodeSetThisDeviceOnly` with `.userPresence` (never synced or restored elsewhere, deleted if the passcode goes), and its scope (server id, address, user, port) is a second item read without a prompt, so a changed server forgets the password before anyone is asked. Every use evaluates `.deviceOwnerAuthentication` first (Face ID, Touch ID or the passcode) and reads the item with that approved context: the simulator does not enforce the item's access control on its own (a read went through without a prompt), and on a device this keeps it to one prompt. Saved only after the server accepted it; forgotten on edit, removal, or when the server rejects it. Not offered in demo mode or on a device without a passcode.
- **Docker through sudo.** `DockerElevation` (Core's `ElevationWindow`, 15 minutes, memory only) and `DockerAccessNotice` on the Docker and Bookmarks screens. A Docker model remembers the elevation key it was made under and is rebuilt on unlock and lock; container shells get `sudo ` in front. Rackoon never suggests joining the docker group.
- **Found on the way.** The Output view kept its first run's coordinator when a second run replaced it, so the second run showed the first run's text under its own status (Docker actions too). Each run now gets its own terminal view. Also: the sudo sheet now hands the password over before closing, so a presenter that treats dismissal as Cancel (the reboot) does not give up.
- **Checked in the simulator.** Against the lab as `rkpw` (sudo wants its password): Refresh Lists, refused `sudo -n`, the password sheet, Remember, the run; then the next Refresh confirmed the password command with the Face ID note, Face ID prompted (simulator enrollment, matched with `notifyutil`), and apt ran as root. In demo mode: Reboot… from the attention row, the confirm sheet, "Rebooting homelab…" with a timer, then "homelab is back after 15 s". The lab was not rebooted (its `systemctl` stub records a marker other checks read) and nothing was installed there (its pending packages are lab facts).
- **Not built / not tried:** the reboot on a real server (never, by rule) or on the lab; Docker through sudo against a server that refuses Docker (the lab's users may all use Docker; proven with `id -u` through `SudoTransport` instead); a real device's Face ID.
