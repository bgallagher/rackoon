"""SSH for the web backend: the asyncssh transport (stage W0 spike, docs/web-spikes.md)."""

from .transport import (
    AsyncSSHTransport,
    CommandResult,
    HostKey,
    HostKeyChanged,
    HostKeyUnknown,
    KnownHosts,
    ShellSession,
    SSHAuth,
    SSHEndpoint,
    SSHError,
    Stream,
    AuthFailed,
    ConnectionLost,
    Timeout,
    Unreachable,
    scan_host_key,
)

__all__ = [
    "AsyncSSHTransport",
    "AuthFailed",
    "CommandResult",
    "ConnectionLost",
    "HostKey",
    "HostKeyChanged",
    "HostKeyUnknown",
    "KnownHosts",
    "SSHAuth",
    "SSHEndpoint",
    "SSHError",
    "Stream",
    "ShellSession",
    "Timeout",
    "Unreachable",
    "scan_host_key",
]
