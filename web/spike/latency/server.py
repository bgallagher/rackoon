"""W0 latency spike: xterm.js <-> WebSocket <-> asyncssh pty, against the integration lab only.

    eval "$(tools/lab env)"
    (cd web/backend && uv run --group spike python ../spike/latency/server.py)    # http://127.0.0.1:8765
    (cd web/backend && uv run --group spike python ../spike/latency/bench.py)     # the same path without a browser

Binds to 127.0.0.1, has no login and talks only to the lab: a spike, not the W4 terminal. Frames: binary = raw
terminal bytes (both ways), text = JSON control ({"type": "resize", "cols": c, "rows": r}).
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
from pathlib import Path

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse

from rackoon.ssh import AsyncSSHTransport, HostKey, KnownHosts, SSHAuth, SSHEndpoint

HERE = Path(__file__).parent


def lab_transport() -> AsyncSSHTransport:
    env = os.environ
    if env.get("RACKOON_LAB") != "1":
        raise SystemExit('the lab is not configured: tools/lab up, then eval "$(tools/lab env)"')
    line = next(ln for ln in Path(env["RACKOON_LAB_KNOWN_HOSTS"]).read_text().splitlines()
                if ln.strip() and not ln.startswith("#"))
    host, port, key = HostKey.from_known_hosts_line(line)
    known = KnownHosts()
    known.trust(env["RACKOON_LAB_HOST"], int(env["RACKOON_LAB_PORT"]), key)
    auth = SSHAuth.key(Path(env["RACKOON_LAB_KEY"]).read_text())
    return AsyncSSHTransport(SSHEndpoint(env["RACKOON_LAB_HOST"], env["RACKOON_LAB_USER"], auth,
                                         int(env["RACKOON_LAB_PORT"])), known)


app = FastAPI()
transport = lab_transport()


@app.get("/")
async def index() -> FileResponse:
    return FileResponse(HERE / "index.html")


@app.websocket("/term")
async def term(ws: WebSocket) -> None:
    await ws.accept()
    cols, rows = int(ws.query_params.get("cols", "80")), int(ws.query_params.get("rows", "24"))
    shell = await transport.open_shell(cols, rows)

    async def pump_out() -> None:
        while chunk := await shell.read():
            await ws.send_bytes(chunk)
        await ws.close()

    out = asyncio.create_task(pump_out())
    try:
        while True:
            message = await ws.receive()
            if message["type"] == "websocket.disconnect":
                break
            if message.get("bytes") is not None:
                shell.write(message["bytes"])
            elif message.get("text") is not None:
                control = json.loads(message["text"])
                if control.get("type") == "resize":
                    shell.resize(int(control["cols"]), int(control["rows"]))
    except WebSocketDisconnect:
        pass
    finally:
        out.cancel()
        with contextlib.suppress(asyncio.CancelledError, Exception):
            await out
        await shell.close()


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=int(os.environ.get("RACKOON_SPIKE_PORT", "8765")), ws="websockets")
