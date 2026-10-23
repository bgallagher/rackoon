"""Terminal output highlighting and auto-reconnect, ported from the Kotlin core (OutputHighlighter,
TerminalOutputFilter, ReconnectPolicy), which mirror the Swift core.

The filter rewrites a terminal's output bytes only by inserting SGR "set foreground" / "default foreground" pairs
around IP addresses, error/warning/success words and high percentages. Escape sequences pass through untouched;
nothing is coloured while a program has set its own colours or on the alternate screen (vim, htop); a match touching
a chunk edge is skipped; a disabled filter is an exact pass-through but still tracks escape state.
"""

from __future__ import annotations

import enum
import re
from dataclasses import dataclass

# --- Highlighter --------------------------------------------------------------------------------------------------


class HighlightKind(enum.Enum):
    IP_ADDRESS = "ip"
    ERROR = "error"
    WARNING = "warning"
    SUCCESS = "success"


@dataclass(frozen=True)
class HighlightSpan:
    """UTF-8 byte offsets into the scanned text."""

    start: int
    end: int
    kind: HighlightKind


# Python's \w is Unicode letters, digits and underscore (Kotlin spells it [\p{L}\p{M}\p{N}_]); octets are ASCII digits.
_W = r"\w"
_OCTET = r"(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])"
_IPV4 = re.compile(rf"(?<!{_W})(?<!\.){_OCTET}(?:\.{_OCTET}){{3}}(?!{_W}|\.\d)")
_IPV6_CANDIDATE = re.compile(rf"(?<!{_W})(?<![:.])[0-9A-Fa-f:]{{3,}}(?!{_W}|:)")
_ERROR_WORDS = re.compile(rf"(?<!{_W})(?:error|failed|failure|fatal|denied|refused|critical|panic)(?!{_W})", re.IGNORECASE)
_WARNING_WORDS = re.compile(rf"(?<!{_W})(?:warning|warn)(?!{_W})", re.IGNORECASE)
_SUCCESS_WORDS = re.compile(rf"(?<!{_W})(?:success|successful|successfully|passed)(?!{_W})", re.IGNORECASE)
_PERCENT = re.compile(rf"(?<!{_W})(?<!\.)(\d{{1,3}})(?:\.\d+)?%")
_HEX = set("0123456789abcdefABCDEF")


def is_ipv6(s: str) -> bool:
    """Well-formed and written with `::` or all 8 groups, so times (11:26:02) and MAC addresses never count."""
    if ":" not in s:
        return False
    compressed = "::" in s
    if not compressed and s.count(":") != 7:
        return False
    if s.find("::") != s.rfind("::"):
        return False

    def groups(p: str) -> list[str] | None:
        if not p:
            return []
        g = p.split(":")
        return g if all(1 <= len(x) <= 4 and all(c in _HEX for c in x) for x in g) else None

    if not compressed:
        whole = groups(s)
        return whole is not None and len(whole) == 8
    left_text, right_text = s.split("::", 1)
    left, right = groups(left_text), groups(right_text)
    return left is not None and right is not None and len(left) + len(right) <= 7


def resolve(spans: list[HighlightSpan]) -> list[HighlightSpan]:
    """Sorted and non-overlapping: the earlier span wins, and on a tie the first found."""
    out: list[HighlightSpan] = []
    for s in sorted(spans, key=lambda x: (x.start, x.end)):
        if out and s.start < out[-1].end:
            continue
        out.append(s)
    return out


def spans(text: str) -> list[HighlightSpan]:
    offsets = [0] * (len(text) + 1)
    n = 0
    for i, ch in enumerate(text):
        offsets[i] = n
        n += len(ch.encode("utf-8", "surrogatepass"))
    offsets[len(text)] = n
    found: list[HighlightSpan] = []

    def add(pattern: re.Pattern[str], kind_of: object) -> None:
        for m in pattern.finditer(text):
            kind = kind_of(m) if callable(kind_of) else kind_of
            if isinstance(kind, HighlightKind):
                found.append(HighlightSpan(offsets[m.start()], offsets[m.end()], kind))

    def percent_kind(m: re.Match[str]) -> HighlightKind | None:
        v = int(m.group(1))
        return HighlightKind.ERROR if v >= 90 else HighlightKind.WARNING if v >= 75 else None

    add(_IPV4, HighlightKind.IP_ADDRESS)
    add(_IPV6_CANDIDATE, lambda m: HighlightKind.IP_ADDRESS if is_ipv6(m.group(0)) else None)
    add(_ERROR_WORDS, HighlightKind.ERROR)
    add(_WARNING_WORDS, HighlightKind.WARNING)
    add(_SUCCESS_WORDS, HighlightKind.SUCCESS)
    add(_PERCENT, percent_kind)
    return resolve(found)


# --- Filter -------------------------------------------------------------------------------------------------------

_SGR = {HighlightKind.IP_ADDRESS: b"\x1b[35m", HighlightKind.ERROR: b"\x1b[31m", HighlightKind.WARNING: b"\x1b[33m",
        HighlightKind.SUCCESS: b"\x1b[32m"}
_RESET_FG = b"\x1b[39m"

TEXT, ESC, ESC_INTERMEDIATE, CSI, OSC, OSC_ESC = range(6)


def _is_token_byte(v: int) -> bool:
    return 0x30 <= v <= 0x39 or 0x41 <= v <= 0x5A or 0x61 <= v <= 0x7A or v in (0x2E, 0x3A, 0x25, 0x5F) or v >= 0x80


def _incomplete_utf8_tail(data: bytes | bytearray) -> int:
    i = len(data) - 1
    back = 0
    while i >= 0 and back < 4:
        b = data[i]
        if b & 0xC0 == 0x80:
            i -= 1
            back += 1
            continue
        needed = 4 if b >= 0xF0 else 3 if b >= 0xE0 else 2 if b >= 0xC0 else 1
        return back + 1 if needed > back + 1 else 0
    return 0


class TerminalOutputFilter:
    def __init__(self, enabled: bool = True) -> None:
        self.is_enabled = enabled
        self._mode = TEXT
        self._csi = bytearray()
        self._fg = self._bg = self._reverse = self._alt = False
        self._carry = b""
        self._ends_with_token = False

    def process(self, chunk: bytes) -> bytes:
        # The common "off" case: no escape byte here and none half-parsed, so nothing can change; hand it back.
        if not self.is_enabled and self._mode == TEXT and not self._carry and 0x1B not in chunk:
            if chunk:
                last = chunk[-1]
                self._ends_with_token = _is_token_byte(last) if not (last < 0x20 or last == 0x7F) else False
            return chunk
        data = self._carry + chunk
        self._carry = b""
        out = bytearray()
        run = bytearray()
        for b in data:
            m = self._mode
            if m == TEXT:
                if b == 0x1B:
                    self._flush(run, out, at_chunk_end=False)
                    out.append(b)
                    self._mode = ESC
                elif b < 0x20 or b == 0x7F:
                    self._flush(run, out, at_chunk_end=False)
                    out.append(b)
                    self._ends_with_token = False
                else:
                    run.append(b)
            elif m == ESC:
                out.append(b)
                if b == 0x5B:
                    self._mode = CSI
                    self._csi.clear()
                elif b in (0x5D, 0x50, 0x58, 0x5E, 0x5F):  # OSC, DCS, SOS, PM, APC: up to a string terminator
                    self._mode = OSC
                elif 0x20 <= b <= 0x2F:  # e.g. ESC ( B
                    self._mode = ESC_INTERMEDIATE
                elif b == 0x63:  # RIS
                    self._fg = self._bg = self._reverse = self._alt = False
                    self._mode = TEXT
                else:
                    self._mode = TEXT
            elif m == ESC_INTERMEDIATE:
                out.append(b)
                if not 0x20 <= b <= 0x2F:
                    self._mode = TEXT
            elif m == CSI:
                out.append(b)
                if 0x40 <= b <= 0x7E:
                    self._finish_csi(b)
                    self._mode = TEXT
                else:
                    self._csi.append(b)
            elif m == OSC:
                out.append(b)
                if b == 0x07:
                    self._mode = TEXT
                elif b == 0x1B:
                    self._mode = OSC_ESC
            else:  # OSC_ESC: ESC \ ends it; anything else is still inside the string
                out.append(b)
                self._mode = TEXT if b == 0x5C else OSC
        tail = _incomplete_utf8_tail(run) if self.is_enabled else 0
        if tail:
            self._carry = bytes(run[-tail:])
            del run[-tail:]
        self._flush(run, out, at_chunk_end=True)
        return bytes(out)

    def finish(self) -> bytes:
        """At the end of the stream: an incomplete UTF-8 tail still held back, unmodified."""
        held, self._carry = self._carry, b""
        return held

    def _flush(self, run: bytearray, out: bytearray, at_chunk_end: bool) -> None:
        if not run:
            return
        data = bytes(run)
        run.clear()
        was_adjacent = self._ends_with_token
        self._ends_with_token = _is_token_byte(data[-1])
        text: str | None = None
        if self.is_enabled and not (self._alt or self._fg or self._bg or self._reverse):
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                text = None
        if text is None:
            out += data
            return
        cursor = 0
        for span in spans(text):
            if at_chunk_end and span.end == len(data):
                continue  # may continue in the next chunk
            if was_adjacent and span.start == 0:
                continue  # may continue the previous chunk's token
            out += data[cursor:span.start]
            out += _SGR[span.kind]
            out += data[span.start:span.end]
            out += _RESET_FG
            cursor = span.end
        out += data[cursor:]

    def _finish_csi(self, final: int) -> None:
        text = self._csi.decode("latin-1")
        if final == 0x6D:  # m
            if not text[:1] in ("?", ">", "<", "="):
                self._apply_sgr(text)
        elif final in (0x68, 0x6C) and text.startswith("?"):  # h, l
            for mode in (p for p in text[1:].split(";") if p):
                if mode in ("47", "1047", "1049"):
                    self._alt = final == 0x68

    def _apply_sgr(self, params: str) -> None:
        parts = params.split(";") if params else ["0"]
        i = 0
        while i < len(parts):
            head = parts[i].split(":")[0]
            code = int(head) if head.isdigit() else 0
            if code == 0:
                self._fg = self._bg = self._reverse = False
            elif code == 7:
                self._reverse = True
            elif code == 27:
                self._reverse = False
            elif 30 <= code <= 37 or 90 <= code <= 97:
                self._fg = True
            elif code == 39:
                self._fg = False
            elif 40 <= code <= 47 or 100 <= code <= 107:
                self._bg = True
            elif code == 49:
                self._bg = False
            elif code in (38, 48):
                if code == 38:
                    self._fg = True
                else:
                    self._bg = True
                if ":" not in parts[i]:
                    kind = parts[i + 1] if i + 1 < len(parts) else ""
                    i += 2 if kind == "5" else 4 if kind == "2" else 0  # skip the colour's own parameters
            i += 1


# --- Reconnect policy ---------------------------------------------------------------------------------------------


class SessionEnd(enum.Enum):
    CONNECTION_LOST = "connectionLost"
    REMOTE_EXIT = "remoteExit"
    CLOSED_BY_USER = "closedByUser"


@dataclass(frozen=True)
class Retry:
    delay_seconds: float
    attempt: int
    of: int


class ReconnectPolicy:
    """Retry only a lost connection, up to 5 times with 1/2/4/8/15 s backoff; a session that lasted 10 s or more
    earns a fresh budget. Pure and deterministic, like the Mac's and Android's."""

    def __init__(self, delays: tuple[float, ...] = (1, 2, 4, 8, 15), fresh_budget_after: float = 10.0) -> None:
        self.delays = delays
        self.fresh_budget_after = fresh_budget_after
        self._used = 0

    @property
    def max_attempts(self) -> int:
        return len(self.delays)

    def on_ended(self, end: SessionEnd, connected_seconds: float) -> Retry | None:
        """None means give up."""
        if end is not SessionEnd.CONNECTION_LOST:
            return None
        if connected_seconds >= self.fresh_budget_after:
            self._used = 0
        if self._used >= self.max_attempts:
            return None
        delay = self.delays[self._used]
        self._used += 1
        return Retry(float(delay), self._used, self.max_attempts)

    def reset(self) -> None:
        self._used = 0
