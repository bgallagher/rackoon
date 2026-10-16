"""The terminal path without a browser, to split the round trip: (1) asyncssh pty echo alone, (2) the same through
the spike server's WebSocket. Needs the lab (`eval "$(tools/lab env)"`) and, for (2), server.py running."""

from __future__ import annotations

import asyncio
import json
import statistics
import sys
import time
from pathlib import Path

import websockets

sys.path.insert(0, str(Path(__file__).parent))
from server import lab_transport  # noqa: E402

N = 200


def summary(ms: list[float]) -> dict[str, float]:
    s = sorted(ms)
    return {"median": round(statistics.median(s), 3), "p95": round(s[int(0.95 * len(s)) - 1], 3), "max": round(s[-1], 3)}


async def wait_for(read: object, needle: bytes) -> None:
    data = b""
    while needle not in data:
        data += await read()  # type: ignore[operator]


async def direct() -> dict[str, float]:
    transport = lab_transport()
    shell = await transport.open_shell(100, 30)
    await asyncio.sleep(1.0)  # let the login banner and prompt arrive
    while True:
        try:
            await asyncio.wait_for(shell.read(), 0.3)
        except TimeoutError:
            break
    times = []
    for _ in range(N):
        t0 = time.perf_counter()
        shell.write(b"x")
        await wait_for(shell.read, b"x")
        times.append((time.perf_counter() - t0) * 1000)
        shell.write(b"\x7f")
        await wait_for(shell.read, b"\x08")
    await shell.close()
    await transport.close()
    return summary(times)


async def through_websocket(url: str) -> dict[str, float]:
    async with websockets.connect(url) as ws:
        await asyncio.sleep(1.0)
        while True:
            try:
                await asyncio.wait_for(ws.recv(), 0.3)
            except TimeoutError:
                break
        times = []
        for _ in range(N):
            t0 = time.perf_counter()
            await ws.send(b"x")
            await wait_for(ws.recv, b"x")
            times.append((time.perf_counter() - t0) * 1000)
            await ws.send(b"\x7f")
            await wait_for(ws.recv, b"\x08")
        return summary(times)


async def main() -> None:
    result = {"n": N, "asyncssh_pty_echo_ms": await direct()}
    try:
        result["websocket_asyncssh_pty_echo_ms"] = await through_websocket("ws://127.0.0.1:8765/term?cols=100&rows=30")
    except OSError as e:
        result["websocket"] = f"server.py not running ({e})"
    print(json.dumps(result, indent=2))


asyncio.run(main())
