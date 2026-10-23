"""Rebooting a server and knowing it came back (Kotlin/Swift `RebootSession`). "Back" means a different kernel boot id,
not just a successful connection: for a couple of seconds after the command, the old system still answers. The plain
reboot uses `sudo -n` (or root); the password one is the spec's `reboot_sudo`, whose `sudo -S` reads the password from
standard input and nowhere else. They are separate intents, so a yes to one never authorises the other.

Rackoon never decides a reboot is needed: the notice is the server's own /var/run/reboot-required flag."""

from __future__ import annotations

from dataclasses import dataclass

from . import spec, sudo
from .policy import Intent, Risk

REBOOT_REQUIRED_ID = "reboot_required"


def boot_id_command() -> str:
    return spec.script("boot_id")


def reboot_command() -> str:
    return spec.script("reboot")


def sudo_reboot_command() -> str:
    return spec.script("reboot_sudo")


def intent() -> Intent:
    return Intent("Reboot the server", reboot_command(), Risk.MUTATE)


def sudo_intent() -> Intent:
    return Intent("Reboot the server with sudo", sudo_reboot_command(), Risk.MUTATE)


NO_SUDO = ("This user can't reboot the server without a password. Enter the password when asked, use root, or allow "
           "passwordless sudo for systemctl.")


@dataclass(frozen=True)
class RebootFailure:
    """no_sudo (sudo wants a password), bad_password, sudo_refused or failed, with a message for the user."""

    kind: str
    message: str


def outcome_of(exit_code: int, stdout: str, stderr: str) -> RebootFailure | None:
    """The plain reboot: None when it was scheduled."""
    if exit_code == 5 or "##no-sudo" in stdout:
        return RebootFailure("no_sudo", NO_SUDO)
    if exit_code != 0 or "##rebooting" not in stdout:
        detail = stderr.strip()
        return RebootFailure("failed", detail or f"The reboot command failed (exit {exit_code}).")
    return None


def classify_sudo_failure(output: str, exit_code: int) -> RebootFailure:
    """What sudo said when the password reboot was refused."""
    text = output.lower()
    if sudo.is_auth_failure(output):
        return RebootFailure("bad_password", "The server did not accept that password.")
    if "must have a tty" in text or "requiretty" in text:
        return RebootFailure("sudo_refused", "sudo on this server insists on a terminal (requiretty), so Rackoon can't "
                             "hand it the password. Allow passwordless sudo for systemctl, or reboot from a terminal tab.")
    if any(w in text for w in ("not in the sudoers", "not allowed to execute", "not allowed to run sudo")):
        return RebootFailure("sudo_refused", "This user is not allowed to use sudo on the server, so it can't reboot "
                             "it. Use root, or give the user sudo rights.")
    lines = [ln.strip() for ln in output.splitlines() if ln.strip() and not ln.strip().startswith("##")]
    return RebootFailure("failed", " ".join(lines) if lines else f"The reboot command failed (exit {exit_code}).")


def sudo_outcome_of(exit_code: int, stdout: str, stderr: str) -> RebootFailure | None:
    if exit_code == 0 and "##rebooting" in stdout:
        return None
    return classify_sudo_failure(stdout + "\n" + stderr, exit_code)


def offers_reboot(attention_id: str) -> bool:
    """The notice a Reboot… button belongs on."""
    return attention_id == REBOOT_REQUIRED_ID


def is_back(previous_boot_id: str, exit_code: int, stdout: str) -> bool:
    """A poll answered with a different boot id."""
    current = stdout.strip()
    return exit_code == 0 and bool(current) and current != previous_boot_id
