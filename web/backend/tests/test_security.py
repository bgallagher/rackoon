"""Passwords, TOTP, sessions and the sign-in rate limit, without HTTP."""

from __future__ import annotations

import base64
from pathlib import Path

import pytest

from rackoon.app import security
from rackoon.app.settings import Settings, SettingsError

# RFC 6238 appendix B, SHA-1: the secret is the ASCII "12345678901234567890".
RFC_SECRET = base64.b32encode(b"12345678901234567890").decode()


class Clock:
    def __init__(self, now: float = 1_800_000_000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


def test_totp_matches_rfc_6238_vectors() -> None:
    for t, code in ((59, "94287082"), (1111111109, "07081804"), (1111111111, "14050471"), (1234567890, "89005924"),
                    (2000000000, "69279037"), (20000000000, "65353130")):
        assert security.totp_code(RFC_SECRET, t // 30, digits=8) == code
    assert security.totp_code(RFC_SECRET, 59 // 30) == "287082"


def test_totp_allows_one_step_of_drift_and_no_replay() -> None:
    secret = security.new_totp_secret()
    now = 1_800_000_000.0
    current = int(now // 30)
    assert security.totp_match(secret, security.totp_code(secret, current), now, None) == current
    assert security.totp_match(secret, security.totp_code(secret, current - 1), now, None) == current - 1
    assert security.totp_match(secret, security.totp_code(secret, current + 1), now, None) == current + 1
    assert security.totp_match(secret, security.totp_code(secret, current - 2), now, None) is None
    assert security.totp_match(secret, security.totp_code(secret, current), now, current) is None, "replayed"
    assert security.totp_match(secret, "12345", now, None) is None
    assert security.totp_uri(secret).startswith("otpauth://totp/Rackoon%3Aadmin?secret=")


def test_passwords_are_argon2id() -> None:
    hashed = security.hash_password("correct horse battery")
    assert hashed.startswith("$argon2id$")
    assert security.verify_password(hashed, "correct horse battery")
    assert not security.verify_password(hashed, "wrong")
    assert not security.verify_password("not a hash", "x")
    assert security.password_problem("short") is not None
    assert security.password_problem("long enough password") is None


def test_password_file_holds_a_password_or_a_hash(tmp_path: Path) -> None:
    plain = tmp_path / "pw"
    plain.write_text("from a docker secret\n")
    assert security.verify_password(security.password_from_file(plain), "from a docker secret")
    hashed = tmp_path / "hash"
    hashed.write_text(security.hash_password("pre-hashed password") + "\n")
    assert security.verify_password(security.password_from_file(hashed), "pre-hashed password")
    empty = tmp_path / "empty"
    empty.write_text("\n")
    with pytest.raises(ValueError):
        security.password_from_file(empty)


def test_rate_limit_per_client_and_overall() -> None:
    clock = Clock(0)
    limiter = security.RateLimiter(per_client=3, total=5, window=60, clock=clock)
    for _ in range(3):
        assert limiter.retry_after("a") is None
        limiter.failed("a")
    wait = limiter.retry_after("a")
    assert wait is not None and 0 < wait <= 60
    assert limiter.retry_after("b") is None, "another address is not blocked by a's failures"
    limiter.failed("b")
    limiter.failed("c")
    assert limiter.retry_after("d") is not None, "five failures in total block everyone"
    clock.now = 61
    assert limiter.retry_after("a") is None and limiter.retry_after("d") is None, "the window slides"


def test_sessions_expire_when_idle_or_old() -> None:
    clock = Clock(0)
    sessions = security.SessionStore(clock=clock)
    token, session = sessions.create("admin")
    assert sessions.get(token) is session
    assert sessions.get("forged") is None
    clock.now = security.SESSION_IDLE_SECONDS + 1
    assert sessions.get(token) is None, "idle too long"
    clock.now = 0
    token, _ = sessions.create("admin")
    while clock.now + security.SESSION_IDLE_SECONDS < security.SESSION_MAX_SECONDS:
        clock.now += security.SESSION_IDLE_SECONDS - 1
        assert sessions.get(token) is not None, "kept alive by use"
    clock.now += security.SESSION_IDLE_SECONDS - 1
    assert clock.now > security.SESSION_MAX_SECONDS
    assert sessions.get(token) is None, "seven days at most, however active"
    token, _ = sessions.create("admin")
    sessions.end(token)
    assert sessions.get(token) is None


def test_account_checks_password_and_code_together() -> None:
    saved: dict[str, object] = {}
    account = security.Account({}, saved.update)
    assert account.needs_setup
    account.set_password("a long admin password")
    assert account.check("a long admin password", None, 1e9)
    secret = account.begin_totp()
    assert not account.totp_enabled, "pending until a code confirms it"
    now = 1_800_000_000.0
    assert account.enable_totp(security.totp_code(secret, int(now // 30)), now)
    later = now + 60
    code = security.totp_code(secret, int(later // 30))
    assert not account.check("a long admin password", None, later)
    assert not account.check("wrong password", code, later)
    assert account.check("a long admin password", code, later)
    assert not account.check("a long admin password", code, later), "a code works once"
    managed = security.Account({}, saved.update, security.hash_password("from file password"))
    assert managed.password_managed and not managed.needs_setup
    with pytest.raises(PermissionError):
        managed.set_password("something else entirely")


def test_setup_token_matches_once() -> None:
    token = security.SetupToken()
    assert token.value is not None and token.matches(f" {token.value}\n")
    assert not token.matches("guess")
    token.used()
    assert not token.matches("anything")


def test_settings_from_env(tmp_path: Path) -> None:
    s = Settings.from_env({"RACKOON_DATA": str(tmp_path), "RACKOON_TRUSTED_PROXIES": "10.0.0.0/8, ::1",
                           "RACKOON_FORWARD_AUTH_HEADER": "Remote-User", "RACKOON_FORWARD_AUTH_USERS": "me, you"})
    assert s.is_trusted_proxy("10.1.2.3") and s.is_trusted_proxy("::1")
    assert not s.is_trusted_proxy("192.168.1.1") and not s.is_trusted_proxy("testclient")
    assert s.forward_auth_users == {"me", "you"}
    with pytest.raises(SettingsError):
        Settings.from_env({"RACKOON_FORWARD_AUTH_HEADER": "Remote-User"})
    with pytest.raises(SettingsError):
        Settings.from_env({"RACKOON_TRUSTED_PROXIES": "not-a-network"})
