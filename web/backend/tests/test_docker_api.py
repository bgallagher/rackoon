"""The Docker section's API (stage W5) in demo mode, where nothing is sent anywhere: the overview and a stack's page,
container and stack actions confirmed and streamed, Read-only and one-run-at-a-time, cancelling, the editor's check
and sha-guarded save, Save and Redeploy, deleting with a typed name, adding a container (new and existing stack),
bookmarks, logs over a WebSocket, container shells, the dashboard's fleet view and the favicon gate."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from rackoon.app.api import create_app
from rackoon.app.settings import Settings

ORIGIN = {"origin": "https://testserver"}
HOMELAB = "/api/servers/demo-homelab/docker"
NUC = "/api/servers/demo-nuc/docker"


@pytest.fixture
def demo(tmp_path: Path) -> Iterator[TestClient]:
    app = create_app(Settings(data_dir=tmp_path / "unused", demo=True), poll=False)
    with TestClient(app, base_url="https://rackoon.test") as client:
        client.headers["X-Rackoon-CSRF"] = client.get("/api/auth/state").json()["csrf"]
        client.put("/api/safety", json={"readOnly": False})
        yield client


def docker(api: TestClient, base: str = HOMELAB) -> dict[str, Any]:
    r = api.get(base, params={"watch": "true"})
    assert r.status_code == 200, r.text
    state: dict[str, Any] = r.json()
    assert state["status"] == "ready", state
    return state


def stack(api: TestClient, stack_id: str, base: str = HOMELAB) -> dict[str, Any]:
    r = api.get(f"{base}/stack", params={"id": stack_id})
    assert r.status_code == 200, r.text
    out: dict[str, Any] = r.json()
    return out


def confirm(api: TestClient, pending: dict[str, Any], typed: str | None = None) -> dict[str, Any]:
    r = api.post(f"/api/actions/{pending['id']}/confirm", json={"typed": typed} if typed else None)
    assert r.status_code == 200, r.text
    result: dict[str, Any] = r.json()["result"]
    return result


def finish(api: TestClient, run: dict[str, Any]) -> tuple[dict[str, Any], str]:
    """Follows a run's WebSocket to its end: the final state and everything it printed."""
    text = ""
    state: dict[str, Any] = run
    with api.websocket_connect(f"/api/runs/{run['id']}/ws", headers=ORIGIN) as ws:
        while True:
            try:
                message = ws.receive()
            except Exception:  # noqa: BLE001 - the server closed it
                break
            if message.get("type") == "websocket.close":
                break
            if message.get("bytes") is not None:
                text += message["bytes"].decode()
            elif message.get("text") is not None:
                state = json.loads(message["text"])
                if state.get("phase") not in (None, "running"):
                    break
    return state, text


def test_the_overview_has_every_stack_with_its_status(demo: TestClient) -> None:
    demo.post("/api/servers/demo-homelab/refresh")  # the Overview's reading gives the link its address
    state = docker(demo)
    names = [s["name"] for s in state["stacks"]]
    assert len(names) == 12 and "grafana" in names and "pihole" in names
    grafana = next(s for s in state["stacks"] if s["id"] == "grafana")
    assert grafana["unhealthy"] == 1 and grafana["health"] == "attention" and grafana["severity"] == "danger"
    assert grafana["link"] == "http://100.100.40.7:3000"
    pihole = next(s for s in state["stacks"] if s["id"] == "standalone/pihole")
    assert pihole["isStandalone"] and pihole["kind"] == "Standalone"
    assert next(s for s in state["stacks"] if s["id"] == "backup")["health"] == "stopped"
    assert "12 stacks" not in state["summary"] and "10 stacks" in state["summary"]
    assert state["totals"]["containers"] == 19 and state["totals"]["unhealthy"] == 1
    assert {b["bookmark"]["name"] for b in state["bookmarks"]} >= {"Immich", "Grafana", "Jellyfin"}
    page = stack(demo, "grafana")["stack"]
    assert page["blocked"] is None and page["composeBlocked"] is None and page["folderProblem"] is None
    assert [f["name"] for f in page["files"]] == ["compose.yaml", ".env"]
    assert page["services"] == ["grafana", "prometheus", "promtail"]
    assert stack(demo, "standalone/pihole")["stack"]["composeBlocked"].startswith("Not available")
    assert demo.get(f"{HOMELAB}/stack", params={"id": "nope"}).status_code == 404


def test_start_runs_at_once_and_stop_asks_first(demo: TestClient) -> None:
    state = docker(demo)
    db = next(c for s in state["stacks"] if s["id"] == "nextcloud" for c in s["containers"] if c["service"] == "db")
    r = demo.post(f"{HOMELAB}/container-action", json={"containerId": db["id"], "action": "start"})
    assert r.status_code == 200 and "run" in r.json(), r.text
    end, text = finish(demo, r.json()["run"])
    assert end["phase"] == "succeeded" and end["exitCode"] == 0 and "##rackoon-exit" not in text
    assert "$ docker start nextcloud-db-1" in text
    pending = demo.post(f"{HOMELAB}/container-action", json={"containerId": db["id"], "action": "stop"}).json()["pending"]
    assert pending["title"] == "Stop nextcloud-db-1?" and pending["destructive"]
    assert pending["command"] == f"docker stop {db['id']}" and pending["target"] == "ubuntu@homelab.demo"
    end, _ = finish(demo, confirm(demo, pending)["run"])
    assert end["phase"] == "succeeded"
    assert demo.post(f"{HOMELAB}/container-action", json={"containerId": "f" * 12, "action": "stop"}).status_code == 404


def test_read_only_refuses_every_change(demo: TestClient) -> None:
    state = docker(demo)
    cid = state["stacks"][0]["containers"][0]["id"]
    demo.put("/api/safety", json={"readOnly": True})
    assert demo.post(f"{HOMELAB}/container-action", json={"containerId": cid, "action": "start"}).json()["error"] == \
        "readOnly"
    assert demo.post(f"{HOMELAB}/stack-action", json={"stackId": "grafana", "action": "up"}).status_code == 409
    assert stack(demo, "grafana")["stack"]["blocked"] == "Read-only mode is on"
    assert demo.post(f"{HOMELAB}/shell", json={"containerId": cid}).json()["error"] == "readOnly"
    demo.put("/api/safety", json={"readOnly": False})
    pending = demo.post(f"{HOMELAB}/stack-action", json={"stackId": "grafana", "action": "up"}).json()["pending"]
    demo.put("/api/safety", json={"readOnly": True})  # switched on between the sheet and the click
    r = demo.post(f"/api/actions/{pending['id']}/confirm")
    assert r.status_code == 409 and r.json()["error"] == "readOnly"


def test_stack_actions_stream_one_at_a_time_and_can_be_cancelled(demo: TestClient) -> None:
    docker(demo)
    pending = demo.post(f"{HOMELAB}/stack-action", json={"stackId": "immich", "action": "pull", "cols": 90,
                                                         "rows": 20}).json()["pending"]
    assert pending["title"] == "Pull images for immich?" and not pending["destructive"]
    assert pending["command"] == "cd '/opt/stacks/immich' && docker compose -p immich -f " \
        "'/opt/stacks/immich/compose.yaml' pull"
    run = confirm(demo, pending)["run"]
    assert run["cols"] == 90 and run["scope"] == "immich" and run["working"] == "Pulling images for immich…"
    busy = demo.post(f"{HOMELAB}/stack-action", json={"stackId": "grafana", "action": "restart"})
    assert busy.status_code == 409 and busy.json()["error"] == "busy"
    assert stack(demo, "immich")["stack"]["busy"] and stack(demo, "grafana")["stack"]["blocked"] == \
        "Another stack action is running"
    assert demo.post(f"/api/runs/{run['id']}/cancel").json()["ok"]
    end, _ = finish(demo, run)
    assert end["phase"] == "cancelled" and end["message"].startswith("Cancelled")
    assert stack(demo, "immich")["run"]["id"] == run["id"], "the stack page finds its last output"
    assert demo.delete(f"/api/runs/{run['id']}").json()["ok"]
    recreate = demo.post(f"{HOMELAB}/stack-action", json={"stackId": "grafana", "action": "recreate"}).json()["pending"]
    assert recreate["destructive"] and recreate["title"] == "Recreate all 3 containers in grafana?"
    rebuild = demo.post(f"{HOMELAB}/stack-action", json={"stackId": "grafana", "action": "rebuild",
                                                         "service": "grafana"}).json()["pending"]
    assert rebuild["command"].endswith("up -d --build --no-deps grafana")
    assert demo.post(f"{HOMELAB}/stack-action", json={"stackId": "grafana", "action": "rebuild",
                                                      "service": "nope"}).status_code == 422
    end, text = finish(demo, confirm(demo, rebuild)["run"])
    assert end["phase"] == "succeeded" and "Building" in text


def test_standalone_pull_and_delete_with_the_typed_name(demo: TestClient) -> None:
    docker(demo)
    pull = demo.post(f"{HOMELAB}/pull-image", json={"stackId": "standalone/portainer"}).json()["pending"]
    assert pull["command"] == "docker pull 'portainer/portainer-ce:2.21.4'"
    assert finish(demo, confirm(demo, pull)["run"])[0]["phase"] == "succeeded"
    assert demo.post(f"{HOMELAB}/stack-action", json={"stackId": "standalone/portainer", "action": "up"}).json()[
        "message"] == "These containers were not started with Docker Compose"
    pending = demo.post(f"{HOMELAB}/delete", json={"stackId": "standalone/portainer"}).json()["pending"]
    assert pending["typed"] == "portainer" and pending["destructive"]
    wrong = demo.post(f"/api/actions/{pending['id']}/confirm", json={"typed": "portaine"})
    assert wrong.status_code == 422 and wrong.json()["error"] == "typedMismatch"
    end, _ = finish(demo, confirm(demo, pending, "portainer")["run"])
    assert end["phase"] == "succeeded"
    demo.post(f"{HOMELAB}/refresh")
    assert "standalone/portainer" not in [s["id"] for s in docker(demo)["stacks"]]


def test_deleting_a_stack_and_its_folder(demo: TestClient) -> None:
    docker(demo)
    plain = demo.post(f"{HOMELAB}/delete", json={"stackId": "backup"}).json()["pending"]
    assert plain["typed"] is None, "containers and networks only: no word to type"
    demo.post(f"/api/actions/{plain['id']}/cancel")
    pending = demo.post(f"{HOMELAB}/delete", json={"stackId": "backup", "deleteFolder": True}).json()["pending"]
    assert pending["typed"] == "backup" and "rm -rf -- '/opt/stacks/backup'" in pending["command"]
    assert "the folder /opt/stacks/backup is deleted" in pending["message"]
    assert demo.post(f"/api/actions/{pending['id']}/confirm").status_code == 422
    run = confirm(demo, pending, "backup")["run"]
    assert next(s for s in docker(demo)["stacks"] if s["id"] == "backup")["removing"]
    assert finish(demo, run)[0]["phase"] == "succeeded"
    demo.post(f"{HOMELAB}/refresh")
    assert "backup" not in [s["id"] for s in docker(demo)["stacks"]]


def read(api: TestClient, stack_id: str, name: str, base: str = HOMELAB) -> dict[str, Any]:
    r = api.post(f"{base}/files/read", json={"stackId": stack_id, "path": f"/opt/stacks/{stack_id}/{name}"})
    assert r.status_code == 200, r.text
    out: dict[str, Any] = r.json()
    return out


def test_the_editor_checks_exactly_the_text_and_saves_only_against_the_opened_file(demo: TestClient) -> None:
    docker(demo)
    f = read(demo, "jellyfin", "compose.yaml")
    assert f["status"] == "file" and f["sha"] == hashlib.sha256(f["content"].encode()).hexdigest()
    path, original = f["path"], f["content"]
    same = demo.post(f"{HOMELAB}/files/check", json={"stackId": "jellyfin", "path": path, "original": original,
                                                     "text": original}).json()
    assert not same["canSave"] and same["blocked"] == "No changes to save"
    broken = original.replace("    restart:", "\trestart:")
    bad = demo.post(f"{HOMELAB}/files/check", json={"stackId": "jellyfin", "path": path, "original": original,
                                                    "text": broken}).json()
    assert not bad["canSave"] and any(r["state"] == "fail" for r in bad["rows"]) and bad["errorLines"] == [4]
    edited = original.replace("unless-stopped", "always")
    waiting = demo.post(f"{HOMELAB}/files/check", json={"stackId": "jellyfin", "path": path, "original": original,
                                                        "text": edited, "checkServer": False}).json()
    assert not waiting["canSave"] and waiting["blocked"] == "Waiting for the check on homelab"
    good = demo.post(f"{HOMELAB}/files/check", json={"stackId": "jellyfin", "path": path, "original": original,
                                                     "text": edited}).json()
    assert good["canSave"] and good["changeCount"] == 2 and good["changedLines"] == [4]
    assert demo.post(f"{HOMELAB}/files/read", json={"stackId": "jellyfin", "path": "/etc/passwd"}).status_code == 422
    lie = demo.post(f"{HOMELAB}/files/save", json={"stackId": "jellyfin", "path": path, "original": "x",
                                                   "sha": f["sha"], "text": edited})
    assert lie.status_code == 422
    pending = demo.post(f"{HOMELAB}/files/save", json={"stackId": "jellyfin", "path": path, "original": original,
                                                       "sha": f["sha"], "text": edited}).json()["pending"]
    assert pending["isPreview"] and "-     restart: unless-stopped" in pending["command"] and pending["then"] is None
    assert pending["title"] == "Save compose.yaml?"
    assert confirm(demo, pending)["outcome"] == "saved"
    assert read(demo, "jellyfin", "compose.yaml")["content"] == edited
    stale = demo.post(f"{HOMELAB}/files/save", json={"stackId": "jellyfin", "path": path, "original": original,
                                                     "sha": f["sha"], "text": original + "# again\n"}).json()["pending"]
    assert confirm(demo, stale)["outcome"] == "changed"


def test_save_and_redeploy_runs_up_after_the_save(demo: TestClient) -> None:
    docker(demo)
    f = read(demo, "uptime-kuma", "compose.yaml")
    text = f["content"] + "# tuned\n"
    pending = demo.post(f"{HOMELAB}/files/save", json={"stackId": "uptime-kuma", "path": f["path"],
                                                       "original": f["content"], "sha": f["sha"], "text": text,
                                                       "redeploy": True}).json()["pending"]
    assert pending["title"] == "Save compose.yaml and update uptime-kuma?"
    assert pending["then"] == "cd '/opt/stacks/uptime-kuma' && docker compose -p uptime-kuma -f " \
        "'/opt/stacks/uptime-kuma/compose.yaml' up -d"
    result = confirm(demo, pending)
    assert result["outcome"] == "saved"
    end, out = finish(demo, result["run"])
    assert end["phase"] == "succeeded" and "Saved compose.yaml." in out
    env = read(demo, "grafana", ".env")
    assert env["status"] == "missing" and env["content"] == ""


def draft(**kw: Any) -> dict[str, Any]:
    d: dict[str, Any] = {"target": "new", "stackName": "kuma2", "folder": "/opt/stacks",
                         "spec": {"name": "kuma2", "image": "louislam/uptime-kuma:1",
                                  "ports": [{"host": "3011", "container": "3001"}], "env": [{"key": "TZ", "value": "UTC"}]}}
    d.update(kw)
    return d


def test_adding_a_container_as_a_new_stack(demo: TestClient) -> None:
    docker(demo)
    defaults = demo.get(f"{HOMELAB}/add").json()
    assert defaults["defaultParent"] == "/opt/stacks" and "jellyfin" in [s["id"] for s in defaults["stacks"]]
    clash = demo.post(f"{HOMELAB}/add/evaluate", json=draft(spec={"name": "x", "image": "nginx",
                                                                 "ports": [{"host": "3000", "container": "80"}]})).json()
    port = next(r for r in clash["rows"] if r["id"] == "port3000")
    assert port["state"] == "fail" and "grafana" in port["detail"]
    taken = demo.post(f"{HOMELAB}/add/evaluate", json=draft(stackName="grafana")).json()
    assert taken["blocked"] == "A stack named grafana already exists"
    r = demo.post(f"{HOMELAB}/add/deploy", json={"draft": draft(), "start": True})
    assert r.status_code == 200, r.text
    pending = r.json()["pending"]
    assert pending["title"] == "Create kuma2 and start it?" and "Create folder /opt/stacks/kuma2" in pending["command"]
    assert pending["then"].endswith("up -d")
    result = confirm(demo, pending)
    assert result["outcome"] == "created" and result["stackId"] == "kuma2"
    assert finish(demo, result["run"])[0]["phase"] == "succeeded"
    demo.post(f"{HOMELAB}/refresh")
    kuma = next(s for s in docker(demo)["stacks"] if s["id"] == "kuma2")
    assert kuma["running"] == 1 and not kuma["notStarted"]
    assert read(demo, "kuma2", ".env")["content"] == "TZ=UTC\n"
    again = demo.post(f"{HOMELAB}/add/deploy", json={"draft": draft(), "start": False})
    assert again.status_code == 409 and "already exists" in again.json()["message"]


def test_a_created_stack_that_is_not_started_stays_visible(demo: TestClient) -> None:
    docker(demo)
    pending = demo.post(f"{HOMELAB}/add/deploy", json={"draft": draft(stackName="later"), "start": False}).json()[
        "pending"]
    assert pending["then"] is None
    assert confirm(demo, pending)["outcome"] == "created"
    later = next(s for s in docker(demo)["stacks"] if s["id"] == "later")
    assert later["notStarted"] and later["statusText"] == "Not started"


def test_adding_a_container_to_an_existing_stack(demo: TestClient) -> None:
    docker(demo)
    d = draft(target="existing", existingName="jellyfin", stackName="",
              spec={"name": "jellyseerr", "image": "fallenbagel/jellyseerr:2", "ports": [{"host": "5055",
                                                                                          "container": "5055"}],
                    "env": [{"key": "LOG_LEVEL", "value": "info"}]})
    ev = demo.post(f"{HOMELAB}/add/evaluate", json=d).json()
    assert ev["compose"].count("  jellyseerr:\n") == 1 and ev["env"] == "LOG_LEVEL=info\n"
    pending = demo.post(f"{HOMELAB}/add/deploy", json={"draft": d, "start": False}).json()["pending"]
    assert pending["title"] == "Add jellyseerr to jellyfin?" and pending["command"].startswith("compose.yaml\n")
    assert ".env\n" in pending["command"]
    assert confirm(demo, pending)["outcome"] == "saved"
    assert "  jellyseerr:\n" in read(demo, "jellyfin", "compose.yaml")["content"]
    assert read(demo, "jellyfin", ".env")["content"] == "LOG_LEVEL=info\n"


def test_bookmarks_are_written_into_the_compose_file(demo: TestClient) -> None:
    docker(demo, NUC)
    body = {"stackId": "mosquitto", "service": "mosquitto", "apply": False,
            "bookmark": {"href": "http://192.168.1.52:1883", "name": "MQTT", "group": "Home"}}
    pending = demo.post(f"{NUC}/bookmark", json=body).json()["pending"]
    assert pending["title"] == "Bookmark mosquitto?"
    assert any(line.startswith("+") and line.endswith("- homepage.href=http://192.168.1.52:1883")
               for line in pending["command"].split("\n"))
    assert confirm(demo, pending)["outcome"] == "saved"
    demo.post(f"{NUC}/refresh")
    marks = docker(demo, NUC)["bookmarks"]
    mqtt = next(b for b in marks if b["service"] == "mosquitto")
    assert mqtt["bookmark"]["name"] == "MQTT" and mqtt["scope"] == "local" and mqtt["address"] == "192.168.1.52:1883"
    assert demo.post(f"{NUC}/bookmark", json={**body, "bookmark": {"href": "ftp://x"}}).status_code == 422
    removal = demo.post(f"{NUC}/bookmark", json={**body, "bookmark": None, "apply": True}).json()["pending"]
    assert removal["title"] == "Remove the bookmark from mosquitto and update mosquitto?" and removal["then"]
    result = confirm(demo, removal)
    assert result["outcome"] == "saved" and finish(demo, result["run"])[0]["phase"] == "succeeded"


def test_logs_stream_parsed_lines_and_stop_with_the_socket(demo: TestClient) -> None:
    state = docker(demo)
    grafana = next(s for s in state["stacks"] if s["id"] == "grafana")
    ids = ",".join(c["id"] for c in grafana["containers"])
    with demo.websocket_connect(f"{HOMELAB}/logs/ws?ids={ids}", headers=ORIGIN) as ws:
        first = json.loads(ws.receive_text())
        assert first["type"] == "state" and first["live"] and len(first["containers"]) == 3
        entries: list[dict[str, Any]] = []
        while len(entries) < 40:
            frame = json.loads(ws.receive_text())
            if frame["type"] == "lines":
                entries += frame["entries"]
    assert {e["source"] for e in entries} == {"grafana", "prometheus", "promtail"}
    promtail = [e for e in entries if e["source"] == "promtail" and e["level"] == "error"]
    assert promtail and promtail[0]["message"].startswith("upstream timed out") and promtail[0]["time"]
    with pytest.raises(Exception):  # noqa: B017 - refused before it opens
        with demo.websocket_connect(f"{HOMELAB}/logs/ws?ids=nope", headers=ORIGIN) as ws:
            ws.receive_text()


def test_a_container_shell_opens_a_terminal_tab(demo: TestClient) -> None:
    state = docker(demo)
    c = next(c for s in state["stacks"] if s["id"] == "jellyfin" for c in s["containers"])
    tab = demo.post(f"{HOMELAB}/shell", json={"containerId": c["id"], "cols": 90, "rows": 25}).json()
    assert tab["kind"] == "command" and tab["title"] == "jellyfin"


def test_the_fleet_view_shows_only_answering_servers(demo: TestClient) -> None:
    for server in ("demo-homelab", "demo-nuc", "demo-nas", "demo-backup"):
        demo.post(f"/api/servers/{server}/refresh")
    fleet = demo.get("/api/fleet/docker", params={"watch": "true"}).json()["servers"]
    assert [s["server"]["name"] for s in fleet] == ["homelab", "garage-nuc"]
    assert fleet[1]["status"] == "ready" and fleet[1]["linkHost"] == "192.168.1.52"


def test_favicons_are_only_fetched_for_addresses_docker_reported(demo: TestClient) -> None:
    docker(demo)
    assert demo.get("/api/favicons", params={"href": "http://169.254.169.254/"}).status_code == 404
    assert demo.get("/api/favicons", params={"href": "not a url"}).status_code == 404
