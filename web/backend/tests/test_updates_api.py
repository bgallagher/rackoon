"""Stage W6's API in demo mode (nothing is sent anywhere; homelab's sudo wants the password "demo", garage-nuc's
user has passwordless sudo): the update list, apt actions streamed, the sudo password asked for and typed at sudo's one
prompt only, a wrong one rejected and never retyped, reboot with and without a password and the wait for a new boot
id, and Docker unlocked through sudo for 15 minutes, in memory only."""

from __future__ import annotations

import json
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from rackoon.app import demo_system
from rackoon.app.api import create_app
from rackoon.app.settings import Settings

ORIGIN = {"origin": "https://testserver"}
LAB = "/api/servers/demo-homelab"
NUC = "/api/servers/demo-nuc"


@pytest.fixture
def demo(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[TestClient]:
    monkeypatch.setattr(demo_system, "DOWN_SECONDS", 0.5)
    app = create_app(Settings(data_dir=tmp_path / "unused", demo=True), poll=False)
    with TestClient(app, base_url="https://rackoon.test") as client:
        client.app.state.rackoon.reboots.interval = 0.2  # type: ignore[attr-defined]
        client.headers["X-Rackoon-CSRF"] = client.get("/api/auth/state").json()["csrf"]
        client.put("/api/safety", json={"readOnly": False})
        yield client


def confirm(api: TestClient, answer: dict[str, Any]) -> dict[str, Any]:
    assert "pending" in answer, answer
    r = api.post(f"/api/actions/{answer['pending']['id']}/confirm")
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
                state = json.loads(m["text"])  # the socket closes after the final state and the replay
    return state, text


def test_the_update_list_security_first(demo: TestClient) -> None:
    u = demo.get(f"{LAB}/updates").json()
    assert u["status"] == "ready" and u["subtitle"] == "5 updates available, 2 security"
    assert [p["name"] for p in u["packages"]][:2] == ["libssl3t64", "openssl"] and u["packages"][0]["isSecurity"]
    assert u["rebootRequired"] and u["securityHint"] is None and u["refreshedText"] == "5 hours ago"
    assert demo.get(f"{NUC}/updates").json()["subtitle"] == "Everything is up to date"
    demo.put("/api/safety", json={"readOnly": True})
    assert demo.get(f"{LAB}/updates").json()["securityHint"] == "Read-only mode is on"
    assert demo.post(f"{LAB}/updates/action", json={"action": "refresh"}).json()["error"] == "readOnly"


def test_sudo_wants_a_password_then_the_password_variant_runs(demo: TestClient) -> None:
    plain = demo.post(f"{LAB}/updates/action", json={"action": "refresh"}).json()["pending"]
    assert plain["title"] == "Refresh package lists?" and "sudo -n" in plain["command"]
    end, text = follow(demo, confirm(demo, {"pending": plain})["run"])
    assert end["phase"] == "failed" and end["needsPassword"] and "without a password" in end["message"]

    wrong = demo.post(f"{LAB}/updates/action", json={"action": "refresh", "password": "nope"}).json()["pending"]
    assert "sudo -p '##rackoon-sudo-" in wrong["command"] and "nope" not in json.dumps(wrong)
    end, text = follow(demo, confirm(demo, {"pending": wrong})["run"])
    assert end["phase"] == "failed" and end["sudo"] == "rejected" and end["needsPassword"]
    assert "not accepted" in text and "nope" not in text and "Password:" not in text

    right = demo.post(f"{LAB}/updates/action", json={"action": "refresh", "password": "demo"}).json()["pending"]
    assert right["command"] != wrong["command"], "a fresh nonce per attempt"
    end, text = follow(demo, confirm(demo, {"pending": right})["run"])
    assert end["phase"] == "succeeded" and end["sudo"] == "accepted" and not end["needsPassword"]
    assert "Reading package lists... Done" in text and "demo" not in text and "*" not in text
    assert "[sudo password sent]" in text and "rackoon-sudo" not in text
    assert demo.get(f"{LAB}/updates").json()["refreshedText"] == "just now"


def test_installing_security_updates_clears_them(demo: TestClient) -> None:
    pending = demo.post(f"{LAB}/updates/action", json={"action": "security", "password": "demo"}).json()["pending"]
    assert pending["title"] == "Install 2 security updates?"
    assert pending["command"].endswith("install --only-upgrade -y -o Dpkg::Options::=--force-confold libssl3t64 openssl")
    end, text = follow(demo, confirm(demo, {"pending": pending})["run"])
    assert end["phase"] == "succeeded" and "Setting up openssl" in text
    u = demo.get(f"{LAB}/updates").json()
    assert u["securityCount"] == 0 and len(u["packages"]) == 3 and u["securityHint"] == "No security updates"
    state = demo.get(f"{LAB}/state").json()
    assert state["overview"]["securityUpdates"] == 0 and state["overview"]["pendingUpdates"] == 3


def wait_back(api: TestClient, base: str) -> dict[str, Any]:
    end = time.monotonic() + 15
    while time.monotonic() < end:
        reboot: dict[str, Any] = api.get(f"{base}/state").json()["reboot"]
        if reboot["phase"] != "waiting":
            return reboot
        time.sleep(0.2)
    raise AssertionError("never came back")


def test_reboot_needs_a_password_on_homelab_and_waits_for_a_new_boot_id(demo: TestClient) -> None:
    plain = demo.post(f"{LAB}/reboot", json={}).json()["pending"]
    assert plain["destructive"] and plain["title"] == "Reboot homelab?" and "sudo -n" in plain["command"]
    assert confirm(demo, {"pending": plain})["outcome"] == "noSudo"
    wrong = demo.post(f"{LAB}/reboot", json={"password": "nope"}).json()
    assert wrong["pending"]["command"].startswith("sudo -S -p ''") and "nope" not in json.dumps(wrong)
    assert confirm(demo, wrong)["outcome"] == "badPassword"
    assert demo.get(f"{LAB}/state").json()["reboot"] is None, "nothing was scheduled"
    right = confirm(demo, demo.post(f"{LAB}/reboot", json={"password": "demo"}).json())
    assert right["outcome"] == "rebooting"
    assert demo.get(f"{LAB}/state").json()["reboot"]["phase"] == "waiting"
    back = wait_back(demo, LAB)
    assert back["phase"] == "back" and back["elapsed"] > 0
    state = demo.post(f"{LAB}/refresh").json()
    assert state["overview"]["bootID"] == "demo-boot-2" and not state["overview"]["rebootRequired"]
    assert demo.post(f"{LAB}/reboot/dismiss").json()["reboot"] is None


def test_passwordless_sudo_reboots_on_the_first_yes(demo: TestClient) -> None:
    assert confirm(demo, demo.post(f"{NUC}/reboot", json={}).json())["outcome"] == "rebooting"
    assert wait_back(demo, NUC)["phase"] == "back"


def test_docker_unlocked_through_sudo_for_a_while_in_memory_only(demo: TestClient, tmp_path: Path) -> None:
    assert demo.post(f"{LAB}/docker/unlock", json={"password": "nope"}).json()["error"] == "badPassword"
    state = demo.post(f"{LAB}/docker/unlock", json={"password": "demo"}).json()
    assert state["status"] == "ready" and state["elevation"]["until"] > time.time() + 14 * 60
    rk = demo.app.state.rackoon  # type: ignore[attr-defined]
    assert '"demo"' not in json.dumps(state)
    data = Path(rk.store.root)
    assert not any("demo" == p.read_text(errors="ignore").strip() for p in data.rglob("*") if p.is_file()), \
        "never written to disk"
    c = next(c for s in state["stacks"] if s["id"] == "jellyfin" for c in s["containers"])
    run = confirm(demo, demo.post(f"{LAB}/docker/container-action", json={"containerId": c["id"],
                                                                         "action": "restart"}).json())["run"]
    end, text = follow(demo, run)
    assert end["phase"] == "succeeded" and "rackoon-sudo" not in text and "demo" not in text
    tab = demo.post(f"{LAB}/docker/shell", json={"containerId": c["id"]}).json()
    assert rk.terminals.tabs[tab["id"]].command.startswith("sudo docker exec -it ")
    assert demo.post(f"{LAB}/docker/lock").json()["until"] is None
    assert demo.get(f"{LAB}/docker").json()["elevation"]["until"] is None


def test_a_rejected_password_locks_docker_again(demo: TestClient) -> None:
    rk = demo.app.state.rackoon  # type: ignore[attr-defined]
    rk.elevation.unlock("demo-homelab", "stale")
    assert demo.get(f"{LAB}/docker").json()["elevation"]["until"] is not None
    state = demo.post(f"{LAB}/docker/refresh").json()
    assert state["error"] and "did not accept" in state["error"]
    el = demo.get(f"{LAB}/docker").json()["elevation"]
    assert el["until"] is None and "did not accept" in el["lockReason"]
