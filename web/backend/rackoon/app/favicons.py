"""Site icons for bookmarks and stack links, like `FaviconStore` on the Mac, fetched by this server (which is on the
tailnet with the user's servers): the page, then each icon link it names (best first, `rackoon.core.favicon`), then
`/favicon.ico`; the first answer that is really an image wins and is cached in `<data>/favicons/`.

Limits: 256 KB for the page and 1 MB for an image, 6 s a request, one site at a time, http(s) only (after redirects
too), no cookies or credentials, and certificate errors are tolerated for these GETs only (home servers are often
self-signed; the worst case is a wrong picture). A site with no icon is tried again after a day; `refresh` forces
it. The bytes are served as they came (the browser decodes them in an <img>); SVG gets a sandboxing CSP on top.
"""

from __future__ import annotations

import asyncio
import hashlib
import ipaddress
import json
import logging
import time
from collections.abc import Callable
from pathlib import Path
from urllib.parse import urlsplit

import httpx

from rackoon.core import favicon

log = logging.getLogger("rackoon.favicons")

PAGE_LIMIT = 256 * 1024
IMAGE_LIMIT = 1024 * 1024
TIMEOUT = 6.0
RETRY_SECONDS = 86400.0
TYPES = {"png": "image/png", "jpg": "image/jpeg", "gif": "image/gif", "ico": "image/x-icon", "webp": "image/webp",
         "svg": "image/svg+xml"}


def sniff(data: bytes) -> str | None:
    """The image kind from its first bytes (never from the server's content type), or None if it isn't one."""
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if data.startswith(b"\xff\xd8\xff"):
        return "jpg"
    if data.startswith((b"GIF87a", b"GIF89a")):
        return "gif"
    if data.startswith((b"\x00\x00\x01\x00", b"\x00\x00\x02\x00")):
        return "ico"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    head = data[:1024].lstrip().lower()
    if (head.startswith(b"<svg") or head.startswith(b"<?xml")) and b"<svg" in data[:4096].lower():
        return "svg"
    return None


def fetchable(url: str) -> bool:
    """http(s), and not a link-local address (cloud metadata lives there)."""
    try:
        u = urlsplit(url)
    except ValueError:
        return False
    if u.scheme.lower() not in ("http", "https") or not u.hostname:
        return False
    try:
        return not ipaddress.ip_address(u.hostname).is_link_local
    except ValueError:
        return True


class FaviconStore:
    def __init__(self, folder: Path, clock: Callable[[], float] = time.time,
                 transport: httpx.AsyncBaseTransport | None = None) -> None:
        self.folder = folder
        self.clock = clock
        self.transport = transport  # tests answer with httpx.MockTransport
        self.lock = asyncio.Lock()
        self._index: dict[str, dict[str, object]] | None = None

    @property
    def index(self) -> dict[str, dict[str, object]]:
        if self._index is None:
            try:
                self._index = json.loads((self.folder / "index.json").read_text())
            except (OSError, ValueError):
                self._index = {}
        return self._index

    def _save(self) -> None:
        self.folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        tmp = self.folder / "index.json.tmp"
        tmp.write_text(json.dumps(self.index))
        tmp.replace(self.folder / "index.json")

    def cached(self, origin: str) -> tuple[bytes, str] | None:
        row = self.index.get(origin)
        if not row or not row.get("file"):
            return None
        try:
            data = (self.folder / str(row["file"])).read_bytes()
        except OSError:
            return None
        return data, TYPES[str(row["kind"])]

    async def get(self, origin: str, refresh: bool = False) -> tuple[bytes, str] | None:
        row = self.index.get(origin)
        have = self.cached(origin)
        if not refresh and row is not None and (have is not None or
                                                self.clock() - float(str(row.get("tried", 0))) < RETRY_SECONDS):
            return have
        async with self.lock:
            found = await self._fetch(origin)
        if found is None:
            self.index[origin] = {**(row or {}), "tried": self.clock()}
            self._save()
            return have  # a failed refresh keeps the old icon
        data, kind = found
        name = hashlib.sha256(origin.encode()).hexdigest()[:32] + "." + kind
        self.folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        (self.folder / name).write_bytes(data)
        self.index[origin] = {"file": name, "kind": kind, "tried": self.clock()}
        self._save()
        return data, TYPES[kind]

    async def _fetch(self, origin: str) -> tuple[bytes, str] | None:
        async with httpx.AsyncClient(verify=False, timeout=TIMEOUT, follow_redirects=False, transport=self.transport,
                                     headers={"User-Agent": "Rackoon (site icon)"}, cookies=None) as client:
            page = await self._get(client, origin + "/", PAGE_LIMIT)
            candidates = []
            if page is not None:
                data, final = page
                candidates = [c.url for c in favicon.candidates(data.decode("utf-8", "replace"), final)]
            for url in candidates + [favicon.default_icon(origin)]:
                got = await self._get(client, url, IMAGE_LIMIT)
                if got is not None:
                    kind = sniff(got[0])
                    if kind is not None:
                        return got[0], kind
        return None

    async def _get(self, client: httpx.AsyncClient, url: str, limit: int) -> tuple[bytes, str] | None:
        """Follows up to three redirects by hand, so every hop is checked before it is requested."""
        for _ in range(4):
            if not fetchable(url):
                return None
            try:
                async with client.stream("GET", url) as r:
                    if r.status_code in (301, 302, 303, 307, 308) and "location" in r.headers:
                        url = str(r.url.join(r.headers["location"]))
                        continue
                    if r.status_code != 200:
                        return None
                    body = bytearray()
                    async for chunk in r.aiter_bytes():
                        body += chunk
                        if len(body) > limit:
                            return None
                    return bytes(body), str(r.url)
            except (httpx.HTTPError, OSError, ValueError):
                return None
        return None
