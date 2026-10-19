"""Running root commands for an ssh user whose sudo wants a password (the Swift core's `SudoElevation`,
`SudoHandshake`, `SudoCredential`, `ElevationWindow` and `SudoTransport.elevated`; Android has no sudo flow yet).

Every root script picks its sudo with `S='sudo -n'` (never prompts). When that is refused, the user is asked for the
password and the same script runs again behind the spec's `sudo_prompt`: `sudo -v` asks ONCE, with a prompt carrying
a random per-run nonce, then prints an ok (or fail) marker with the same nonce; the script's own `sudo -n` then uses
the session record `sudo -v` just made. `SudoHandshake` types the password at that one prompt and stops listening
once a marker arrives, so nothing the script prints later (journal lines, user names: text other people on the server
control) can make it type the password again. The password is never part of a command.
"""

from __future__ import annotations

import re
import secrets
from dataclasses import dataclass, field

from . import shell, spec
from .stream import strip_ansi

NO_PASSWORD = "S='sudo -n'"


def prefix() -> str:
    """The spec's `sudo_prompt`, with `{nonce}` still in it."""
    return spec.script("sudo_prompt")


def make_nonce() -> str:
    """16 random bytes as hex. The nonce shows in `ps` on the server, so it is a second layer, not the protection: the
    protection is that only one prompt, before the script runs, is ever answered."""
    return secrets.token_hex(16)


_NONCE = re.compile(r"[0-9a-f]{32}")


def is_nonce(s: str) -> bool:
    return _NONCE.fullmatch(s) is not None


def with_password(command: str, nonce: str) -> str | None:
    """The script behind the password prefix, or None if it does not use `$S` or the nonce is malformed."""
    if NO_PASSWORD not in command or not is_nonce(nonce):
        return None
    return shell.fill(prefix(), {"nonce": nonce}) + command


def needs_password(output: str) -> bool:
    """sudo refused because it wanted a password (classic "a password is required" / "a terminal is required", sudo-rs
    "interactive authentication is required"). Only ever used to OFFER the password sheet."""
    for raw in output.splitlines():
        line = raw.strip().lower()
        if line.startswith("sudo:") and ("password is required" in line or "terminal is required" in line
                                         or "authentication is required" in line):
            return True
    return False


def is_auth_failure(text: str) -> bool:
    """sudo's words for a wrong password, classic and sudo-rs. Shared with the reboot."""
    t = text.lower()
    return any(w in t for w in ("sorry, try again", "incorrect password", "authentication failed",
                                "incorrect authentication", "no password was provided", "authentication required"))


def is_sudo_auth_failure(stderr: str) -> bool:
    """sudo's OWN wrong-password lines: they start with "sudo:", or are classic sudo's bare "Sorry, try again.". A
    command's own text ("unauthorized: authentication required" from a registry) doesn't count."""
    for raw in stderr.splitlines():
        line = raw.strip()
        if line == "Sorry, try again." or (line.lower().startswith("sudo:") and is_auth_failure(line)):
            return True
    return False


def explain_refusal(sudo_text: str) -> str:
    """sudo said no for a reason other than a wrong password, in plain words."""
    text = sudo_text.lower()
    if any(w in text for w in ("not in the sudoers", "not allowed to execute", "not allowed to run sudo",
                               "may not run sudo")):
        return "This user is not allowed to use sudo on the server. Use root, or give the user sudo rights."
    if "must have a tty" in text or "requiretty" in text:
        return ("sudo on this server insists on a terminal, so Rackoon can't hand it the password. Allow passwordless "
                "sudo for this command, or run it in a terminal tab.")
    lines = [ln.strip() for ln in sudo_text.splitlines() if ln.strip()]
    return "sudo refused: " + " ".join(lines) if lines else "sudo refused, and said nothing about why."


OTHER_PROMPT = ("sudo asked for something besides the password (a second factor, or a password that must be changed), "
                "which Rackoon can't answer. Run the command in a terminal tab.")
ASKS_EVERY_TIME = ("sudo on this server asks for the password for every command, so Rackoon can't pass it on safely. "
                   "Allow passwordless sudo for this command, or run it in a terminal tab.")


@dataclass(frozen=True)
class SudoCredential:
    """A password and the nonce of the one prompt it may be typed at. Built once per attempt: the nonce is part of the
    intent's command, so the confirmation and the run must use the same one."""

    password: str = field(repr=False)
    nonce: str


@dataclass(frozen=True)
class SudoOutcome:
    """accepted, rejected (a wrong password), refused (sudo said no for another reason; `said` is what it printed),
    other_prompt (a second factor or password change) or unfinished (the stream ended before any marker)."""

    kind: str
    said: str = ""


ACCEPTED = SudoOutcome("accepted")
REJECTED = SudoOutcome("rejected")
OTHER = SudoOutcome("other_prompt")
UNFINISHED = SudoOutcome("unfinished")

TYPE_PASSWORD = "type"
INTERRUPT = "interrupt"


class SudoHandshake:
    """Reads the start of a password run: hides the nonce prompt line (sudo-rs wraps it as `[sudo: ##rackoon-sudo-…:]
    Password:` and echoes an asterisk per typed character, which would show the password's length), asks for the
    password to be typed at the first prompt only, and settles the outcome from the markers. Once settled, everything
    passes through untouched and is never looked at again. Chunks can cut a marker anywhere, so an unfinished line that
    could still become one is held back. Pure."""

    NOTICE = "\x1b[2m[sudo password sent]\x1b[0m\r\n"
    REJECTED_NOTICE = "\x1b[31m[the sudo password was not accepted]\x1b[0m\r\n"

    def __init__(self, nonce: str) -> None:
        self.prompt = f"##rackoon-sudo-{nonce}:"
        self.ok = f"##rackoon-sudo-ok-{nonce}"
        self.fail = f"##rackoon-sudo-fail-{nonce}"
        self._pending = ""
        self._suppressing = False
        self._answered = False
        self._seen = ""
        self._since_answer = ""
        self.outcome: SudoOutcome | None = None

    def push(self, chunk: str) -> tuple[str, list[str]]:
        """What to show of this chunk, and what to type (`TYPE_PASSWORD`, `INTERRUPT`)."""
        self._pending += chunk
        shown = ""
        actions: list[str] = []
        while True:
            p = self._pending
            if self._suppressing:
                # Drop the rest of a prompt or marker line (the typed-password echo, the marker's line end).
                nl = p.find("\n")
                if nl < 0:
                    self._pending = ""
                    break
                self._pending = p[nl + 1:]
                self._suppressing = False
                continue
            if self.outcome is not None:
                shown += p
                self._pending = ""
                break
            found = [(i, kind, m) for kind, m in enumerate((self.prompt, self.ok, self.fail))
                     if (i := p.find(m)) >= 0]
            if found:
                at, kind, marker = min(found)
                line_start = p.rfind("\n", 0, at) + 1
                before = p[:line_start]
                shown += before
                self._seen += before
                if self._answered:
                    self._since_answer += before
                wrong = self._answered and is_auth_failure(strip_ansi(self._since_answer))
                if kind == 0 and not self._answered:
                    self._answered = True
                    actions.append(TYPE_PASSWORD)
                    shown += self.NOTICE
                elif kind == 0:
                    # A second prompt: a wrong password only if sudo said so; otherwise another question (2FA,
                    # password change) whose prompt sudo-rs also wraps with our marker.
                    self.outcome = REJECTED if wrong else OTHER
                    actions.append(INTERRUPT)
                    shown += self.REJECTED_NOTICE if wrong else ""
                elif kind == 1:
                    self.outcome = ACCEPTED
                else:
                    # sudo gave up after the typed password (passwd_tries=1): that is a wrong password too.
                    self.outcome = REJECTED if wrong else SudoOutcome("refused", strip_ansi(self._seen).strip())
                self._pending = p[at + len(marker):]
                self._suppressing = True
                continue
            # Hold back the unfinished last line if it could still become a prompt or a marker.
            tail_start = p.rfind("\n") + 1
            tail = p[tail_start:]
            hold_from = len(p)
            if tail and ("[sudo: ".startswith(tail) or tail.startswith("[sudo: ")):
                hold_from = tail_start
            else:
                markers = (self.prompt, self.ok, self.fail)
                longest = max(len(m) for m in markers)
                for length in range(min(longest - 1, len(tail)), 0, -1):
                    suffix = tail[-length:]
                    if any(len(m) > length and m.startswith(suffix) for m in markers):
                        hold_from = len(p) - length
                        break
            released = p[:hold_from]
            shown += released
            self._seen += released
            if self._answered:
                self._since_answer += released
            self._pending = p[hold_from:]
            break
        return shown, actions

    def finish(self) -> str:
        """At the end of the stream: what was held back; `unfinished` if no marker ever arrived."""
        held, self._pending = self._pending, ""
        if self.outcome is None:
            self.outcome = UNFINISHED
        return "" if self._suppressing else held


def elevated(command: str) -> str | None:
    """`sudo -S -p '' sh -c '<command>'` (the password goes to stdin), or None if the command can't be one word."""
    quoted = shell.quote(command)
    return "sudo -S -p '' sh -c " + quoted if quoted is not None else None


def elevated_stream(command: str, nonce: str) -> str | None:
    """A stream through sudo: one `sudo -v` at the nonce prompt, then `sudo -n sh -c '<command>'` in the same pty."""
    quoted = shell.quote(command)
    if quoted is None or not is_nonce(nonce):
        return None
    return shell.fill(prefix(), {"nonce": nonce}) + "sudo -n sh -c " + quoted


@dataclass(frozen=True)
class Unlock:
    password: str = field(repr=False)
    until: float


class ElevationWindow:
    """Which servers have Docker unlocked through sudo, until when, and why one was locked. Pure (the clock is passed
    in). The password lives here, in memory only, for `length` seconds (15 minutes, like sudo's own grace period)."""

    DEFAULT_LENGTH = 15 * 60.0

    def __init__(self, length: float = DEFAULT_LENGTH) -> None:
        self.length = length
        self._unlocks: dict[str, Unlock] = {}
        self._generations: dict[str, int] = {}
        self.lock_reasons: dict[str, str] = {}

    def unlock(self, server_id: str, password: str, now: float) -> None:
        self._unlocks[server_id] = Unlock(password, now + self.length)
        self.lock_reasons.pop(server_id, None)
        self._generations[server_id] = self.generation(server_id) + 1

    def lock(self, server_id: str, reason: str | None = None) -> None:
        """Locks now. Does nothing (not even a new generation) if it was not unlocked."""
        if self._unlocks.pop(server_id, None) is None:
            return
        if reason is not None:
            self.lock_reasons[server_id] = reason
        else:
            self.lock_reasons.pop(server_id, None)
        self._generations[server_id] = self.generation(server_id) + 1

    def active(self, server_id: str, now: float) -> Unlock | None:
        """The unlock that is still valid at `now`; an expired one is never returned."""
        u = self._unlocks.get(server_id)
        return u if u is not None and u.until > now else None

    def generation(self, server_id: str) -> int:
        return self._generations.get(server_id, 0)
