# Rackoon PRD

Oct 9, 2026 · @Brian

## Overview

Rackoon is an agentless SSH app that lets one person run their self-hosted Linux servers from a Mac, then an iPhone and Android phone. The MVP is a Mac app that does four things well: connect, monitor, manage Docker Compose stacks, and open services by Tailscale or public URL.

**Positioning:** the server manager for people who self-host over Tailscale and Docker Compose. Built first for the author's own servers; sold later if it earns it.

**Working name:** Rackoon (placeholder, check trademark and App Store availability before launch).

## Problem and opportunity

Self-hosters manage servers through raw SSH, Compose commands and scattered bookmarks, and no single app covers Mac, iPhone and Android.

- **Daily friction:** checking disk, restarting a container or finding the right URL means a terminal session or a hunt through bookmarks.
- **Tailscale vs public:** the same service has two addresses depending on where you are, and bookmarks do not know which to use.
- **Updates go unnoticed:** pending apt patches and new image versions are only seen if you look.
- **No phone answer:** most GUI tools are Mac-only or web dashboards you must host yourself.

**Closest competitor:** ServerBuddy (Mac only) offers stats, SSH terminal, processes, systemd, Docker, files, ports, users, apt, cron and logs. It costs $59 one-off with one year of updates, and a free tier allows one server. Rackoon does not try to match that breadth at launch. It aims to be better at Compose, Tailscale-aware access, updates and alerts, and to reach phones.

## Goals and non-goals

**Goals**

1. Replace the author's daily SSH-and-Compose routine for 2 to 3 servers within the MVP.
2. Show server health and anything needing attention within 2 seconds of opening a server.
3. Open any service in one tap using the right Tailscale or public URL.
4. Keep the server untouched: no agent, nothing installed, standard SSH only.
5. Keep an option open to sell on the Mac App Store without a rewrite.

**Non-goals for the MVP**

- Windows or Linux desktop versions. (A web version was listed here until 2026-10-16; it is now Phase 5, below.)
- Kubernetes, multi-user teams, or cloud-provider management.
- A server-side agent or hosted backend.

## Target user and scenarios

**Primary user:** a technical self-hoster running 1 to 5 Linux servers (a VPS and a home box) with Docker Compose and Tailscale, who is comfortable in a terminal but would rather not use it for routine jobs.

| Scenario | What they do today | With Rackoon |
| --- | --- | --- |
| Morning check | SSH in, run df, docker ps, apt list | Open the app, read the "needs attention" strip |
| A service is down | SSH, find the container, read logs, restart | Tap the unhealthy container, view logs, restart |
| Reach a service | Remember which URL works from where | Tap the bookmark, pick Tailscale or Public |
| Patch day | apt upgrade and docker compose pull by hand | Review pending updates, apply security ones in one tap |
| Away from desk | Mobile SSH client, typing on glass | Phone app with the same overview and alerts |

## Phasing at a glance

Roadmap: Phase 1 MVP (Mac) → Phase 2 Monitoring and alerts → Phase 3 iPhone → Phase 4 Android and Mac App Store. Each phase ends at a gate.

Only the MVP is scoped in detail. Phases 2 to 4 are directional and get re-planned after each gate.

## MVP requirements

The MVP is a signed Mac app (macOS 14+, Apple Silicon) that the author can use daily on their own servers. P0 means the MVP does not ship without it.

| ID | Requirement | Priority | Acceptance criteria |
| --- | --- | --- | --- |
| M1 | Server connections: add a server by host or an existing \~/.ssh/config entry, using the keys and ssh-agent already set up; a key or password is optional and stored in Keychain only if given | P0 | A host from \~/.ssh/config connects with no extra setup; reconnects after sleep; host key checked on first use; no password stored in plain text |
| M2 | Overview: CPU, memory, disk, load, uptime and OS from standard Linux commands over SSH | P0 | Values refresh every 5 seconds; no software installed on the server |
| M3 | Needs-attention strip: disk over 85%, unhealthy container, reboot required, pending security updates | P0 | Each condition shows with a plain-language reason and a link to the fix |
| M4 | Terminal: tabbed SSH sessions with copy, paste and scrollback | P0 | Runs vim, htop and docker logs -f correctly; several tabs per server |
| M5 | Docker and Compose: list stacks and containers with status, CPU and memory; start, stop, restart; live logs; pull, recreate and rebuild a stack or a single container | P0 | Restart works in 2 taps; logs stream without freezing the UI; recreate and rebuild ask for confirmation; rebuild streams build output and reports failures |
| M6 | Bookmarks: name, Tailscale URL, public URL, grouped by server; open in default browser | P0 | Toggle chooses which URL opens; status dot and response time checked from the Mac |
| M7 | Updates view: pending apt packages with security ones flagged, and reboot-required notice | P0 | Lists packages in under 5 seconds; refresh on demand |
| M8 | Apply security updates in one action | P1 | Confirmation shows the package list; output shown live; failure is reported clearly |
| M9 | Docker image update check (new tag or digest available) | P1 | Badge on containers with updates; checked on demand, not in the background |
| M10 | Command palette (Cmd+K) to jump to a server, screen or action | P1 | Opens in under 200 ms; keyboard only |
| M11 | Tailscale device picker when adding a server | P1 | Lists devices from the local Tailscale client when installed; manual entry still works |
| M12 | Light and dark mode following the system | P1 | No unreadable text in either mode |

**MVP exit criteria:** the author runs the app for 2 weeks on all their own servers without opening a separate terminal for routine checks, restarts or updates, and no critical bug is open.

## Later phases

**Phase 2: Monitoring and alerts (Mac)**

- Background checks and local notifications: disk, container down, cert expiry, reboot required.
- 24-hour history for CPU, memory, disk and network, sampled while the app is open.
- TLS certificate and uptime checks for every bookmark.
- Saved snippets with variables, and a confirmation step for destructive commands.
- Gate to move on: alerts caught a real problem before the author noticed it.

**Phase 3: iPhone**

- Overview, Docker, Bookmarks and Alerts on iOS, sharing the same connection and parsing logic.
- Push alerts via an optional small agent or webhook relay, because a phone cannot poll while asleep. This is the first point where something may run on the server, and it stays optional.
- Home Screen widgets, Shortcuts actions and Face ID before destructive actions.
- Gate: the author handles a real incident from the phone alone.

**Phase 4: Android and Mac App Store**

- Android app with feature parity for the Phase 3 screens.
- Mac App Store build: sandboxing, key import flow, privacy policy, pricing and review notes.
- Backup status (restic, borg), security view (open ports, fail2ban, SSH logins), reverse-proxy route map.
- Gate: 5 outside testers use it for 4 weeks and at least 3 would pay.

**Phase 5: Self-hosted web version**

- A Docker image the user runs on their own tailnet: a Python (FastAPI) backend that holds the SSH connections and a React + TypeScript frontend that only renders. Nothing is installed on the managed servers; the web host is just another SSH client.
- A third core in Python, kept in step with Swift and Kotlin through `spec/` only (golden fixtures, shared scenarios, lab checks; docs/parity.md). The browser holds no server logic.
- Single user: argon2id admin password (from a file or a one-time setup token), optional TOTP, HttpOnly/Secure/SameSite=Strict session cookie, CSRF on mutations, login rate limit, optional forward-auth header from trusted proxies only. Every mutation uses the same confirm-the-exact-command policy. Non-root container; the docs say keep it on the tailnet.
- Stages W0 (spike: asyncssh transport, browser terminal latency) to W8 (end-to-end tests, image hardening, release), each approved before the next. Spike results: docs/web-spikes.md.
- Gate: the author uses it from a browser on a machine with no Rackoon app installed for 2 weeks.

**Parked ideas:** file browser, cron and user management, log search, multi-server dashboards, team sharing.

## Technical approach

Build the Mac app natively in SwiftUI first, keep server logic in a separate portable layer, and decide the phone stack after the MVP proves the product.

| Decision | Recommendation | Why |
| --- | --- | --- |
| Mac client | SwiftUI with SwiftTerm for the terminal | Best feel on Mac; mature terminal view; fits App Store rules |
| SSH | MVP: the system OpenSSH client, so \~/.ssh/config, ssh-agent and existing keys just work. App Store build later: an embedded Swift SSH library | Direct downloads are not sandboxed; the App Store sandbox blocks the system ssh and \~/.ssh |
| Server data | Run standard commands (df, free, docker ps --format json, apt list) and parse the output | Agentless; works on any Debian or Ubuntu host |
| Docker | Docker CLI over SSH; Compose via docker compose ps, up and build | Same results as the author's own commands |
| Secrets | Keys stay where they already are; optional passwords or passphrases in Keychain; optional Face ID gate on mobile | No plain-text secrets |
| Phones | Decide after the MVP: Swift on iOS (reuse code) and a separate Android app, or Flutter or React Native for both | A terminal view is the hard part on every stack, so test it first |
| Distribution | Notarized direct download for the MVP; App Store later | Sandbox limits on SSH keys and local access can wait |

**Distro scope:** Debian and Ubuntu for the MVP, since the author's servers use apt. Other package managers come later.

**Build method:** prototype with AI-assisted coding, starting with a thin vertical slice (connect, run one command, show the result) before any screen polish.

## Metrics, risks and open questions

**Success metrics**

| Stage | Metric | Target |
| --- | --- | --- |
| MVP | Routine tasks done without a separate terminal | All checks, restarts and updates for 2 weeks |
| MVP | Time from launch to a useful overview | Under 2 seconds on a known server |
| Phase 2 | Real problems caught by alerts | At least 1 before the author notices |
| Phase 4 | Outside testers who would pay | At least 3 of 5 |

**Risks**

- **SSH on iOS and Android:** background connections are limited, so push alerts need a small optional agent or relay. Mitigation: design alerts as a separate component.
- **Mac App Store sandbox:** reading keys and running a terminal may complicate review. Mitigation: ship notarized direct downloads first.
- **Terminal quality:** a poor terminal makes the whole app feel cheap. Mitigation: use a proven terminal view and test it in week 1.
- **Scope creep from ServerBuddy parity:** Mitigation: keep the parked list parked until the MVP exit criteria are met.
- **Destructive actions:** a mis-tap can restart or update production. Mitigation: confirmation sheets and a read-only mode.

**Open questions**

- Should Phase 3 be native Swift for iPhone, or one cross-platform codebase for both phones?
- Is a paid tier ($30 to $60 one-off, similar to ServerBuddy's $59) the right model, or a free app with a paid mobile add-on?
- Which distros beyond Debian and Ubuntu matter to testers?
- Is the name Rackoon available for trademark and App Store use?
