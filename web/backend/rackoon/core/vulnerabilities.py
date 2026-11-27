"""Known vulnerabilities in installed packages (docs/security-plan.md, stage S3), ported from the Swift core's
Vulnerabilities.swift.

Opt-in: the read-only `security_packages` command lists installed packages, and only when the user turned the lookup on
are source package names and versions sent to OSV.dev (run by Google), from this backend, never from the server.
Pure parts are checked against spec/scenarios/vulnerability-report.json and debian-version.json; the network goes
through an injected `OSVClient` so tests replay spec/osv.
"""

from __future__ import annotations

import asyncio
import json
import time
import urllib.parse
from dataclasses import dataclass, field
from typing import Any, Protocol

from . import spec
from .security import sections

# --- Inventory -------------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class InstalledPackage:
    binary: str
    version: str
    source: str
    source_version: str


@dataclass(frozen=True)
class InventoryOS:
    id: str
    like: str
    version: str
    codename: str


@dataclass
class PackageInventory:
    os: InventoryOS
    packages: list[InstalledPackage] = field(default_factory=list)


def command() -> str:
    return spec.script("security_packages")


def parse_inventory(output: str) -> PackageInventory:
    secs = sections(output)
    os_kv: dict[str, str] = {}
    for line in secs.get("os", []):
        i = line.find("=")
        if i >= 0:
            os_kv[line[:i]] = line[i + 1:].strip(" \t")
    packages = []
    for line in secs.get("packages", []):
        f = line.split("\t")
        if len(f) < 4 or not f[0] or not f[1]:
            continue
        packages.append(InstalledPackage(f[0], f[1], f[2] or f[0], f[3] or f[1]))
    return PackageInventory(InventoryOS(os_kv.get("id", ""), os_kv.get("like", ""), os_kv.get("version", ""),
                                        os_kv.get("codename", "")), packages)


# --- dpkg version order ----------------------------------------------------------------------------------------------


def _split(v: str) -> tuple[int, str, str]:
    epoch = 0
    rest = v
    colon = rest.find(":")
    if colon >= 0 and rest[:colon].isdigit():
        epoch = int(rest[:colon])
        rest = rest[colon + 1:]
    dash = rest.rfind("-")
    if dash >= 0:
        return epoch, rest[:dash], rest[dash + 1:]
    return epoch, rest, ""


def _order(c: str | None) -> int:
    if c is None or ("0" <= c <= "9"):
        return 0
    if c == "~":
        return -1
    if c.isascii() and c.isalpha():
        return ord(c)
    return ord(c) + 256


def _is_digit(c: str) -> bool:
    return "0" <= c <= "9"


def _part(a: str, b: str) -> int:
    i = j = 0
    while i < len(a) or j < len(b):
        first = 0
        while (i < len(a) and not _is_digit(a[i])) or (j < len(b) and not _is_digit(b[j])):
            ac = _order(a[i] if i < len(a) else None)
            bc = _order(b[j] if j < len(b) else None)
            if ac != bc:
                return -1 if ac < bc else 1
            i += 1
            j += 1
        while i < len(a) and a[i] == "0":
            i += 1
        while j < len(b) and b[j] == "0":
            j += 1
        while i < len(a) and _is_digit(a[i]) and j < len(b) and _is_digit(b[j]):
            if first == 0:
                first = ord(a[i]) - ord(b[j])
            i += 1
            j += 1
        if i < len(a) and _is_digit(a[i]):
            return 1
        if j < len(b) and _is_digit(b[j]):
            return -1
        if first:
            return -1 if first < 0 else 1
    return 0


def compare_versions(a: str, b: str) -> int:
    """dpkg's ordering: -1, 0 or 1."""
    ea, ua, ra = _split(a)
    eb, ub, rb = _split(b)
    if ea != eb:
        return -1 if ea < eb else 1
    u = _part(ua, ub)
    return u if u else _part(ra, rb)


# --- OSV -------------------------------------------------------------------------------------------------------------

BATCH_URL = "https://api.osv.dev/v1/querybatch"
BATCH_SIZE = 500


def record_url(vuln_id: str) -> str:
    return "https://api.osv.dev/v1/vulns/" + urllib.parse.quote(vuln_id)


@dataclass(frozen=True)
class OSVQuery:
    name: str
    ecosystem: str
    version: str


@dataclass(frozen=True)
class Affected:
    ecosystem: str
    name: str
    fixed: list[str]


@dataclass(frozen=True)
class OSVRecord:
    id: str
    modified: str
    summary: str
    aliases: list[str]
    ubuntu_priority: str | None
    affected: list[Affected]


class OSVError(Exception):
    pass


def ecosystem(os_id: str, version: str) -> str | None:
    parts = version.split(".") if version else []
    if os_id == "ubuntu":
        if len(parts) != 2 or not parts[0].isdigit() or not parts[1].isdigit():
            return None
        return f"Ubuntu:{version}:LTS" if parts[1] == "04" and int(parts[0]) % 2 == 0 else f"Ubuntu:{version}"
    if os_id == "debian":
        if not parts or not parts[0].isdigit():
            return None
        return f"Debian:{parts[0]}"
    return None


def queries(inventory: PackageInventory) -> list[OSVQuery]:
    eco = ecosystem(inventory.os.id, inventory.os.version)
    if eco is None:
        return []
    unique = {OSVQuery(p.source, eco, p.source_version) for p in inventory.packages}
    return sorted(unique, key=lambda q: (q.name, q.version))


def batch_body(qs: list[OSVQuery], page_tokens: list[str | None] | None = None) -> bytes:
    items: list[dict[str, Any]] = []
    for i, q in enumerate(qs):
        item: dict[str, Any] = {"package": {"name": q.name, "ecosystem": q.ecosystem}, "version": q.version}
        if page_tokens is not None and page_tokens[i] is not None:
            item["page_token"] = page_tokens[i]
        items.append(item)
    return json.dumps({"queries": items}, sort_keys=True).encode()


def parse_batch(data: bytes, count: int) -> tuple[list[list[str]], list[str | None]]:
    doc = json.loads(data)
    if not isinstance(doc, dict):
        raise OSVError("not an object")
    results = doc.get("results") or []
    if len(results) != count:
        raise OSVError(f"expected {count} results, got {len(results)}")
    ids = [[v["id"] for v in (r.get("vulns") or []) if isinstance(v.get("id"), str)] for r in results]
    tokens = [r.get("next_page_token") if isinstance(r.get("next_page_token"), str) else None for r in results]
    return ids, tokens


def parse_record(data: bytes) -> OSVRecord:
    doc = json.loads(data)
    if not isinstance(doc, dict) or not isinstance(doc.get("id"), str):
        raise OSVError("no id")
    priority = next((s.get("score") for s in doc.get("severity") or [] if s.get("type") == "Ubuntu"), None)
    affected = []
    for a in doc.get("affected") or []:
        pkg = a.get("package") or {}
        if not isinstance(pkg.get("ecosystem"), str) or not isinstance(pkg.get("name"), str):
            continue
        fixed = [e["fixed"] for r in a.get("ranges") or [] if r.get("type") == "ECOSYSTEM"
                 for e in r.get("events") or [] if isinstance(e.get("fixed"), str)]
        affected.append(Affected(pkg["ecosystem"], pkg["name"], fixed))
    return OSVRecord(doc["id"], doc.get("modified", ""), doc.get("summary", ""), list(doc.get("aliases") or []),
                     priority.lower() if isinstance(priority, str) else None, affected)


# --- Report ----------------------------------------------------------------------------------------------------------

SEVERITIES = ["critical", "high", "medium", "low", "negligible", "unrated"]
STATUSES = ["fix_waiting", "fix_released", "no_fix"]


@dataclass(frozen=True)
class PendingPackage:
    name: str
    new_version: str


@dataclass
class VulnerabilityFinding:
    id: str
    package: str
    installed: str
    fixed: str | None
    status: str  # fix_waiting, fix_released, no_fix
    severity: str
    summary: str
    aliases: list[str]
    binaries: list[str]


def build_report(inventory: PackageInventory, qs: list[OSVQuery], ids: list[list[str]], records: dict[str, OSVRecord],
                 pending: list[PendingPackage]) -> list[VulnerabilityFinding]:
    binaries: dict[str, list[str]] = {}
    for p in inventory.packages:
        binaries.setdefault(p.source, []).append(p.binary)
    new_version: dict[str, str] = {}
    for pp in pending:
        new_version.setdefault(pp.name, pp.new_version)
    out: list[VulnerabilityFinding] = []
    seen: set[str] = set()
    for q, found in zip(qs, ids):
        for vid in found:
            key = f"{q.name}|{vid}"
            record = records.get(vid)
            if key in seen or record is None:
                continue
            seen.add(key)
            affected = next((a for a in record.affected if a.ecosystem == q.ecosystem and a.name == q.name), None)
            if affected is None:
                continue
            newer = [f for f in affected.fixed if compare_versions(f, q.version) > 0]
            fixed = None
            for f in newer:
                if fixed is None or compare_versions(f, fixed) < 0:
                    fixed = f
            if fixed is None and affected.fixed:
                continue  # every fix is already installed
            bins = sorted(binaries.get(q.name, []))
            if fixed is not None:
                waiting = any(b in new_version and compare_versions(new_version[b], fixed) >= 0 for b in bins)
                status = "fix_waiting" if waiting else "fix_released"
            else:
                status = "no_fix"
            priority = record.ubuntu_priority if record.ubuntu_priority in SEVERITIES else "unrated"
            out.append(VulnerabilityFinding(vid, q.name, q.version, fixed, status, priority, record.summary,
                                            record.aliases, bins))
    return sorted(out, key=lambda f: (STATUSES.index(f.status), SEVERITIES.index(f.severity), f.id))


def finding_json(f: VulnerabilityFinding) -> dict[str, Any]:
    return {"id": f.id, "package": f.package, "installed": f.installed, "fixed": f.fixed, "status": f.status,
            "severity": f.severity, "summary": f.summary, "aliases": f.aliases, "binaries": f.binaries}


# --- Lookup ----------------------------------------------------------------------------------------------------------


class OSVClient(Protocol):
    async def post(self, url: str, body: bytes) -> bytes: ...

    async def get(self, url: str) -> bytes: ...


class OSVCache:
    """OSV answers for a day, so opening the page again sends nothing new."""

    LIFETIME = 86400.0

    def __init__(self) -> None:
        self.answers: dict[OSVQuery, tuple[list[str], float]] = {}
        self.records: dict[str, tuple[OSVRecord, float]] = {}

    def ids(self, q: OSVQuery, now: float) -> list[str] | None:
        hit = self.answers.get(q)
        return hit[0] if hit and now - hit[1] < self.LIFETIME else None

    def record(self, vid: str, now: float) -> OSVRecord | None:
        hit = self.records.get(vid)
        return hit[0] if hit and now - hit[1] < self.LIFETIME else None


async def lookup(inventory: PackageInventory, pending: list[PendingPackage], client: OSVClient, cache: OSVCache,
                 now: float | None = None, concurrency: int = 8) -> list[VulnerabilityFinding]:
    now = time.time() if now is None else now
    qs = queries(inventory)
    ids: list[list[str]] = [[] for _ in qs]
    ask: list[int] = []
    for i, q in enumerate(qs):
        cached = cache.ids(q, now)
        if cached is None:
            ask.append(i)
        else:
            ids[i] = list(cached)
    for start in range(0, len(ask), BATCH_SIZE):
        chunk = ask[start:start + BATCH_SIZE]
        open_ = list(chunk)
        tokens: list[str | None] | None = None
        while open_:
            batch = [qs[i] for i in open_]
            got, next_tokens = parse_batch(await client.post(BATCH_URL, batch_body(batch, tokens)), len(batch))
            follow: list[int] = []
            follow_tokens: list[str | None] = []
            for k, i in enumerate(open_):
                ids[i] += got[k]
                if next_tokens[k] is not None:
                    follow.append(i)
                    follow_tokens.append(next_tokens[k])
            open_, tokens = follow, follow_tokens
        for i in chunk:
            cache.answers[qs[i]] = (ids[i], now)

    records: dict[str, OSVRecord] = {}
    missing: list[str] = []
    for vid in sorted({v for found in ids for v in found}):
        hit = cache.record(vid, now)
        if hit is None:
            missing.append(vid)
        else:
            records[vid] = hit
    gate = asyncio.Semaphore(max(1, concurrency))

    async def fetch(vid: str) -> OSVRecord:
        async with gate:
            return parse_record(await client.get(record_url(vid)))

    for record in await asyncio.gather(*(fetch(v) for v in missing)):
        records[record.id] = record
        cache.records[record.id] = (record, now)
    return build_report(inventory, qs, ids, records, pending)
