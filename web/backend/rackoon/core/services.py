"""Services outside Docker: the `services` command's parser and discovery (spec/fixtures/services), ported from the
Swift core's Services.swift.

One read-only command lists every loaded systemd service (the system's and the ssh user's `--user` ones), listening
TCP sockets and, per listening process, its command line and cgroup. The cgroup ties a port to its unit and tells a
process started by hand (a login session) from one a unit runs. Containers are left to the Docker screen.

Which names are known products, OS plumbing or interpreters is data shared by every core: spec/service-catalog.json,
read at runtime (`catalog()`).
"""

from __future__ import annotations

import enum
from dataclasses import dataclass, field
from functools import cache

from . import spec
from .text import split_sections, to_float, to_int, trim_blanks

# --- The raw reading ----------------------------------------------------------------------------------------------


@dataclass
class SystemdUnit:
    name: str
    description: str = ""
    load_state: str = ""
    active_state: str = ""
    sub_state: str = ""
    result: str = ""
    unit_file_state: str = ""
    fragment_path: str = ""
    type: str = ""
    main_pid: int | None = None
    active_enter_monotonic: int | None = None
    memory_bytes: int | None = None
    restarts: int | None = None


@dataclass(frozen=True)
class SocketOwner:
    name: str
    pid: int


@dataclass(frozen=True)
class ListeningSocket:
    address: str
    port: int
    processes: list[SocketOwner]


@dataclass(frozen=True)
class ListeningProcess:
    pid: int
    command_line: str
    cgroup: str


@dataclass
class ServicesScan:
    uptime: float | None = None
    is_root: bool = False
    system: list[SystemdUnit] = field(default_factory=list)
    user: list[SystemdUnit] = field(default_factory=list)
    sockets: list[ListeningSocket] = field(default_factory=list)
    processes: list[ListeningProcess] = field(default_factory=list)


# --- What the app shows -------------------------------------------------------------------------------------------

NON_WEB_PORTS = frozenset({21, 22, 23, 25, 53, 110, 111, 139, 143, 389, 445, 465, 587, 636, 853, 993, 995, 1194, 1883,
                           2049, 3306, 3478, 5353, 5432, 6379, 8883, 11211, 27017, 41641, 45876, 51820})


@dataclass(frozen=True)
class ServicePort:
    address: str
    """As ss reports it, without brackets or interface: `0.0.0.0`, `::`, `*`, `127.0.0.1`."""
    port: int

    @property
    def is_loopback(self) -> bool:
        return self.address.startswith("127.") or self.address in ("::1", "localhost")

    @property
    def is_wildcard(self) -> bool:
        return self.address in ("0.0.0.0", "::", "*", "")

    @property
    def is_likely_web(self) -> bool:
        return self.port not in NON_WEB_PORTS

    def link_host(self, preferred: str | None) -> str | None:
        if self.is_loopback:
            return None
        if self.is_wildcard:
            return preferred
        return f"[{self.address}]" if ":" in self.address else self.address

    @property
    def reach(self) -> int:
        """Everywhere, then one address, then loopback (for keeping one entry per port)."""
        return 2 if self.is_wildcard else (0 if self.is_loopback else 1)


class Kind(enum.Enum):
    SYSTEM = "system"
    USER = "user"
    PROCESS = "process"


class Status(enum.Enum):
    RUNNING = "running"
    STARTING = "starting"
    RESTARTING = "restarting"
    STOPPING = "stopping"
    STOPPED = "stopped"
    FAILED = "failed"


@dataclass(frozen=True)
class DiscoveredService:
    id: str
    """`system/<unit>`, `user/<unit>` or `process/<name>`: stable across scans."""
    kind: Kind
    unit: str | None
    name: str
    detail: str
    product: str | None
    status: Status
    sub_state: str
    result: str | None
    enabled_at_boot: bool | None
    active_seconds: float | None
    memory_bytes: int | None
    restarts: int
    ports: list[ServicePort]
    path: str | None
    is_plumbing: bool
    visible_by_default: bool

    @property
    def is_problem(self) -> bool:
        return self.status in (Status.FAILED, Status.RESTARTING)

    def matches(self, query: str) -> bool:
        words = [w for w in query.lower().split(" ") if w]
        if not words:
            return True
        haystack = " ".join([self.name, self.unit or "", self.product or "", self.detail, self.path or ""]
                            + [str(p.port) for p in self.ports]).lower()
        return all(w in haystack for w in words)


@dataclass(frozen=True)
class ServicesSnapshot:
    services: list[DiscoveredService]
    is_root: bool
    has_systemd: bool


# --- Known products and OS plumbing -------------------------------------------------------------------------------


@dataclass(frozen=True)
class ServiceProduct:
    id: str
    name: str
    icon: str | None
    names: tuple[str, ...]
    prefixes: tuple[str, ...] = ()
    hidden_by_default: bool = False


@dataclass(frozen=True)
class ServiceCatalog:
    """spec/service-catalog.json: known products, OS plumbing and the process names discovery treats specially."""
    products: tuple[ServiceProduct, ...]
    plumbing: frozenset[str]
    plumbing_prefixes: tuple[str, ...]
    plumbing_processes: frozenset[str]
    container_helpers: tuple[str, ...]
    interpreters: tuple[str, ...]
    helpers: frozenset[str]


@cache
def catalog() -> ServiceCatalog:
    d = spec.load_json("service-catalog.json")
    try:
        return ServiceCatalog(
            products=tuple(ServiceProduct(p["id"], p["name"], p.get("icon"), tuple(p["names"]),
                                          tuple(p.get("prefixes", ())), bool(p.get("hiddenByDefault", False)))
                           for p in d["products"]),
            plumbing=frozenset(d["plumbing"]),
            plumbing_prefixes=tuple(d["plumbingPrefixes"]),
            plumbing_processes=frozenset(d["plumbingProcesses"]),
            container_helpers=tuple(d["containerHelpers"]),
            interpreters=tuple(d["interpreters"]),
            helpers=frozenset(d["helpers"]),
        )
    except (KeyError, TypeError) as e:
        raise spec.SpecError(f"spec/service-catalog.json is malformed: {e!r}") from None


def is_container_helper(name: str) -> bool:
    n = name.lower()
    return any(n.startswith(h) for h in catalog().container_helpers)


def base_name(name: str) -> str:
    """Lower-case, no `.service`, no `@instance`, `_` as `-`."""
    n = name.lower()
    n = n.removesuffix(".service")
    n = n.split("@", 1)[0]
    return n.replace("_", "-")


def product_for(name: str) -> ServiceProduct | None:
    base = base_name(name)
    return next((p for p in catalog().products if base in p.names or any(base.startswith(x) for x in p.prefixes)),
                None)


def is_plumbing(name: str) -> bool:
    base = base_name(name)
    c = catalog()
    return base in c.plumbing or any(base.startswith(p) for p in c.plumbing_prefixes)


# --- Parsing ------------------------------------------------------------------------------------------------------


def command() -> str:
    return spec.script("services")


def _positive(value: int | None) -> int | None:
    return value if value is not None and value > 0 else None


def parse_units(lines: list[str]) -> list[SystemdUnit]:
    """`systemctl show` prints one `Key=value` block per unit, in its own key order; a block starts at `Id=`."""
    out: list[SystemdUnit] = []
    current: SystemdUnit | None = None
    for line in lines:
        eq = line.find("=")
        if eq < 0:
            continue
        key, value = line[:eq], line[eq + 1:]
        if key == "Id":
            if current is not None:
                out.append(current)
            current = SystemdUnit(value)
            continue
        if current is None:
            continue
        match key:
            case "Description": current.description = value
            case "LoadState": current.load_state = value
            case "ActiveState": current.active_state = value
            case "SubState": current.sub_state = value
            case "Result": current.result = value
            case "UnitFileState": current.unit_file_state = value
            case "FragmentPath": current.fragment_path = value
            case "Type": current.type = value
            case "MainPID": current.main_pid = _positive(to_int(value))
            case "ActiveEnterTimestampMonotonic": current.active_enter_monotonic = _positive(to_int(value, (0, 2**64 - 1)))
            case "NRestarts": current.restarts = to_int(value)
            case "MemoryCurrent":
                # "[not set]" without memory accounting; UINT64_MAX ("infinity") on some versions.
                n = to_int(value, (0, 2**64 - 1))
                if n is not None and n < 2**63 - 1:
                    current.memory_bytes = n
            case _:
                pass
    if current is not None:
        out.append(current)
    return out


def parse_socket(line: str) -> ListeningSocket | None:
    """`LISTEN 0 4096 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=1001,fd=6),...)`. The local address is the first
    `address:port` column; IPv6 comes in brackets and an address may carry `%interface`."""
    fields = [f for f in line.replace("\t", " ").split(" ") if f]
    local = next((f for f in fields if ":" in f and not f.startswith("users:")), None)
    if local is None:
        return None
    colon = local.rfind(":")
    port = to_int(local[colon + 1:])
    if port is None:
        return None
    address = local[:colon]
    if address.startswith("[") and address.endswith("]"):
        address = address[1:-1]
    address = address.split("%", 1)[0]
    owners: list[SocketOwner] = []
    users = line.find("users:(")
    if users >= 0:
        for part in line[users + len("users:("):].split('("')[1:]:
            end_name = part.find('"')
            if end_name < 0:
                continue
            pid_at = part.find("pid=")
            if pid_at < 0:
                continue
            digits = ""
            for c in part[pid_at + 4:]:
                if not c.isdigit():
                    break
                digits += c
            pid = to_int(digits)
            if pid is not None:
                owners.append(SocketOwner(part[:end_name], pid))
    return ListeningSocket(address, port, owners)


def parse_process(line: str) -> ListeningProcess | None:
    """`<pid>\\t<command line>\\t<cgroup>`."""
    parts = line.split("\t")
    if len(parts) < 3:
        return None
    pid = to_int(trim_blanks(parts[0]))
    if pid is None:
        return None
    return ListeningProcess(pid, trim_blanks(parts[1]), trim_blanks(parts[2]))


def scan(output: str) -> ServicesScan:
    sections = split_sections(output)
    result = ServicesScan()
    uptime = sections.get("uptime")
    result.uptime = to_float(trim_blanks(uptime[0])) if uptime else None
    uid = sections.get("uid")
    result.is_root = uid is not None and bool(uid) and trim_blanks(uid[0]) == "0"
    result.system = parse_units(sections.get("system", []))
    result.user = parse_units(sections.get("user", []))
    result.sockets = [s for s in (parse_socket(x) for x in sections.get("listen", [])) if s is not None]
    result.processes = [p for p in (parse_process(x) for x in sections.get("procs", [])) if p is not None]
    return result


def parse(output: str) -> ServicesSnapshot:
    return discover(scan(output))


# --- From a reading to services -----------------------------------------------------------------------------------


def home_of(cgroup: str) -> tuple[str, str]:
    """("container", ""), ("system", unit), ("user", unit) or ("loose", cgroup)."""
    lower = cgroup.lower()
    if any(w in lower for w in ("docker", "containerd", "libpod", "kubepods", "/lxc")):
        return ("container", "")
    parts = [p for p in cgroup.split("/") if p]
    unit = next((p for p in reversed(parts) if p.endswith(".service")), None)
    if unit is not None:
        # user@1000.service is the user's systemd itself; a unit below it is one of theirs.
        if unit.startswith("user@"):
            return ("loose", cgroup)
        under_user = any(p.startswith("user@") and p.endswith(".service") for p in parts)
        return ("user", unit) if under_user else ("system", unit)
    return ("loose", cgroup)


_SCRIPT_EXTENSIONS = (".js", ".mjs", ".cjs", ".ts", ".py", ".rb", ".php", ".pl", ".jar", ".sh")


def _last_path_component(path: str) -> str:
    """NSString.lastPathComponent: trailing slashes ignored, "/" stays "/"."""
    trimmed = path.rstrip("/")
    if not trimmed:
        return "/" if path else ""
    return trimmed.rsplit("/", 1)[-1]


def process_name(comm: str, command_line: str) -> str:
    """A process's name: its own, or for an interpreter the script it runs (`node .../paperclipai` -> paperclipai)."""
    name = comm.lower().replace("-mainthread", "", 1)
    is_interpreter = any(name == i or (name.startswith(i) and all(c.isdigit() or c == "." for c in name[len(i):]))
                         for i in catalog().interpreters)
    if not is_interpreter:
        return comm
    args = [a for a in command_line.split(" ") if a][1:]
    for arg in args:
        if arg in ("-c", "-e"):
            break  # inline code: nothing to name it after
        if arg.startswith("-"):
            continue
        base = _last_path_component(arg)
        for ext in _SCRIPT_EXTENSIONS:
            if base.endswith(ext):
                base = base[:-len(ext)]
        if base and base not in ("index", "main", "server"):
            return base
    return comm


def unit_base(unit: str) -> str:
    return unit.removesuffix(".service")


def display_name(unit: str) -> str:
    """`code-server@alice.service` -> "code-server (alice)"."""
    n = unit.removesuffix(".service")
    at = n.find("@")
    if at >= 0:
        instance = n[at + 1:]
        n = n[:at] + (f" ({instance})" if instance else "")
    return n


def dedupe(ports: list[ServicePort]) -> list[ServicePort]:
    """One entry per port, keeping the most reachable address, sorted by port."""
    best: dict[int, ServicePort] = {}
    for p in ports:
        if (best[p.port].reach if p.port in best else -1) < p.reach:
            best[p.port] = p
    return sorted(best.values(), key=lambda p: p.port)


def _unit_service(unit: SystemdUnit, kind: Kind, uptime: float | None,
                  ports: list[ServicePort]) -> DiscoveredService | None:
    """None when not worth listing: not found, masked, a one-shot that ran and is done, or stopped and not enabled."""
    if unit.load_state != "loaded":
        return None
    product = product_for(unit.name)
    match unit.active_state:
        case "active" | "reloading":
            if unit.sub_state == "exited" and product is None:
                return None
            status = Status.RUNNING
        case "activating":
            status = Status.RESTARTING if unit.sub_state == "auto-restart" else Status.STARTING
        case "deactivating":
            status = Status.STOPPING
        case "failed":
            status = Status.FAILED
        case "inactive":
            if unit.unit_file_state != "enabled" or unit.type == "oneshot":
                return None
            status = Status.STOPPED
        case _:
            return None
    plumbing = is_plumbing(unit.name)
    active: float | None = None
    if status is Status.RUNNING and uptime is not None and unit.active_enter_monotonic is not None:
        active = max(0.0, uptime - unit.active_enter_monotonic / 1_000_000)
    enabled = {"enabled": True, "enabled-runtime": True, "disabled": False}.get(unit.unit_file_state)
    if status in (Status.FAILED, Status.RESTARTING):
        visible = True
    elif product is not None:
        visible = not product.hidden_by_default
    else:
        visible = not plumbing
    return DiscoveredService(
        id=f"{kind.value}/{unit.name}", kind=kind, unit=unit.name,
        name=product.name if product else display_name(unit.name), detail=unit.description,
        product=product.id if product else None, status=status, sub_state=unit.sub_state,
        result=None if unit.result in ("", "success") else unit.result,
        enabled_at_boot=enabled, active_seconds=active, memory_bytes=unit.memory_bytes, restarts=unit.restarts or 0,
        ports=dedupe(ports), path=unit.fragment_path or None,
        is_plumbing=plumbing and product is None, visible_by_default=visible)


@dataclass
class _Found:
    pid: int
    name: str
    proc: ListeningProcess
    ports: list[ServicePort]


def _processes(loose: dict[int, tuple[str, list[ServicePort]]], order: list[int],
               by_pid: dict[int, ListeningProcess]) -> list[DiscoveredService]:
    """Processes no unit runs. A database or cache alone beside one app in the same cgroup (a login session) is
    folded into that app."""
    found = [_Found(pid, process_name(loose[pid][0], by_pid[pid].command_line), by_pid[pid], list(loose[pid][1]))
             for pid in order if pid in loose and pid in by_pid]
    helpers = catalog().helpers
    folded: set[int] = set()
    for helper in found:
        if helper.name.lower() not in helpers:
            continue
        apps = [i for i, f in enumerate(found)
                if f.proc.cgroup == helper.proc.cgroup and f.name.lower() not in helpers]
        if len(apps) == 1 and helper.proc.cgroup != "/":
            found[apps[0]].ports += helper.ports
            folded.add(helper.pid)
    found = [f for f in found if f.pid not in folded]
    # One program with several processes (nginx's master and workers) is one service, named after the lowest pid.
    merged: list[_Found] = []
    for f in found:
        same = next((m for m in merged if m.name.lower() == f.name.lower() and m.proc.cgroup == f.proc.cgroup), None)
        if same is not None:
            same.ports += f.ports
            if f.pid < same.pid:
                same.pid, same.proc = f.pid, f.proc
        else:
            merged.append(f)

    used: dict[str, int] = {}
    out: list[DiscoveredService] = []
    for f in merged:
        product = product_for(f.name)
        plumbing = f.name.lower() in catalog().plumbing_processes
        ports = dedupe(f.ports)
        sid = "process/" + f.name
        used[sid] = used.get(sid, 0) + 1
        if used[sid] > 1:
            sid += ":" + (str(ports[0].port) if ports else str(f.pid))
        # Started by hand in a login session = the user's own; a root-cgroup process on a server without systemd is
        # shown when it is a known product.
        in_session = "session-" in f.proc.cgroup or "user.slice" in f.proc.cgroup
        visible = not plumbing and ((not product.hidden_by_default) if product else in_session)
        words = [w for w in f.proc.command_line.split(" ") if w]
        out.append(DiscoveredService(
            id=sid, kind=Kind.PROCESS, unit=None, name=product.name if product else f.name, detail=f.proc.command_line,
            product=product.id if product else None, status=Status.RUNNING, sub_state="running", result=None,
            enabled_at_boot=None, active_seconds=None, memory_bytes=None, restarts=0, ports=ports,
            path=words[0] if words else None, is_plumbing=plumbing, visible_by_default=visible))
    return out


def discover(reading: ServicesScan) -> ServicesSnapshot:
    by_pid: dict[int, ListeningProcess] = {}
    for p in reading.processes:
        by_pid.setdefault(p.pid, p)
    unit_ports: dict[str, list[ServicePort]] = {}  # "system/<unit>" or "user/<unit>"
    loose: dict[int, tuple[str, list[ServicePort]]] = {}
    order: list[int] = []
    user_units = {u.name for u in reading.user}
    for sock in reading.sockets:
        port = ServicePort(sock.address, sock.port)
        for owner in sock.processes:
            if is_container_helper(owner.name):
                continue
            proc = by_pid.get(owner.pid)
            if proc is None:
                continue
            where, unit = home_of(proc.cgroup)
            if where == "container":
                continue
            if where == "system":
                unit_ports.setdefault("system/" + unit, []).append(port)
            elif where == "user" and unit in user_units:
                unit_ports.setdefault("user/" + unit, []).append(port)
            else:
                # A login session, the root cgroup, or another user's unit (seen only as root, named after its unit).
                if owner.pid not in loose:
                    order.append(owner.pid)
                    loose[owner.pid] = (unit_base(unit) if where == "user" else owner.name, [])
                loose[owner.pid][1].append(port)

    services: list[DiscoveredService] = []
    for kind, units in ((Kind.SYSTEM, reading.system), (Kind.USER, reading.user)):
        for u in units:
            s = _unit_service(u, kind, reading.uptime, unit_ports.get(f"{kind.value}/{u.name}", []))
            if s is not None:
                services.append(s)
    services += _processes(loose, order, by_pid)
    services.sort(key=lambda s: (s.name.lower(), s.id))
    return ServicesSnapshot(services, reading.is_root, bool(reading.system))

