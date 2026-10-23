"""The Docker API end to end against the integration lab's real sshd and Docker (`tools/lab up`, then
`eval "$(tools/lab env)"`); skipped without it. Everything it changes is a throwaway stack it creates under /tmp
(busybox, already in the lab's Docker, no volumes): create and start it, edit its compose file with the sha guard,
restart its container, then delete it with its folder. Whatever happens, the stack and folder are removed at the
end."""

from __future__ import annotations

import asyncio
import secrets
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from rackoon.app.api import create_app
from rackoon.app.settings import Settings
from rackoon.ssh import AsyncSSHTransport, KnownHosts, SSHAuth, SSHEndpoint

from .test_api_lab import PASSWORD, add_lab_server, lab_env, lab_host_key, trust_lab

COMPOSE = 'services:\n  sleeper:\n    image: busybox:1.36\n    command: ["sleep", "3600"]\n'


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


def shell(lab: dict[str, str], command: str) -> str:
    """Runs a command on the lab directly (to look, and to clean up), not through the API."""
    known = KnownHosts()
    known.trust(lab["RACKOON_LAB_HOST"], int(lab["RACKOON_LAB_PORT"]), lab_host_key(lab))
    endpoint = SSHEndpoint(lab["RACKOON_LAB_HOST"], lab["RACKOON_LAB_USER"],
                           SSHAuth.key(Path(lab["RACKOON_LAB_KEY"]).read_text()), int(lab["RACKOON_LAB_PORT"]))

    async def go() -> str:
        async with AsyncSSHTransport(endpoint, known) as t:
            return (await t.run(command, 120)).stdout
    return asyncio.run(go())


def confirm(api: TestClient, answer: dict[str, Any], typed: str | None = None) -> dict[str, Any]:
    assert "pending" in answer, answer
    r = api.post(f"/api/actions/{answer['pending']['id']}/confirm", json={"typed": typed} if typed else None)
    assert r.status_code == 200, r.text
    result: dict[str, Any] = r.json()["result"]
    return result


def finish(api: TestClient, run: dict[str, Any], seconds: float = 180) -> dict[str, Any]:
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        state: dict[str, Any] = api.get(f"/api/runs/{run['id']}").json()
        if state["phase"] != "running":
            return state
        time.sleep(0.5)
    raise AssertionError(f"{run['title']} did not finish")


def test_lab_create_edit_restart_and_delete_a_throwaway_stack(api: TestClient, lab: dict[str, str]) -> None:
    name = f"rkweb{secrets.token_hex(4)}"
    parent = f"/tmp/rk-web-{name}"
    folder = f"{parent}/{name}"
    try:
        key = api.post("/api/keys/import", json={"name": "lab", "privateKey": Path(lab["RACKOON_LAB_KEY"]).read_text()})
        server = add_lab_server(api, lab, key.json()["id"])
        trust_lab(api, server, lab)
        api.put("/api/safety", json={"readOnly": False})
        base = f"/api/servers/{server['id']}/docker"
        state = api.get(base, params={"watch": "true"}).json()
        assert state["status"] == "ready", state
        assert any(s["id"] == "labstack" for s in state["stacks"])

        # Create and start (the server checks the files in a scratch folder first, then in place).
        draft = {"target": "new", "stackName": name, "folder": parent, "paste": True, "pasteCompose": COMPOSE}
        checked = api.post(f"{base}/add/evaluate", json=draft).json()
        assert next(r for r in checked["rows"] if r["title"] == "YAML syntax")["state"] == "pass", checked
        created = confirm(api, api.post(f"{base}/add/deploy", json={"draft": draft, "start": True}).json())
        assert created["outcome"] == "created", created
        assert finish(api, created["run"])["phase"] == "succeeded"
        api.post(f"{base}/refresh")
        page = api.get(f"{base}/stack", params={"id": name}).json()["stack"]
        assert page["running"] == 1 and page["folderProblem"] is None
        container = page["containers"][0]["id"]

        # Edit compose.yaml: checked on the server, saved against the sha it was opened with.
        path = f"{folder}/compose.yaml"
        opened = api.post(f"{base}/files/read", json={"stackId": name, "path": path}).json()
        assert opened["content"] == COMPOSE
        edited = COMPOSE + '    restart: "no"\n'
        verdict = api.post(f"{base}/files/check", json={"stackId": name, "path": path, "original": COMPOSE,
                                                         "text": edited}).json()
        assert verdict["canSave"], verdict
        broken = api.post(f"{base}/files/check", json={"stackId": name, "path": path, "original": COMPOSE,
                                                        "text": COMPOSE + "  nope: [\n"}).json()
        assert not broken["canSave"] and any(r["state"] == "fail" for r in broken["rows"])
        saved = confirm(api, api.post(f"{base}/files/save", json={"stackId": name, "path": path, "original": COMPOSE,
                                                                  "sha": opened["sha"], "text": edited}).json())
        assert saved["outcome"] == "saved", saved
        assert shell(lab, f"cat {folder}/compose.yaml") == edited
        assert shell(lab, f"test -f {folder}/compose.yaml.rackoon.bak && echo kept").strip() == "kept"
        stale = confirm(api, api.post(f"{base}/files/save", json={"stackId": name, "path": path, "original": COMPOSE,
                                                                  "sha": opened["sha"], "text": COMPOSE}).json())
        assert stale["outcome"] == "changed", "the file changed since it was opened: nothing is written"

        # Restart its container, streamed.
        restarted = confirm(api, api.post(f"{base}/container-action", json={"containerId": container,
                                                                             "action": "restart"}).json())
        assert finish(api, restarted["run"])["phase"] == "succeeded"

        # Delete with its folder: the name must be typed.
        pending = api.post(f"{base}/delete", json={"stackId": name, "deleteFolder": True}).json()
        assert pending["pending"]["typed"] == name
        deleted = confirm(api, pending, name)
        assert finish(api, deleted["run"])["phase"] == "succeeded"
        assert shell(lab, f"[ -e {folder} ] && echo still || echo gone").strip() == "gone"
        assert name not in shell(lab, "docker ps -a --format '{{.Names}}'")
    finally:
        shell(lab, f"cd / && docker compose -p {name} down --remove-orphans >/dev/null 2>&1; rm -rf {parent}")
