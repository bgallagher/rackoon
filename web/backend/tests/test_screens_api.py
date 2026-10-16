"""What the W3 screens read: the monitor's polling (with a fake transport), server state and fleet JSON, demo mode,
appearance, Read-only with its auto re-enable, the confirm-the-exact-command action center, the server list
endpoints and the served frontend."""

from __future__ import annotations

import asyncio
import json
from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from rackoon.app.actions import ActionCenter, ActionError
from rackoon.app.api import create_app
from rackoon.app.connections import Connections
from rackoon.app.keys import KeyStore
from rackoon.app.monitor import Monitor
from rackoon.app.preferences import Preferences
from rackoon.app.settings import Settings
from rackoon.app.storage import DataStore
from rackoon.core import overview
from rackoon.core.models import Server
from rackoon.core.policy import ActionPolicy, Confirmation, Intent, NotConfirmed, Risk
from rackoon.ssh import CommandResult, HostKey, HostKeyUnknown, Unreachable

from .support import out

READING = out("overview", "ubuntu-24.04")


class FakeTransport:
    def __init__(self) -> None:
        self.answers: list[CommandResult | Exception] = []
        self.ticks = 0
        self.commands: list[str] = []

    async def run(self, command: str, timeout: float, input: str | None = None) -> CommandResult:
        self.commands.append(command)
        if self.answers:
            answer = self.answers.pop(0)
            if isinstance(answer, Exception):
                raise answer
            return answer
        # CPU counters move: 1000 ticks, 750 idle.
        self.ticks += 1
        lines = READING.split("\n")
        i = lines.index("##stat") + 1
        parts = lines[i].split()
        values = [int(v) for v in parts[1:]]
        values[0] += 250 * self.ticks
        values[3] += 750 * self.ticks
        lines[i] = "cpu  " + " ".join(str(v) for v in values)
        return CommandResult("\n".join(lines), "", 0)

    async def connect(self) -> None:
        pass

    async def close(self) -> None:
        pass


class FakeConnections(Connections):
    def __init__(self, store: DataStore) -> None:
        super().__init__(store, KeyStore(store))
        self.fake = FakeTransport()

    def transport(self, server: Server) -> FakeTransport:
        return self.fake

    async def forget(self, server_id: str) -> None:
        pass


class Clock:
    def __init__(self) -> None:
        self.now = 1_800_000_000.0

    def __call__(self) -> float:
        return self.now


def make_monitor(tmp_path: Path) -> tuple[Monitor, FakeConnections, Clock, Server]:
    store = DataStore(tmp_path)
    connections = FakeConnections(store)
    clock = Clock()
    monitor = Monitor(store, connections, clock)
    server = Server("S1", "vps", "vps.example.com", user="root")
    monitor.sync([server])
    return monitor, connections, clock, server


# --- the monitor --------------------------------------------------------------------------------------------------


def test_poll_reads_overview_attention_and_cpu_from_two_readings(tmp_path: Path) -> None:
    monitor, connections, clock, server = make_monitor(tmp_path)
    entry = monitor.entries[server.id]
    asyncio.run(monitor.poll(entry))
    state = monitor.state_json(server.id)
    assert state is not None
    assert state["connection"] == "ok" and state["overview"]["hostname"] and state["cpuPercent"] is None
    assert connections.fake.commands == [overview.command()], "exactly the spec command"
    clock.now += 5
    asyncio.run(monitor.poll(entry))
    state = monitor.state_json(server.id)
    assert state is not None and state["cpuPercent"] == pytest.approx(25.0)
    assert DataStore(tmp_path).load_snapshot(server.id) is not None, "a good reading is cached"


def test_a_failed_poll_keeps_the_last_reading_and_explains_the_error(tmp_path: Path) -> None:
    monitor, connections, clock, server = make_monitor(tmp_path)
    entry = monitor.entries[server.id]
    asyncio.run(monitor.poll(entry))
    connections.fake.answers = [Unreachable("ssh: connect to host vps.example.com port 22: Connection refused")]
    clock.now += 60
    asyncio.run(monitor.poll(entry))
    state = monitor.state_json(server.id)
    assert state is not None
    assert state["overview"] is not None, "the last good reading stays"
    assert state["connection"] == "unreachable" and "refused" in state["error"]
    assert state["failure"]["headline"] == "Nothing accepts SSH at that address and port."
    connections.fake.answers = [CommandResult("", "boom", 2)]
    clock.now += 60
    asyncio.run(monitor.poll(entry))
    assert monitor.state_json(server.id)["error"] == "boom"  # type: ignore[index]
    fleet = monitor.fleet_json([server])
    assert [h["up"] for h in fleet["servers"][0]["history"]] == [True, False, False]
    assert fleet["totals"]["servers"] == 1 and fleet["totals"]["online"] == 0


def test_an_unknown_host_key_stops_polling_until_asked(tmp_path: Path) -> None:
    monitor, connections, _, server = make_monitor(tmp_path)
    connections.fake.answers = [HostKeyUnknown(HostKey("ssh-ed25519", b"\x01" * 51))]

    async def run() -> int:
        monitor.start()
        await asyncio.sleep(0.05)
        polls = len(connections.fake.commands)
        await asyncio.sleep(0.1)
        assert len(connections.fake.commands) == polls, "not polled again"
        await monitor.refresh(server.id)
        await asyncio.sleep(0.05)
        await monitor.stop()
        return polls

    assert asyncio.run(run()) == 1
    state = monitor.state_json(server.id)
    assert state is not None and state["connection"] == "ok", "a refresh after trusting starts again"


def test_the_cached_snapshot_is_shown_stale_until_the_first_poll(tmp_path: Path) -> None:
    store = DataStore(tmp_path)
    store.save_snapshot("S1", overview.parse(READING))
    monitor = Monitor(store, FakeConnections(store))
    monitor.sync([Server("S1", "vps", "vps.example.com")])
    state = monitor.state_json("S1")
    assert state is not None and state["isStale"] is True and state["overview"]["hostname"]
    assert state["attention"] == [] or all("short" in a for a in state["attention"])
    assert monitor.fleet_json([Server("S1", "vps", "vps.example.com")])["totals"]["online"] == 0


def test_watching_wakes_the_poller_and_sync_follows_the_list(tmp_path: Path) -> None:
    monitor, _, clock, server = make_monitor(tmp_path)
    entry = monitor.entries[server.id]
    assert not monitor.watch(server.id), "nothing to wake while the monitor isn't running"
    entry.watched_until = 0
    monitor.running = True
    assert monitor.watch(server.id)
    assert entry.wake.is_set() and entry.watched_until > clock.now
    assert not monitor.watch(server.id), "already watched"
    monitor.running = False  # no event loop here for sync to start tasks on
    assert monitor.state_json(server.id)["polling"] == "watched"  # type: ignore[index]
    moved = Server("S1", "vps", "other.example.com")
    monitor.sync([moved])
    assert monitor.entries["S1"] is not entry, "a new address starts over"
    monitor.sync([])
    assert monitor.entries == {}


# --- demo mode ----------------------------------------------------------------------------------------------------


@pytest.fixture
def demo(tmp_path: Path) -> Iterator[TestClient]:
    app = create_app(Settings(data_dir=tmp_path / "not-used", demo=True), poll=False)
    with TestClient(app, base_url="https://rackoon.test") as client:
        state = client.get("/api/auth/state").json()
        client.headers["X-Rackoon-CSRF"] = state["csrf"]
        yield client


def test_demo_needs_no_sign_in_and_never_uses_the_data_folder(demo: TestClient, tmp_path: Path) -> None:
    state = demo.get("/api/auth/state").json()
    assert state["authenticated"] and state["via"] == "demo" and state["demo"] is True
    assert not (tmp_path / "not-used").exists()
    assert [s["name"] for s in demo.get("/api/servers").json()] == ["homelab", "garage-nuc", "old-nas", "backup-box"]


def test_demo_servers_show_every_kind_of_state(demo: TestClient) -> None:
    homelab = demo.post("/api/servers/demo-homelab/refresh").json()
    assert homelab["connection"] == "ok" and homelab["overview"]["hostname"] == "homelab"
    ids = [a["id"] for a in homelab["attention"]]
    assert ids[0] == "container_unhealthy:promtail", "red first"
    assert {"security_updates", "reboot_required"} <= set(ids)
    assert homelab["overview"]["tailscaleIP"] == "100.100.40.7"
    nuc = demo.post("/api/servers/demo-nuc/refresh").json()
    assert nuc["attention"] == [] and nuc["overview"].get("tailscaleIP") is None
    nas = demo.post("/api/servers/demo-nas/refresh").json()
    assert nas["connection"] == "unreachable" and nas["failure"]["kind"] == "unreachable"
    backup = demo.post("/api/servers/demo-backup/refresh").json()
    assert backup["connection"] == "authFailed" and backup["failure"]["kind"] == "authRefused"
    fleet = demo.get("/api/fleet").json()
    assert fleet["totals"]["servers"] == 4 and fleet["totals"]["online"] == 2
    assert demo.post("/api/servers/demo-homelab/check").json()["status"] == "ok"


# --- appearance, read-only and actions ----------------------------------------------------------------------------


def test_appearance(demo: TestClient) -> None:
    a = demo.get("/api/appearance").json()
    assert a["selection"] == "automatic" and len(a["themes"]) == 45
    assert a["dark"]["themeId"] == "rackoon-dark" and a["light"]["themeId"] == "rackoon-light"
    assert a["dark"]["palette"]["background"] == "#15171C" and len(a["dark"]["terminal"]["ansi"]) == 16
    b = demo.put("/api/appearance", json={"selection": "dracula"}).json()
    assert b["dark"]["themeId"] == b["light"]["themeId"] == "dracula"
    assert demo.put("/api/appearance", json={"selection": "nope"}).status_code == 422


def test_read_only_starts_on_and_turns_itself_back_on(tmp_path: Path) -> None:
    clock = Clock()
    prefs = Preferences(DataStore(tmp_path), clock)
    assert prefs.read_only, "on for a new install"
    prefs.set_read_only(False)
    assert not Preferences(DataStore(tmp_path), clock).read_only, "saved"
    clock.now += 14 * 60
    assert not prefs.check_idle(busy=False)
    clock.now += 61
    assert not prefs.check_idle(busy=True), "never while an action runs"
    assert prefs.check_idle(busy=False) and prefs.read_only
    prefs.set_auto("never")
    prefs.set_read_only(False)
    clock.now += 1e6
    assert not prefs.check_idle(busy=False)
    assert prefs.safety_json()["auto"] == "never"


def test_safety_endpoint(demo: TestClient) -> None:
    assert demo.get("/api/safety").json()["readOnly"] is True
    r = demo.put("/api/safety", json={"readOnly": False, "auto": "idle5"}).json()
    assert r["readOnly"] is False and r["auto"] == "idle5" and len(r["options"]) == 4


def test_actions_confirm_the_exact_intent(tmp_path: Path) -> None:
    policy = ActionPolicy(read_only=True)
    clock = Clock()
    center = ActionCenter(policy, clock)
    intent = Intent("Restart container abcdef012345", "docker restart abcdef012345", Risk.MUTATE)
    ran: list[Confirmation] = []

    async def run(confirmation: Confirmation) -> str:
        policy.authorize(intent, confirmation)  # what a service does again before running
        ran.append(confirmation)
        return "restarted"

    with pytest.raises(ActionError, match="Read-only"):
        center.propose(intent, run)
    policy.is_read_only = False
    pending = center.propose(intent, run, destructive=True)
    assert pending.json() == {"id": pending.id, "summary": intent.summary, "command": intent.command, "risk": "mutate",
                              "destructive": True}
    assert asyncio.run(center.confirm(pending.id)) == "restarted" and len(ran) == 1
    with pytest.raises(ActionError, match="expired"):
        asyncio.run(center.confirm(pending.id))  # used once

    second = center.propose(intent, run)
    policy.is_read_only = True  # switched on after the sheet was shown
    with pytest.raises(ActionError, match="Read-only"):
        asyncio.run(center.confirm(second.id))
    assert len(ran) == 1, "nothing ran"
    policy.is_read_only = False
    third = center.propose(intent, run)
    clock.now += 301
    with pytest.raises(ActionError, match="expired"):
        asyncio.run(center.confirm(third.id))

    other = Intent("Restart", "docker restart 000000000000", Risk.MUTATE)

    async def sneaky(confirmation: Confirmation) -> None:
        policy.authorize(other, confirmation)  # a confirmation for one command never authorizes another

    fourth = center.propose(intent, sneaky)
    with pytest.raises(NotConfirmed):
        asyncio.run(center.confirm(fourth.id))
    preview = Intent("Save compose.yaml", "printf %s 'c2VydmljZXM6' | base64 -d > f", Risk.MUTATE, preview="+ services:")
    assert center.propose(preview, run).json()["command"] == "+ services:", "the readable preview is shown"


def test_action_endpoints(demo: TestClient) -> None:
    rackoon = demo.app.state.rackoon  # type: ignore[attr-defined]
    intent = Intent("Test", "true", Risk.MUTATE)

    async def run(confirmation: Confirmation) -> str:
        rackoon.preferences.policy.authorize(intent, confirmation)
        return "done"

    rackoon.preferences.set_read_only(False)
    pending = rackoon.actions.propose(intent, run)
    assert demo.post(f"/api/actions/{pending.id}/confirm").json() == {"ok": True, "result": "done"}
    assert demo.post(f"/api/actions/{pending.id}/confirm").json()["error"] == "expired"
    again = rackoon.actions.propose(intent, run)
    assert demo.post(f"/api/actions/{again.id}/cancel").json() == {"ok": True}
    assert demo.post(f"/api/actions/{again.id}/confirm").status_code == 409


# --- server list and frontend -------------------------------------------------------------------------------------


def test_server_filter_and_move(demo: TestClient) -> None:
    assert [s["name"] for s in demo.get("/api/servers", params={"query": "nuc"}).json()] == ["garage-nuc"]
    moved = demo.post("/api/servers/demo-backup/move", json={"onto": "demo-homelab"}).json()
    assert [s["name"] for s in moved] == ["backup-box", "homelab", "garage-nuc", "old-nas"]
    moved = demo.post("/api/servers/demo-backup/move", json={"by": 2}).json()
    assert [s["name"] for s in moved] == ["homelab", "garage-nuc", "backup-box", "old-nas"]
    assert demo.post("/api/servers/demo-backup/move", json={}).status_code == 422


def test_frontend_is_served_with_a_strict_policy(tmp_path: Path) -> None:
    dist = tmp_path / "dist"
    (dist / "assets").mkdir(parents=True)
    (dist / "index.html").write_text("<!doctype html><title>Rackoon</title>")
    (dist / "assets" / "app-1234.js").write_text("console.log(1)")
    (tmp_path / "secret.txt").write_text("no")
    app = create_app(Settings(data_dir=tmp_path / "data", static_dir=dist), poll=False)
    client = TestClient(app, base_url="https://rackoon.test")
    page = client.get("/")
    assert page.status_code == 200 and "Rackoon" in page.text
    assert "frame-ancestors 'none'" in page.headers["content-security-policy"]
    assert "script-src 'self'" in page.headers["content-security-policy"]
    assert client.get("/servers/abc/overview").text == page.text, "app routes get the page"
    asset = client.get("/assets/app-1234.js")
    assert "immutable" in asset.headers["cache-control"]
    assert client.get("/../secret.txt").text == page.text
    assert client.get("/%2e%2e/secret.txt").text == page.text, "no way out of the folder"
    assert client.get("/api/nothing-here").status_code == 404
    assert json.loads(client.get("/api/health").text) == {"ok": True}


def test_unknown_server_state(demo: TestClient) -> None:
    assert demo.get("/api/servers/nope/state").status_code == 404

