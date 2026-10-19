"""Stage W6 against the integration lab's real sshd, sudo and apt (`tools/lab up`, then `eval "$(tools/lab env)"`);
skipped without it. Signed in as the lab's rkpw, whose sudo wants a password (and allows one try): the update list,
`apt-get update` refused without the password, a wrong password rejected and never retyped, the right one accepted at
sudo's one prompt; the reboot refused without a password and with a wrong one (nothing is ever scheduled: this test
never reboots anything); and Docker unlocked through sudo. Only the throwaway lab container is touched."""

from __future__ import annotations

import os
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from rackoon.app.api import create_app
from rackoon.app.settings import Settings

from .test_api_lab import PASSWORD, lab_env, trust_lab


@pytest.fixture
def lab() -> dict[str, str]:
    env = lab_env()
    if not os.environ.get("RACKOON_LAB_SUDO_PASSWORD"):
        pytest.skip("the lab's sudo password is not in the environment")
    return {**env, "SUDO_USER": os.environ.get("RACKOON_LAB_SUDO_USER", "rkpw"),
            "SUDO_PASSWORD": os.environ["RACKOON_LAB_SUDO_PASSWORD"]}


@pytest.fixture
def api(tmp_path: Path) -> Iterator[TestClient]:
    with TestClient(create_app(Settings(data_dir=tmp_path / "data")), base_url="https://rackoon.test") as client:
        token = client.app.state.rackoon.setup_token.value  # type: ignore[attr-defined]
        r = client.post("/api/auth/setup", json={"token": token, "password": PASSWORD})
        client.headers["X-Rackoon-CSRF"] = r.json()["csrf"]
        yield client


def confirm(api: TestClient, answer: dict[str, Any]) -> dict[str, Any]:
    assert "pending" in answer, answer
    r = api.post(f"/api/actions/{answer['pending']['id']}/confirm")
    assert r.status_code == 200, r.text
    out: dict[str, Any] = r.json()["result"]
    return out


def finish(api: TestClient, run: dict[str, Any], seconds: float = 300) -> dict[str, Any]:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        state: dict[str, Any] = api.get(f"/api/runs/{run['id']}").json()
        if state["phase"] != "running":
            return state
        time.sleep(0.5)
    raise AssertionError(f"{run['title']} did not finish")


def test_lab_sudo_password_for_apt_reboot_and_docker(api: TestClient, lab: dict[str, str]) -> None:
    key = api.post("/api/keys/import", json={"name": "lab", "privateKey": Path(lab["RACKOON_LAB_KEY"]).read_text()})
    r = api.post("/api/servers", json={"name": "lab-sudo", "host": lab["RACKOON_LAB_HOST"], "user": lab["SUDO_USER"],
                                       "port": int(lab["RACKOON_LAB_PORT"]), "keyId": key.json()["id"]})
    server = r.json()
    trust_lab(api, server, lab)
    api.put("/api/safety", json={"readOnly": False})
    base = f"/api/servers/{server['id']}"

    u = api.get(f"{base}/updates").json()
    assert u["status"] == "ready" and len(u["packages"]) == 2 and u["securityCount"] == 1 and u["rebootRequired"]

    plain = finish(api, confirm(api, api.post(f"{base}/updates/action", json={"action": "refresh"}).json())["run"])
    assert plain["phase"] == "failed" and plain["needsPassword"], plain
    wrong = finish(api, confirm(api, api.post(f"{base}/updates/action", json={"action": "refresh",
                                                                             "password": "not-it"}).json())["run"])
    assert wrong["phase"] == "failed" and wrong["sudo"] == "rejected" and wrong["needsPassword"], wrong
    right = finish(api, confirm(api, api.post(f"{base}/updates/action",
                                              json={"action": "refresh", "password": lab["SUDO_PASSWORD"]}).json())["run"])
    assert right["phase"] == "succeeded" and right["sudo"] == "accepted", right

    # The reboot is refused twice and nothing is ever scheduled (this test never sends the right password to it).
    assert confirm(api, api.post(f"{base}/reboot", json={}).json())["outcome"] == "noSudo"
    assert confirm(api, api.post(f"{base}/reboot", json={"password": "not-it"}).json())["outcome"] == "badPassword"
    assert api.get(f"{base}/state").json()["reboot"] is None

    # Docker through sudo: a wrong password is never kept; the right one is held in memory and every command uses it.
    assert api.post(f"{base}/docker/unlock", json={"password": "not-it"}).json()["error"] == "badPassword"
    state = api.post(f"{base}/docker/unlock", json={"password": lab["SUDO_PASSWORD"]}).json()
    assert state["status"] == "ready", state
    assert state["elevation"]["until"] > time.time() + 14 * 60
    ticker = next(c for s in state["stacks"] if s["id"] == "labstack" for c in s["containers"])
    restarted = confirm(api, api.post(f"{base}/docker/container-action", json={"containerId": ticker["id"],
                                                                                "action": "restart"}).json())
    assert finish(api, restarted["run"])["phase"] == "succeeded"
    assert api.post(f"{base}/docker/lock").json()["until"] is None
