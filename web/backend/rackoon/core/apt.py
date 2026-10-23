"""apt actions and the Updates screen's rules (Kotlin `AptAction`, `UpdatesPresentation`; Swift `AptAction` for the
password variant). Every action is a MUTATE intent; the scripts come from the spec and pick `sudo -n` unless the ssh
user is root, so the sudo password flow (`sudo.with_password`) applies to them unchanged."""

from __future__ import annotations

from dataclasses import dataclass

from . import shell, spec, sudo
from .policy import Intent, Risk
from .updates import PendingUpdate, UpdatesSnapshot

MAX_PACKAGES = 200
STALE_AFTER_SECONDS = 3 * 86_400


def is_package_name(name: str) -> bool:
    """Debian policy: lowercase letters, digits, `+`, `-`, `.`; at least two characters, starting alphanumeric."""
    if len(name) < 2 or not (name[0].isascii() and (name[0].islower() or name[0].isdigit())):
        return False
    return all(c.isascii() and (c.islower() or c.isdigit() or c in "+-.") for c in name)


@dataclass(frozen=True)
class AptAction:
    """`refresh` (apt-get update), `upgrade_all` (apt-get upgrade) or `upgrade` (only `packages`)."""

    kind: str
    packages: tuple[str, ...] = ()

    @property
    def timeout_seconds(self) -> int:
        return 300 if self.kind == "refresh" else 1800

    @property
    def command(self) -> str | None:
        if self.kind == "refresh":
            return spec.script("apt_refresh")
        if self.kind == "upgrade_all":
            return spec.script("apt_upgrade")
        if self.kind == "upgrade":
            unique = list(dict.fromkeys(self.packages))
            # The cap keeps the command far below any argument-length limit; callers fall back to upgrade_all.
            if not unique or len(unique) > MAX_PACKAGES or not all(is_package_name(p) for p in unique):
                return None
            return shell.fill(spec.script("apt_upgrade_packages"), {"packages": " ".join(unique)})
        return None

    @property
    def summary(self) -> str:
        if self.kind == "refresh":
            return "Refresh package lists"
        if self.kind == "upgrade_all":
            return "Install all available updates"
        n = len(self.packages)
        return f"Install updates for {n} package{'' if n == 1 else 's'}"

    @property
    def intent(self) -> Intent | None:
        cmd = self.command
        return Intent(self.summary, cmd, Risk.MUTATE) if cmd else None

    def password_intent(self, nonce: str) -> Intent | None:
        """The same action for a user whose sudo wants a password: a separate intent, so a yes to the plain one never
        authorises it. `nonce` must be the one the run uses."""
        plain = self.intent
        cmd = sudo.with_password(plain.command, nonce) if plain else None
        return Intent(self.summary + " (with sudo password)", cmd, Risk.MUTATE) if plain and cmd else None


def explain(stdout: str, stderr: str, exit_code: int) -> str:
    """A failure a person can act on. apt runs with LC_ALL=C; sudo's messages always start with "sudo:"."""
    lines = [ln.strip() for ln in (stderr + "\n" + stdout).split("\n") if ln.strip()]
    if any(ln.startswith("sudo:") for ln in lines):
        return ("This user can't run apt with sudo without a password. Enter the password when asked, use root, or "
                "allow passwordless sudo for apt-get.")
    if any("Could not get lock" in ln or "Unable to acquire the dpkg" in ln for ln in lines):
        return "Another package manager is running on the server (apt lock held). Try again in a minute."
    if any("dpkg was interrupted" in ln for ln in lines):
        return "A previous install was interrupted. Run `sudo dpkg --configure -a` on the server, then try again."
    errors = [ln for ln in lines if ln.startswith("E:")]
    shown = (errors or lines)[-3:]
    return "\n".join(shown) if shown else f"apt-get failed (exit {exit_code})"


# --- the Updates screen ---------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class AptPrompt:
    title: str
    message: str
    working: str
    output_title: str


def subtitle(s: UpdatesSnapshot) -> str:
    if not s.packages:
        return "Everything is up to date"
    n = len(s.packages)
    base = f"{n} update{'' if n == 1 else 's'} available"
    return f"{base}, {s.security_count} security" if s.security_count else base


def relative_age(seconds: int) -> str:
    s = max(seconds, 0)

    def unit(n: int, name: str) -> str:
        return f"{n} {name}{'' if n == 1 else 's'} ago"
    if s < 60:
        return "just now"
    if s < 3600:
        return unit(s // 60, "minute")
    if s < 86_400:
        return unit(s // 3600, "hour")
    if s < 30 * 86_400:
        return unit(s // 86_400, "day")
    return unit(s // (30 * 86_400), "month")


def refreshed_text(s: UpdatesSnapshot, now: int) -> str:
    return relative_age(now - s.refreshed_at) if s.refreshed_at is not None else "unknown"


def staleness(s: UpdatesSnapshot, now: int) -> str | None:
    if s.refreshed_at is None or now - s.refreshed_at <= STALE_AFTER_SECONDS:
        return None
    return f"Package lists were refreshed {relative_age(now - s.refreshed_at)}. Refresh them to see newer updates."


def sorted_packages(packages: list[PendingUpdate]) -> list[PendingUpdate]:
    """Security updates first, then by name."""
    return sorted(packages, key=lambda p: (0 if p.is_security else 1, p.name))


def security_names(packages: list[PendingUpdate]) -> list[str]:
    return [p.name for p in sorted_packages(packages) if p.is_security]


def can_install_security(packages: list[PendingUpdate]) -> bool:
    n = len(security_names(packages))
    return 0 < n <= MAX_PACKAGES


def install_security_hint(packages: list[PendingUpdate], read_only: bool) -> str | None:
    if read_only:
        return "Read-only mode is on"
    if not security_names(packages):
        return "No security updates"
    if not can_install_security(packages):
        return "Too many to list one by one; use Install All"
    return None


def prompt(action: AptAction, package_count: int, security_count: int) -> AptPrompt:
    if action.kind == "refresh":
        return AptPrompt("Refresh package lists?", "Checks the repositories for new versions. Nothing is installed.",
                         "Refreshing package lists…", "apt-get update")
    if action.kind == "upgrade_all":
        return AptPrompt(f"Install all {package_count} updates?", "Held packages stay as they are and existing config "
                         "files are kept. Some updates may ask for a reboot afterwards.",
                         f"Installing {package_count} updates…", "apt-get upgrade")
    names = list(action.packages)
    more = f" and {len(names) - 6} more" if len(names) > 6 else ""
    return AptPrompt(f"Install {security_count} security update{'' if security_count == 1 else 's'}?",
                     f"Only these packages are upgraded: {', '.join(names[:6])}{more}.", "Installing security updates…",
                     f"apt-get install --only-upgrade ({len(names)} package{'' if len(names) == 1 else 's'})")
