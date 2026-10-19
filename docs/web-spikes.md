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
- `ServiceCatalog` (product names, plumbing lists) is data only the Swift core had, now copied into `services.py`. It should move to `spec/` so the cores can't drift; the services fixtures cover the names they use, nothing more.
- The Python `DockerContainer` carries `iconURL` (Unraid template icons) like Swift; the Kotlin core does not have it yet.
- The CI `lab` job does not run the Python lab checks yet: gated, they would all skip. Add it when the first lab-checked feature (W3's overview) is done for web.

## Stage W2 result: server, sign-in, servers, host keys and keys (16 Oct 2026)

`python -m rackoon.app` serves the API (FastAPI on uvicorn, `0.0.0.0:8080` by default); everything is kept under `RACKOON_DATA` (`/data` in the image). No UI yet (W3), and nothing in W2 runs a command on a server: the only SSH traffic is the host-key scan and the connection check, which signs in and runs nothing.

| Area | What is built |
|---|---|
| Data folder (`rackoon/app/storage.py`) | `servers.json` (a plain JSON array of Server, the Mac's format), `snapshots/<id>.json`, `known_hosts.json`, `keys.json` + `keys/<id>`, `auth.json`, `secret`. Folders 0700, files 0600, every write atomic (temp file, fsync, rename). An unreadable JSON file is moved aside, never overwritten. |
| Sign-in (`security.py`, `api.py`) | argon2id password from `RACKOON_ADMIN_PASSWORD_FILE` (the password or an `$argon2id$` hash; the API then can't change it), else a one-time setup token in the log and `<data>/setup-token` until a password is set (12 characters at least). Optional TOTP (RFC 6238, ±1 step, no replay). In-memory sessions: `__Host-rackoon` cookie, HttpOnly, Secure, SameSite=Strict, Path=/, stored as a SHA-256, 12 h idle / 7 day limit; a password change signs other sessions out. Sign-in failures are limited to 5 per address and 50 overall per 15 minutes. Password and code are always checked together, so a failure doesn't say which one was wrong. |
| Request guard | Every change needs the `X-Rackoon-CSRF` token, a same-origin `Origin` when the browser sends one, and a JSON body (64 KiB max); responses carry nosniff, DENY framing, no-referrer and `no-store`. |
| Forward auth | `RACKOON_FORWARD_AUTH_HEADER` (e.g. `Remote-User`) is believed only from `RACKOON_TRUSTED_PROXIES` CIDRs (the app refuses to start with a header but no proxies), optionally only for `RACKOON_FORWARD_AUTH_USERS`; CSRF still applies (an HMAC token per user). `X-Forwarded-For` counts only from trusted proxies (the rate limit can't be dodged by sending it). |
| Servers | List, add, edit, reorder, remove. Fields are checked with the core's `server_input_problem` (the shared server-input scenarios now run on web). An edit that changes the connection (`connects_like` false) drops the open connection and the cached reading; a rename keeps them. |
| ssh_config import | `RACKOON_SSH_CONFIG` (mount `~/.ssh` read-only). Each entry is resolved into a plain Server (HostName, User, Port), because the container doesn't share the host's `~/.ssh` the way the Mac's ssh does. Its IdentityFile (`~/.ssh/x` maps to the mounted folder; other paths only if inside it) is copied into the key store, or ssh's default key names when it names none. Encrypted keys are left for the Keys page; ProxyJump entries are refused (not supported yet). |
| Host keys | Scan, or a check that meets an unknown key, returns the fingerprint and a scan id. Trust needs that scan id (10 minutes, one use, the same server and address) and the fingerprint the user confirmed. A changed key is reported with both fingerprints and never offered; `known_hosts.json` refuses to replace a key. To accept a legitimately changed key, delete the entry from that file by hand, as with `~/.ssh/known_hosts`. |
| Keys | Generate Ed25519, or import OpenSSH/PEM private keys (an encrypted one with its passphrase, used once to decrypt it; that needed `asyncssh[bcrypt]`, found by a test). The API returns names, fingerprints and the `authorized_keys` line, never a private key. A key in use can't be deleted. A server with no key signs in with SSH `none` (Tailscale SSH). |

Tests: `tests/test_security.py` (RFC 6238 vectors, argon2id, limits, sessions), `tests/test_storage.py` (data folder, modes, known hosts, keys, the Swift core's ssh_config cases), `tests/test_api.py` (every endpoint over HTTP with a fake scanner), and against the lab `tests/test_api_lab.py`: scan, trust, sign in with an imported key, then a changed key is blocked after a restart; sign in with a generated key only while its line is in rk's `authorized_keys` (the test adds and removes it). The CI `lab` job now runs the Python lab tests too (`junit-web-lab`). Done for web: `servers.edit`, `servers.sshconfig-import`, `connect.hostkey`, `connect.keys`, and the new web-only `web.sign-in`. `servers.saved` stays planned until W3 paints the cached snapshot.

Limits to know:
- The cookie is `Secure`, so browsers keep it only over HTTPS or on `localhost`. On a tailnet, put Rackoon behind `tailscale serve` (HTTPS with a real certificate) or another TLS proxy; plain `http://host:8080` won't stay signed in.
- Private keys sit unencrypted (0600) in the data volume, like files in `~/.ssh`; protect the volume.
- Sessions, scans and rate-limit counters are in memory: a restart signs everyone out.
- Starlette warns that its TestClient will move from `httpx` to `httpx2`; harmless for now.

## Stage W3 result: UI shell, Overview, attention, dashboard, Read-only, demo (16 Oct 2026)

The web app now has a frontend: `web/frontend`, React 18 + TypeScript (strict) + Vite, about 60 KB gzipped, served by the backend from `RACKOON_STATIC` with a strict Content-Security-Policy (scripts, styles and requests from its own origin only, no framing) and a fallback to `index.html` for the app's own routes. It holds no server logic: everything it shows comes computed from the API, and it only formats numbers.

| Piece | Where | What it does |
|---|---|---|
| Polling | `rackoon/app/monitor.py` | One task per server, as `ServerSession` + `FleetMonitor` on the Mac: the `overview` command every 5 s while a browser watches that Overview (`?watch=1`; a newly opened one waits up to 2.5 s for a fresh reading), once a minute otherwise. A failed poll keeps the last reading beside the error; CPU % from two readings; the cached snapshot is painted (stale) until the first answer; a good reading is cached at most once a minute; an unknown or changed host key stops polling until the key is trusted or the user asks. |
| Attention | `core/attention.py` | `spec/attention-rules.json` as a pure function, red items first, short wording (Kotlin's `AttentionPresentation`). |
| Failures explained | `core/connection_failure.py` | The transport now reports failures in ssh's words ("Connection refused", "Could not resolve hostname", "timed out", "No route to host"), so one explainer gives a headline and advice for every platform's messages; the sign-in method (key or Tailscale SSH) shapes the advice for a refused login. |
| Dashboard | `core/fleet.py`, `/api/fleet` | Fleet totals (CPU weighted by cores), and per server a one-hour heartbeat (a sample a minute, every up/down change kept), uptime %, CPU and memory sparklines (fixed 0–100) and the fullest disk; server tiles. |
| Palette | `core/palette.py` | `AppPalette.derive` ported line for line; every bundled theme meets the same contrast floors as on the Mac and Android (test over all 45). `/api/appearance` sends both the dark and light resolution, so Automatic follows the browser by CSS alone, plus the terminal colours for W4. |
| Read-only | `app/preferences.py` | On for a new install (a web app is reachable from more places than a Mac app). It turns itself back on after 15 minutes without a click or key press by default (5 min, an hour or never can be chosen), and never while an action runs. The browser sends at most one activity ping a minute while changes are allowed. |
| Confirm the exact command | `app/actions.py` | An endpoint that would change a server only proposes an `Intent`; `POST /api/actions/<id>/confirm` mints the `Confirmation` through the shared `ActionPolicy` and runs it, and the service authorizes it again (Read-only switched on in between still blocks it). One use, five minutes. The sheet shows the exact command (or its readable preview); a destructive one has a red button that Return doesn't press. W5 brings the first real actions. |
| Server list | `core/server_list.py` | Filter (every word, case and accents ignored) and move onto / up / down, from the backend. |
| Demo | `RACKOON_DEMO=1`, `app/demo.py` | The Mac's homelab and garage-nuc, plus Android's old-nas (never answers) and backup-box (refuses the login). It uses a temporary data folder, is signed in as "demo" without a password, and sends nothing anywhere. |

Screens: sign-in and first-run setup, a sidebar with the server card and switcher (filter, drag to reorder, ↑↓, add), Dashboard, Overview (attention strip, connection-problem card with Check Host Key… / Edit Connection… / Try Again, CPU, memory, uptime, disks, system info with copyable IPs, ticking uptime and server clock), Settings (servers with add/edit/check/host key/remove and ssh_config import, keys, password and TOTP, 46 theme choices, Read-only's timer), and a Read-only switch. Under 760 px the sidebar becomes a top bar. Checked by hand in the app's browser pane in demo mode: dashboard, every Overview state, the switcher's filter, Settings, Rackoon Light and Dracula, and phone width.

Tests: `tests/test_core_ui.py` (palette over every theme, attention, failures, fleet, server list, Read-only timer), `tests/test_screens_api.py` (the monitor with a fake transport, demo mode, appearance, Read-only, the action center, server list endpoints, the served frontend and its CSP), `web/frontend/src/format.test.ts` (vitest), and the `overview_parses` lab check now runs for web. CI: a `web-frontend` job (`npm ci`, type check, tests, build). Done for web: `servers.saved`, `servers.menu`, `connect.failure-explained`, `overview`, `overview.system-info`, `attention`, `themes`, `safety.read-only`, `safety.confirm`, `demo`. `fleet.dashboard` waits for W5's Docker and bookmark pages.

Found while checking: opening an Overview first showed a reading up to a minute old (fixed by the settle wait above). A health table with 60 fixed-width beats overflowed narrow windows (beats now shrink; Memory and Disk columns hide under 1100 px).

## Stage W4 result: terminal over WebSocket (16 Oct 2026)

Terminal tabs (`rackoon/app/terminals.py`, `web/frontend/src/screens/Terminal.tsx`): the backend keeps each tab's SSH shell, so a tab survives switching screens and servers and reloading the page, until it is closed, its server removed or its connection edited (as with the Mac's TerminalStore). The browser runs xterm.js 5.5 with the fit addon, loaded only when a terminal opens (the main bundle stays about 60 KB gzipped).

| Piece | What it does |
|---|---|
| Transport | Each tab is a pty shell on the server's shared asyncssh connection (like the Mac's tabs over ControlMaster), with the keepalive that makes a dead link fail in about 45 s. |
| WebSocket | `/api/terminals/<id>/ws`: binary frames are terminal bytes both ways, text frames JSON (`resize` from the browser; `state` and `readOnly` from the backend). A WebSocket can't carry the CSRF header, so the upgrade needs this page's Origin (a missing one is refused too) on top of the SameSite=Strict session cookie or a trusted forward-auth header. Attaching replays the last 512 KB of output; a browser that loses the socket attaches again by itself. |
| Highlighting | `core/terminal.py` ports the Kotlin `OutputHighlighter` and `TerminalOutputFilter` byte for byte: SGR 35/31/33/32 pairs around IPs, error, warning and success words and high percentages, coloured by the theme's own ANSI palette; never inside escape sequences, a program's own colours or the alternate screen; a token touching a chunk edge is left plain. The Highlight output switch (Terminal bar, saved as a preference) changes open tabs at once, and the filter tracks escape state while off, so switching on inside vim is correct. |
| Reconnect | `ReconnectPolicy` ported: only a lost connection is retried, 1/2/4/8/15 s, a fresh budget after 10 s connected; a dim notice goes into the scrollback and the tab shows "Reconnecting in N s (attempt a of b)" with Reconnect Now / Close Tab. A shell that exits, a refused login or a host-key problem is final (Start Again / Reconnect Now). |
| Read-only | As on Android, a shell can change anything: while Read-only is on no tab opens, and keystrokes to open tabs are refused (output keeps flowing; the page says why). Typing counts as activity for Read-only's idle timer. |
| Tabs | Up to 10 per server, rename by clicking the selected tab's name (40 characters, empty means "Shell"), close with ×. |
| Demo | A scripted shell (banner, prompt, a few canned answers, line editing, `drop` to fake a lost connection, `exit`); nothing typed is run anywhere. |

Tests: `tests/test_terminal.py` (the Kotlin highlighter, filter and reconnect tests, case for case, including 300 random chunkings and 3000 random byte strings through a disabled filter), `tests/test_terminals_api.py` (demo mode over the real WebSocket: the Origin check, Read-only gating, typing, live highlight switching, resize, replay on reattach, a lost connection reconnecting, exit, rename and close, refused logins not retried) and `tests/test_api_lab.py::test_lab_terminal_over_the_websocket` (a real shell on the lab's sshd: typed command, highlighted IP in its output, a resize that `stty size` sees, `exit 3` ending the tab with code 3). Checked by hand in demo mode: the Read-only gate, a shell, highlighted IPs, `drop` reconnecting with the history kept, and a page reload reattaching to the same shell. Done for web: `terminal.tabs`, `terminal.highlight`, `terminal.reconnect`.

Found while building: the test client's WebSockets always connect as `testserver`, so tests send that Origin and pass the session cookie by hand (a browser sends both by itself). Reconnect on an exited tab first answered "exited" (fixed: it reports "starting" at once). The W0 latency harness measured this same path at about 1.5 ms per keystroke on loopback.

## Stage W5 result: Docker D1–D7 (19 Oct 2026)

The Docker section, ported from the Kotlin core and the Mac app's behaviour. The backend works out every rule (`rackoon/app/docker_api.py`, `docker_hub.py`, `runs.py`, `favicons.py`; core `action_prompts.py`, `docker_view.py`, `stack_actions.py`, `stack_files.py`, `editor.py`, `line_diff.py`, `compose_edit.py`, `add_container.py`, `logs.py`, `favicon.py`); the React screens (`screens/Docker.tsx`, `DockerPanels.tsx`, `AddContainer.tsx`, `Bookmarks.tsx`) only lay it out.

| Piece | What it does |
|---|---|
| Overview (D1) | `docker ps -a` + `docker stats` every 10 s, only while a browser shows a Docker page of that server (`docker stats` is slow). Stacks grouped by compose project; a `docker run` container is its own standalone stack, ids `standalone/<name>`. Search, the running / needs attention / stopped chips, per-stack status, images, usage, the main web port as a link to the Tailscale (else LAN) address, Docker totals with the disk holding /var/lib/docker. A just-created stack with no containers stays "Not started"; a stack being deleted stays on screen until its run ends. |
| Actions with live output (D2) | Every change is proposed with the apps' own words (`action_prompts`) and runs only from the confirm sheet; start runs on one click but still through the policy. Confirmed actions become runs (`RunManager`): wrapped by `stream_wrap` at the size of the browser's Output view, on their own pty connection, output to every browser over `/api/runs/<id>/ws` (a late or reloaded page gets the replay), the exit marker as the only success, Cancel types Ctrl-C before closing. One run per server; restarts and stops are destructive (red, Return doesn't confirm), as on the Mac. Stack Actions: Update, Pull, Rebuild, Restart All, Recreate, Delete; per container Start/Stop/Restart, Rebuild from Dockerfile, Shell (a terminal tab running `docker exec -it`; Read-only gates it), Copy name. Standalone: Pull Latest Image, Restart/Start, Delete Container, with the compose actions shown disabled with the reason. |
| Logs (D3) | `/api/servers/<id>/docker/logs/ws?ids=…`: one `docker logs -f --tail 100` per chosen container on its own pty, merged, parsed into time / level / source / message, sent in 100 ms batches. Closing the socket sends Ctrl-C to each (the `logs_cancel_leaves_nothing` lab check). The page follows the end while it is in view and counts new lines when scrolled up. |
| Editor (D4) | The stack's own compose files and `.env` only. The page sends the exact text; `/files/check` answers with the server's own `docker compose config` verdict for that text (`.env` syntax is checked first without a round trip), the checklist and whether Save may be pressed; the page shows a verdict only for the text it was about. Save is sha-guarded against the file as opened (the backend also checks that the original it was sent hashes to that sha), keeps `.rackoon.bak`, and shows the diff in the sheet. Save and Redeploy names the `up -d` as the sheet's follow-on command and runs it into Output after the save. A file changed on the server offers Reload / Keep Editing, never overwrite. |
| Delete (D5) | The sheet chooses named volumes (off) and the folder (on when allowed); the confirm sheet then asks for the stack's name whenever data goes, and the backend checks the typed word too. Folder rules and the shell guards come from the core (tested with real `/bin/sh` runs and symlink traps). A successful delete returns to the overview; a failed one keeps the stack as "Not started". |
| Add container (D6) | A form or a pasted compose file (Android-style: no two-way form parser), new stack or an existing one. `/add/evaluate` builds the files and runs the server's checks for exactly that draft (scratch-folder compose check, image lookup remembered for 5 minutes and run in the background, listening ports, names), `/add/deploy` checks again and proposes the create (or the `.env`-first saves) with the `up -d` as follow-on. |
| Bookmarks and icons (D7) | Homepage labels written as line edits into the compose file that defines the service (`compose_edit`), diff in the sheet, Save and Apply / Save Only; a Bookmarks screen grouped by `homepage.group`, and the dashboard's Docker and Bookmarks pages over every answering server (`/api/fleet/docker`). Site icons are fetched by this server, only for addresses Docker reported (bookmarks and stack links), with the Mac's limits (256 KB page, 1 MB image, 6 s, http(s) only, every redirect hop checked, link-local refused), cached under `<data>/favicons`, sniffed by their bytes, SVG served with a sandbox CSP. Not built: the dashboard-icons / selfh.st app-icon catalog and picker (`docker.app-icons` stays planned). |
| Demo | `app/demo_docker.py`: the Mac's 12 homelab stacks and garage-nuc's two, with compose files that can be opened, checked and saved, stacks that can be created and deleted, believable streamed output and live logs, all in memory. |

Tests: core ports (`test_stack_actions.py` incl. real `/bin/sh` runs, `test_editor_core.py`, `test_compose_edit.py`, `test_add_container.py` with the real create scripts, `test_add_draft.py`, `test_logs.py`), `test_runs_and_prompts.py` (the prompts, the run manager, the favicon fetcher against canned sites), `test_docker_api.py` (16 tests over the whole API in demo mode, the logs and run WebSockets included) and `test_docker_api_lab.py` (on the lab: create and start a throwaway busybox stack under /tmp, check and save its compose file against the sha, a stale save refused, restart its container, delete it with its folder; always cleaned up). The `docker_parses`, `stream_exit_status` and `logs_cancel_leaves_nothing` lab checks and the `compose_command`, `docker_ids` and `stream_output` scenarios now run for web. Checked by hand in demo mode: the overview, a stack page with merged logs, Update through the sheet into Output, an edit checked on the server, Add Container's live checks, the dashboard's Docker page. Done for web: `docker.overview`, `docker.container-actions`, `docker.logs`, `docker.stack-actions`, `docker.rebuild-service`, `docker.standalone`, `docker.shell`, `docker.editor`, `docker.delete-stack`, `docker.add-container`, `docker.bookmarks`, `docker.favicons`, `fleet.dashboard`. `docker.sudo` is W6.

Found while building: `contextlib.suppress(CancelledError)` around a WebSocket's writer task swallowed the handler's own cancellation and left Starlette's test client with a cancelled future (now `gather(..., return_exceptions=True)`). The editor has no syntax colouring yet (a plain text area with a line gutter marking changed and failing lines).
