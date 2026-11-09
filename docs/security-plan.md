# Security screen: plan

Status: proposal, nothing built. The sidebar already has a Security entry (`Screen.security`) that shows an empty
page. This plan says what goes on it, in what order to build it, and what it deliberately does not do.

## What it is for

A self-hoster's quick answer to "is anything obviously wrong with how this server is set up, and is it running
software with known holes?" It is a short list of common hardening signals plus known vulnerabilities in installed
packages. It is not an audit, a compliance report or a replacement for a scanner such as Lynis, OpenSCAP, Trivy or
Grype.

## Ground rules (same as the rest of Rackoon)

- **Read-only.** Every check is a read. The screen never changes the server. Where something can be fixed, it shows
  advice and the command a person would run themselves, never a button that runs it (same reason Rackoon never offers to
  add the user to the docker group or edit sudoers).
- **Agentless, standard tools only.** One batched shell command, spec-first in `spec/commands.json` (`security`), with
  captured fixtures and expected parses, so the Swift, Kotlin and Python cores parse it identically.
- **No root by default.** Checks that need root say "Needs sudo to check" rather than guessing. When the user has unlocked
  sudo for the server (the Docker-through-sudo unlock, or the saved password), the deeper variant can run through the
  same `SudoTransport`, never silently.
- **Unknown is not a pass.** Each finding is `pass`, `info`, `warning`, `critical` or `unknown`; a check that could not
  run is `unknown`, shown greyed out with why.
- **No single score.** A "92/100" number suggests precision the checks do not have. Show counts by severity instead.

## Disclaimer (shown at the top of the screen, and in the Dashboard page later)

> These checks look for a small set of common hardening problems and known vulnerabilities in installed packages. They
> are not a complete security review and can be wrong: a setting may be overridden somewhere Rackoon does not read, a
> vulnerability may not apply to how a package is used, and new issues appear every day. Treat a clean result as "nothing
> obvious found", not "secure".

Each finding also links "How this is checked" to the exact command lines it read, so a person can verify it.

## Screen layout

1. Header: Security, last checked time, Check Now, the disclaimer (collapsible after first read, remembered per Mac).
2. Summary tiles: Critical, Warnings, Passed, Not checked (unknown); Vulnerabilities (with "fix available" count).
3. **Hardening** list, grouped (SSH, Firewall and exposure, Brute-force protection, Updates, Accounts, Docker, Kernel),
   each row: status icon, one-line finding, detail on expand (what was read, why it matters, suggested fix text).
4. **Exposed ports** table: every listening TCP/UDP port, the process or container, and where it listens (all
   interfaces / LAN / Tailscale only / localhost), with Docker-published ports flagged separately.
5. **Vulnerabilities** list (stage S3): CVE / advisory id, package, installed version, fixed version, severity, and
   whether the fix is already among the server's pending updates (links to the Updates screen).

## Core hardening checks (first set)

Kept deliberately small and common to Debian/Ubuntu. Each needs at most standard tools and world-readable files unless
noted.

| Group | Check | How (non-root first) | Severity if bad |
|---|---|---|---|
| SSH | Root can log in with a password (`PermitRootLogin yes`) | effective config via `sshd -T` with sudo; without sudo, parse `/etc/ssh/sshd_config` and `sshd_config.d/*.conf` with sshd's first-value-wins rule, marked "from config files" | critical |
| SSH | Password logins allowed (`PasswordAuthentication yes`, `KbdInteractiveAuthentication yes`) | as above | warning (critical if also reachable on all interfaces) |
| SSH | Empty passwords permitted (`PermitEmptyPasswords yes`) | as above | critical |
| SSH | `MaxAuthTries` above 6, `X11Forwarding yes` | as above | info |
| SSH | Tailscale SSH in use | `tailscale status --json` (`SSH` capability) | info (explains that sshd settings may not apply to tailnet logins) |
| Firewall | No firewall active | `/etc/ufw/ufw.conf` `ENABLED=`; `systemctl is-active ufw firewalld nftables`; rule counts need sudo (`ufw status`, `nft list ruleset`) | warning |
| Exposure | Services listening on all interfaces | `ss -H -tlnp` / `ss -H -ulnp` (process names only for the ssh user's own unless root, like the Services screen) | info per port; warning for databases, Redis, Docker API (2375/2376) on all interfaces |
| Exposure | Docker-published ports bypass ufw | Docker's `PublishedPorts` on `0.0.0.0`/`::` while ufw is the firewall (Docker's own iptables rules come first) | warning |
| Brute force | No fail2ban / CrowdSec / sshguard running | `systemctl is-active fail2ban crowdsec sshguard`; jail list needs sudo (`fail2ban-client status`) | info if SSH only reachable over Tailscale/LAN, warning if on all interfaces with passwords on |
| Updates | Security updates pending | existing `##security` count (the fixed, phased-aware one) | warning; critical if older than 14 days (from apt's list dates) |
| Updates | Automatic security updates off | `apt-config dump APT::Periodic::Unattended-Upgrade` and `dpkg -s unattended-upgrades` | info |
| Updates | Reboot needed for a new kernel | existing `/var/run/reboot-required` | warning |
| Accounts | A second UID 0 account | `/etc/passwd` | critical |
| Accounts | Accounts with empty passwords | `/etc/shadow`, needs sudo | critical / unknown |
| Accounts | Passwordless sudo (`NOPASSWD`) | `sudo -n -l` for the ssh user only (no root needed) | info |
| Docker | Docker API on TCP without TLS | `ss` on 2375, `dockerd` flags | critical |
| Docker | Containers that are privileged, use host network/PID, or mount `/var/run/docker.sock` | `docker inspect` of running containers (through sudo only if Docker is unlocked) | warning per container (info for well-known tools that need the socket: Portainer, Watchtower, Traefik, Homepage) |
| Kernel | ASLR off | `/proc/sys/kernel/randomize_va_space` != 2 | warning |
| Time | Clock not synchronised | `timedatectl show -p NTPSynchronized` | info (certificates and logs depend on it) |

Unraid gets a reduced set (no apt; Unraid's own update and plugin checks are a later item); other systems show
"Security checks support Debian and Ubuntu for now".

## Vulnerabilities (CVE) approach

Matching installed packages to advisories is the part most likely to be wrong, so it comes after the hardening checks
and is opt-in.

1. Read the installed **source** packages and versions on the server: `dpkg-query -W -f='${source:Package} ${source:Version}\n'`
   (Debian and Ubuntu advisories are keyed by source package), plus `/etc/os-release` for the release.
2. Look them up **from the Mac/phone/web backend, not the server**, in the OSV database (`https://api.osv.dev/v1/querybatch`),
   which carries Ubuntu (USN / Ubuntu CVE tracker) and Debian (DSA, DLA, Debian security tracker) records with fixed
   versions. Cache results per (release, package, version) for a day.
3. Show only advisories whose fixed version is newer than what is installed for that release, with OSV's severity
   when present. Mark "Fix available: install pending updates" when the Updates screen already has a newer version of that
   package; "No fix released yet" otherwise.
4. **Privacy**: this sends the server's package names and versions to a third party (OSV is run by Google). It is off
   until the user turns it on per server or globally, with that sentence next to the switch. Nothing else (hostnames,
   IPs) is sent.
5. Known limits, stated on screen: kernel CVEs depend on config and modules; backported fixes can make a version look
   vulnerable when it is not (OSV's distro data accounts for this, but not perfectly); packages outside apt (Docker
   images, binaries in /opt, pip/npm installs) are not covered.

Later, not in the first set: container images (needs an image scanner such as Trivy or Grype, which Rackoon would have
to run somewhere; possibly on the Mac against the image digest), and self-hosted apps by version (image tag to GitHub
security advisories is unreliable).

## Spec and parity work

- `spec/commands.json`: `security` (read-only, batched, sections `##sshd`, `##sshd_files`, `##ufw`, `##services`,
  `##listen`, `##passwd`, `##sudo_l`, `##apt_config`, `##sysctl`, `##time`, `##dpkg_sources`), ending in `|| true` like
  every polled script; `security_root` variant for when sudo is unlocked.
- `spec/security-rules.json`: the rule table above as data (id, group, severity, title, advice), like
  `attention-rules.json`, run by each core's `SharedScenarioTests`.
- Fixtures: Ubuntu 24.04 and 26.04 (sudo-rs), Debian 12, a hardened and a default install, Tailscale SSH, ufw with
  Docker; captured with `tools/capture-fixtures` and sanitised.
- `spec/features.json`: `security.checks`, `security.ports`, `security.cves`, each planned on mac, ios, android, web.
- Integration lab: add a check that the script runs as the unprivileged `rk` user and reports `PermitRootLogin` from
  the lab's sshd.

## Stages

- **S0** spec command, fixtures, rules, parsers in all three cores (Swift, Kotlin, Python).
- **S1** Mac Security screen: disclaimer, hardening list, "How this is checked".
- **S2** Exposed ports table, including Docker-published ports and the ufw bypass.
- **S3** CVE lookup through OSV, opt-in, cross-referenced with pending updates.
- **S4** Critical findings into Alerts (new category Security, off by default) and a Security page on the Dashboard.
- **S5** iOS, web and Android screens.

## Open questions for the user

1. OSV lookups send package lists to Google's OSV service. Acceptable as opt-in, or should CVE matching wait for an
   offline approach (downloading Ubuntu/Debian OVAL data to the Mac, which is large)?
2. Should deeper checks use the Docker sudo unlock automatically while it is active, or ask separately?
3. Should Security findings ever raise notifications, or stay on the Security screen and Alerts list only?
