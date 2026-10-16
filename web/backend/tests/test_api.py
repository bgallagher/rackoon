"""The HTTP API without a network: signing in (setup token, password file, TOTP, rate limit, sessions, CSRF, origin,
forward auth), saved servers, ssh_config import, host-key trust (with a fake scanner) and keys."""

from __future__ import annotations

import json
import stat
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import asyncssh
import pytest
from fastapi.testclient import TestClient

from rackoon.app import security
from rackoon.app.api import COOKIE, create_app
from rackoon.app.settings import Settings
from rackoon.ssh import HostKey

PASSWORD = "a long admin password"
KEY_A = HostKey("ssh-ed25519", b"\x01" * 51)
KEY_B = HostKey("ssh-ed25519", b"\x02" * 51)


class FakeScanner:
    def __init__(self) -> None:
        self.key = KEY_A

    async def __call__(self, host: str, port: int) -> HostKey:
        return self.key


def client_for(settings: Settings, scanner: FakeScanner | None = None, peer: str = "203.0.113.9") -> TestClient:
    app = create_app(settings, scanner=scanner or FakeScanner(), poll=False)
    return TestClient(app, base_url="https://rackoon.test", client=(peer, 40000))


def setup_token(client: TestClient) -> str:
    token = client.app.state.rackoon.setup_token.value  # type: ignore[attr-defined]
    assert isinstance(token, str)
    return token


def signed_in(client: TestClient) -> TestClient:
    r = client.post("/api/auth/setup", json={"token": setup_token(client), "password": PASSWORD})
    assert r.status_code == 200, r.text
    client.headers["X-Rackoon-CSRF"] = r.json()["csrf"]
    return client


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(data_dir=tmp_path / "data")


@pytest.fixture
def api(settings: Settings) -> Iterator[TestClient]:
    with signed_in(client_for(settings)) as c:
        yield c


def add(api: TestClient, **fields: Any) -> dict[str, Any]:
    r = api.post("/api/servers", json={"name": "vps", "host": "vps.example.com", **fields})
    assert r.status_code == 201, r.text
    result: dict[str, Any] = r.json()
    return result


# --- signing in ---------------------------------------------------------------------------------------------------


def test_setup_needs_the_token_and_a_strong_password(settings: Settings) -> None:
    client = client_for(settings)
    token_file = settings.data_dir / "setup-token"
    assert token_file.read_text().strip() == setup_token(client)
    assert stat.S_IMODE(token_file.stat().st_mode) == 0o600
    assert client.get("/api/auth/state").json()["setupRequired"] is True
    assert client.get("/api/servers").status_code == 401
    assert client.post("/api/auth/login", json={"password": PASSWORD}).json()["error"] == "setupRequired"
    assert client.post("/api/auth/setup", json={"token": "guess", "password": PASSWORD}).status_code == 403
    assert client.post("/api/auth/setup", json={"token": setup_token(client), "password": "short"}).status_code == 422
    r = client.post("/api/auth/setup", json={"token": setup_token(client), "password": PASSWORD})
    assert r.status_code == 200
    cookie = r.headers["set-cookie"]
    assert cookie.startswith(f"{COOKIE}=")
    for flag in ("HttpOnly", "Secure", "SameSite=strict", "Path=/"):
        assert flag.lower() in cookie.lower(), flag
    assert "domain=" not in cookie.lower(), "__Host- cookies have no Domain"
    assert not token_file.exists(), "the token is gone once used"
    assert client.post("/api/auth/setup", json={"token": "x", "password": PASSWORD}).status_code == 409
    auth = json.loads((settings.data_dir / "auth.json").read_text())
    assert auth["passwordHash"].startswith("$argon2id$") and PASSWORD not in json.dumps(auth)
    # A restart keeps the password and prints no new token.
    again = client_for(settings)
    assert again.app.state.rackoon.setup_token is None  # type: ignore[attr-defined]
    assert again.post("/api/auth/login", json={"password": PASSWORD}).status_code == 200


def test_login_logout_and_rate_limit(api: TestClient, settings: Settings) -> None:
    client = client_for(settings, peer="198.51.100.7")
    for _ in range(5):
        assert client.post("/api/auth/login", json={"password": "wrong password!"}).status_code == 401
    r = client.post("/api/auth/login", json={"password": PASSWORD})
    assert r.status_code == 429 and int(r.headers["retry-after"]) > 0, "even the right password waits"
    other = client_for(settings, peer="198.51.100.8")
    # A new app instance has its own counters; within one instance another address is not blocked.
    assert other.post("/api/auth/login", json={"password": PASSWORD}).status_code == 200
    assert api.get("/api/servers").status_code == 200
    assert api.post("/api/auth/logout").status_code == 200
    assert api.get("/api/servers").status_code == 401


def test_changes_need_csrf_same_origin_and_json(api: TestClient) -> None:
    csrf = api.headers.pop("X-Rackoon-CSRF")
    body = {"name": "vps", "host": "vps.example.com"}
    assert api.post("/api/servers", json=body).json()["error"] == "csrf"
    assert api.post("/api/servers", json=body, headers={"X-Rackoon-CSRF": "forged"}).status_code == 403
    assert api.get("/api/servers").status_code == 200, "reads need no token"
    api.headers["X-Rackoon-CSRF"] = csrf
    r = api.post("/api/servers", json=body, headers={"Origin": "https://evil.example"})
    assert r.status_code == 403 and r.json()["error"] == "crossOrigin"
    r = api.post("/api/servers", content="name=x", headers={"Content-Type": "application/x-www-form-urlencoded"})
    assert r.status_code == 415
    r = api.post("/api/servers", json=body, headers={"Origin": "https://rackoon.test"})
    assert r.status_code == 201
    assert api.get("/api/auth/state").json()["csrf"] == csrf
    for header in ("x-content-type-options", "x-frame-options", "referrer-policy"):
        assert header in r.headers
    assert r.headers["cache-control"] == "no-store"


def test_password_file_manages_the_password(tmp_path: Path) -> None:
    secret = tmp_path / "admin-password"
    secret.write_text("from a docker secret\n")
    client = client_for(Settings(data_dir=tmp_path / "data", admin_password_file=secret))
    state = client.get("/api/auth/state").json()
    assert state["setupRequired"] is False and state["passwordManaged"] is True
    assert not (tmp_path / "data" / "setup-token").exists()
    r = client.post("/api/auth/login", json={"password": "from a docker secret"})
    assert r.status_code == 200
    client.headers["X-Rackoon-CSRF"] = r.json()["csrf"]
    r = client.post("/api/auth/password", json={"current": "from a docker secret", "new": "another long password"})
    assert r.status_code == 409


def test_change_password_signs_other_sessions_out(api: TestClient, settings: Settings) -> None:
    other = TestClient(api.app, base_url="https://rackoon.test", client=("203.0.113.10", 1))  # the same instance
    r = other.post("/api/auth/login", json={"password": PASSWORD})
    assert r.status_code == 200
    r = api.post("/api/auth/password", json={"current": "wrong", "new": "another long password"})
    assert r.status_code == 403
    r = api.post("/api/auth/password", json={"current": PASSWORD, "new": "another long password"})
    assert r.status_code == 200
    api.headers["X-Rackoon-CSRF"] = r.json()["csrf"]
    assert api.get("/api/servers").status_code == 200, "this browser stays signed in"
    assert other.get("/api/servers").status_code == 401


def test_totp_enrol_sign_in_and_disable(settings: Settings) -> None:
    now = [1_800_000_000.0]
    app = create_app(settings, scanner=FakeScanner(), clock=lambda: now[0], poll=False)
    api = signed_in(TestClient(app, base_url="https://rackoon.test", client=("203.0.113.9", 1)))
    secret = api.post("/api/auth/totp/setup").json()["secret"]
    step = int(now[0] // 30)
    window = {security.totp_code(secret, step + d) for d in (-1, 0, 1)}
    wrong = next(c for c in (f"{n:06d}" for n in range(1000)) if c not in window)
    assert api.post("/api/auth/totp/enable", json={"code": wrong}).status_code == 422
    assert api.get("/api/auth/state").json()["totpEnabled"] is False
    assert api.post("/api/auth/totp/enable", json={"code": security.totp_code(secret, step)}).status_code == 200
    assert api.get("/api/auth/state").json()["totpEnabled"] is True
    api.post("/api/auth/logout")
    assert api.post("/api/auth/login", json={"password": PASSWORD}).status_code == 401
    now[0] += 30
    code = security.totp_code(secret, step + 1)
    r = api.post("/api/auth/login", json={"password": PASSWORD, "code": code})
    assert r.status_code == 200
    api.headers["X-Rackoon-CSRF"] = r.json()["csrf"]
    assert api.post("/api/auth/login", json={"password": PASSWORD, "code": code}).status_code == 401, "no replay"
    assert api.post("/api/auth/totp/disable", json={"password": PASSWORD, "code": code}).status_code == 403
    now[0] += 30
    r = api.post("/api/auth/totp/disable", json={"password": PASSWORD, "code": security.totp_code(secret, step + 2)})
    assert r.status_code == 200 and api.get("/api/auth/state").json()["totpEnabled"] is False
    assert api.post("/api/auth/logout").status_code == 200
    assert api.post("/api/auth/login", json={"password": PASSWORD}).status_code == 200


def test_forward_auth_only_from_trusted_proxies(tmp_path: Path) -> None:
    settings = Settings(data_dir=tmp_path / "data", trusted_proxies=[__import__("ipaddress").ip_network("10.0.0.0/8")],
                        forward_auth_header="Remote-User", forward_auth_users=frozenset({"me"}))
    untrusted = client_for(settings, peer="203.0.113.9")
    assert untrusted.get("/api/servers", headers={"Remote-User": "me"}).status_code == 401
    proxy = client_for(settings, peer="10.1.2.3")
    proxy.headers["Remote-User"] = "me"
    state = proxy.get("/api/auth/state").json()
    assert state["authenticated"] and state["via"] == "forwardAuth" and state["user"] == "me"
    assert proxy.get("/api/servers").status_code == 200
    body = {"name": "vps", "host": "vps.example.com"}
    assert proxy.post("/api/servers", json=body).status_code == 403, "still needs the CSRF token"
    assert proxy.post("/api/servers", json=body, headers={"X-Rackoon-CSRF": state["csrf"]}).status_code == 201
    assert proxy.get("/api/servers", headers={"Remote-User": "someone-else"}).status_code == 401


def test_rate_limit_uses_the_forwarded_address_only_from_trusted_proxies(tmp_path: Path) -> None:
    import ipaddress
    settings = Settings(data_dir=tmp_path / "data", trusted_proxies=[ipaddress.ip_network("10.0.0.0/8")])
    client = client_for(settings, peer="10.0.0.2")
    signed_in(client)
    for _ in range(5):
        client.post("/api/auth/login", json={"password": "wrong password!"}, headers={"X-Forwarded-For": "1.1.1.1"})
    assert client.post("/api/auth/login", json={"password": PASSWORD},
                       headers={"X-Forwarded-For": "1.1.1.1"}).status_code == 429
    assert client.post("/api/auth/login", json={"password": PASSWORD},
                       headers={"X-Forwarded-For": "2.2.2.2"}).status_code == 200
    direct = TestClient(client.app, base_url="https://rackoon.test", client=("203.0.113.5", 1))
    for _ in range(5):
        direct.post("/api/auth/login", json={"password": "wrong password!"}, headers={"X-Forwarded-For": "3.3.3.3"})
    assert direct.post("/api/auth/login", json={"password": PASSWORD},
                       headers={"X-Forwarded-For": "4.4.4.4"}).status_code == 429, "spoofed header ignored"


# --- servers ------------------------------------------------------------------------------------------------------


def test_servers_add_edit_reorder_remove(api: TestClient, settings: Settings) -> None:
    for bad in ({"host": "-oProxyCommand=evil"}, {"host": "has space"}, {"user": "-x"}, {"port": 70000},
                {"name": "   "}, {"keyId": "NOPE"}):
        r = api.post("/api/servers", json={"name": "x", "host": "vps.example.com", **bad})
        assert r.status_code == 422, bad
    first = add(api, user="root", port=2222)
    assert first["keyId"] is None and first["user"] == "root" and first["port"] == 2222
    second = add(api, name="nas", host="nas.lan")
    assert [s["name"] for s in api.get("/api/servers").json()] == ["vps", "nas"]
    r = api.put("/api/servers/order", json={"ids": [second["id"], first["id"]]})
    assert [s["name"] for s in r.json()] == ["nas", "vps"]
    assert api.put("/api/servers/order", json={"ids": [first["id"]]}).status_code == 422

    store = api.app.state.rackoon.store  # type: ignore[attr-defined]
    from rackoon.core import overview
    from .support import out
    store.save_snapshot(first["id"], overview.parse(out("overview", "ubuntu-24.04")))
    r = api.put(f"/api/servers/{first['id']}", json={"name": "renamed", "host": "vps.example.com", "user": "root",
                                                     "port": 2222})
    assert r.json()["name"] == "renamed"
    assert store.load_snapshot(first["id"]) is not None, "a rename keeps the cached reading"
    api.put(f"/api/servers/{first['id']}", json={"name": "renamed", "host": "new.example.com"})
    assert store.load_snapshot(first["id"]) is None, "a new address drops it"
    assert api.delete(f"/api/servers/{second['id']}").status_code == 200
    assert api.get(f"/api/servers/{second['id']}").status_code == 404
    saved = json.loads((settings.data_dir / "servers.json").read_text())
    assert [s["name"] for s in saved] == ["renamed"] and "keyId" not in saved[0]


def test_ssh_config_import(api: TestClient, tmp_path: Path) -> None:
    ssh = tmp_path / "ssh"
    ssh.mkdir()
    key = asyncssh.generate_private_key("ssh-ed25519")
    (ssh / "id_lab").write_bytes(key.export_private_key("openssh"))
    locked = asyncssh.generate_private_key("ssh-ed25519")
    (ssh / "id_locked").write_bytes(locked.export_private_key("openssh", passphrase="p"))
    (ssh / "config").write_text("""
Host lab
  HostName 127.0.0.1
  Port 2222
  User rk
  IdentityFile ~/.ssh/id_lab
Host lab-again
  HostName 127.0.0.1
  Port 2222
  User rk
  IdentityFile ~/.ssh/id_lab
Host locked
  HostName locked.lan
  IdentityFile ~/.ssh/id_locked
Host escape
  HostName escape.lan
  IdentityFile /etc/passwd
Host jumpy
  HostName 10.0.0.9
  ProxyJump bastion
""")
    api.app.state.rackoon.settings = Settings(data_dir=api.app.state.rackoon.settings.data_dir,  # type: ignore[attr-defined]
                                              ssh_config=ssh / "config")
    listing = api.get("/api/ssh-config").json()
    by_alias = {h["alias"]: h for h in listing["hosts"]}
    assert by_alias["lab"]["keyFile"] == "id_lab" and by_alias["lab"]["supported"]
    assert by_alias["escape"]["keyFile"] is None, "only files inside the mounted folder"
    assert by_alias["jumpy"]["supported"] is False and "ProxyJump" in by_alias["jumpy"]["note"]
    r = api.post("/api/ssh-config/import", json={"aliases": ["lab", "lab-again", "locked", "jumpy", "nope"]})
    assert r.status_code == 201
    added = {s["name"]: s for s in r.json()["added"]}
    assert set(added) == {"lab", "locked"}
    lab = added["lab"]
    assert (lab["host"], lab["port"], lab["user"], lab["sshConfigAlias"]) == ("127.0.0.1", 2222, "rk", "lab")
    assert lab["keyId"] is not None and added["locked"]["keyId"] is None
    notes = " ".join(r.json()["notes"])
    assert "lab-again: already added" in notes and "ProxyJump" in notes and "passphrase" in notes and "nope" in notes
    keys = api.get("/api/keys").json()
    assert [k["fingerprint"] for k in keys] == [HostKey.from_asyncssh(key).fingerprint]
    assert api.get("/api/ssh-config").json()["hosts"][0]["alreadyAdded"] is True


def test_no_ssh_config_mounted(api: TestClient) -> None:
    assert api.get("/api/ssh-config").json()["error"] == "noSSHConfig"


# --- host keys ----------------------------------------------------------------------------------------------------


def test_host_key_trust_only_the_scanned_fingerprint(settings: Settings) -> None:
    scanner = FakeScanner()
    with signed_in(client_for(settings, scanner)) as api:
        server = add(api)
        scan = api.post(f"/api/servers/{server['id']}/host-key/scan").json()
        assert scan["status"] == "hostKeyUnknown" and scan["hostKey"]["fingerprint"] == KEY_A.fingerprint
        trust = f"/api/servers/{server['id']}/host-key/trust"
        assert api.post(trust, json={"scanId": scan["scanId"], "fingerprint": KEY_B.fingerprint}).json()["error"] == \
            "fingerprintMismatch"
        assert api.post(trust, json={"scanId": "forged", "fingerprint": KEY_A.fingerprint}).status_code == 409
        r = api.post(trust, json={"scanId": scan["scanId"], "fingerprint": KEY_A.fingerprint})
        assert r.status_code == 200 and r.json()["trusted"]["fingerprint"] == KEY_A.fingerprint
        assert api.post(trust, json={"scanId": scan["scanId"], "fingerprint": KEY_A.fingerprint}).status_code == 409, \
            "a scan is used once"
        known = json.loads((settings.data_dir / "known_hosts.json").read_text())
        assert known["vps.example.com:22"]["fingerprint"] == KEY_A.fingerprint
        assert api.post(f"/api/servers/{server['id']}/host-key/scan").json()["status"] == "ok"

        scanner.key = KEY_B  # the server now shows another key
        changed = api.post(f"/api/servers/{server['id']}/host-key/scan").json()
        assert changed["status"] == "hostKeyChanged" and "scanId" not in changed, "never offered for acceptance"
        assert changed["trusted"]["fingerprint"] == KEY_A.fingerprint


def test_a_scan_is_for_one_server_and_address(settings: Settings) -> None:
    with signed_in(client_for(settings)) as api:
        a = add(api)
        b = add(api, name="other", host="other.example.com")
        scan = api.post(f"/api/servers/{a['id']}/host-key/scan").json()
        r = api.post(f"/api/servers/{b['id']}/host-key/trust",
                     json={"scanId": scan["scanId"], "fingerprint": KEY_A.fingerprint})
        assert r.status_code == 409
        api.put(f"/api/servers/{a['id']}", json={"name": "vps", "host": "moved.example.com"})
        r = api.post(f"/api/servers/{a['id']}/host-key/trust",
                     json={"scanId": scan["scanId"], "fingerprint": KEY_A.fingerprint})
        assert r.status_code == 409, "the address changed since the scan"


def test_a_different_trusted_key_is_never_replaced(settings: Settings) -> None:
    with signed_in(client_for(settings)) as api:
        server = add(api)
        scan = api.post(f"/api/servers/{server['id']}/host-key/scan").json()
        api.app.state.rackoon.store.known_hosts.trust("vps.example.com", 22, KEY_B)  # type: ignore[attr-defined]
        r = api.post(f"/api/servers/{server['id']}/host-key/trust",
                     json={"scanId": scan["scanId"], "fingerprint": KEY_A.fingerprint})
        assert r.status_code == 409 and r.json()["error"] == "hostKeyChanged"


# --- keys ---------------------------------------------------------------------------------------------------------


def test_keys_api(api: TestClient, settings: Settings) -> None:
    generated = api.post("/api/keys/generate", json={"name": "web"}).json()
    assert generated["keyType"] == "ssh-ed25519" and generated["publicKey"].startswith("ssh-ed25519 ")
    assert "privateKey" not in generated and "PRIVATE" not in json.dumps(api.get("/api/keys").json())
    rsa = asyncssh.generate_private_key("ssh-rsa", key_size=2048).export_private_key("pkcs8-pem").decode()
    imported = api.post("/api/keys/import", json={"name": "old", "privateKey": rsa})
    assert imported.status_code == 201 and imported.json()["keyType"] == "ssh-rsa"
    assert api.post("/api/keys/import", json={"name": "x", "privateKey": "nonsense"}).status_code == 422
    server = add(api, keyId=generated["id"])
    assert server["keyId"] == generated["id"]
    assert server["identityFile"] == str(settings.data_dir / "keys" / generated["id"])
    r = api.delete(f"/api/keys/{generated['id']}")
    assert r.status_code == 409 and "vps" in r.json()["message"]
    api.delete(f"/api/servers/{server['id']}")
    assert api.delete(f"/api/keys/{generated['id']}").status_code == 200
    assert api.delete(f"/api/keys/{generated['id']}").status_code == 404
    assert [k["name"] for k in api.get("/api/keys").json()] == ["old"]
