# Feature parity across platforms

Rackoon ships, or is planned to ship, on four platforms: **mac** (`apple/Apps/RackoonMac`), **android** (`android/`), **ios** (planned, `feature/ios-app`) and **web**, the self-hosted Docker image (planned, `feature/self-hosted-web`). The server logic lives in cores kept in step by `spec/`:

| Core | Language | Used by |
|---|---|---|
| `apple/Packages/RackoonCore` | Swift | mac, ios |
| `android/core` | Kotlin | android |
| `web/backend/rackoon/core` (planned) | Python | web |

The rule: **a change to one app keeps the others honest.** Platforms may lag, but only visibly, and nothing can claim to be done without a passing test. Four layers enforce it.

## 1. The feature matrix: `spec/features.json`

Every user-facing feature has one entry per platform:

```json
"docker.logs": {
  "mac":     {"status": "done", "tests": ["RackoonCoreTests.LogBufferTests", "RackoonSSHSystemTests.LabIntegrationTests/testLogsCancelLeavesNothing"]},
  "android": {"status": "done", "tests": ["com.bgallagher.rackoon.core.LogFollowerTests"]},
  "ios":     {"status": "planned", "reason": "stage I4"},
  "web":     {"status": "na", "reason": "…"}
}
```

- `done` names the tests that prove it, as a JUnit class (`Class`, every case must pass) or one case (`Class/method`). A feature that really has no automated test yet (a SwiftTerm view verified by hand) says so in `untested`. `check-spec` counts these, so the debt stays visible.
- `planned` and `na` need a `reason`.
- Every command in `spec/commands.json` belongs to exactly one feature (`commands`), so a new server command cannot arrive without a matrix entry.

`python3 tools/check-spec` validates all of this. `tools/check-parity` reads the platforms' JUnit reports and fails if a test named by a `done` entry did not run or did not pass. CI runs it in the `parity` job and writes the matrix to the job summary.

```bash
(cd apple && swift test --parallel --skip LabIntegrationTests --xunit-output build/junit/swift.xml)
tools/check-parity --summary mac=apple/build/junit android=android/core/build/test-results/test,android/ssh/build/test-results/test
```

SwiftPM writes XCTest results as xUnit only with `--parallel`, and it reports a skipped XCTest as **passed**. The Swift lab tests are therefore left out of the main report with `--skip LabIntegrationTests` and come only from a run against the lab. Gradle reports skips correctly, and `check-parity` never counts a skip as proof.

## 2. Golden fixtures: `spec/fixtures/`

These were already in place. Captured real output and its expected parse; every core's parsers must match them (see `spec/README.md`).

## 3. Shared behaviour scenarios: `spec/scenarios/*.json`

Rules that are not parsers, written once as data and run by every core: shell quoting, one-pass templates, the action policy (confirm the exact command, read-only checked again at run time), compose command building, the streamed exit marker, connection input, id checks.

```json
{"feature": "docker.stack-actions", "subject": "compose_command", "about": "…",
 "cases": [{"name": "rebuild one service", "action": "rebuild", "service": "web", "stack": {…}, "expect": "cd '/srv/media' && …"}]}
```

- Each core has one runner, `SharedScenarioTests` (Swift `RackoonCoreTests`, Kotlin `android/core`), with a test per `subject`.
- **A file runs on a platform only while its `feature` is done there**, so marking a feature done switches its scenarios on. A runner fails if an applicable file has a subject it does not know. A file without a `feature` runs on every core.
- Wording stays each app's own: scenarios compare results (a command, null, ok or refused), not message text.

When you change a rule that a scenario covers, edit the scenario first, then make every core pass.

## 4. Integration lab: `test/lab` and `spec/integration/checks.json`

A disposable Ubuntu server in Docker. It has sshd, a Docker-in-Docker sidecar running one compose stack (`labstack`, a ticker that logs every second), and a local apt archive with one ordinary and one security update. It also has a pending-reboot flag, and stub `systemctl` (records `reboot` instead of rebooting) and stub `tailscale` commands. Users: `rk` (key login, passwordless sudo) and `rkpw` (sudo wants `lab-sudo-password`, from `test/lab/lab.env`).

```bash
tools/lab up                 # build, start, wait; writes test/lab/.state (throwaway key, scanned host key, env)
eval "$(tools/lab env)"
(cd apple && swift test --filter LabIntegrationTests)
(cd android && ./gradlew :ssh:test --tests 'com.bgallagher.rackoon.ssh.LabIntegrationTests')
tools/lab down
```

- Every transport runs the same checks with its real SSH code: `LabIntegrationTests` in `RackoonSSHSystemTests` and in `android/ssh`. The checks cover parsing real output, streamed exit status, a cancelled `docker logs` leaving nothing behind, a changed host key blocked, exact stdin bytes, and sudo password checking.
- Feature gating works as for the scenarios. The tests skip themselves when the lab isn't configured, so a normal `swift test` is unaffected.
- The Mac transport is pointed at the lab with `-F /dev/null` and the lab's own known_hosts. Nothing in `~/.ssh` is read or written.
- In CI, the `lab` job runs on Linux, because macOS runners have no Docker. It runs the Kotlin checks there, and the Mac's `OpenSSHTransport` in the `swift:6.2` image. `RackoonCore` and `RackoonSSHSystem` therefore build on Linux; the Secure Enclave secret store is compiled only on Apple platforms.
- The lab is the only place checks may change things. Real servers stay read-only (the existing `rackoon-probe` rules still apply).

## Definition of done for a change

1. If it touches a server command, a parser or a shared rule: change `spec/` first (command, fixture, scenario).
2. Make every core that has the feature pass. If the change is for one platform only, update the other platforms' entries in `spec/features.json` (still `done` with a test, or `planned` with a reason).
3. Name the tests that prove it in `spec/features.json`. For behaviour that talks to a server, add a lab check.
4. `python3 tools/check-spec`, the platform test suites and `tools/check-parity` pass locally or in CI.
