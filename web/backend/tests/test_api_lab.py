"""The API's host-key trust and key sign-in against the integration lab's real sshd (`tools/lab up`, then
`eval "$(tools/lab env)"`); skipped without it. The lab is the only server this may change: the generated-key test
adds its public key to rk's authorized_keys for the duration of the test and removes it again."""

from __future__ import annotations

import base64
import json
import os
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from rackoon.app.api import create_app
from rackoon.app.settings import Settings
from rackoon.ssh import AsyncSSHTransport, HostKey, KnownHosts, SSHAuth, SSHEndpoint

PASSWORD = "a long admin password"


def lab_env() -> dict[str, str]:
    env = os.environ
    if env.get("RACKOON_LAB") != "1":
        pytest.skip('integration lab not configured (tools/lab up, then eval "$(tools/lab env)")')
    return {k: env[k] for k in ("RACKOON_LAB_HOST", "RACKOON_LAB_PORT", "RACKOON_LAB_USER", "RACKOON_LAB_KEY",
                                "RACKOON_LAB_KNOWN_HOSTS")}


@pytest.fixture
def lab() -> dict[str, str]:
    return lab_env()


@pytest.fixture
def api(tmp_path: Path) -> Iterator[TestClient]:
    with TestClient(create_app(Settings(data_dir=tmp_path / "data")), base_url="https://rackoon.test") as client:
        token = client.app.state.rackoon.setup_token.value  # type: ignore[attr-defined]
        r = client.post("/api/auth/setup", json={"token": token, "password": PASSWORD})
        client.headers["X-Rackoon-CSRF"] = r.json()["csrf"]
        yield client


def lab_host_key(lab: dict[str, str]) -> HostKey:
    line = next(ln for ln in Path(lab["RACKOON_LAB_KNOWN_HOSTS"]).read_text().splitlines()
                if ln.strip() and not ln.startswith("#"))
    return HostKey.from_known_hosts_line(line)[2]


def add_lab_server(api: TestClient, lab: dict[str, str], key_id: str) -> dict[str, Any]:
    r = api.post("/api/servers", json={"name": "lab", "host": lab["RACKOON_LAB_HOST"], "user": lab["RACKOON_LAB_USER"],
                                       "port": int(lab["RACKOON_LAB_PORT"]), "keyId": key_id})
    assert r.status_code == 201, r.text
    server: dict[str, Any] = r.json()
    return server


def trust_lab(api: TestClient, server: dict[str, Any], lab: dict[str, str]) -> None:
    first = api.post(f"/api/servers/{server['id']}/check").json()
    assert first["status"] == "hostKeyUnknown", first
    assert first["hostKey"]["fingerprint"] == lab_host_key(lab).fingerprint, "the scanned key is the lab's"
    r = api.post(f"/api/servers/{server['id']}/host-key/trust",
                 json={"scanId": first["scanId"], "fingerprint": first["hostKey"]["fingerprint"]})
    assert r.status_code == 200, r.text


def test_lab_trust_then_sign_in_then_changed_key_blocked(api: TestClient, lab: dict[str, str],
                                                         tmp_path: Path) -> None:
    key = api.post("/api/keys/import", json={"name": "lab", "privateKey": Path(lab["RACKOON_LAB_KEY"]).read_text()})
    assert key.status_code == 201, key.text
    server = add_lab_server(api, lab, key.json()["id"])
    trust_lab(api, server, lab)
    assert api.post(f"/api/servers/{server['id']}/check").json()["status"] == "ok"

    # Someone swaps the server's key (simulated by changing what is trusted): blocked, never offered.
    path = tmp_path / "data" / "known_hosts.json"
    known = json.loads(path.read_text())
    entry = known[f"{lab['RACKOON_LAB_HOST']}:{lab['RACKOON_LAB_PORT']}"]
    other = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20" + bytes(32)  # a valid Ed25519 blob, not the lab's
    entry["key"] = base64.b64encode(other).decode()
    path.write_text(json.dumps(known))
    restarted = TestClient(create_app(Settings(data_dir=tmp_path / "data")), base_url="https://rackoon.test")
    r = restarted.post("/api/auth/login", json={"password": PASSWORD})
    restarted.headers["X-Rackoon-CSRF"] = r.json()["csrf"]
    changed = restarted.post(f"/api/servers/{server['id']}/check").json()
    assert changed["status"] == "hostKeyChanged" and "scanId" not in changed, changed
    assert changed["hostKey"]["fingerprint"] == lab_host_key(lab).fingerprint
    scan = restarted.post(f"/api/servers/{server['id']}/host-key/scan").json()
    assert scan["status"] == "hostKeyChanged" and "scanId" not in scan


async def _authorized_keys(lab: dict[str, str], edit: str) -> None:
    known = KnownHosts()
    known.trust(lab["RACKOON_LAB_HOST"], int(lab["RACKOON_LAB_PORT"]), lab_host_key(lab))
    endpoint = SSHEndpoint(lab["RACKOON_LAB_HOST"], lab["RACKOON_LAB_USER"],
                           SSHAuth.key(Path(lab["RACKOON_LAB_KEY"]).read_text()), int(lab["RACKOON_LAB_PORT"]))
    async with AsyncSSHTransport(endpoint, known) as t:
        result = await t.run(edit, timeout=15)
        assert result.exit_code == 0, result.stderr


def test_lab_sign_in_with_a_generated_key(api: TestClient, lab: dict[str, str]) -> None:
    import asyncio
    generated = api.post("/api/keys/generate", json={"name": "lab generated"}).json()
    server = add_lab_server(api, lab, generated["id"])
    trust_lab(api, server, lab)
    assert api.post(f"/api/servers/{server['id']}/check").json()["status"] == "authFailed", "not authorized yet"
    line = generated["publicKey"]
    marker = generated["fingerprint"]
    add = f"printf '%s # {marker}\\n' '{line}' >> ~/.ssh/authorized_keys"
    remove = f"grep -vF '# {marker}' ~/.ssh/authorized_keys > ~/.ssh/ak.tmp; cat ~/.ssh/ak.tmp > ~/.ssh/authorized_keys; rm ~/.ssh/ak.tmp"
    asyncio.run(_authorized_keys(lab, add))
    try:
        assert api.post(f"/api/servers/{server['id']}/check").json()["status"] == "ok"
    finally:
        asyncio.run(_authorized_keys(lab, remove))
    assert api.post(f"/api/servers/{server['id']}/check").json()["status"] == "authFailed", "removed again"


def test_lab_terminal_over_the_websocket(api: TestClient, lab: dict[str, str]) -> None:
    """A real shell on the lab's sshd, through the API and its WebSocket: typing, a highlighted IP, a resize the
    shell sees, and exit ending the tab."""
    import json as jsonlib
    import time
    key = api.post("/api/keys/import", json={"name": "lab", "privateKey": Path(lab["RACKOON_LAB_KEY"]).read_text()})
    server = add_lab_server(api, lab, key.json()["id"])
    trust_lab(api, server, lab)
    api.put("/api/safety", json={"readOnly": False})
    tab = api.post(f"/api/servers/{server['id']}/terminals", json={"cols": 100, "rows": 30}).json()

    def until(ws: Any, needle: str) -> str:
        seen, deadline = "", time.monotonic() + 20
        while needle not in seen:
            assert time.monotonic() < deadline, seen[-500:]
            m = ws.receive()
            if m.get("bytes") is not None:
                seen += m["bytes"].decode("utf-8", "replace")
            elif m.get("text") is not None:
                seen += f"<<{jsonlib.loads(m['text']).get('state', '')}>>"
        return seen

    # What a browser sends with the upgrade: this page's Origin and the session cookie. (The test client's sockets
    # always go to "testserver", so the cookie set for rackoon.test is passed by hand.)
    headers = {"origin": "https://testserver", "cookie": f"__Host-rackoon={api.cookies.get('__Host-rackoon')}"}
    with api.websocket_connect(f"/api/terminals/{tab['id']}/ws", headers=headers) as ws:
        until(ws, "<<connected>>")
        ws.send_bytes(b"echo rk-$((6*7)) at 10.20.30.40 here\r")
        # Typed echo is never coloured, so this only appears in the command's output, highlighted.
        out = until(ws, "rk-42 at \x1b[35m10.20.30.40\x1b[39m here")
        assert "rk-42" in out
        ws.send_text(jsonlib.dumps({"type": "resize", "cols": 120, "rows": 40}))
        ws.send_bytes(b"stty size\r")
        assert "40 120" in until(ws, "40 120")
        ws.send_bytes(b"exit 3\r")
        assert "<<exited>>" in until(ws, "<<exited>>")
    tabs = api.get(f"/api/servers/{server['id']}/terminals").json()
    assert tabs[0]["state"] == "exited" and tabs[0]["exitCode"] == 3
