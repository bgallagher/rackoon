"""Streamed commands: the `stream_wrap` template and the parser that takes its exit marker off the end of the output
(spec/scenarios/stream-output.json). A streamed ssh gives output but no exit status, so the wrapper prints
`##rackoon-exit:<n>`; no marker means cancelled or dropped, never success."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import TYPE_CHECKING

from . import shell, spec

if TYPE_CHECKING:
    from .sudo import SudoOutcome

MARKER = "##rackoon-exit:"


def wrap(command: str, cols: int, rows: int) -> str:
    """`cols`/`rows` are the size of the terminal that shows the output, so redrawing progress lines up. The command
    must already be vetted."""
    return shell.fill(spec.script("stream_wrap"), {
        "cols": str(min(400, max(20, cols))), "rows": str(min(200, max(5, rows))), "command": command})


def _leading_int(text: str) -> int | None:
    """The number at the start of `text`, after any spaces, ignoring what follows it."""
    digits = ""
    for c in text.lstrip(" "):
        if c not in "0123456789":
            break
        digits += c
    if not digits:
        return None
    value = int(digits)
    return value if value <= 2**31 - 1 else None


class StreamOutputParser:
    """Chunks can cut the marker anywhere, so a possible start of it is held back until the next chunk shows what it
    is. Works on code points, so a `\\r\\n` pair is two characters here as in Kotlin (Swift needed unicode scalars)."""

    def __init__(self) -> None:
        self._pending = ""
        self.exit_code: int | None = None

    def push(self, chunk: str) -> str:
        """Text that is safe to show now."""
        if self.exit_code is not None:
            return ""  # nothing follows the marker
        self._pending += chunk
        found = self._pending.find(MARKER)
        if found >= 0:
            shown = self._pending[:found]
            rest = self._pending[found + len(MARKER):]
            end = next((i for i, c in enumerate(rest) if c in "\r\n"), -1)
            if end >= 0:
                self.exit_code = _leading_int(rest[:end])
                self._pending = ""
            else:
                self._pending = self._pending[found:]  # the number has not fully arrived
            return shown
        hold = 0
        for length in range(min(len(MARKER) - 1, len(self._pending)), 0, -1):
            if MARKER.startswith(self._pending[-length:]):
                hold = length
                break
        cut = len(self._pending) - hold
        shown, self._pending = self._pending[:cut], self._pending[cut:]
        return shown

    def finish(self) -> tuple[str, int | None]:
        """At the end: whatever was held back, and the exit code (None if the stream ended before the marker)."""
        held, self._pending = self._pending, ""
        if self.exit_code is None:
            found = held.find(MARKER)
            if found >= 0:
                # The marker was the last thing sent, without a trailing newline.
                code = _leading_int(held[found + len(MARKER):])
                if code is not None:
                    self.exit_code = code
                    return held[:found], code
        return (held if self.exit_code is None else ""), self.exit_code


_CSI = re.compile("\x1b\\[[0-9;?]*[ -/]*[@-~]")
_CHARSET = re.compile("\x1b[()][0-9A-Za-z]")


def strip_ansi(text: str) -> str:
    """Text without escape sequences and carriage returns, for matching on what a command printed."""
    return _CHARSET.sub("", _CSI.sub("", text)).replace("\r", "")


@dataclass(frozen=True)
class StreamedRun:
    """What a streamed run came to (Kotlin `StreamedRun`)."""

    exit_code: int | None
    cancelled: bool
    transport_error: str | None
    text: str
    sudo: SudoOutcome | None = None
    """How the password step went, when a sudo password was given (None otherwise)."""

    @property
    def succeeded(self) -> bool:
        return self.exit_code == 0

    @property
    def sudo_rejected(self) -> bool:
        return self.sudo is not None and self.sudo.kind == "rejected"

    @property
    def needs_sudo_password(self) -> bool:
        """Offer the password sheet. A plain run: sudo refused for want of a password, judged from the text (a pipeline
        can exit 0). A password run: only when the password was rejected."""
        from .sudo import needs_password
        if self.sudo is not None:
            return self.sudo_rejected
        return needs_password(strip_ansi(self.text))

    @property
    def sudo_asks_every_time(self) -> bool:
        """sudo took the password, but the command's own `sudo -n` still wanted one (it keeps no session record)."""
        from .sudo import needs_password
        return self.sudo is not None and self.sudo.kind == "accepted" and needs_password(strip_ansi(self.text))

    @property
    def sudo_problem(self) -> str | None:
        """Why the password step failed, in plain words, or None when it did not."""
        from . import sudo as s
        if self.sudo is None:
            return None
        if self.sudo.kind == "rejected":
            return "The server did not accept that sudo password. Nothing was run."
        if self.sudo.kind == "refused":
            return s.explain_refusal(self.sudo.said)
        if self.sudo.kind == "other_prompt":
            return s.OTHER_PROMPT
        if self.sudo_asks_every_time:
            return s.ASKS_EVERY_TIME
        return None

    def failure_message(self, label: str) -> str | None:
        if self.exit_code is not None:
            return None if self.exit_code == 0 else f"{label} failed (exit {self.exit_code}). The output shows why."
        if self.transport_error is not None:
            return self.transport_error
        if self.cancelled:
            return "Cancelled. The command was interrupted on the server."
        return f"The connection ended before {label} reported a result."
