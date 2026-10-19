"""Stage W7's API in demo mode (nothing is sent anywhere): the Commands library (reads at once, changes with their dry
run, interactive ones as terminal tabs, the free-form box), Services (scan, show/hide, actions), Files (list, an upload
confirmed then sent with its one-use token, a short upload refused, downloads, new folder, rename, delete), Alerts (the
sweep, the baseline, seen and muted, ntfy and webhook delivery, Web Push keys and subscriptions) and Search."""

from __future__ import annotations

import base64
import hashlib
import hmac
import io
import json
import tarfile
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

from rackoon.app.api import create_app
from rackoon.app.settings import Settings
from rackoon.core import alerts
from rackoon.core.models import Severity

ORIGIN = {"origin": "https://testserver"}
LAB = "/api/servers/demo-homelab"


@pytest.fixture
def demo(tmp_path: Path) -> Iterator[TestClient]:
    app = create_app(Settings(data_dir=tmp_path / "unused", demo=True), poll=False)
    with TestClient(app, base_url="https://rackoon.test") as client:
        client.headers["X-Rackoon-CSRF"] = client.get("/api/auth/state").json()["csrf"]
        client.put("/api/safety", json={"readOnly": False})
        yield client


def rk(api: TestClient) -> Any:
    return api.app.state.rackoon  # type: ignore[attr-defined]


def confirm(api: TestClient, answer: dict[str, Any], typed: str | None = None) -> dict[str, Any]:
    assert "pending" in answer, answer
    r = api.post(f"/api/actions/{answer['pending']['id']}/confirm", json={"typed": typed} if typed else None)
    assert r.status_code == 200, r.text
    out: dict[str, Any] = r.json()["result"]
    return out


def follow(api: TestClient, run: dict[str, Any]) -> tuple[dict[str, Any], str]:
    text, state = "", run
    with api.websocket_connect(f"/api/runs/{run['id']}/ws", headers=ORIGIN) as ws:
        while True:
            try:
                m = ws.receive()
            except Exception:  # noqa: BLE001 - closed
                break
            if m.get("type") == "websocket.close":
                break
            if m.get("bytes") is not None:
                text += m["bytes"].decode()
            elif m.get("text") is not None:
                state = json.loads(m["text"])
    return state, text


# --- commands -----------------------------------------------------------------------------------------------------


def test_the_library_reads_at_once_and_changes_ask_with_their_dry_run(demo: TestClient) -> None:
    lib = demo.get("/api/commands").json()
    assert lib["groups"][0] == "Disk" and len(lib["commands"]) > 30
    ports = next(c for c in lib["commands"] if c["id"] == "listening_ports")
    assert ports["readable"] == "sudo ss -tulpn" and ports["root"]
    r = demo.post(f"{LAB}/commands/run", json={"id": "disk_usage"}).json()
    end, text = follow(demo, r["run"])
    assert end["phase"] == "succeeded" and end["scope"] == "command:disk_usage" and "Filesystem" in text
    prune = demo.post(f"{LAB}/commands/run", json={"id": "docker_prune"}).json()["pending"]
    assert prune["title"] == "Prune unused Docker data?" and prune["command"].endswith("docker system prune -f")
    assert "Volumes are kept" in prune["message"]
    end, _ = follow(demo, confirm(demo, {"pending": prune})["run"])
    assert end["phase"] == "succeeded"
    assert demo.post(f"{LAB}/commands/run", json={"id": "container_logs", "params": {"container": "a; b"}}).status_code \
        == 422
    tab = demo.post(f"{LAB}/commands/run", json={"id": "live_top"}).json()["tab"]
    assert tab["kind"] == "command" and tab["title"] == "Live processes (top)"
    custom = demo.post(f"{LAB}/commands/custom", json={"text": "uptime"}).json()["pending"]
    assert custom["command"] == "uptime" and custom["risk"] == "mutate"
    demo.post(f"/api/actions/{custom['id']}/cancel")
    demo.put("/api/safety", json={"readOnly": True})
    assert demo.post(f"{LAB}/commands/custom", json={"text": "uptime"}).json()["error"] == "readOnly"
    assert demo.post(f"{LAB}/commands/run", json={"id": "live_top"}).json()["error"] == "readOnly"
    assert "run" in demo.post(f"{LAB}/commands/run", json={"id": "memory"}).json(), "reads still run in Read-only"


# --- services -----------------------------------------------------------------------------------------------------


def test_services_scan_show_hide_and_act(demo: TestClient) -> None:
    s = demo.get(f"{LAB}/services").json()
    assert s["status"] == "ready"
    by = {x["id"]: x for x in s["services"]}
    failed = by["system/backup-sync.service"]
    assert failed["status"] == "failed" and failed["visible"] and failed["isProblem"] and "start" in failed["actions"]
    assert not by["system/ssh.service"]["visible"], "ssh is hidden by default"
    demo.put("/api/services/visibility", json={"serverId": "demo-homelab", "serviceId": "system/ssh.service",
                                               "visible": True})
    assert next(x for x in demo.get(f"{LAB}/services").json()["services"] if x["id"] == "system/ssh.service")["visible"]
    status = demo.post(f"{LAB}/services/action", json={"serviceId": failed["id"], "action": "status"}).json()
    assert follow(demo, status["run"])[0]["phase"] == "succeeded"
    start = demo.post(f"{LAB}/services/action", json={"serviceId": failed["id"], "action": "start"}).json()["pending"]
    assert "systemctl start 'backup-sync.service'" in start["command"] and start["title"] == "Start backup-sync?"
    assert demo.post(f"{LAB}/services/action", json={"serviceId": failed["id"], "action": "stop"}).status_code == 422
    tab = demo.post(f"{LAB}/services/follow", json={"serviceId": failed["id"]}).json()
    assert tab["kind"] == "command"


# --- files --------------------------------------------------------------------------------------------------------


def test_files_list_upload_download_and_change(demo: TestClient) -> None:
    home = demo.get(f"{LAB}/files/home").json()["path"]
    assert home == "/home/ubuntu"
    listing = demo.get(f"{LAB}/files/list", params={"path": home}).json()
    assert [e["name"] for e in listing["entries"]][:2] == ["backups", "notes"], "folders first"
    assert listing["crumbs"][-1] == {"name": "ubuntu", "path": home} and listing["parent"] == "/home"
    assert demo.get(f"{LAB}/files/list", params={"path": "/nope"}).status_code == 404

    up = demo.post(f"{LAB}/files/upload", json={"directory": home, "name": "hello.txt", "size": 5}).json()
    assert up["pending"]["title"] == "Upload hello.txt?" and ".hello.txt.rackoon-part" in up["pending"]["command"]
    token = confirm(demo, up)["upload"]
    bad = demo.put(f"/api/files/uploads/{token}", content=b"hello!", headers={"Content-Type": "application/octet-stream"})
    assert bad.status_code == 422, "not the confirmed size"
    token = confirm(demo, demo.post(f"{LAB}/files/upload", json={"directory": home, "name": "hello.txt",
                                                                 "size": 5}).json())["upload"]
    ok = demo.put(f"/api/files/uploads/{token}", content=b"hello", headers={"Content-Type": "application/octet-stream"})
    assert ok.status_code == 200, ok.text
    again = demo.put(f"/api/files/uploads/{token}", content=b"hello")
    assert again.status_code == 409, "a token is used once"
    got = demo.get(f"{LAB}/files/download", params={"directory": home, "name": "hello.txt"})
    assert got.content == b"hello" and "hello.txt" in got.headers["content-disposition"]
    tar = demo.get(f"{LAB}/files/download", params={"directory": home, "name": "notes", "folder": "true"})
    names = tarfile.open(fileobj=io.BytesIO(tar.content)).getnames()
    assert "./todo.md" in names
    mk = confirm(demo, demo.post(f"{LAB}/files/op", json={"kind": "mkdir", "directory": home, "name": "new"}).json())
    assert mk["ok"]
    taken = confirm(demo, demo.post(f"{LAB}/files/op", json={"kind": "mkdir", "directory": home, "name": "new"}).json())
    assert not taken["ok"] and "taken" in taken["message"]
    rn = confirm(demo, demo.post(f"{LAB}/files/op", json={"kind": "rename", "directory": home, "name": "hello.txt",
                                                          "to": "hi.txt"}).json())
    assert rn["ok"]
    rm = demo.post(f"{LAB}/files/op", json={"kind": "delete", "directory": home, "name": "new", "isFolder": True}).json()
    assert rm["pending"]["typed"] == "new" and rm["pending"]["destructive"]
    assert confirm(demo, rm, "new")["ok"]
    assert demo.post(f"{LAB}/files/op", json={"kind": "delete", "directory": "/", "name": "home",
                                              "isFolder": True}).status_code == 422
    names = [e["name"] for e in demo.get(f"{LAB}/files/list", params={"path": home}).json()["entries"]]
    assert "hi.txt" in names and "new" not in names
    demo.put("/api/safety", json={"readOnly": True})
    assert demo.post(f"{LAB}/files/upload", json={"directory": home, "name": "x", "size": 1}).json()["error"] == \
        "readOnly"
    assert demo.get(f"{LAB}/files/download", params={"directory": home, "name": "hi.txt"}).content == b"hello"


# --- alerts and search --------------------------------------------------------------------------------------------


def sweep(api: TestClient) -> dict[str, Any]:
    for server in ("demo-homelab", "demo-nuc", "demo-nas"):
        api.post(f"/api/servers/{server}/refresh")
    r = api.post("/api/alerts/check", json={})
    assert r.status_code == 200, r.text
    out: dict[str, Any] = r.json()
    return out


def test_the_sweep_finds_problems_and_the_first_reading_is_a_baseline(demo: TestClient) -> None:
    state = sweep(demo)
    keys = {a["key"] for a in state["active"]}
    assert {"reboot_required", "security_updates", "container_unhealthy:promtail",
            "service_failed:system/backup-sync.service", "service_crashing:system/cloudflared.service",
            "container_down:nextcloud-db-1", "not_answering"} <= keys, keys
    assert state["active"][0]["severity"] == "critical", "worst first"
    summary = demo.get("/api/alerts/summary").json()
    assert summary["servers"]["demo-homelab"]["unseen"] > 0 and summary["worst"] == "critical"
    a = next(x for x in state["active"] if x["key"] == "reboot_required")
    demo.post(f"/api/alerts/{a['id']}/seen", json={"seen": True})
    assert next(x for x in demo.get("/api/alerts").json()["active"] if x["id"] == a["id"])["acknowledged"]
    demo.post(f"/api/alerts/{a['id']}/mute", json={"on": True})
    muted = demo.get("/api/alerts", params={"server": "demo-homelab"}).json()
    assert a["id"] in [x["id"] for x in muted["muted"]] and a["id"] not in [x["id"] for x in muted["active"]]
    assert demo.post("/api/alerts/nope/seen", json={}).status_code == 404
    assert (Path(rk(demo).store.root) / "alerts.json").exists()


def test_new_alerts_are_delivered_to_ntfy_and_a_signed_webhook(demo: TestClient) -> None:
    sent: list[httpx.Request] = []
    def answer(req: httpx.Request) -> httpx.Response:
        sent.append(req)
        return httpx.Response(200)
    rk(demo).alerts.notifier.transport = httpx.MockTransport(answer)
    r = demo.put("/api/notifications", json={"ntfyUrl": "https://ntfy.example/rackoon", "ntfyToken": "tk",
                                             "webhookUrl": "https://hooks.example/in", "webhookSecret": "s3cret",
                                             "publicUrl": "https://rackoon.example"}).json()
    assert r["hasNtfyToken"] and r["hasWebhookSecret"] and "tk" not in json.dumps(r) and "s3cret" not in json.dumps(r)
    assert demo.put("/api/notifications", json={"webhookUrl": "file:///etc/passwd"}).status_code == 422
    test = demo.post("/api/notifications/test").json()
    assert test["ok"] and len(sent) == 2
    sweep(demo)
    sent.clear()
    lab = next(s for s in rk(demo).store.load_servers() if s.id == "demo-homelab")
    import asyncio
    signal = alerts.Signal("disk_high:/data", alerts.Category.DISK, Severity.CRITICAL, "Disk almost full",
                           "/data is 97% full.")
    asyncio.run(rk(demo).alerts.record(lab, alerts.Source.OVERVIEW, [signal]))
    ntfy = next(q for q in sent if q.url.host == "ntfy.example")
    assert ntfy.headers["Title"] == "homelab: Disk almost full" and ntfy.headers["Priority"] == "5"
    assert ntfy.headers["Authorization"] == "Bearer tk"
    assert ntfy.headers["Click"] == "https://rackoon.example/#/servers/demo-homelab/alerts"
    hook = next(q for q in sent if q.url.host == "hooks.example")
    expected = hmac.new(b"s3cret", hook.content, hashlib.sha256).hexdigest()
    assert hook.headers["X-Rackoon-Signature"] == f"sha256={expected}"
    assert json.loads(hook.content)["alert"]["key"] == "disk_high:/data"


def test_web_push_key_and_subscriptions(demo: TestClient) -> None:
    key = demo.get("/api/notifications/push/key").json()["publicKey"]
    raw = base64.urlsafe_b64decode(key + "=" * (-len(key) % 4))
    assert len(raw) == 65 and raw[0] == 4, "an uncompressed P-256 point, as PushManager.subscribe wants"
    assert demo.get("/api/notifications/push/key").json()["publicKey"] == key, "made once, kept"
    sub = {"endpoint": "https://push.example/abc", "keys": {"p256dh": "x" * 87, "auth": "y" * 22}}
    assert demo.post("/api/notifications/push/subscribe", json=sub).json()["pushSubscriptions"] == 1
    assert demo.post("/api/notifications/push/subscribe", json=sub).json()["pushSubscriptions"] == 1, "once per browser"
    assert demo.post("/api/notifications/push/subscribe", json={**sub, "endpoint": "http://x"}).status_code == 422
    assert demo.post("/api/notifications/push/unsubscribe", json={"endpoint": sub["endpoint"]}).json()[
        "pushSubscriptions"] == 0


def test_search_everything_the_backend_holds(demo: TestClient) -> None:
    sweep(demo)
    demo.get(f"{LAB}/docker", params={"watch": "true"})

    def groups(q: str) -> dict[str, list[dict[str, Any]]]:
        return {s["group"]: s["items"] for s in demo.get("/api/search", params={"q": q}).json()["sections"]}
    assert groups("homelab")["servers"][0]["target"] == {"kind": "server", "server": "demo-homelab", "id": "demo-homelab"}
    jf = groups("jellyfin")
    assert jf["docker"][0]["title"] == "jellyfin" and jf["bookmarks"][0]["link"] == "https://jellyfin.org"
    backup = groups("backup-sync")
    assert backup["services"][0]["tone"] == "danger" and backup["alerts"][0]["title"] == "backup-sync failed"
    assert groups("disk usage")["commands"][0]["target"]["id"] == "disk_usage"
    assert groups("100.100")["servers"][0]["title"] == "homelab", "found by its Tailscale address"
    assert demo.get("/api/search", params={"q": "x"}).json()["sections"] == []


async def test_certificates_are_read_from_a_handshake_without_trusting_them(tmp_path: Path) -> None:
    """A self-signed certificate on a local TLS server: its expiry is read (nothing is trusted); a closed port is None."""
    import asyncio
    import datetime
    import ssl

    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID

    from rackoon.app.alert_monitor import read_certificate
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
    expires = datetime.datetime(2031, 1, 2, 3, 4, 5, tzinfo=datetime.UTC)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(1).not_valid_before(datetime.datetime(2025, 1, 1, tzinfo=datetime.UTC))
            .not_valid_after(expires).sign(key, hashes.SHA256()))
    (tmp_path / "c.pem").write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    (tmp_path / "k.pem").write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                       serialization.NoEncryption()))
    ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    ctx.load_cert_chain(tmp_path / "c.pem", tmp_path / "k.pem")

    async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        writer.close()
    server = await asyncio.start_server(handle, "127.0.0.1", 0, ssl=ctx)
    port = server.sockets[0].getsockname()[1]
    try:
        assert await read_certificate(f"https://127.0.0.1:{port}/") == expires.timestamp()
    finally:
        server.close()
        await server.wait_closed()
    assert await read_certificate(f"https://127.0.0.1:{port}/", timeout=2) is None
