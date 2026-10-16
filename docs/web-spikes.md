# Web Stage W0: spike results

Decision record for the self-hosted web version (PRD Phase 5): a Docker image with a Python (FastAPI) backend that holds the SSH connections, and a React + TypeScript + Vite frontend that only renders. Python is a third core, kept in step with Swift and Kotlin through `spec/` alone (docs/parity.md). Only the findings are kept here; the spike code that stays is the transport (`web/backend/rackoon/ssh/transport.py`), its lab test and the latency harness (`web/spike/latency/`). Everything ran against the integration lab only; no real server was touched.

## S1: asyncssh transport against the integration lab: PASS (16 Oct 2026)

Setup: Python 3.12.13 (uv), asyncssh 2.24.1 on cryptography 50.0.2, run from the Mac against `tools/lab` (Ubuntu 24.04.5, OpenSSH 9.6p1 sshd, Docker-in-Docker, `labstack`). The test is `web/backend/tests/test_lab_integration.py`: `uv run pytest` from `web/backend` after `eval "$(tools/lab env)"`; it skips every lab test when `RACKOON_LAB` is unset (checked: 1 passed, 13 skipped). Three runs in a row: 14 of 14 passed (about 7.5 s each). `mypy --strict` is clean on `rackoon/`.

Same contract as the Mac's `OpenSSHTransport` and Android's `SshjTransport`:

| Piece | How it is done |
|---|---|
| `run(command, timeout)` | one lazily opened connection per server, shared by all commands (the web's ControlMaster); `asyncio.timeout`, the channel is closed when it fires and the connection stays usable |
| `run(command, timeout, input=…)` | its own connection every time, host key checked again, closed afterwards; `communicate(input)` writes the bytes then EOF; the input is never logged or put in the command |
| `stream(command, input=None, cols, rows)` | its own connection, `xterm-256color` pty, stderr merged; `async with t.stream(c) as s: async for chunk in s`. Leaving the block, `aclose()` or cancelling the reading task types `0x03` into the pty, waits up to 2 s for the remote command to exit, then closes the channel and connection. Strings from `input` are typed into the pty (the sudo prompt answer) |
| `open_shell(cols, rows)` | interactive pty on the shared connection (like the Mac's tabs over ControlMaster), bytes in and out, `resize(cols, rows)` |
| Host keys | strict pinning: `known_hosts=([], [], [])` sends every key to our `validate_host_public_key`, which compares with `KnownHosts`. Unknown raises `HostKeyUnknown(presented)`, different raises `HostKeyChanged(trusted, presented)`, never offered for acceptance. Both happen in key exchange, before any credential. Host certificates are not negotiated (we pin plain keys). `scan_host_key` returns the key to show the user |
| Isolation | `config=None`, `agent_path=None`, no default key files: nothing in `~/.ssh` is read; everything comes from the arguments (in the image, from `/data`, stage W2) |
| Errors | `Unreachable`, `AuthFailed`, `HostKeyUnknown`, `HostKeyChanged`, `ConnectionLost`, `Timeout`, as on Android |
| Keepalive | `keepalive_interval=15`, `keepalive_count_max=3`, like `ServerAliveInterval=15`/`CountMax=3` on the Mac |

The checks in `spec/integration/checks.json`:

| Check | Result |
|---|---|
| `overview_parses` | PASS: hostname, disks, non-zero CPU counters, reboot flag, stub Tailscale IP `100.101.102.103`, 2 pending / 1 security |
| `updates_parse` | PASS: exactly `rackoon-lab-secure` and `rackoon-lab-tool`, the first one security, reboot flag |
| `docker_parses` | PASS: `labstack` / `ticker` running, absolute working dir and compose file labels |
| `stream_exit_status` | PASS: `stream_wrap` around `echo lab-out; exit 3` streams the output and `##rackoon-exit:3` |
| `logs_cancel_leaves_nothing` | PASS: a `tick` line arrives, then 0 `docker logs -f` processes left |
| `hostkey_mismatch_blocked` | PASS: one flipped bit in the pinned key gives `HostKeyChanged` carrying the real key, and the `touch` never ran |
| `stdin_exact_bytes` | PASS: 1 MiB in, `wc -c` counted 1048576 |
| `sudo_password_checked` | PASS: as `rkpw`, a wrong password fails with sudo's "incorrect password" text, the right one gives `id -u` = 0; the password only travels on stdin |

Spike extras (in the same file, `test_spike_*`):

| Check | Result |
|---|---|
| Unknown server: `scan_host_key` and a first connection | PASS after a fix: asyncssh's default order offers **RSA first**, so a new server showed its RSA key while `ssh` and `ssh-keyscan` show Ed25519. The transport now asks in OpenSSH's order (Ed25519, ECDSA, then RSA) for an unknown server, and only the pinned key's algorithm for a known one (otherwise a server with several keys could look "changed") |
| `none` auth against OpenSSH | `AuthFailed`, as it should (proves the mapping only; see S3) |
| Exit codes | `exit 7` = 7; `kill -TERM $$` = 15 (the signal number, like `OpenSSHTransport.exitCode`); a 1 s timeout on `sleep 30` raises `Timeout` and the next command on the same connection works |
| 200,000 three-byte characters through a pty stream | no replacement characters, count exact: asyncssh's incremental decoder keeps a character split across reads whole (the Mac needed `Utf8Chunker` for this) |
| Shell pty size and resize | `stty size` reads 30 100, then 43 132 after `resize` |

Findings:
- asyncssh fits the contract with no workarounds beyond the host-key order. The streamed exit marker stays the cross-platform contract, but asyncssh also reports a pty channel's real exit status (`Stream.exit_status`), which the Mac's `ssh -tt` stream cannot.
- On the lab's OpenSSH sshd, closing a `docker logs -f` stream **without** Ctrl-C also leaves nothing (sshd hangs up the pty). So the lab check cannot tell whether the Ctrl-C step works; only Tailscale SSH leaks the follower (Android S1, Mac). The transport sends it anyway, and S3 is where it gets proven.
- Ctrl-C typed into a pty channel on the **shared** asyncssh connection does reach the remote command (`docker logs -f` exited at once). The OpenSSH mux client is what loses it on the Mac. Streams keep their own connection for now, for parity and so a stream's failure cannot take the shared connection down; this can be revisited if many simultaneous log panes make extra connections costly.
- Timings on loopback: connect + key auth 23 ms median; a command on the shared connection 1.9 ms; `run` with input (new connection each time) 73 ms.
- `tools/lab` uses a fixed compose project (`rackoon-lab`) and port. Another worktree's `tools/lab up` recreated the container with its own key mid-session and every login here started failing with `Permission denied`. This session ran a private copy with `COMPOSE_PROJECT_NAME=rackoon-lab-web RACKOON_LAB_PORT=2232 tools/lab up` (works because the env var beats the file's `name:`). Worth fixing in `tools/lab` (derive both from the worktree); not changed here because the file is shared.

## S2: terminal round trip, xterm.js ↔ WebSocket ↔ asyncssh pty: PASS (16 Oct 2026)

Harness: `web/spike/latency/server.py` (FastAPI 0.143 + uvicorn 0.54 with `websockets`, 127.0.0.1 only, no login, lab only), `index.html` (xterm.js 5.5.0 from jsDelivr) and `bench.py`. Binary WebSocket frames carry raw terminal bytes both ways; text frames carry JSON control (`resize`). A keystroke is typed at the lab's bash prompt and timed until its pty echo comes back, then erased with a backspace; 200 to 300 samples. Everything is on one Mac, so the numbers are the software stack's cost, not the network's.

| Path | Median | p95 | Max |
|---|---|---|---|
| asyncssh pty echo alone (Python) | 0.30 ms | 0.37 ms | 0.83 ms |
| WebSocket → FastAPI → asyncssh pty → back (Python client) | 0.55 ms | 0.77 ms | 2.2 ms |
| Browser: keystroke sent → echo frame arrives (xterm.js page, Chromium 152) | 1.4 ms | 2.1 ms | 2.8 ms |
| Browser: → xterm.js has parsed it (`term.write` callback) | 1.5 ms | 2.2 ms | 3.0 ms |
| Browser: → next animation frame | 1.7 ms | see note | |

Findings:
- The whole stack adds about 1.5 ms per keystroke. Against a real server the tailnet round trip (a few ms on a LAN, tens over DERP) dominates, exactly as it does for the Mac app's terminal. No reason to put anything but a plain byte pipe between xterm.js and the pty.
- The "next animation frame" column could only be measured in the app's built-in browser pane while it was hidden: 27 of 300 samples waited for the ~1 s frame a hidden window gets. Its median (1.7 ms) is the honest number; on a visible tab painting adds at most one frame (16.7 ms at 60 Hz). Re-measure in a visible browser during W4.
- Login banner, prompt and colours render correctly in xterm.js; resize goes through a JSON control frame.
- Not measured yet: many tabs at once, large output bursts (`cat` of a big file), back-pressure when the browser is slower than the server. All belong in W4.

## S3: Tailscale SSH `none` auth: NOT RUN

Needs a real server that runs Tailscale SSH, run read-only. None was supplied for this session. The transport already tries `none` first when it has no key or password (asyncssh sends `none` as its first userauth request) and maps a refusal to `AuthFailed`; against OpenSSH that refusal was checked. Still to prove, when the user names a server: `none` accepted, the same Ed25519 key as the Mac sees, plain exec, and above all **Ctrl-C then close leaves 0 `docker logs -f` followers** (and close alone leaves them, as on Android and the Mac). Tailscale "check" mode is untested on every platform.

## Decision so far

- **asyncssh** for SSH in the web backend. It met every lab check on the first run, multiplexes channels on one connection, and needs no native library beyond `cryptography`.
- **xterm.js over a binary WebSocket** for terminals: about 1.5 ms of overhead.
- Parse checks in the W0 test read the raw `##` sections themselves because there is no Python core yet. Stage W1 replaces that with the core's parsers and gates every check on the web column of `spec/features.json`, like `LabIntegrationTests.swift` / `.kt` (until then every check runs, and none is named as proof in `features.json`).

## Still open

- S3 above (needs a Tailscale SSH server from the user).
- Encrypted private keys, and password auth (asyncssh supports both; W2 decides what is offered, given the PRD's "no password stored in plain text").
- Keepalive behaviour over a dropped link (W4, with the terminal's auto-reconnect).
- `tools/lab` clash between worktrees (see S1).

## Stage W1 result: the Python core (16 Oct 2026)

`web/backend/rackoon/core`, pure Python (no SSH, network or database; the only thing it reads is `spec/`), `mypy --strict` clean over the core and its tests. `cd web/backend && uv run pytest` runs it; `uv run mypy` type-checks it.

- **spec/ is the only copy.** `spec.py` reads `commands.json`, `command-library.json` and `themes.json` at runtime (from `$RACKOON_SPEC` / `$RACKOON_THEMES` in the image, else the repository), like the Kotlin core. A test walks every string literal in the core and fails if one holds a whole spec script.
- **Models** follow `spec/models.schema.json`: `to_json` writes camelCase keys and leaves out unknown optionals; a test validates parsed Overview, DockerSnapshot, UpdatesSnapshot and Server output against the schema with `jsonschema`.
- **Golden fixtures: every folder passes** (35 files): overview, docker, updates, file_read, listening_ports, files_list, docker_states, services, unraid. Services, Unraid, docker_states and files_list were ported from Swift (the Kotlin core does not have them yet). `licence` is not parsed: supporter keys are `na` for web. A test fails if a new fixture folder has no Python parser test. Number parsing is strict on purpose (Python's `int()`/`float()` accept spaces, `_` and `nan`; Swift and Kotlin do not), and rounding is half-up like theirs.
- **Shared scenarios:** `tests/test_shared_scenarios.py` implements all seven subjects and is gated by the web column exactly like the Swift and Kotlin runners; a subject with no applicable file is reported as skipped rather than as an empty pass. With `RACKOON_PARITY_ALL=1` every file runs: all pass.
- **Lab checks** now use the core's parsers and command builders and are gated the same way (all eight pass against the lab with `RACKOON_PARITY_ALL=1`; gated, they skip until their features are done for web). The sudo check still matches sudo's own words; the core's sudo classifier comes with stage W6.
- **Also in the core** (used from W3 on): the action policy, compose/container command builders and id checks, the stream wrapper and exit-marker parser, connection-field checks, theme loading and validation, the command library with parameter quoting.
- **CI:** the `web-core` job runs mypy and pytest (JUnit `junit-web`, refs like `tests.test_shared_scenarios/test_shell_quote`), then the scenarios once more with `RACKOON_PARITY_ALL=1`. The parity job requires `web`. `core.shell-safety` is now done for web.

Notes for later stages:
- `ServiceCatalog` (product names, plumbing lists, interpreters, helpers) now lives in `spec/service-catalog.json`: `services.py` reads it at runtime (`catalog()`), the Swift constants are held equal to it by `ServicesTests.testCatalogMatchesTheSpecFile`, and `tools/check-spec` validates it.
- The Python `DockerContainer` carries `iconURL` (Unraid template icons) like Swift; the Kotlin core does not have it yet.
- The CI `lab` job does not run the Python lab checks yet: gated, they would all skip. Add it when the first lab-checked feature (W3's overview) is done for web.
