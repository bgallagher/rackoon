"""Terminal tabs over the API and WebSocket, in demo mode (the scripted shell, nothing is sent anywhere): Read-only
gating, the Origin check, input and output, live highlighting, resize, replay on reattach, reconnecting after a lost
connection, a shell that exits, rename and close; plus the manager's reconnect rules with a fake opener."""

from __future__ import annotations

import asyncio
import json
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient
from starlette.testclient import WebSocketTestSession
from starlette.websockets import WebSocketDisconnect

from rackoon.app.api import create_app
from rackoon.app.settings import Settings
from rackoon.app.terminals import TerminalManager
from rackoon.core.models import Server
from rackoon.ssh import AuthFailed, Unreachable

ORIGIN = {"origin": "https://testserver"}  # the test client's WebSockets always send Host: testserver


@pytest.fixture
def demo(tmp_path: Path) -> Iterator[TestClient]:
    app = create_app(Settings(data_dir=tmp_path / "unused", demo=True), poll=False)
    with TestClient(app, base_url="https://rackoon.test") as client:
        client.headers["X-Rackoon-CSRF"] = client.get("/api/auth/state").json()["csrf"]
        client.put("/api/safety", json={"readOnly": False})
        yield client


def open_tab(api: TestClient, server: str = "demo-homelab") -> dict[str, Any]:
    r = api.post(f"/api/servers/{server}/terminals", json={"cols": 100, "rows": 30})
    assert r.status_code == 201, r.text
    tab: dict[str, Any] = r.json()
    return tab


def read_until(ws: WebSocketTestSession, needle: str, states: list[dict[str, Any]] | None = None) -> str:
    seen = ""
    deadline = time.monotonic() + 10
    while needle not in seen:
        assert time.monotonic() < deadline, f"never saw {needle!r} in {seen[-400:]!r}"
        message = ws.receive()
        if message.get("bytes") is not None:
            seen += message["bytes"].decode("utf-8", "replace")
        elif message.get("text") is not None:
            control = json.loads(message["text"])
            if states is not None:
                states.append(control)
            seen += f"\n<<{control.get('type')}:{control.get('state', '')}>>\n"
    return seen


def type_line(ws: WebSocketTestSession, text: str) -> None:
    ws.send_bytes(text.encode() + b"\r")


def test_read_only_gates_new_tabs(demo: TestClient) -> None:
    demo.put("/api/safety", json={"readOnly": True})
    r = demo.post("/api/servers/demo-homelab/terminals", json={})
    assert r.status_code == 409 and r.json()["error"] == "readOnly"
    demo.put("/api/safety", json={"readOnly": False})
    assert open_tab(demo)["state"] == "starting"


def test_the_socket_needs_this_pages_origin(demo: TestClient) -> None:
    tab = open_tab(demo)
    for headers in ({}, {"origin": "https://evil.example"}):
        with pytest.raises(WebSocketDisconnect) as closed:
            with demo.websocket_connect(f"/api/terminals/{tab['id']}/ws", headers=headers) as ws:
                ws.receive()
        assert closed.value.code == 4403
    with pytest.raises(WebSocketDisconnect) as closed:
        with demo.websocket_connect("/api/terminals/nope/ws", headers=ORIGIN) as ws:
            ws.receive()
    assert closed.value.code == 4404


def test_type_read_highlight_resize_and_replay(demo: TestClient) -> None:
    tab = open_tab(demo)
    with demo.websocket_connect(f"/api/terminals/{tab['id']}/ws", headers=ORIGIN) as ws:
        read_until(ws, "$ ")
        type_line(ws, "whoami")
        assert "ubuntu" in read_until(ws, "ubuntu")
        type_line(ws, "ip -4 a")
        assert "\x1b[35m203.0.113.24\x1b[39m" in read_until(ws, "scope global eth0"), "IPs are coloured"
        demo.put("/api/appearance", json={"highlightOutput": False})
        type_line(ws, "hostname; ip -4 a")
        out = read_until(ws, "hostname;")
        type_line(ws, "ip -4 a")
        out = read_until(ws, "tailscale0")
        assert "\x1b[35m" not in out.split("ip -4 a")[-1], "switched off live"
        demo.put("/api/appearance", json={"highlightOutput": True})
        ws.send_text(json.dumps({"type": "resize", "cols": 132, "rows": 43}))
        type_line(ws, "size")
        assert "132 columns x 43 rows" in read_until(ws, "rows")
    with demo.websocket_connect(f"/api/terminals/{tab['id']}/ws", headers=ORIGIN) as again:
        replay = read_until(again, "132 columns x 43 rows")
        assert "Welcome to Ubuntu" in replay, "reattaching replays the scrollback"


def test_read_only_refuses_keystrokes_but_keeps_the_session(demo: TestClient) -> None:
    tab = open_tab(demo)
    with demo.websocket_connect(f"/api/terminals/{tab['id']}/ws", headers=ORIGIN) as ws:
        read_until(ws, "$ ")
        demo.put("/api/safety", json={"readOnly": True})
        type_line(ws, "whoami")
        assert "<<readOnly:>>" in read_until(ws, "<<readOnly")
        demo.put("/api/safety", json={"readOnly": False})
        type_line(ws, "hostname")
        assert "homelab" in read_until(ws, "homelab\r\n")


def test_a_lost_connection_reconnects_and_an_exit_is_final(demo: TestClient) -> None:
    tab = open_tab(demo)
    with demo.websocket_connect(f"/api/terminals/{tab['id']}/ws", headers=ORIGIN) as ws:
        read_until(ws, "$ ")
        type_line(ws, "drop")
        states: list[dict[str, Any]] = []
        out = read_until(ws, "<<state:connected>>", states)
        reconnecting = next(s for s in states if s.get("state") == "reconnecting")
        assert (reconnecting["attempt"], reconnecting["of"], reconnecting["delay"]) == (1, 5, 1)
        assert "Reconnecting in 1 s (attempt 1 of 5)" in out, "scrollback keeps a dim notice"
        read_until(ws, "$ ")
        type_line(ws, "exit")
        states = []
        read_until(ws, "<<state:exited>>", states)
        assert states[-1]["exitCode"] == 0
    assert demo.get("/api/servers/demo-homelab/terminals").json()[0]["state"] == "exited"
    assert demo.post(f"/api/terminals/{tab['id']}/reconnect").json()["state"] in ("starting", "connected")


def test_rename_list_close_and_remove_the_server(demo: TestClient) -> None:
    a = open_tab(demo)
    b = open_tab(demo)
    assert demo.put(f"/api/terminals/{a['id']}", json={"title": "  logs   tail " + "x" * 60}).json()["title"] == \
        ("logs tail " + "x" * 60)[:40]
    assert demo.put(f"/api/terminals/{b['id']}", json={"title": "   "}).json()["title"] == "Shell"
    assert [t["id"] for t in demo.get("/api/servers/demo-homelab/terminals").json()] == [a["id"], b["id"]]
    assert demo.delete(f"/api/terminals/{a['id']}").status_code == 200
    assert demo.delete(f"/api/terminals/{a['id']}").status_code == 404
    demo.delete("/api/servers/demo-homelab")
    assert demo.get("/api/servers/demo-nuc/terminals").json() == []
    assert b["id"] not in demo.app.state.rackoon.terminals.tabs  # type: ignore[attr-defined]


# --- the manager's rules with a fake opener -----------------------------------------------------------------------


def test_refused_logins_are_not_retried_and_unreachable_ones_are() -> None:
    async def run() -> tuple[str, str, int]:
        calls = {"n": 0}

        async def refuse(server: Server, cols: int, rows: int) -> Any:
            raise AuthFailed("Permission denied")

        async def unreachable(server: Server, cols: int, rows: int) -> Any:
            calls["n"] += 1
            raise Unreachable("ssh: connect to host x port 22: Connection timed out")

        refused = TerminalManager(refuse, lambda: False, lambda: None, lambda: True, delays=(0.01, 0.01))
        lost = TerminalManager(unreachable, lambda: False, lambda: None, lambda: True, delays=(0.01, 0.01))
        server = Server("S", "s", "s.example")
        t1 = refused.open(server, 80, 24)
        t2 = lost.open(server, 80, 24)
        await asyncio.sleep(0.2)
        states = (t1.state, t2.state, calls["n"])
        await refused.close_all()
        await lost.close_all()
        return states

    refused_state, lost_state, attempts = asyncio.run(run())
    assert refused_state == "disconnected", "a refused login is final"
    assert lost_state == "disconnected" and attempts == 3, "first try plus the two retries, then give up"
