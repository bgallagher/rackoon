"""`~/.ssh/config` entries for importing servers, like `SSHConfigParser` in the Swift core: concrete `Host` aliases
only (patterns and `Match` blocks are skipped), first value wins as in ssh itself.

The Mac keeps the alias as `host` and lets ssh apply the rest of the entry. The web backend can't (the container
doesn't share the host's ~/.ssh), so it imports `resolved()`: a plain Server with HostName, User and Port filled in.
This parser therefore also reads `IdentityFile` (the key to copy into the web key store) and `ProxyJump` (which
the web transport does not support yet, so such entries are flagged).
"""

from __future__ import annotations

from dataclasses import dataclass, field

from .models import Server
from .text import to_int


@dataclass
class SSHConfigHost:
    alias: str
    host_name: str | None = None
    user: str | None = None
    port: int | None = None
    identity_files: list[str] = field(default_factory=list)
    proxy_jump: str | None = None

    def as_mac_server(self, server_id: str) -> Server:
        """What the Mac imports: the alias as `host`, so ssh applies the entry."""
        return Server(server_id, self.alias, self.alias, ssh_config_alias=self.alias)

    def resolved(self, server_id: str) -> Server:
        """What the web imports: the entry resolved into plain connection fields."""
        return Server(server_id, self.alias, self.host_name or self.alias, user=self.user, port=self.port,
                      ssh_config_alias=self.alias)


def _split(line: str) -> tuple[str, str]:
    """`Key value` or `Key=value`; one pair of surrounding double quotes is removed."""
    i = next((k for k, c in enumerate(line) if c in " \t="), -1)
    if i < 0:
        return line, ""
    rest = line[i + 1:].strip(" \t")
    if rest.startswith("="):
        rest = rest[1:].strip(" \t")
    if len(rest) >= 2 and rest.startswith('"') and rest.endswith('"'):
        rest = rest[1:-1]
    return line[:i], rest


def parse(text: str) -> list[SSHConfigHost]:
    hosts: list[SSHConfigHost] = []
    current: list[SSHConfigHost] = []  # the entries the lines below apply to
    for raw in text.splitlines():
        line = raw.strip(" \t")
        if not line or line.startswith("#"):
            continue
        key, value = _split(line)
        match key.lower():
            case "host":
                current = []
                for alias in (a for a in value.split(" ") if a):
                    if "*" in alias or "?" in alias or alias.startswith("!"):
                        continue
                    entry = SSHConfigHost(alias)
                    hosts.append(entry)
                    current.append(entry)
            case "match":
                current = []
            case "hostname":
                for h in current:
                    if h.host_name is None:
                        h.host_name = value
            case "user":
                for h in current:
                    if h.user is None:
                        h.user = value
            case "port":
                for h in current:
                    if h.port is None:
                        h.port = to_int(value)
            case "identityfile":
                for h in current:
                    h.identity_files.append(value)
            case "proxyjump":
                for h in current:
                    if h.proxy_jump is None:
                        h.proxy_jump = value
            case _:
                pass
    return hosts
