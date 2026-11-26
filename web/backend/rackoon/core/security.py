"""The Security screen's checks (docs/security-plan.md): the `security` command's parser, the rules that turn a
reading into findings, and the exposed-ports list, ported from the Swift core's Security.swift.

One read-only command reads hardening facts as the ssh user; nothing here changes a server. A check that could not
be read is `unknown`, never a pass. Check titles and advice are data in spec/security-checks.json (no Python copy);
spec/scenarios/security-checks.json says which severity each fixture gives.
"""

from __future__ import annotations

import enum
import re
from dataclasses import dataclass, field
from typing import Any

from . import spec
from .jsonmodel import json

# --- The reading ---------------------------------------------------------------------------------------------------


class Scope(enum.Enum):
    ALL = "all"            # 0.0.0.0, :: or *: every interface
    PUBLIC = "public"      # a specific public address
    LAN = "lan"            # 10/8, 172.16/12, 192.168/16, 169.254/16, fc00::/7, fe80::/10
    TAILSCALE = "tailscale"  # 100.64.0.0/10, fd7a:115c:a1e0::/48
    LOOPBACK = "loopback"

    @property
    def rank(self) -> int:
        return list(Scope).index(self)

    @property
    def is_exposed(self) -> bool:
        """Reachable from other machines."""
        return self in (Scope.ALL, Scope.PUBLIC)


@dataclass
class OS:
    id: str
    like: str
    version: str

    @property
    def is_debian_like(self) -> bool:
        return self.id in ("debian", "ubuntu") or "debian" in self.like.split(" ")


class SSHDSource(enum.Enum):
    EFFECTIVE = "effective"  # sshd -T: what sshd really uses (needs root)
    FILES = "files"          # the config files, in sshd's first-value-wins order
    NONE = "none"


@dataclass
class SSHD:
    installed: bool
    active: bool
    source: SSHDSource
    settings: dict[str, str] = field(default_factory=dict)
    origin: dict[str, str] = field(default_factory=dict)
    unreadable: list[str] = field(default_factory=list)
    uncertain: list[str] = field(default_factory=list)


@dataclass
class Firewall:
    ufw_enabled: bool | None = None
    services: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class Listener:
    proto: str
    address: str
    port: int
    scope: Scope


@dataclass(frozen=True)
class Published:
    container: str
    address: str
    port: str
    proto: str
    scope: Scope


@dataclass
class Container:
    name: str
    privileged: bool
    host_network: bool
    host_pid: bool = field(metadata=json("hostPID"))
    docker_socket: bool
    host_root: bool


@dataclass
class DockerExposure:
    installed: bool = False
    problem: str | None = None
    published: list[Published] = field(default_factory=list)
    containers: list[Container] = field(default_factory=list)


@dataclass
class Unattended:
    installed: bool = False
    enabled: bool | None = None


@dataclass
class SecuritySnapshot:
    uid: int | None
    os: OS
    sshd: SSHD
    tailscale_ssh: bool | None = field(metadata=json("tailscaleSSH"))
    firewall: Firewall
    guards: dict[str, str]
    listeners: list[Listener]
    docker: DockerExposure
    unattended: Unattended
    root_accounts: list[str]
    empty_password_accounts: list[str] | None
    aslr: int | None
    ntp_synchronized: bool | None

    @property
    def is_root(self) -> bool:
        return self.uid == 0


# --- Parser --------------------------------------------------------------------------------------------------------

SSHD_KEYWORDS = frozenset({
    "port", "permitrootlogin", "passwordauthentication", "kbdinteractiveauthentication",
    "challengeresponseauthentication", "permitemptypasswords", "maxauthtries", "x11forwarding",
})

_INT = re.compile(r"[+-]?[0-9]+")


def _int(text: str | None) -> int | None:
    """Swift `Int(String)`: digits with an optional sign, nothing else."""
    if text is None or not _INT.fullmatch(text):
        return None
    return int(text)


def _trim(text: str) -> str:
    return text.strip(" \t")


def sections(output: str) -> dict[str, list[str]]:
    """`##name` sections; lines before the first marker and empty lines are dropped, a repeated header continues."""
    out: dict[str, list[str]] = {}
    current: str | None = None
    for raw in output.split("\n"):
        line = raw.strip("\r")
        if line.startswith("##"):
            current = line[2:]
            out.setdefault(current, [])
        elif current is not None and line:
            out[current].append(line)
    return out


def _key_values(lines: list[str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in lines:
        i = line.find("=")
        if i >= 0:
            out[_trim(line[:i])] = _trim(line[i + 1:])
    return out


def parse(output: str) -> SecuritySnapshot:
    secs = sections(output)

    def lines(name: str) -> list[str]:
        return secs.get(name, [])

    def first(name: str) -> str | None:
        got = lines(name)
        return got[0] if got else None

    os_kv = _key_values(lines("os"))
    sshd_state = _key_values(lines("sshd"))
    ntp = first("ntp")
    ntp_value = {"yes": True, "no": False}.get(_trim(ntp)) if ntp is not None else None
    uid = first("uid")
    aslr = first("aslr")
    snapshot = SecuritySnapshot(
        uid=_int(_trim(uid)) if uid is not None else None,
        os=OS(id=os_kv.get("id", ""), like=os_kv.get("like", ""), version=os_kv.get("version", "")),
        sshd=parse_sshd(installed=sshd_state.get("installed") == "yes",
                        active=(_int(sshd_state.get("active", "")) or 0) > 0,
                        effective=lines("sshd_effective"), files=lines("sshd_files")),
        tailscale_ssh=None,
        firewall=Firewall(),
        guards={},
        listeners=parse_listeners(lines("listen")),
        docker=parse_docker(lines("docker"), lines("docker_inspect")),
        unattended=Unattended(),
        root_accounts=[a for a in (_trim(x) for x in lines("uid0")) if a],
        empty_password_accounts=([a for a in (_trim(x) for x in lines("shadow_empty")[1:]) if a]
                                 if first("shadow_empty") == "checked" else None),
        aslr=_int(_trim(aslr)) if aslr is not None else None,
        ntp_synchronized=ntp_value,
    )

    run = first("tailscale_ssh")
    if run is not None and ":" in run:
        snapshot.tailscale_ssh = _trim(run[run.rfind(":") + 1:]) == "true"

    firewall = _key_values(lines("firewall"))
    enabled = firewall.pop("ENABLED", None)
    if enabled is not None:
        snapshot.firewall.ufw_enabled = enabled.lower() == "yes"
    snapshot.firewall.services = firewall
    snapshot.guards = _key_values(lines("guards"))

    unattended = lines("unattended")
    snapshot.unattended.installed = any(x.startswith("package=") and x.endswith(" installed") for x in unattended)
    prefix = "APT::Periodic::Unattended-Upgrade "
    periodic = next((x for x in unattended if x.startswith(prefix)), None)
    if periodic is not None:
        n = _int(periodic[len(prefix):].strip('"; '))
        snapshot.unattended.enabled = None if n is None else n > 0
    return snapshot


# sshd

@dataclass
class _ConfigFile:
    path: str
    readable: bool
    lines: list[str] = field(default_factory=list)


def keyword_line(line: str) -> tuple[str, str] | None:
    """`Keyword value` or `Keyword=value`, keyword lower-cased; comments and other keywords give None."""
    trimmed = _trim(line)
    if not trimmed or trimmed.startswith("#"):
        return None
    split = next((i for i, c in enumerate(trimmed) if c in " \t="), None)
    if split is None:
        return None
    key = trimmed[:split].lower()
    if key not in SSHD_KEYWORDS and key not in ("include", "match"):
        return None
    value = trimmed[split + 1:].strip(" \t=")
    return key, value if key in ("include", "match") else value.lower()


def glob_matches(pattern: str, path: str) -> bool:
    """Shell-style `*` and `?` against a whole path; `*` never crosses `/`."""
    p, s = pattern, path
    memo: dict[tuple[int, int], bool] = {}

    def match(i: int, j: int) -> bool:
        key = (i, j)
        if key in memo:
            return memo[key]
        if i == len(p):
            r = j == len(s)
        elif p[i] == "*":
            r = match(i + 1, j) or (j < len(s) and s[j] != "/" and match(i, j + 1))
        else:
            r = j < len(s) and (p[i] == "?" or p[i] == s[j]) and match(i + 1, j + 1)
        memo[key] = r
        return r

    return match(0, 0)


def parse_sshd(installed: bool, active: bool, effective: list[str], files: list[str]) -> SSHD:
    result = SSHD(installed=installed, active=active, source=SSHDSource.NONE)
    from_sshd_t = [kv for kv in (keyword_line(x) for x in effective) if kv is not None]
    if from_sshd_t:
        result.source = SSHDSource.EFFECTIVE
        for key, value in from_sshd_t:
            result.settings.setdefault(key, value)
        return result

    parsed: list[_ConfigFile] = []
    for line in files:
        if line.startswith("#file "):
            parsed.append(_ConfigFile(line[6:], True))
        elif line.startswith("#unreadable "):
            parsed.append(_ConfigFile(line[12:], False))
        elif parsed:
            parsed[-1].lines.append(line)
    result.unreadable = [f.path for f in parsed if not f.readable]
    if not parsed:
        return result
    result.source = SSHDSource.FILES

    # sshd reads the main file top to bottom, splicing each Include in where it appears; the first value of a keyword
    # wins, and lines after a Match apply only to some connections, so they are skipped (to the end of that file).
    uncertain: set[str] = set()
    seen = {parsed[0].path}

    def walk(file: _ConfigFile, depth: int) -> None:
        if depth >= 4:
            return
        if not file.readable:
            uncertain.update(SSHD_KEYWORDS - set(result.settings))
            return
        for line in file.lines:
            kv = keyword_line(line)
            if kv is None:
                continue
            key, value = kv
            if key == "match":
                return
            if key == "include":
                for pattern in (x for x in value.split(" ") if x):
                    full = pattern if pattern.startswith("/") else "/etc/ssh/" + pattern
                    for included in parsed[1:]:
                        if included.path not in seen and glob_matches(full, included.path):
                            seen.add(included.path)
                            walk(included, depth + 1)
                continue
            if key not in result.settings:
                result.settings[key] = value
                result.origin[key] = file.path

    walk(parsed[0], 0)
    result.uncertain = sorted(uncertain - {"port", "challengeresponseauthentication"})
    return result


# listeners

def host_port(text: str) -> tuple[str, str] | None:
    """Splits `addr:port`, `[v6]:port` or `*:port`; drops a `%interface` suffix and IPv4-mapped prefixes."""
    colon = text.rfind(":")
    if colon < 0:
        return None
    host, port = text[:colon], text[colon + 1:]
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]
    if "%" in host:
        host = host[:host.find("%")]
    if host.lower().startswith("::ffff:") and "." in host:
        host = host[7:]
    if not host:
        host = "::"  # docker's old ":::8080"
    return host, port


def scope_of(address: str) -> Scope:
    a = address.lower()
    if a in ("*", "0.0.0.0", "::"):
        return Scope.ALL
    if a == "::1" or a.startswith("127.") or a == "localhost":
        return Scope.LOOPBACK
    v4 = [n for n in (_int(x) for x in a.split(".") if x) if n is not None]
    if len(v4) == 4:
        x, y = v4[0], v4[1]
        if x == 100 and 64 <= y <= 127:
            return Scope.TAILSCALE
        if x == 10 or (x, y) == (192, 168) or (x == 172 and 16 <= y <= 31) or (x, y) == (169, 254):
            return Scope.LAN
        return Scope.PUBLIC
    if a.startswith("fd7a:115c:a1e0:"):
        return Scope.TAILSCALE
    if a.startswith(("fe8", "fe9", "fea", "feb", "fc", "fd")):
        return Scope.LAN
    return Scope.PUBLIC


def parse_listeners(lines: list[str]) -> list[Listener]:
    """`ss -H -tuln` lines: netid, state, queues, local address:port, peer."""
    out: list[Listener] = []
    for line in lines:
        cols = [c for c in re.split(r"[ \t]", line) if c]
        if len(cols) < 5:
            continue
        hp = host_port(cols[4])
        if hp is None:
            continue
        number = _int(hp[1])
        if number is None:
            continue
        listener = Listener(cols[0], hp[0], number, scope_of(hp[0]))
        if listener not in out:
            out.append(listener)
    return sorted(out, key=lambda x: (x.port, x.proto, x.scope.rank, x.address))


# docker

def parse_docker(lines: list[str], inspect: list[str]) -> DockerExposure:
    result = DockerExposure()
    if not lines or lines[0] != "installed=yes":
        return result
    result.installed = True
    problem: list[str] = []
    for line in lines[1:]:
        if "\t" not in line:
            problem.append(line)
            continue
        name, rest = line.split("\t", 1)
        for entry in rest.split(","):
            item = _trim(entry)
            if "->" not in item:
                continue  # exposed but not published
            hp = host_port(item[:item.find("->")])
            if hp is None:
                continue
            proto = item.split("/")[-1] if item else "tcp"
            published = Published(name, hp[0], hp[1], proto, scope_of(hp[0]))
            if published not in result.published:
                result.published.append(published)
    if problem:
        result.problem = " ".join(problem)
    for line in inspect:
        f = line.split("|")
        if len(f) < 5:
            continue
        mounts = [m for m in f[4].split(";") if m]
        result.containers.append(Container(
            name=f[0][1:] if f[0].startswith("/") else f[0],
            privileged=f[1] == "true", host_network=f[2] == "host", host_pid=f[3] == "host",
            docker_socket=any(m in ("/var/run/docker.sock", "/run/docker.sock") for m in mounts),
            host_root="/" in mounts))
    result.containers.sort(key=lambda c: c.name)
    return result


# --- Checks and findings ---------------------------------------------------------------------------------------------

GROUP_TITLES = {
    "ssh": "SSH", "exposure": "Firewall and exposure", "brute_force": "Brute-force protection", "updates": "Updates",
    "accounts": "Accounts", "docker": "Docker", "system": "Kernel and time",
}


@dataclass(frozen=True)
class SecurityCheck:
    id: str
    group: str
    title: str
    why: str
    advice: str


def checks() -> list[SecurityCheck]:
    """The catalog, from spec/security-checks.json."""
    return [SecurityCheck(c["id"], c["group"], c["title"], c["why"], c["advice"])
            for c in spec.load_json("security-checks.json")["checks"]]


class Severity(enum.Enum):
    CRITICAL = "critical"
    WARNING = "warning"
    INFO = "info"
    UNKNOWN = "unknown"
    PASS = "pass"

    @property
    def rank(self) -> int:
        return list(Severity).index(self)


@dataclass
class SecurityFinding:
    id: str      # the check's id, plus `:<subject>` for one finding per item (a port, a container)
    check: str
    severity: Severity
    summary: str
    evidence: str | None = None


@dataclass(frozen=True)
class SecurityContext:
    """What the Overview poll already knows, so the Security command does not run apt again."""
    pending_security_updates: int | None = None
    reboot_required: bool | None = None


SENSITIVE_PORTS = {
    3306: "MySQL/MariaDB", 5432: "PostgreSQL", 6379: "Redis", 27017: "MongoDB", 9200: "Elasticsearch",
    11211: "Memcached", 5984: "CouchDB", 8086: "InfluxDB",
}

SOCKET_TOOLS = ["portainer", "watchtower", "traefik", "homepage", "dozzle", "dockge", "diun", "autoheal", "beszel",
                "uptime-kuma", "socket-proxy", "cadvisor", "netdata"]

# sshd's built-in defaults for the keywords Rackoon checks (OpenSSH 8.7 and later).
SSHD_DEFAULTS = {
    "port": "22", "permitrootlogin": "prohibit-password", "passwordauthentication": "yes",
    "kbdinteractiveauthentication": "yes", "permitemptypasswords": "no", "maxauthtries": "6", "x11forwarding": "no",
}


def _plural(n: int, one: str = "", many: str = "s") -> str:
    return one if n == 1 else many


def _port_key(text: str) -> tuple[int, str]:
    digits = re.match(r"[0-9]*", text)
    return (int(digits.group()) if digits and digits.group() else 0, text)


def evaluate(s: SecuritySnapshot, context: SecurityContext | None = None) -> list[SecurityFinding]:
    context = context or SecurityContext()
    out: list[SecurityFinding] = []

    def add(check: str, severity: Severity, summary: str, evidence: str | None = None,
            subject: str | None = None) -> None:
        out.append(SecurityFinding(f"{check}:{subject}" if subject is not None else check, check, severity, summary,
                                   evidence))

    # SSH
    sshd = s.sshd
    ssh_on = sshd.installed and sshd.active
    passwords_on: bool | None
    if not sshd.installed:
        add("ssh.server", Severity.INFO, "No OpenSSH server is installed.")
        passwords_on = False
    elif sshd.source == SSHDSource.NONE:
        add("ssh.server", Severity.UNKNOWN, "Rackoon could not read sshd's settings.",
            evidence=("Unreadable: " + ", ".join(sshd.unreadable)) if sshd.unreadable else None)
        passwords_on = None
    else:
        add("ssh.server", Severity.PASS if ssh_on else Severity.INFO,
            "OpenSSH is running." if ssh_on else "OpenSSH is installed but not running.",
            evidence="From sshd -T (the settings in use)." if sshd.source == SSHDSource.EFFECTIVE
            else "From the config files (sshd -T needs root).")

        def setting(key: str) -> tuple[str, bool, bool, str]:
            certain = key not in sshd.uncertain
            if key in sshd.settings:
                value = sshd.settings[key]
                origin = sshd.origin.get(key)
                return value, False, certain, f"{key} {value}" + (f" in {origin}" if origin is not None else "")
            value = SSHD_DEFAULTS.get(key, "")
            return value, True, certain, f"{key} not set, so sshd uses its default: {value}"

        def unsure(e: str) -> str:
            return e + f". A file Rackoon cannot read ({', '.join(sshd.unreadable)}) may set it first."

        root_value, _, root_certain, root_evidence = setting("permitrootlogin")
        if not root_certain:
            add("ssh.root_login", Severity.UNKNOWN, "Root login could not be read for certain.",
                evidence=unsure(root_evidence))
        elif root_value == "yes":
            add("ssh.root_login", Severity.CRITICAL, "Root can log in with a password.", evidence=root_evidence)
        else:
            add("ssh.root_login", Severity.PASS,
                "Root cannot log in over SSH." if root_value == "no" else "Root can log in with a key only.",
                evidence=root_evidence)

        pw_value, _, pw_certain, pw_evidence = setting("passwordauthentication")
        kb_value, kb_default, kb_certain, kb_evidence = setting("kbdinteractiveauthentication")
        challenge = sshd.settings.get("challengeresponseauthentication")
        # KbdInteractiveAuthentication's old name, ChallengeResponseAuthentication, counts when the new one is not set.
        if kb_default:
            keyboard_on = challenge == "yes" if challenge is not None else kb_value == "yes"
        else:
            keyboard_on = kb_value == "yes"
        password_evidence = f"{pw_evidence}; {kb_evidence}"
        pw_sure = pw_certain and pw_value == "yes"
        kb_sure = kb_certain and keyboard_on
        if pw_sure or kb_sure:
            which = " and ".join(x for x in ("passwords" if pw_sure else None,
                                             "keyboard-interactive logins" if kb_sure else None) if x)
            add("ssh.password_auth", Severity.WARNING, f"SSH accepts {which}.", evidence=password_evidence)
            passwords_on = True
        elif not pw_certain or not kb_certain:
            add("ssh.password_auth", Severity.UNKNOWN, "Password logins could not be read for certain.",
                evidence=unsure(password_evidence))
            passwords_on = None
        else:
            add("ssh.password_auth", Severity.PASS, "SSH accepts keys only.", evidence=password_evidence)
            passwords_on = False

        empty_value, _, empty_certain, empty_evidence = setting("permitemptypasswords")
        if not empty_certain:
            add("ssh.empty_passwords", Severity.UNKNOWN, "Empty-password logins could not be read for certain.",
                evidence=unsure(empty_evidence))
        elif empty_value == "yes":
            add("ssh.empty_passwords", Severity.CRITICAL, "Accounts with an empty password can log in.",
                evidence=empty_evidence)
        else:
            add("ssh.empty_passwords", Severity.PASS, "Empty passwords are refused.", evidence=empty_evidence)

        tries_value, _, _, tries_evidence = setting("maxauthtries")
        tries = _int(tries_value)
        if tries is not None and tries > 6:
            add("ssh.max_auth_tries", Severity.INFO, f"Each connection may try {tries} logins.",
                evidence=tries_evidence)
        else:
            add("ssh.max_auth_tries", Severity.PASS, f"At most {tries_value} login attempts per connection.",
                evidence=tries_evidence)

        x11_value, _, _, x11_evidence = setting("x11forwarding")
        add("ssh.x11_forwarding", Severity.INFO if x11_value == "yes" else Severity.PASS,
            "X11 forwarding is on." if x11_value == "yes" else "X11 forwarding is off.", evidence=x11_evidence)
    if s.tailscale_ssh is True:
        add("ssh.tailscale", Severity.INFO, "Tailscale SSH is on: tailnet logins follow your tailnet's SSH policy.")

    # Firewall and exposure
    def active(unit: str) -> bool:
        return s.firewall.services.get(unit) == "active"

    ufw_on = active("ufw") and s.firewall.ufw_enabled is not False
    if ufw_on:
        add("exposure.firewall", Severity.PASS, "ufw is on.")
    elif active("firewalld"):
        add("exposure.firewall", Severity.PASS, "firewalld is on.")
    elif active("nftables"):
        add("exposure.firewall", Severity.INFO, "nftables rules are loaded, but reading them needs root.",
            evidence="Debian's default nftables.conf allows everything; check it with sudo nft list ruleset.")
    elif all(not v for v in s.firewall.services.values()):
        add("exposure.firewall", Severity.UNKNOWN, "Rackoon could not ask systemd about firewalls.")
    else:
        add("exposure.firewall", Severity.WARNING, "No firewall is running.",
            evidence=", ".join(f"{k}: {v}" for k, v in sorted(s.firewall.services.items())))

    exposed = [x for x in s.listeners if x.scope.is_exposed]
    exposed_ports = sorted({f"{x.port}/{x.proto}" for x in exposed}, key=_port_key)
    if not s.listeners:
        add("exposure.listening", Severity.UNKNOWN, "Rackoon could not list listening sockets.")
    elif not exposed_ports:
        add("exposure.listening", Severity.PASS, "Nothing listens on every interface.")
    else:
        n = len(exposed_ports)
        add("exposure.listening", Severity.INFO, f"{n} port{_plural(n)} listen on every interface.",
            evidence=", ".join(exposed_ports))
    sensitive_seen: set[int] = set()
    for x in exposed:
        name = SENSITIVE_PORTS.get(x.port)
        if x.proto != "tcp" or name is None or x.port in sensitive_seen:
            continue
        sensitive_seen.add(x.port)
        add("exposure.sensitive_port", Severity.WARNING, f"{name} (port {x.port}) listens on every interface.",
            evidence=f"{x.proto} {x.address}:{x.port}", subject=str(x.port))

    docker_exposed = [p for p in s.docker.published if p.scope.is_exposed]
    if ufw_on and docker_exposed:
        items = sorted({f"{p.port}/{p.proto} ({p.container})" for p in docker_exposed})
        add("exposure.docker_bypass", Severity.WARNING,
            f"Docker publishes {len(items)} port{_plural(len(items))} on every interface, past ufw.",
            evidence=", ".join(items))

    # Brute-force protection
    guarding = [g for g in ("fail2ban", "crowdsec", "sshguard") if s.guards.get(g) == "active"]
    if guarding:
        add("brute_force.guard", Severity.PASS, f"{' and '.join(guarding)} is running.")
    elif not ssh_on:
        add("brute_force.guard", Severity.PASS, "No SSH server to protect.")
    elif all(not v for v in s.guards.values()):
        add("brute_force.guard", Severity.UNKNOWN,
            "Rackoon could not ask systemd about fail2ban, CrowdSec or sshguard.")
    elif passwords_on is False:
        add("brute_force.guard", Severity.INFO,
            "No fail2ban, CrowdSec or sshguard (less important with password logins off).")
    else:
        add("brute_force.guard", Severity.WARNING, "No fail2ban, CrowdSec or sshguard, and SSH may accept passwords.")

    # Updates
    if s.os.is_debian_like:
        pending = context.pending_security_updates
        if pending is not None and pending > 0:
            add("updates.security_pending", Severity.WARNING,
                f"{pending} security update{_plural(pending, ' is', 's are')} waiting to be installed.")
        elif pending is not None:
            add("updates.security_pending", Severity.PASS, "No security updates waiting.")
        else:
            add("updates.security_pending", Severity.UNKNOWN, "The update count is not known yet.")
        if s.unattended.installed and s.unattended.enabled is True:
            add("updates.automatic", Severity.PASS, "unattended-upgrades installs security updates automatically.")
        elif s.unattended.installed:
            state = "0" if s.unattended.enabled is False else "not set"
            add("updates.automatic", Severity.INFO, "unattended-upgrades is installed but not switched on.",
                evidence=f"APT::Periodic::Unattended-Upgrade is {state}.")
        else:
            add("updates.automatic", Severity.INFO, "Security updates are not installed automatically.",
                evidence="The unattended-upgrades package is not installed.")
    if context.reboot_required is True:
        add("updates.reboot", Severity.WARNING, "The server asks for a reboot to finish updates.")
    elif context.reboot_required is False:
        add("updates.reboot", Severity.PASS, "No reboot pending.")

    # Accounts
    extra = [a for a in s.root_accounts if a != "root"]
    if not s.root_accounts:
        add("accounts.extra_root", Severity.UNKNOWN, "Rackoon could not read /etc/passwd.")
    elif not extra:
        add("accounts.extra_root", Severity.PASS, "Only root has user id 0.")
    else:
        add("accounts.extra_root", Severity.CRITICAL, f"Other accounts have user id 0: {', '.join(extra)}.",
            evidence="UID 0 in /etc/passwd: " + ", ".join(s.root_accounts))

    if s.empty_password_accounts is None:
        add("accounts.empty_password", Severity.UNKNOWN, "Reading /etc/shadow needs root: use Check Deeper with sudo.")
    elif not s.empty_password_accounts:
        add("accounts.empty_password", Severity.PASS, "No account has an empty password.")
    else:
        names = ", ".join(s.empty_password_accounts)
        add("accounts.empty_password", Severity.CRITICAL, f"Accounts with an empty password: {names}.",
            evidence=f"Empty password field in /etc/shadow: {names}")

    # Docker
    def api(port: int) -> Listener | None:
        return next((x for x in s.listeners if x.port == port and x.proto == "tcp" and x.scope != Scope.LOOPBACK),
                    None)

    plain, tls = api(2375), api(2376)
    if plain is not None:
        add("docker.tcp_api", Severity.CRITICAL, "Docker's API answers without TLS on port 2375.",
            evidence=f"tcp {plain.address}:2375")
    elif tls is not None:
        add("docker.tcp_api", Severity.INFO,
            "Docker's API listens on port 2376 (TLS); make sure it requires client certificates.",
            evidence=f"tcp {tls.address}:2376")
    if s.docker.installed:
        if s.docker.problem is not None:
            add("docker.unchecked", Severity.UNKNOWN, "Docker would not list containers for this user.",
                evidence=s.docker.problem)
        for c in s.docker.containers:
            reasons = [r for r, on in (("privileged", c.privileged), ("host network", c.host_network),
                                       ("host PID namespace", c.host_pid), ("Docker socket mounted", c.docker_socket),
                                       ("host / mounted", c.host_root)) if on]
            if not reasons:
                continue
            expected = c.docker_socket and len(reasons) == 1 and any(t in c.name.lower() for t in SOCKET_TOOLS)
            add("docker.container", Severity.INFO if expected else Severity.WARNING,
                f"{c.name}: {', '.join(reasons)}{' (expected for this tool)' if expected else ''}.", subject=c.name)

    # Kernel and time
    if s.aslr == 2:
        add("system.aslr", Severity.PASS, "Full address space randomisation.")
    elif s.aslr is not None:
        add("system.aslr", Severity.WARNING,
            f"Address space randomisation is {'off' if s.aslr == 0 else 'partial'} ({s.aslr}).",
            evidence=f"/proc/sys/kernel/randomize_va_space = {s.aslr}")
    else:
        add("system.aslr", Severity.UNKNOWN, "Rackoon could not read the ASLR setting.")
    if s.ntp_synchronized is True:
        add("system.time_sync", Severity.PASS, "The clock is synchronised.")
    elif s.ntp_synchronized is False:
        add("system.time_sync", Severity.INFO, "The clock is not synchronised.",
            evidence="timedatectl: NTPSynchronized=no")
    else:
        add("system.time_sync", Severity.UNKNOWN, "Rackoon could not ask timedatectl.")
    return out


def counts(findings: list[SecurityFinding]) -> dict[Severity, int]:
    out: dict[Severity, int] = {}
    for f in findings:
        out[f.severity] = out.get(f.severity, 0) + 1
    return out


# --- Exposure (the Security screen's ports list) ---------------------------------------------------------------------

KNOWN_PORTS: dict[int, str] = {
    22: "SSH", 53: "DNS", 80: "HTTP", 443: "HTTPS", 25: "SMTP", 111: "rpcbind", 139: "SMB", 445: "SMB",
    631: "Printing (CUPS)", 2049: "NFS", 2375: "Docker API", 2376: "Docker API (TLS)", 3389: "Remote Desktop",
    5900: "VNC", 8080: "HTTP (alt)", 8443: "HTTPS (alt)", 41641: "Tailscale", 51820: "WireGuard", 32400: "Plex",
    **SENSITIVE_PORTS,
}


@dataclass
class ExposedPort:
    """One port as the screen shows it: IPv4 and IPv6 sockets merged, the widest scope, who published it, and why it is
    worth a look."""
    port: int
    proto: str
    scope: Scope
    addresses: list[str] = field(default_factory=list)
    containers: list[str] = field(default_factory=list)
    service: str | None = None
    flags: list[str] = field(default_factory=list)

    @property
    def id(self) -> str:
        return f"{self.port}/{self.proto}"

    @property
    def is_exposed(self) -> bool:
        return self.scope.is_exposed


def exposed_ports(s: SecuritySnapshot, ufw_on: bool) -> list[ExposedPort]:
    merged: dict[str, ExposedPort] = {}
    for x in s.listeners:
        key = f"{x.port}/{x.proto}"
        row = merged.get(key) or ExposedPort(x.port, x.proto, x.scope, service=KNOWN_PORTS.get(x.port))
        if x.scope.rank < row.scope.rank:
            row.scope = x.scope
        if x.address not in row.addresses:
            row.addresses.append(x.address)
        merged[key] = row
    for p in s.docker.published:
        port = _int(p.port)
        found = merged.get(f"{port}/{p.proto}") if port is not None else None
        if found is None:
            continue
        if p.container not in found.containers:
            found.containers.append(p.container)
        if ufw_on and p.scope.is_exposed and "past ufw" not in found.flags:
            found.flags.append("past ufw")
    for row in merged.values():
        if not row.is_exposed:
            continue
        if row.proto == "tcp" and row.port in SENSITIVE_PORTS:
            row.flags.insert(0, "database or cache")
        if row.proto == "tcp" and row.port == 2375:
            row.flags.insert(0, "no TLS")
    return sorted(merged.values(), key=lambda r: (r.scope.rank, r.port, r.proto))


def ufw_on(s: SecuritySnapshot) -> bool:
    return s.firewall.services.get("ufw") == "active" and s.firewall.ufw_enabled is not False


def command() -> str:
    return spec.script("security")


def to_screen_json(s: SecuritySnapshot, findings: list[SecurityFinding]) -> dict[str, Any]:
    """What the web UI renders: findings with their check's title/advice, and the ports list."""
    catalog = {c.id: c for c in checks()}
    rows = []
    for f in findings:
        c = catalog.get(f.check)
        rows.append({"id": f.id, "check": f.check, "severity": f.severity.value, "summary": f.summary,
                     "evidence": f.evidence, "group": c.group if c else None,
                     "groupTitle": GROUP_TITLES.get(c.group, "") if c else "", "title": c.title if c else f.check,
                     "why": c.why if c else "", "advice": c.advice if c else ""})
    ports = [{"id": r.id, "port": r.port, "proto": r.proto, "scope": r.scope.value, "addresses": r.addresses,
              "containers": r.containers, "service": r.service, "flags": r.flags}
             for r in exposed_ports(s, ufw_on(s))]
    return {"findings": rows, "ports": ports}
