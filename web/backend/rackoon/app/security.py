"""Signing in to the web app. Single user ("admin"):

- The password is kept only as an argon2id hash: from RACKOON_ADMIN_PASSWORD_FILE (the password itself, hashed in
  memory at start, or an `$argon2id$` hash), or set once through the setup page with a one-time token printed to the
  log at start (and written to <data>/setup-token, mode 0600) while no password exists.
- Optional TOTP (RFC 6238: SHA-1, 6 digits, 30 s steps, one step of clock drift, a code works once).
- Sessions live in memory (a restart signs everyone out): a random cookie value, stored only as its SHA-256, with a
  CSRF token, a 12 h idle and 7 day absolute limit.
- Failed sign-ins are limited per client address and in total.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import secrets
import struct
import time
import urllib.parse
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError

Clock = Callable[[], float]

MIN_PASSWORD_LENGTH = 12
SESSION_IDLE_SECONDS = 12 * 3600
SESSION_MAX_SECONDS = 7 * 24 * 3600
MAX_SESSIONS = 20

_hasher = PasswordHasher()  # argon2id with the library's current recommended parameters


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(hashed: str, password: str) -> bool:
    try:
        return _hasher.verify(hashed, password)
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        return False


def password_problem(password: str) -> str | None:
    if len(password) < MIN_PASSWORD_LENGTH:
        return f"Use at least {MIN_PASSWORD_LENGTH} characters."
    if "\0" in password:
        return "The password can't contain a NUL character."
    return None


def password_from_file(path: Path) -> str:
    """The admin password file: the password (one line), or an argon2id hash of it. Returns a hash."""
    text = path.read_text(encoding="utf-8").rstrip("\r\n")
    if text.startswith("$argon2id$"):
        return text
    if not text:
        raise ValueError(f"{path} is empty")
    return hash_password(text)


# --- TOTP ---------------------------------------------------------------------------------------------------------


def new_totp_secret() -> str:
    return base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")


def totp_code(secret: str, counter: int, digits: int = 6) -> str:
    key = base64.b32decode(secret.upper() + "=" * (-len(secret) % 8))
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    value = struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF
    return str(value % 10**digits).zfill(digits)


def totp_uri(secret: str, account: str = "admin", issuer: str = "Rackoon") -> str:
    label = urllib.parse.quote(f"{issuer}:{account}")
    query = urllib.parse.urlencode({"secret": secret, "issuer": issuer, "algorithm": "SHA1", "digits": 6, "period": 30})
    return f"otpauth://totp/{label}?{query}"


def totp_match(secret: str, code: str, now: float, last_counter: int | None) -> int | None:
    """The time step `code` belongs to (now, one before or one after), or None. A step at or before `last_counter`
    is refused, so a code can't be replayed."""
    code = code.strip().replace(" ", "")
    if len(code) != 6 or not code.isdigit():
        return None
    current = int(now // 30)
    for counter in (current - 1, current, current + 1):
        if last_counter is not None and counter <= last_counter:
            continue
        if hmac.compare_digest(totp_code(secret, counter), code):
            return counter
    return None


# --- Rate limiting ------------------------------------------------------------------------------------------------


@dataclass
class RateLimiter:
    """At most `per_client` failures per address and `total` failures overall in a sliding `window`."""

    per_client: int = 5
    total: int = 50
    window: float = 15 * 60
    clock: Clock = time.monotonic
    _failures: dict[str, list[float]] = field(default_factory=dict)

    def _recent(self, key: str) -> list[float]:
        cutoff = self.clock() - self.window
        kept = [t for t in self._failures.get(key, []) if t > cutoff]
        if kept:
            self._failures[key] = kept
        else:
            self._failures.pop(key, None)
        return kept

    def retry_after(self, client: str) -> float | None:
        """Seconds to wait before trying again, or None when a try is allowed."""
        for key, limit in ((f"client:{client}", self.per_client), ("total", self.total)):
            recent = self._recent(key)
            if len(recent) >= limit:
                return max(1.0, recent[0] + self.window - self.clock())
        return None

    def failed(self, client: str) -> None:
        now = self.clock()
        for key in (f"client:{client}", "total"):
            self._failures.setdefault(key, []).append(now)

    def succeeded(self, client: str) -> None:
        self._failures.pop(f"client:{client}", None)


# --- Sessions -----------------------------------------------------------------------------------------------------


@dataclass
class Session:
    user: str
    csrf: str
    created: float
    last_seen: float


@dataclass
class SessionStore:
    clock: Clock = time.time
    _sessions: dict[str, Session] = field(default_factory=dict)

    @staticmethod
    def _key(token: str) -> str:
        return hashlib.sha256(token.encode()).hexdigest()

    def create(self, user: str) -> tuple[str, Session]:
        now = self.clock()
        token = secrets.token_urlsafe(32)
        session = Session(user, secrets.token_urlsafe(32), now, now)
        self._sessions[self._key(token)] = session
        if len(self._sessions) > MAX_SESSIONS:
            oldest = min(self._sessions, key=lambda k: self._sessions[k].last_seen)
            del self._sessions[oldest]
        return token, session

    def get(self, token: str | None) -> Session | None:
        if not token:
            return None
        key = self._key(token)
        session = self._sessions.get(key)
        if session is None:
            return None
        now = self.clock()
        if now - session.last_seen > SESSION_IDLE_SECONDS or now - session.created > SESSION_MAX_SECONDS:
            del self._sessions[key]
            return None
        session.last_seen = now
        return session

    def end(self, token: str | None) -> None:
        if token:
            self._sessions.pop(self._key(token), None)

    def end_all(self) -> None:
        self._sessions.clear()


# --- The admin account --------------------------------------------------------------------------------------------


class Account:
    """The password and TOTP state, persisted through `save` (auth.json) unless the password comes from a file."""

    def __init__(self, state: dict[str, Any], save: Callable[[dict[str, Any]], None],
                 managed_hash: str | None = None) -> None:
        self._state = dict(state)
        self._save = save
        self._managed_hash = managed_hash

    @property
    def password_managed(self) -> bool:
        """The password comes from RACKOON_ADMIN_PASSWORD_FILE and can't be set or changed here."""
        return self._managed_hash is not None

    @property
    def password_hash(self) -> str | None:
        return self._managed_hash or self._state.get("passwordHash")

    @property
    def needs_setup(self) -> bool:
        return self.password_hash is None

    @property
    def totp_enabled(self) -> bool:
        return bool(self._state.get("totpSecret"))

    def check(self, password: str, code: str | None, now: float) -> bool:
        """Password and, when TOTP is on, a fresh code. Both are always checked, so a failure says nothing about
        which one was wrong."""
        hashed = self.password_hash
        ok = hashed is not None and verify_password(hashed, password)
        if self.totp_enabled:
            counter = totp_match(self._state["totpSecret"], code or "", now, self._state.get("totpLastCounter"))
            if ok and counter is not None:
                self._state["totpLastCounter"] = counter
                self._save(self._state)
            return ok and counter is not None
        return ok

    def set_password(self, password: str) -> None:
        if self.password_managed:
            raise PermissionError("the password is set by RACKOON_ADMIN_PASSWORD_FILE")
        self._state["passwordHash"] = hash_password(password)
        self._save(self._state)

    def begin_totp(self) -> str:
        secret = new_totp_secret()
        self._state["totpPending"] = secret
        self._save(self._state)
        return secret

    def enable_totp(self, code: str, now: float) -> bool:
        pending = self._state.get("totpPending")
        if not pending:
            return False
        counter = totp_match(pending, code, now, None)
        if counter is None:
            return False
        self._state.update(totpSecret=pending, totpLastCounter=counter, totpPending=None)
        self._save(self._state)
        return True

    def disable_totp(self) -> None:
        self._state.update(totpSecret=None, totpLastCounter=None, totpPending=None)
        self._save(self._state)


class SetupToken:
    """The one-time token that lets the first visitor set the password. Lives until a password is set."""

    def __init__(self) -> None:
        self.value: str | None = secrets.token_urlsafe(18)

    def matches(self, candidate: str) -> bool:
        return self.value is not None and hmac.compare_digest(self.value.encode(), candidate.strip().encode())

    def used(self) -> None:
        self.value = None
