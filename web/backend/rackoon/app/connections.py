"""From a saved server to an SSH connection, and the host-key trust flow.

A server with a key (`identityFile` naming one of the web key store's files) signs in with it; one without signs in
with SSH `none` (Tailscale SSH). A new server's host key is shown to the user from a scan and trusted only when the
user confirms that exact fingerprint; a changed key is reported and never offered.
"""

from __future__ import annotations

import secrets
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from rackoon.core.models import Server
from rackoon.ssh import (
    AsyncSSHTransport,
    AuthFailed,
    CommandResult,
    HostKey,
    HostKeyChanged,
    HostKeyUnknown,
    SSHAuth,
    SSHEndpoint,
    SSHError,
    scan_host_key,
)

from .keys import KeyStore
from .storage import DataStore, HostKeyConflict

SCAN_TTL_SECONDS = 600

Scanner = Callable[[str, int], Awaitable[HostKey]]


class Transport(Protocol):
    """What the backend's services need from a server connection (AsyncSSHTransport, or the demo's)."""

    async def run(self, command: str, timeout: float, input: str | None = None) -> CommandResult: ...

    async def connect(self) -> None: ...

    async def close(self) -> None: ...


def key_id_of(server: Server, keys_dir: Path) -> str | None:
    """The web key a server signs in with, from its identityFile (a path inside the key store)."""
    if server.identity_file is None:
        return None
    path = Path(server.identity_file)
    return path.name if path.parent == keys_dir else None


@dataclass(frozen=True)
class Scan:
    server_id: str
    host: str
    port: int
    key: HostKey
    expires: float


@dataclass(frozen=True)
class CheckResult:
    """`ok`, `hostKeyUnknown`, `hostKeyChanged`, `authFailed`, `unreachable` or `failed`."""

    status: str
    message: str
    host_key: HostKey | None = None
    trusted: HostKey | None = None
    scan_id: str | None = None


class TrustError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code


class Connections:
    def __init__(self, store: DataStore, keys: KeyStore, scanner: Scanner = scan_host_key,
                 clock: Callable[[], float] = time.monotonic) -> None:
        self.store = store
        self.keys = keys
        self.scanner = scanner
        self.clock = clock
        self._scans: dict[str, Scan] = {}
        self._transports: dict[str, Transport] = {}

    def endpoint(self, server: Server) -> SSHEndpoint:
        key_id = key_id_of(server, self.store.keys_dir)
        if server.identity_file is not None and key_id is None:
            raise TrustError(409, "keyMissing", "This server names a key file that is not in Rackoon's key store.")
        auth = SSHAuth.key(self.keys.private_key(key_id)) if key_id else SSHAuth.none()
        return SSHEndpoint(server.host, server.user or "root", auth, server.port or 22)

    def transport(self, server: Server) -> Transport:
        """The server's shared transport (the monitor polls through it)."""
        t = self._transports.get(server.id)
        if t is None:
            t = AsyncSSHTransport(self.endpoint(server), self.store.known_hosts)
            self._transports[server.id] = t
        return t

    async def forget(self, server_id: str) -> None:
        """Drop the server's open connection (its address or key changed, or it was removed)."""
        t = self._transports.pop(server_id, None)
        if t is not None:
            await t.close()

    async def close(self) -> None:
        for server_id in list(self._transports):
            await self.forget(server_id)

    # --- host keys

    def _remember(self, server: Server, key: HostKey) -> str:
        now = self.clock()
        self._scans = {k: v for k, v in self._scans.items() if v.expires > now}
        scan_id = secrets.token_urlsafe(16)
        self._scans[scan_id] = Scan(server.id, server.host, server.port or 22, key, now + SCAN_TTL_SECONDS)
        return scan_id

    async def scan(self, server: Server) -> CheckResult:
        port = server.port or 22
        try:
            presented = await self.scanner(server.host, port)
        except SSHError as e:
            return CheckResult("unreachable", str(e))
        trusted = self.store.known_hosts.lookup(server.host, port)
        if trusted is None:
            return CheckResult("hostKeyUnknown", "This server's host key is not trusted yet.", presented,
                               scan_id=self._remember(server, presented))
        if trusted != presented:
            return CheckResult("hostKeyChanged", "The host key changed since it was trusted. Connection blocked.",
                               presented, trusted)
        return CheckResult("ok", "The host key is trusted.", presented, trusted)

    def trust(self, server: Server, scan_id: str, fingerprint: str) -> HostKey:
        """Trusts exactly the key the user was shown: the scan must be this server's, unexpired, for its current
        address, and carry the fingerprint the user confirmed. Never replaces a different trusted key."""
        scan = self._scans.get(scan_id)
        if scan is None or scan.expires <= self.clock() or scan.server_id != server.id:
            raise TrustError(409, "scanExpired", "Scan the server again and compare the fingerprint.")
        if (scan.host, scan.port) != (server.host, server.port or 22):
            raise TrustError(409, "scanExpired", "The server's address changed since the scan. Scan it again.")
        if scan.key.fingerprint != fingerprint:
            raise TrustError(409, "fingerprintMismatch", "That is not the fingerprint the scan found.")
        try:
            self.store.known_hosts.trust(scan.host, scan.port, scan.key)
        except HostKeyConflict:
            raise TrustError(409, "hostKeyChanged", "A different host key is already trusted for this server. "
                             "It is never replaced from here.") from None
        del self._scans[scan_id]
        return scan.key

    async def check(self, server: Server) -> CheckResult:
        """Connects (host key, then sign-in) and runs nothing."""
        try:
            t = AsyncSSHTransport(self.endpoint(server), self.store.known_hosts)
        except TrustError as e:
            return CheckResult("failed", str(e))
        try:
            await t.connect()
        except HostKeyUnknown as e:
            return CheckResult("hostKeyUnknown", str(e), e.presented, scan_id=self._remember(server, e.presented))
        except HostKeyChanged as e:
            return CheckResult("hostKeyChanged", str(e), e.presented, e.trusted)
        except AuthFailed as e:
            return CheckResult("authFailed", str(e))
        except SSHError as e:
            return CheckResult("unreachable", str(e))
        finally:
            await t.close()
        return CheckResult("ok", "Connected and signed in.")
