"""Everything the web backend keeps, under one data directory (the container's /data volume):

    servers.json         the saved servers, a JSON array of Server (spec/models.schema.json), in the user's order
    snapshots/<id>.json  each server's last good Overview, painted before the first poll answers
    known_hosts.json     trusted host keys by host:port (strict; a changed key is never replaced from the app)
    keys.json, keys/     SSH key pairs: an index (names, fingerprints, public keys) and one private key file each
    auth.json            the admin password's argon2id hash and the TOTP secret
    secret               32 random bytes for HMACs (forward-auth CSRF tokens)

Folders are 0700 and files 0600; every write goes to a temporary file in the same folder, is fsynced and renamed
over the old one, so a crash never leaves half a file. Private keys are stored unencrypted (mode 0600): protect the
volume, as you would ~/.ssh.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import secrets
import tempfile
import time
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from rackoon.core.jsonmodel import DecodeError, from_json, to_json
from rackoon.core.models import Server
from rackoon.core.overview import Overview
from rackoon.ssh import HostKey, KnownHosts

log = logging.getLogger("rackoon.storage")


def new_id() -> str:
    """Like Swift's `UUID().uuidString`."""
    return str(uuid.uuid4()).upper()


def now_iso() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def ensure_dir(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def write_private(path: Path, data: bytes) -> None:
    """Atomic, 0600, fsynced."""
    ensure_dir(path.parent)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def write_json(path: Path, value: Any) -> None:
    write_private(path, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode())


def read_json(path: Path) -> Any | None:
    """The file's JSON, None if it does not exist. An unreadable file is moved aside (never overwritten later) and
    reads as missing."""
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    try:
        return json.loads(text)
    except ValueError:
        aside = path.with_name(f"{path.name}.unreadable-{int(time.time())}")
        path.rename(aside)
        log.error("%s is not valid JSON; moved it to %s and started without it", path, aside.name)
        return None


class FileKnownHosts(KnownHosts):
    """`KnownHosts` saved to known_hosts.json. `trust` refuses to replace a different key: a changed key is blocked,
    and only removing the entry from the file by hand (as with ~/.ssh/known_hosts) lets a new one be trusted."""

    def __init__(self, path: Path) -> None:
        super().__init__()
        self.path = path
        raw = read_json(path) or {}
        for host_port, entry in raw.items():
            try:
                self.keys[host_port] = HostKey(entry["keyType"], base64.b64decode(entry["key"]))
            except (KeyError, TypeError, ValueError):
                log.error("known_hosts.json: skipping a malformed entry for %s", host_port)
        self._meta: dict[str, str] = {k: v.get("trustedAt", "") for k, v in raw.items() if isinstance(v, dict)}

    def trust(self, host: str, port: int, key: HostKey) -> None:
        existing = self.lookup(host, port)
        if existing is not None and existing != key:
            raise HostKeyConflict(host, port)
        super().trust(host, port, key)
        self._meta[self._id(host, port)] = now_iso()
        self._save()

    def forget(self, host: str, port: int) -> None:
        super().forget(host, port)
        self._meta.pop(self._id(host, port), None)
        self._save()

    def _save(self) -> None:
        write_json(self.path, {k: {"keyType": v.key_type, "key": base64.b64encode(v.blob).decode(),
                                   "fingerprint": v.fingerprint, "trustedAt": self._meta.get(k, "")}
                               for k, v in self.keys.items()})


class HostKeyConflict(Exception):
    def __init__(self, host: str, port: int) -> None:
        super().__init__(f"A different host key is already trusted for {host}:{port}.")


@dataclass(frozen=True)
class KeyInfo:
    """One SSH key pair. The private key never leaves the data folder through the API."""

    id: str
    name: str
    key_type: str
    fingerprint: str
    public_key: str
    """One `authorized_keys` line."""
    created_at: str
    source: str
    """"generated" or "imported"."""


@dataclass(frozen=True)
class CachedSnapshot:
    overview: Overview
    saved_at: str


class DataStore:
    def __init__(self, root: Path) -> None:
        self.root = root
        ensure_dir(root)
        ensure_dir(self.keys_dir)
        self.known_hosts = FileKnownHosts(root / "known_hosts.json")

    # --- paths

    @property
    def servers_file(self) -> Path:
        return self.root / "servers.json"

    @property
    def keys_dir(self) -> Path:
        return self.root / "keys"

    def key_path(self, key_id: str) -> Path:
        if not _is_id(key_id):
            raise ValueError("bad key id")
        return self.keys_dir / key_id

    # --- servers

    def load_servers(self) -> list[Server]:
        raw = read_json(self.servers_file)
        if raw is None:
            return []
        if not isinstance(raw, list):
            log.error("servers.json is not a list; ignoring it")
            return []
        servers: list[Server] = []
        for i, item in enumerate(raw):
            try:
                servers.append(from_json(Server, item))
            except DecodeError as e:
                log.error("servers.json[%d]: %s; skipped", i, e)
        return servers

    def save_servers(self, servers: list[Server]) -> None:
        write_json(self.servers_file, [to_json(s) for s in servers])

    # --- snapshots

    def snapshot_path(self, server_id: str) -> Path:
        if not _is_id(server_id):
            raise ValueError("bad server id")
        return self.root / "snapshots" / f"{server_id}.json"

    def save_snapshot(self, server_id: str, overview: Overview) -> None:
        write_json(self.snapshot_path(server_id), {"overview": to_json(overview), "savedAt": now_iso()})

    def load_snapshot(self, server_id: str) -> CachedSnapshot | None:
        raw = read_json(self.snapshot_path(server_id))
        if raw is None:
            return None
        try:
            return from_json(CachedSnapshot, raw)
        except DecodeError:
            return None

    def delete_snapshot(self, server_id: str) -> None:
        self.snapshot_path(server_id).unlink(missing_ok=True)

    # --- keys

    def load_keys(self) -> list[KeyInfo]:
        raw = read_json(self.root / "keys.json") or []
        keys: list[KeyInfo] = []
        for item in raw:
            try:
                keys.append(from_json(KeyInfo, item))
            except DecodeError as e:
                log.error("keys.json: %s; skipped", e)
        return keys

    def save_keys(self, keys: list[KeyInfo]) -> None:
        write_json(self.root / "keys.json", [to_json(k) for k in keys])

    def write_private_key(self, key_id: str, pem: str) -> None:
        write_private(self.key_path(key_id), pem.encode())

    def read_private_key(self, key_id: str) -> str:
        return self.key_path(key_id).read_text(encoding="utf-8")

    def delete_private_key(self, key_id: str) -> None:
        self.key_path(key_id).unlink(missing_ok=True)

    # --- auth state and the HMAC secret

    def load_auth(self) -> dict[str, Any]:
        raw = read_json(self.root / "auth.json")
        return raw if isinstance(raw, dict) else {}

    def save_auth(self, state: dict[str, Any]) -> None:
        write_json(self.root / "auth.json", state)

    def secret(self) -> bytes:
        path = self.root / "secret"
        try:
            data = path.read_bytes()
            if len(data) >= 32:
                return data
        except FileNotFoundError:
            pass
        data = secrets.token_bytes(32)
        write_private(path, data)
        return data

    def write_setup_token(self, token: str | None) -> None:
        path = self.root / "setup-token"
        if token is None:
            path.unlink(missing_ok=True)
        else:
            write_private(path, (token + "\n").encode())


def _is_id(value: str) -> bool:
    """Ids become file names, so only uuid-like text: letters, digits and dashes."""
    return 0 < len(value) <= 64 and all(c.isascii() and (c.isalnum() or c == "-") for c in value)
