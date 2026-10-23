"""Finding a site's icon in its HTML (`FaviconLinks` in the Swift and Kotlin cores). Pure: the backend does the
fetching; this only says where to look, best candidate first."""

from __future__ import annotations

import re
from dataclasses import dataclass
from urllib.parse import urljoin, urlsplit

from .docker import is_valid_url


@dataclass(frozen=True)
class Candidate:
    url: str
    rel: list[str]
    type: str | None
    size: int


def origin(href: str) -> str | None:
    """`scheme://host[:port]`, the key an icon is cached under: every bookmark on one site shares it."""
    if not is_valid_url(href):
        return None
    try:
        u = urlsplit(href.strip())
        port = u.port
    except ValueError:
        return None
    scheme = u.scheme.lower()
    host = (u.hostname or "").lower()
    if not host:
        return None
    if ":" in host:
        host = f"[{host}]"
    default = 443 if scheme == "https" else 80
    return f"{scheme}://{host}" if port is None or port == default else f"{scheme}://{host}:{port}"


def default_icon(site: str) -> str:
    return f"{site}/favicon.ico"


_LINK = re.compile(r"<link\b[^>]*>", re.IGNORECASE)
_ATTRIBUTE = re.compile(r"""([a-zA-Z][\w:-]*)\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'>]+))""")


def attributes(tag: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for m in _ATTRIBUTE.finditer(tag):
        value = next((g for g in (m.group(3), m.group(4), m.group(5)) if g is not None), "")
        out.setdefault(m.group(1).lower(), value.replace("&amp;", "&"))
    return out


def _largest(sizes: str | None) -> int:
    best = 0
    for part in (sizes or "").lower().split():
        dims = part.split("x")
        if part.count("x") == 1 and all(d.isdigit() for d in dims):
            best = max(best, int(dims[0]), int(dims[1]))
    return best


def score(c: Candidate) -> int:
    """apple-touch-icons first, then PNG-like, then SVG, then .ico; larger before smaller up to 256."""
    try:
        path = urlsplit(c.url).path.lower()
    except ValueError:
        path = ""
    t = c.type or ""
    if any(r.startswith("apple-touch-icon") for r in c.rel):
        kind = 4
    elif "svg" in t or path.endswith(".svg"):
        kind = 2
    elif "icon" in t or path.endswith(".ico"):
        kind = 1
    else:
        kind = 3
    return kind * 1000 + min(c.size, 256)


def candidates(html: str, base: str, limit: int = 5) -> list[Candidate]:
    found: list[Candidate] = []
    for m in _LINK.finditer(html):
        attrs = attributes(m.group(0))
        rel = [r for r in attrs.get("rel", "").lower().split() if r]
        if not ({"icon", "apple-touch-icon", "apple-touch-icon-precomposed"} & set(rel)) or "mask-icon" in rel:
            continue
        href = attrs.get("href", "").strip()
        if not href:
            continue
        url = urljoin(base, href.replace(" ", "%20"))
        try:
            u = urlsplit(url)
        except ValueError:
            continue
        if u.scheme.lower() not in ("http", "https") or not u.hostname:
            continue
        found.append(Candidate(url, rel, attrs.get("type", "").lower() or None, _largest(attrs.get("sizes"))))
    ranked = sorted(found, key=score, reverse=True)  # stable: ties keep page order
    out: list[Candidate] = []
    for c in ranked:
        if all(c.url != x.url for x in out):
            out.append(c)
    return out[:limit]
