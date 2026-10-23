"""Stage W7 against the integration lab (`tools/lab up`, then `eval "$(tools/lab env)"`); skipped without it. Read-only
everywhere except Files, which only touches a throwaway folder it creates under /tmp and removes at the end: the
services scan, library commands (one through `sudo -n`), the NAS page refusing a server that is not Unraid, a real
upload and download through the confirm-then-token flow, new folder, rename and delete, and the alert sweep."""

from __future__ import annotations

import os
import secrets
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from rackoon.app.api import create_app
from rackoon.app.settings import Settings

from .test_api_lab import PASSWORD, add_lab_server, lab_env, trust_lab
from .test_docker_api_lab import shell


@pytest.fixture
def lab() -> dict[str, str]:
    return lab_env()


@pytest.fixture
def api(tmp_path: Path) -> Iterator[TestClient]:
    with TestClient(create_app(Settings(data_dir=tmp_path / "data"), poll=False), base_url="https://rackoon.test") as c:
        token = c.app.state.rackoon.setup_token.value  # type: ignore[attr-defined]
        r = c.post("/api/auth/setup", json={"token": token, "password": PASSWORD})
        c.headers["X-Rackoon-CSRF"] = r.json()["csrf"]
        yield c


def confirm(api: TestClient, answer: dict[str, Any], typed: str | None = None) -> dict[str, Any]:
    assert "pending" in answer, answer
    r = api.post(f"/api/actions/{answer['pending']['id']}/confirm", json={"typed": typed} if typed else None)
    assert r.status_code == 200, r.text
    out: dict[str, Any] = r.json()["result"]
    return out


def finish(api: TestClient, run: dict[str, Any]) -> dict[str, Any]:
    end = time.monotonic() + 120
    while time.monotonic() < end:
        state: dict[str, Any] = api.get(f"/api/runs/{run['id']}").json()
        if state["phase"] != "running":
            return state
        time.sleep(0.3)
    raise AssertionError("the run did not finish")


def test_lab_services_commands_nas_files_and_the_sweep(api: TestClient, lab: dict[str, str]) -> None:
    folder = f"/tmp/rk-web-files-{secrets.token_hex(4)}"
    try:
        key = api.post("/api/keys/import", json={"name": "lab", "privateKey": Path(lab["RACKOON_LAB_KEY"]).read_text()})
        server = add_lab_server(api, lab, key.json()["id"])
        trust_lab(api, server, lab)
        api.put("/api/safety", json={"readOnly": False})
        base = f"/api/servers/{server['id']}"

        s = api.get(f"{base}/services").json()
        assert s["status"] == "ready" and s["hasSystemd"] is False and s["isRoot"] is False, s
        # The lab container has no systemd, and rk may not see root's process names, so nothing can be attributed.
        assert s["services"] == []

        disk = finish(api, api.post(f"{base}/commands/run", json={"id": "disk_usage"}).json()["run"])
        assert disk["phase"] == "succeeded", disk
        ports = finish(api, api.post(f"{base}/commands/run", json={"id": "listening_ports"}).json()["run"])
        assert ports["phase"] == "succeeded" and not ports["needsPassword"], "rk's sudo -n works"

        nas = api.get(f"{base}/nas").json()
        assert nas["status"] == "failed" and "Unraid" in nas["error"]

        shell(lab, f"mkdir -p {folder}")
        assert confirm(api, api.post(f"{base}/files/op", json={"kind": "mkdir", "directory": folder,
                                                               "name": "sub"}).json())["ok"]
        data = os.urandom(1024 * 1024 + 7)
        token = confirm(api, api.post(f"{base}/files/upload", json={"directory": f"{folder}/sub", "name": "blob.bin",
                                                                    "size": len(data)}).json())["upload"]
        r = api.put(f"/api/files/uploads/{token}", content=data, headers={"Content-Type": "application/octet-stream"})
        assert r.status_code == 200, r.text
        listing = api.get(f"{base}/files/list", params={"path": f"{folder}/sub"}).json()
        assert [(e["name"], e["size"]) for e in listing["entries"]] == [("blob.bin", len(data))]
        got = api.get(f"{base}/files/download", params={"directory": f"{folder}/sub", "name": "blob.bin"})
        assert got.content == data, "byte for byte"
        assert confirm(api, api.post(f"{base}/files/op", json={"kind": "rename", "directory": f"{folder}/sub",
                                                               "name": "blob.bin", "to": "b.bin"}).json())["ok"]
        rm = api.post(f"{base}/files/op", json={"kind": "delete", "directory": folder, "name": "sub",
                                                "isFolder": True}).json()
        assert confirm(api, rm, "sub")["ok"]
        assert shell(lab, f"[ -e {folder}/sub ] && echo still || echo gone").strip() == "gone"

        api.post(f"{base}/refresh")
        sweep = api.post("/api/alerts/check", json={"serverId": server["id"]}).json()
        rk = api.app.state.rackoon  # type: ignore[attr-defined]
        assert server["id"] in rk.alerts.states, "the light container check ran"
        assert "reboot_required" in {a["key"] for a in sweep["active"]}, "the lab flags a pending reboot"
    finally:
        shell(lab, f"rm -rf {folder}")
