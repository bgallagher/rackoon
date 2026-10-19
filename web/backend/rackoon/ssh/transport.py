"""The web backend's SSH transport, on asyncssh.

Same contract as the Mac's `OpenSSHTransport` and Android's `SshjTransport` (docs/parity.md):

- `run(command, timeout)`: one command on a shared connection (the web's ControlMaster), stdout, stderr, exit code.
- `run(command, timeout, input=...)`: the input goes to the command's standard input and nowhere else (not the
  command text, not a log). It always uses its own connection, so it is checked against the trusted host key on
  its own; a secret (a sudo password) never rides on a connection opened earlier.
- `stream(command)`: output over a pty, on its own connection. Cancelling it types Ctrl-C (0x03) into the pty, gives
  the remote command a moment to exit, then closes. Merely closing the channel leaves `docker logs -f` running on
  Tailscale SSH servers.
- `open_shell(cols, rows)`: an interactive pty for a terminal tab, resizable.

Host keys are strict: a server is only talked to when it presents exactly the key `KnownHosts` holds for it. An
unknown key raises `HostKeyUnknown` (carrying the key to show the user), a different one `HostKeyChanged`, which is
never offered for acceptance. Both happen during key exchange, before any credential is sent. Nothing reads
`~/.ssh/config`, `~/.ssh/known_hosts` or an ssh-agent: everything comes from the arguments.
"""

from __future__ import annotations

import asyncio
import base64
import errno
import hashlib
import signal
import socket
from collections.abc import AsyncIterable, AsyncIterator
from dataclasses import dataclass, field
from types import TracebackType
from typing import Literal

import asyncssh

# How long a cancelled stream waits for the remote command to exit after Ctrl-C before closing anyway.
CANCEL_GRACE_SECONDS = 2.0
# Like `ServerAliveInterval=15` / `ServerAliveCountMax=3` on the Mac: a dead link fails in about 45 s.
KEEPALIVE_INTERVAL = 15
KEEPALIVE_COUNT_MAX = 3
CONNECT_TIMEOUT = 15.0


# --- Errors -------------------------------------------------------------------------------------------------------


class SSHError(Exception):
    """What can go wrong reaching a server, in terms the UI can explain (mirrors Android's `SshException`)."""


class Unreachable(SSHError):
    """No connection at all: no route, refused, timed out, unknown host name."""


class AuthFailed(SSHError):
    """The server did not accept the credentials (the host key was already checked)."""


class HostKeyUnknown(SSHError):
    """Nothing is trusted for this server yet. No credentials were sent."""

    def __init__(self, presented: HostKey) -> None:
        super().__init__(f"This server's host key is not trusted yet ({presented.fingerprint}).")
        self.presented = presented


class HostKeyChanged(SSHError):
    """The server presented a different key than the trusted one. Blocked; no credentials were sent."""

    def __init__(self, trusted: HostKey, presented: HostKey) -> None:
        super().__init__("The host key changed since it was trusted. Connection blocked.")
        self.trusted = trusted
        self.presented = presented


class ConnectionLost(SSHError):
    """An established connection dropped or failed mid-command."""


class Timeout(SSHError):
    """A command did not finish in time."""

    def __init__(self, seconds: float) -> None:
        super().__init__(f"The command did not finish within {seconds:g} s.")
        self.seconds = seconds


# --- Host keys ----------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class HostKey:
    """A server's public host key: its type (`ssh-ed25519`) and wire-format blob."""

    key_type: str
    blob: bytes

    @property
    def fingerprint(self) -> str:
        """`SHA256:...` as `ssh-keygen -l` prints it."""
        digest = base64.b64encode(hashlib.sha256(self.blob).digest()).decode().rstrip("=")
        return f"SHA256:{digest}"

    @classmethod
    def from_asyncssh(cls, key: asyncssh.SSHKey) -> HostKey:
        return cls(key.get_algorithm(), key.public_data)

    @classmethod
    def from_known_hosts_line(cls, line: str) -> tuple[str, int, HostKey]:
        """One `ssh-keyscan` line, `[host]:port type base64` or `host type base64`."""
        names, key_type, b64 = line.split()[:3]
        name = names.split(",")[0]
        port = 22
        if name.startswith("["):
            host, _, port_text = name[1:].partition("]:")
            port = int(port_text)
        else:
            host = name
        return host, port, cls(key_type, base64.b64decode(b64))

    def algorithms(self) -> list[str]:
        """The host key algorithms that make a server present this key (an RSA key has three)."""
        if self.key_type == "ssh-rsa":
            return ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"]
        return [self.key_type]


Verdict = Literal["trusted", "unknown", "changed"]


@dataclass
class KnownHosts:
    """Trusted host keys by `host:port`. In memory for the spike; stage W2 stores it under /data."""

    keys: dict[str, HostKey] = field(default_factory=dict)

    @staticmethod
    def _id(host: str, port: int) -> str:
        return f"{host.lower()}:{port}"

    def lookup(self, host: str, port: int) -> HostKey | None:
        return self.keys.get(self._id(host, port))

    def trust(self, host: str, port: int, key: HostKey) -> None:
        self.keys[self._id(host, port)] = key

    def forget(self, host: str, port: int) -> None:
        self.keys.pop(self._id(host, port), None)

    def verdict(self, host: str, port: int, presented: HostKey) -> Verdict:
        trusted = self.lookup(host, port)
        if trusted is None:
            return "unknown"
        return "trusted" if trusted == presented else "changed"


# --- Endpoint and auth --------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class SSHAuth:
    """How to sign in. `none` is Tailscale SSH (the tailnet already identified us)."""

    kind: Literal["none", "key", "password"]
    private_key: str | None = field(default=None, repr=False)
    passphrase: str | None = field(default=None, repr=False)
    password: str | None = field(default=None, repr=False)

    @classmethod
    def none(cls) -> SSHAuth:
        return cls("none")

    @classmethod
    def key(cls, pem: str, passphrase: str | None = None) -> SSHAuth:
        return cls("key", private_key=pem, passphrase=passphrase)

    @classmethod
    def with_password(cls, password: str) -> SSHAuth:
        return cls("password", password=password)


@dataclass(frozen=True)
class SSHEndpoint:
    host: str
    user: str
    auth: SSHAuth
    port: int = 22


@dataclass(frozen=True)
class CommandResult:
    stdout: str
    stderr: str
    exit_code: int


# --- Connection ---------------------------------------------------------------------------------------------------


class _Client(asyncssh.SSHClient):
    """Checks the host key against `KnownHosts` and remembers the verdict, so a refused key becomes a precise error."""

    def __init__(self, known: KnownHosts, host: str, port: int) -> None:
        self._known = known
        self._host = host
        self._port = port
        self.verdict: Verdict | None = None
        self.presented: HostKey | None = None
        self.lost = False

    def validate_host_public_key(self, host: str, addr: str, port: int, key: asyncssh.SSHKey) -> bool:
        self.presented = HostKey.from_asyncssh(key)
        self.verdict = self._known.verdict(self._host, self._port, self.presented)
        return self.verdict == "trusted"

    def connection_lost(self, exc: Exception | None) -> None:
        self.lost = True


# OpenSSH's own preference, so a new server shows the same key `ssh` and `ssh-keyscan` would (asyncssh's default
# order puts RSA first).
_PREFERRED_HOST_KEY_ALGS = [
    "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
    "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com", "rsa-sha2-512", "rsa-sha2-256",
]


def _plain_host_key_algs() -> list[str]:
    # No certificate algorithms: we pin plain keys, and a host certificate would be checked against CAs we never trust.
    available = [alg.decode() for alg in asyncssh.public_key.get_default_public_key_algs()]
    preferred = [alg for alg in _PREFERRED_HOST_KEY_ALGS if alg in available]
    return preferred + [alg for alg in available if alg not in preferred]


async def _connect(endpoint: SSHEndpoint, known: KnownHosts) -> tuple[asyncssh.SSHClientConnection, _Client]:
    client = _Client(known, endpoint.host, endpoint.port)
    trusted = known.lookup(endpoint.host, endpoint.port)
    # Ask for the trusted key's algorithm, or a server with several keys could show another one and look "changed".
    host_key_algs = trusted.algorithms() if trusted else _plain_host_key_algs()
    auth = endpoint.auth
    client_keys = [asyncssh.import_private_key(auth.private_key, auth.passphrase)] if auth.private_key else None
    try:
        conn = await asyncssh.connect(
            endpoint.host,
            endpoint.port,
            username=endpoint.user,
            client_factory=lambda: client,
            # An empty (not None) trusted list sends every key to `validate_host_public_key`.
            known_hosts=([], [], []),
            server_host_key_algs=host_key_algs,
            config=None,
            agent_path=None,
            client_keys=client_keys,
            password=auth.password,
            kbdint_auth=False,
            gss_host=None,
            ignore_encrypted=False,
            connect_timeout=CONNECT_TIMEOUT,
            keepalive_interval=KEEPALIVE_INTERVAL,
            keepalive_count_max=KEEPALIVE_COUNT_MAX,
        )
    except asyncssh.HostKeyNotVerifiable as e:
        if client.presented is not None and client.verdict == "unknown":
            raise HostKeyUnknown(client.presented) from None
        if client.presented is not None and client.verdict == "changed" and trusted is not None:
            raise HostKeyChanged(trusted, client.presented) from None
        raise Unreachable(str(e)) from None
    except asyncssh.PermissionDenied as e:
        raise AuthFailed(e.reason or "permission denied") from None
    except asyncssh.KeyImportError as e:
        raise AuthFailed(f"the private key could not be read: {e}") from None
    except (OSError, asyncio.TimeoutError, asyncssh.Error) as e:
        raise Unreachable(_describe(e, endpoint)) from None
    return conn, client


def _describe(e: BaseException, endpoint: SSHEndpoint) -> str:
    """The failure in the words ssh would use, so `connection_failure.explain` recognises it on every platform."""
    where = f"{endpoint.host} port {endpoint.port}"
    if isinstance(e, ConnectionRefusedError):
        return f"ssh: connect to host {where}: Connection refused"
    if isinstance(e, socket.gaierror):
        return f"ssh: Could not resolve hostname {endpoint.host}: Name or service not known"
    if isinstance(e, (TimeoutError, asyncio.TimeoutError)):
        return f"ssh: connect to host {where}: Connection timed out"
    if isinstance(e, OSError) and e.errno in (errno.EHOSTUNREACH, errno.ENETUNREACH):
        what = "No route to host" if e.errno == errno.EHOSTUNREACH else "Network is unreachable"
        return f"ssh: connect to host {where}: {what}"
    if isinstance(e, (asyncssh.ConnectionLost, asyncssh.DisconnectError, ConnectionResetError, BrokenPipeError)):
        return f"Connection closed by {where} ({e})"
    return str(e) or type(e).__name__


async def scan_host_key(host: str, port: int = 22) -> HostKey:
    """The key a server presents, for the user to compare before trusting it. Sends no credentials."""
    try:
        await _connect(SSHEndpoint(host, "rackoon-scan", SSHAuth.none(), port), KnownHosts())
    except HostKeyUnknown as e:
        return e.presented
    raise Unreachable("the server did not present a host key")


def _exit_code(process: asyncssh.SSHClientProcess[bytes]) -> int:
    """The exit status, or the signal number if the remote command was killed (like `OpenSSHTransport.exitCode`)."""
    if process.exit_status is not None and process.exit_status >= 0:
        return process.exit_status
    if process.exit_signal is not None:
        name = process.exit_signal[0]
        try:
            return int(signal.Signals["SIG" + name])
        except KeyError:
            return 255
    return 255


def _decode(data: bytes | str | None) -> str:
    if data is None:
        return ""
    return data if isinstance(data, str) else data.decode("utf-8", errors="replace")


class AsyncSSHTransport:
    """One server. `run` shares one lazily opened connection; `run(input=...)`, `stream` and shells open their own."""

    def __init__(self, endpoint: SSHEndpoint, known_hosts: KnownHosts) -> None:
        self.endpoint = endpoint
        self.known_hosts = known_hosts
        self._shared: tuple[asyncssh.SSHClientConnection, _Client] | None = None
        self._lock = asyncio.Lock()

    async def __aenter__(self) -> AsyncSSHTransport:
        return self

    async def __aexit__(self, *exc: object) -> None:
        await self.close()

    async def connect(self) -> None:
        await self._connection()

    async def _connection(self) -> asyncssh.SSHClientConnection:
        async with self._lock:
            if self._shared is None or self._shared[1].lost:
                self._shared = await _connect(self.endpoint, self.known_hosts)
            return self._shared[0]

    async def _invalidate(self, conn: asyncssh.SSHClientConnection) -> None:
        async with self._lock:
            if self._shared is not None and self._shared[0] is conn:
                self._shared = None
        conn.close()

    async def close(self) -> None:
        async with self._lock:
            shared, self._shared = self._shared, None
        if shared is not None:
            shared[0].close()
            await shared[0].wait_closed()

    async def run(self, command: str, timeout: float, input: str | None = None) -> CommandResult:
        if input is not None:
            # Own connection, checked against the pinned host key on its own; closed straight after.
            conn, _ = await _connect(self.endpoint, self.known_hosts)
            try:
                return await self._exec(conn, command, timeout, input.encode())
            finally:
                conn.close()
                await conn.wait_closed()
        conn = await self._connection()
        try:
            return await self._exec(conn, command, timeout, None)
        except ConnectionLost:
            await self._invalidate(conn)
            raise

    async def _exec(self, conn: asyncssh.SSHClientConnection, command: str, timeout: float,
                    input: bytes | None) -> CommandResult:
        try:
            process = await conn.create_process(command, encoding=None)
        except (asyncssh.ChannelOpenError, asyncssh.ConnectionLost, asyncssh.DisconnectError, OSError) as e:
            raise ConnectionLost(str(e)) from None
        try:
            async with asyncio.timeout(timeout):
                # communicate writes the input (if any) and then EOF, so the command never waits on stdin.
                stdout, stderr = await process.communicate(input)
        except TimeoutError:
            raise Timeout(timeout) from None
        except (asyncssh.ConnectionLost, asyncssh.DisconnectError, BrokenPipeError) as e:
            raise ConnectionLost(str(e)) from None
        finally:
            process.close()
        if process.exit_status is None and process.exit_signal is None:
            raise ConnectionLost("the connection closed before the command finished")
        return CommandResult(_decode(stdout), _decode(stderr), _exit_code(process))

    async def upload(self, command: str, chunks: AsyncIterable[bytes], timeout: float) -> CommandResult:
        """Feeds `chunks` to the command's standard input (file content never travels in a command), then EOF, on the
        shared connection. Cancelling closes the channel; the command sees a short input and changes nothing."""
        conn = await self._connection()
        try:
            process = await conn.create_process(command, encoding=None)
        except (asyncssh.ChannelOpenError, asyncssh.ConnectionLost, asyncssh.DisconnectError, OSError) as e:
            await self._invalidate(conn)
            raise ConnectionLost(str(e)) from None
        try:
            async with asyncio.timeout(timeout):
                async for chunk in chunks:
                    process.stdin.write(chunk)
                    await process.stdin.drain()
                process.stdin.write_eof()
                stdout, stderr = await asyncio.gather(process.stdout.read(), process.stderr.read())
                await process.wait_closed()
        except TimeoutError:
            raise Timeout(timeout) from None
        except (asyncssh.ConnectionLost, asyncssh.DisconnectError, BrokenPipeError) as e:
            raise ConnectionLost(str(e)) from None
        finally:
            process.close()
        return CommandResult(_decode(stdout), _decode(stderr), _exit_code(process))

    async def download(self, command: str) -> AsyncIterator[bytes]:
        """The command's standard output as it arrives, on the shared connection. Raises `SSHError` at the end when the
        command failed (with its stderr), so a partial download is never mistaken for a whole one."""
        conn = await self._connection()
        try:
            process = await conn.create_process(command, encoding=None)
        except (asyncssh.ChannelOpenError, asyncssh.ConnectionLost, asyncssh.DisconnectError, OSError) as e:
            await self._invalidate(conn)
            raise ConnectionLost(str(e)) from None
        try:
            while True:
                chunk = await process.stdout.read(65536)
                if not chunk:
                    break
                yield chunk
            stderr = await process.stderr.read()
            await process.wait_closed()
            if _exit_code(process) != 0:
                raise SSHError(_decode(stderr).strip() or f"the server answered with status {_exit_code(process)}")
        except (asyncssh.ConnectionLost, asyncssh.DisconnectError) as e:
            raise ConnectionLost(str(e)) from None
        finally:
            process.close()

    def stream(self, command: str, input: AsyncIterable[str] | None = None,
               cols: int = 80, rows: int = 24) -> Stream:
        """Output of `command` over a pty on its own connection. Use as `async with t.stream(c) as s: async for ...`.
        Strings from `input` are typed into the pty (a sudo password at its prompt); they are never recorded."""
        return Stream(self, command, input, cols, rows)

    async def open_shell(self, cols: int, rows: int, command: str | None = None) -> ShellSession:
        """A terminal tab: an interactive pty on the shared connection (like the Mac's tabs over ControlMaster)."""
        conn = await self._connection()
        try:
            process = await conn.create_process(command, term_type="xterm-256color", term_size=(cols, rows),
                                                encoding=None)
        except (asyncssh.ChannelOpenError, asyncssh.ConnectionLost, asyncssh.DisconnectError, OSError) as e:
            await self._invalidate(conn)
            raise ConnectionLost(str(e)) from None
        return ShellSession(process)


class Stream:
    """A running `stream`. Iterating yields decoded text (asyncssh's incremental decoder keeps a UTF-8 character that
    is split across reads whole). Leaving the `async with`, `aclose()`, or cancelling the task that reads it, all
    type Ctrl-C into the pty first, then close the channel and the connection."""

    def __init__(self, transport: AsyncSSHTransport, command: str, input: AsyncIterable[str] | None,
                 cols: int, rows: int) -> None:
        self._transport = transport
        self._command = command
        self._input = input
        self._size = (cols, rows)
        self._conn: asyncssh.SSHClientConnection | None = None
        self._process: asyncssh.SSHClientProcess[str] | None = None
        self._feeder: asyncio.Task[None] | None = None
        self._closed = False
        self.exit_status: int | None = None

    async def __aenter__(self) -> Stream:
        await self._start()
        return self

    async def __aexit__(self, exc_type: type[BaseException] | None, exc: BaseException | None,
                        tb: TracebackType | None) -> None:
        await self.aclose()

    async def _start(self) -> None:
        if self._process is not None:
            return
        self._conn, _ = await _connect(self._transport.endpoint, self._transport.known_hosts)
        try:
            self._process = await self._conn.create_process(
                self._command, term_type="xterm-256color", term_size=self._size,
                encoding="utf-8", errors="replace", stderr=asyncssh.STDOUT)
        except (asyncssh.ChannelOpenError, asyncssh.ConnectionLost, asyncssh.DisconnectError, OSError) as e:
            await self.aclose()
            raise ConnectionLost(str(e)) from None
        if self._input is not None:
            self._feeder = asyncio.create_task(self._feed(self._input, self._process))

    @staticmethod
    async def _feed(input: AsyncIterable[str], process: asyncssh.SSHClientProcess[str]) -> None:
        async for text in input:
            process.stdin.write(text)

    def __aiter__(self) -> AsyncIterator[str]:
        return self._chunks()

    async def _chunks(self) -> AsyncIterator[str]:
        await self._start()
        assert self._process is not None
        try:
            while True:
                chunk = await self._process.stdout.read(65536)
                if not chunk:
                    break
                yield chunk
        except (asyncssh.ConnectionLost, asyncssh.DisconnectError) as e:
            raise ConnectionLost(str(e)) from None
        await self._process.wait_closed()
        self.exit_status = self._process.exit_status

    async def aclose(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self._feeder is not None:
            self._feeder.cancel()
        process, conn = self._process, self._conn
        try:
            if process is not None and process.exit_status is None and process.exit_signal is None:
                # Ctrl-C through the pty reaches the remote command (its terminal sends SIGINT to the foreground
                # process group); closing alone does not stop `docker logs -f` on Tailscale SSH.
                try:
                    process.stdin.write("\x03")
                    await asyncio.wait_for(asyncio.shield(process.wait_closed()), CANCEL_GRACE_SECONDS)
                except (TimeoutError, asyncssh.Error, OSError, BrokenPipeError):
                    pass
        finally:
            if process is not None:
                process.close()
            if conn is not None:
                conn.close()
                await conn.wait_closed()


class ShellSession:
    """One interactive pty. Bytes in, bytes out: the browser's xterm.js decodes UTF-8 itself."""

    def __init__(self, process: asyncssh.SSHClientProcess[bytes]) -> None:
        self._process = process

    async def read(self) -> bytes:
        """The next output, or b"" once the shell ended."""
        try:
            return await self._process.stdout.read(65536)
        except (asyncssh.ConnectionLost, asyncssh.DisconnectError) as e:
            raise ConnectionLost(str(e)) from None

    def write(self, data: bytes) -> None:
        self._process.stdin.write(data)

    def resize(self, cols: int, rows: int) -> None:
        self._process.change_terminal_size(cols, rows)

    @property
    def exit_status(self) -> int | None:
        return self._process.exit_status

    async def close(self) -> None:
        self._process.close()
        await self._process.wait_closed()
