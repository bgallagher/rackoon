"""What can be done to a discovered service (the Swift core's `ServiceActions` and `ServiceVisibility`). Each action
is a `LibraryCommand`, so it runs exactly like a Commands entry: reads stream straight away, Start/Stop/Restart show a
read-only status first and then the standard confirmation, system units go through `$S` (sudo -n, with the password
sheet when sudo wants one) and a user's own units through `systemctl --user`. Processes started by hand have no actions:
nothing on the server knows how to start one again."""

from __future__ import annotations

import enum
import re

from . import shell
from .command_library import LibraryCommand
from .policy import Risk
from .services import DiscoveredService, Kind, Status


class ServiceAction(enum.Enum):
    START = "start"
    STOP = "stop"
    RESTART = "restart"
    STATUS = "status"
    LOGS = "logs"

    @property
    def title(self) -> str:
        return {"start": "Start", "stop": "Stop", "restart": "Restart", "status": "Status",
                "logs": "Recent Logs"}[self.value]

    @property
    def is_mutating(self) -> bool:
        return self in (ServiceAction.START, ServiceAction.STOP, ServiceAction.RESTART)

    def applies(self, s: DiscoveredService) -> bool:
        if self is ServiceAction.START:
            return s.status in (Status.STOPPED, Status.FAILED)
        if self is ServiceAction.STOP:
            return s.status not in (Status.STOPPED, Status.FAILED)
        if self is ServiceAction.RESTART:
            return s.status is not Status.STOPPING
        return True


_UNIT = re.compile(r"[A-Za-z0-9:_.@\\-]+")


def is_unit_name(name: str) -> bool:
    """Safe to hand to systemctl (it is quoted too): letters, digits and `:_.@-\\`, ending in `.service`, not an
    option."""
    return name.endswith(".service") and not name.startswith("-") and len(name) <= 256 and _UNIT.fullmatch(name) is not None


JOURNAL_READER = """[ "$(id -u)" -eq 0 ] || id -nG | tr ' ' '\\n' | grep -qxE 'adm|systemd-journal|wheel'"""


def _summary(action: ServiceAction, s: DiscoveredService) -> str:
    unit = s.unit or s.name
    how = "with systemctl --user (your own service, no sudo)" if s.kind is Kind.USER else "with systemctl (needs sudo)"
    if action is ServiceAction.START:
        return f"Starts {unit} {how}."
    if action is ServiceAction.STOP:
        return f"Stops {unit} {how}. It starts again at the next boot if it is enabled."
    return f"Stops and starts {unit} {how}."


def _warning(s: DiscoveredService) -> str | None:
    p = s.product
    if p == "tailscale":
        return "If you reach this server over Tailscale, the connection drops until it is back (Rackoon included)."
    if p == "ssh":
        return ("Rackoon talks to this server over ssh. Open sessions usually survive, but new ones are refused while it "
                "is down.")
    if p == "docker":
        return "Every container on this server stops with it."
    if p in ("wireguard", "netbird", "zerotier", "openvpn", "cloudflared"):
        return "Anything reaching this server through it loses access until it is back."
    return None


def command(action: ServiceAction, s: DiscoveredService) -> LibraryCommand | None:
    """The command for `action` on `s`, or None for a process or a name that is not safe."""
    if s.unit is None or not is_unit_name(s.unit):
        return None
    q = shell.quote(s.unit)
    if q is None:
        return None
    user = s.kind is Kind.USER
    ctl = "systemctl --user" if user else "$S systemctl"
    flag = " --user" if user else ""
    cid = f"service.{action.value}.{s.id}"
    title = f"{action.title} {s.name}"
    status = f"systemctl{flag} status --no-pager --lines=5 {q} 2>&1 | head -n 20; true"
    if action.is_mutating:
        return LibraryCommand(cid, title, "Services", _summary(action, s),
                              f'{ctl} {action.value} {q} && echo "Now: $(systemctl{flag} is-active {q})"',
                              risk=Risk.MUTATE, root=not user, preview=status,
                              warning=None if action is ServiceAction.START else _warning(s))
    if action is ServiceAction.STATUS:
        return LibraryCommand(cid, title, "Services", f"What systemd says about {s.unit} now.",
                              f"systemctl{flag} status --no-pager --lines=30 {q}; true")
    script = (f"journalctl --user -u {q} -n 200 --no-pager" if user else
              f"if {JOURNAL_READER}; then journalctl -u {q} -n 200 --no-pager; else $S journalctl -u {q} -n 200 "
              "--no-pager; fi")
    return LibraryCommand(cid, title, "Services", f"The last 200 lines {s.unit} wrote to the journal.", script,
                          root=not user)


def follow_logs_command(s: DiscoveredService) -> str | None:
    """Follows the unit's journal in a terminal tab; for a system unit the user can't read, sudo asks there."""
    if s.unit is None or not is_unit_name(s.unit):
        return None
    q = shell.quote(s.unit)
    if q is None:
        return None
    if s.kind is Kind.USER:
        return f"journalctl --user -u {q} -f -n 100"
    return f"if {JOURNAL_READER}; then journalctl -u {q} -f -n 100; else sudo journalctl -u {q} -f -n 100; fi"


EVERYWHERE = "*"


class ServiceVisibility:
    """Show or hide a service on one server or on every server; otherwise its default (OS plumbing hidden)."""

    def __init__(self, overrides: dict[str, bool] | None = None) -> None:
        self.overrides: dict[str, bool] = dict(overrides or {})

    @staticmethod
    def key(server: str, service: str) -> str:
        return f"{server}|{service}"

    def is_visible(self, s: DiscoveredService, server: str) -> bool:
        own = self.overrides.get(self.key(server, s.id))
        if own is not None:
            return own
        every = self.overrides.get(self.key(EVERYWHERE, s.id))
        return every if every is not None else s.visible_by_default

    def is_chosen(self, s: DiscoveredService, server: str) -> bool:
        return self.key(server, s.id) in self.overrides or self.key(EVERYWHERE, s.id) in self.overrides

    def set(self, visible: bool | None, service: str, server: str, everywhere: bool = False) -> None:
        """`visible` None goes back to the default. `everywhere` also drops each server's own choice."""
        if everywhere:
            self.overrides = {k: v for k, v in self.overrides.items() if not k.endswith("|" + service)}
            target = self.key(EVERYWHERE, service)
        else:
            target = self.key(server, service)
        if visible is None:
            self.overrides.pop(target, None)
        else:
            self.overrides[target] = visible

    def forget(self, server_id: str) -> bool:
        before = len(self.overrides)
        self.overrides = {k: v for k, v in self.overrides.items() if not k.startswith(server_id + "|")}
        return len(self.overrides) != before
