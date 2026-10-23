"""Configuration, all from the environment (the Docker image sets the defaults).

    RACKOON_DATA                  where everything is kept (default /data): servers, known hosts, SSH keys, auth
    RACKOON_ADMIN_PASSWORD_FILE   a file holding the admin password (a Docker secret), or an argon2id hash of it.
                                  When unset, the first start prints a one-time setup token instead.
    RACKOON_TRUSTED_PROXIES       comma-separated CIDRs whose X-Forwarded-For and forward-auth header are believed
    RACKOON_FORWARD_AUTH_HEADER   the header a trusted proxy names the signed-in user in (e.g. Remote-User);
                                  unset = forward auth off
    RACKOON_FORWARD_AUTH_USERS    optional comma-separated users that header may name; empty = any
    RACKOON_SSH_CONFIG            an ssh_config file to import servers from (mount ~/.ssh/config read-only)
    RACKOON_STATIC                the built frontend (web/frontend/dist) to serve at /; the image sets it
    RACKOON_DEMO=1                demo mode: made-up servers, a temporary data folder, nothing is sent anywhere
"""

from __future__ import annotations

import ipaddress
import os
from dataclasses import dataclass, field
from pathlib import Path

Network = ipaddress.IPv4Network | ipaddress.IPv6Network


class SettingsError(Exception):
    pass


def _networks(text: str) -> list[Network]:
    out: list[Network] = []
    for piece in (p.strip() for p in text.split(",")):
        if not piece:
            continue
        try:
            out.append(ipaddress.ip_network(piece, strict=False))
        except ValueError:
            raise SettingsError(f"RACKOON_TRUSTED_PROXIES: {piece!r} is not an address or CIDR") from None
    return out


@dataclass(frozen=True)
class Settings:
    data_dir: Path
    admin_password_file: Path | None = None
    trusted_proxies: list[Network] = field(default_factory=list)
    forward_auth_header: str | None = None
    forward_auth_users: frozenset[str] = frozenset()
    ssh_config: Path | None = None
    static_dir: Path | None = None
    demo: bool = False

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> Settings:
        e = dict(os.environ if env is None else env)
        header = e.get("RACKOON_FORWARD_AUTH_HEADER", "").strip() or None
        proxies = _networks(e.get("RACKOON_TRUSTED_PROXIES", ""))
        if header and not proxies:
            raise SettingsError("RACKOON_FORWARD_AUTH_HEADER needs RACKOON_TRUSTED_PROXIES: without it anyone could "
                                "send the header")
        password_file = e.get("RACKOON_ADMIN_PASSWORD_FILE", "").strip()
        ssh_config = e.get("RACKOON_SSH_CONFIG", "").strip()
        static = e.get("RACKOON_STATIC", "").strip()
        return cls(
            data_dir=Path(e.get("RACKOON_DATA", "/data")),
            admin_password_file=Path(password_file) if password_file else None,
            trusted_proxies=proxies,
            forward_auth_header=header,
            forward_auth_users=frozenset(u.strip() for u in e.get("RACKOON_FORWARD_AUTH_USERS", "").split(",")
                                         if u.strip()),
            ssh_config=Path(ssh_config) if ssh_config else None,
            static_dir=Path(static) if static else None,
            demo=e.get("RACKOON_DEMO", "").strip() == "1",
        )

    def is_trusted_proxy(self, address: str | None) -> bool:
        if not address:
            return False
        try:
            ip = ipaddress.ip_address(address)
        except ValueError:
            return False
        return any(ip in net for net in self.trusted_proxies)
