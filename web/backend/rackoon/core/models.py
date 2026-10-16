"""`Server` and `AttentionItem` from spec/models.schema.json, and the connection-field checks
(spec/scenarios/server-input.json)."""

from __future__ import annotations

import enum
from dataclasses import dataclass

from .text import to_int32


@dataclass(frozen=True)
class Server:
    """`host` is whatever SSH connects to: a hostname, an IP or a Tailscale name."""

    id: str
    name: str
    host: str
    user: str | None = None
    port: int | None = None
    ssh_config_alias: str | None = None
    identity_file: str | None = None

    @property
    def ssh_destination(self) -> str:
        return f"{self.user}@{self.host}" if self.user else self.host

    def connects_like(self, other: Server) -> bool:
        """Same connection: everything but id and name. A rename alone must not reconnect."""
        return (self.host, self.user, self.port, self.ssh_config_alias, self.identity_file) == (
            other.host, other.user, other.port, other.ssh_config_alias, other.identity_file)


class Severity(enum.Enum):
    INFO = "info"
    WARNING = "warning"
    CRITICAL = "critical"


@dataclass(frozen=True)
class AttentionItem:
    id: str
    severity: Severity
    message: str
    fix: str


def server_input_problem(host: str, user: str, port: str) -> str | None:
    """Why the connection fields can't be saved, or None. A blank user or port is fine (root and 22)."""
    h, u, p = host.strip(), user.strip(), port.strip()
    if not h:
        return "A host is needed."
    # The host becomes part of the ssh target: a leading dash would read as an option.
    if h.startswith("-"):
        return "A host can't start with a dash."
    if any(c.isspace() for c in h):
        return "A host can't contain spaces."
    if u.startswith("-"):
        return "A user name can't start with a dash."
    if any(c.isspace() for c in u) or "@" in u:
        return "A user name can't contain spaces or @."
    if p:
        number = to_int32(p)
        if number is None or not 1 <= number <= 65535:
            return "The port must be a number from 1 to 65535."
    return None
