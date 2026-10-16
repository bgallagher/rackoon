"""The data folder: saved servers, snapshots, known hosts and keys, with private file modes and atomic writes; and
the ssh_config parser (the Swift core's SSHConfigParserTests)."""

from __future__ import annotations

import stat
from pathlib import Path

import pytest

from rackoon.app.keys import KeyError_, KeyStore
from rackoon.app.storage import DataStore, FileKnownHosts, HostKeyConflict
from rackoon.core import overview, ssh_config
from rackoon.core.models import Server
from rackoon.ssh import HostKey

from .support import out


def mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def test_servers_round_trip_and_empty_store_is_empty(tmp_path: Path) -> None:
    store = DataStore(tmp_path / "data")
    assert store.load_servers() == []
    servers = [Server("A", "vps", "vps.example.com", user="root", port=2222),
               Server("B", "nas", "nas", ssh_config_alias="nas")]
    store.save_servers(servers)
    assert store.load_servers() == servers
    assert mode(tmp_path / "data") == 0o700
    assert mode(store.servers_file) == 0o600
    assert not [p for p in (tmp_path / "data").iterdir() if p.name.startswith(".")], "no temporary files left"


def test_servers_json_is_the_macs_format(tmp_path: Path) -> None:
    """A plain JSON array of Server, as the Mac's ServerStore writes it, so a copied file loads."""
    store = DataStore(tmp_path)
    store.servers_file.write_text('[{"id": "X", "name": "vps", "host": "vps", "user": "root", "port": null}]')
    assert store.load_servers() == [Server("X", "vps", "vps", user="root")]


def test_corrupt_servers_file_is_moved_aside_not_overwritten(tmp_path: Path) -> None:
    store = DataStore(tmp_path)
    store.servers_file.write_text("not json")
    assert store.load_servers() == []
    assert [p.name for p in tmp_path.iterdir() if p.name.startswith("servers.json.unreadable-")]
    assert not store.servers_file.exists()


def test_snapshot_round_trip_and_delete(tmp_path: Path) -> None:
    store = DataStore(tmp_path)
    reading = overview.parse(out("overview", "ubuntu-24.04"))
    store.save_snapshot("A", reading)
    cached = store.load_snapshot("A")
    assert cached is not None and cached.overview == reading and cached.saved_at.endswith("Z")
    store.delete_snapshot("A")
    assert store.load_snapshot("A") is None
    with pytest.raises(ValueError):
        store.snapshot_path("../escape")


def test_known_hosts_persist_and_never_replace_a_different_key(tmp_path: Path) -> None:
    path = tmp_path / "known_hosts.json"
    known = FileKnownHosts(path)
    key = HostKey("ssh-ed25519", b"\x01" * 51)
    known.trust("Example.com", 22, key)
    known.trust("example.com", 22, key)  # the same key again is fine
    with pytest.raises(HostKeyConflict):
        known.trust("example.com", 22, HostKey("ssh-ed25519", b"\x02" * 51))
    reloaded = FileKnownHosts(path)
    assert reloaded.lookup("example.com", 22) == key
    assert reloaded.verdict("example.com", 22, key) == "trusted"
    assert reloaded.verdict("example.com", 2222, key) == "unknown"
    assert mode(path) == 0o600


def test_keys_generate_import_and_delete(tmp_path: Path) -> None:
    import asyncssh
    store = DataStore(tmp_path)
    keys = KeyStore(store)
    generated = keys.generate("  laptop   key ")
    assert generated.name == "laptop key" and generated.key_type == "ssh-ed25519"
    assert generated.public_key.startswith("ssh-ed25519 ") and generated.public_key.endswith("rackoon-web laptop key")
    assert mode(store.key_path(generated.id)) == 0o600
    assert mode(store.keys_dir) == 0o700
    assert asyncssh.import_private_key(keys.private_key(generated.id)).public_data  # readable again

    rsa = asyncssh.generate_private_key("ssh-rsa", key_size=2048)
    encrypted = rsa.export_private_key("openssh", passphrase="secret phrase").decode()
    with pytest.raises(KeyError_, match="passphrase"):
        keys.import_key("old", encrypted)
    imported = keys.import_key("old", encrypted, "secret phrase")
    assert imported.key_type == "ssh-rsa" and imported.source == "imported"
    assert "ENCRYPTED" not in keys.private_key(imported.id) and "aes" not in keys.private_key(imported.id)
    with pytest.raises(KeyError_, match="already"):
        keys.import_key("again", encrypted, "secret phrase")
    with pytest.raises(KeyError_):
        keys.import_key("public", rsa.export_public_key().decode())
    assert [k.id for k in keys.list()] == [generated.id, imported.id]
    assert keys.delete(generated.id) and not store.key_path(generated.id).exists()
    assert not keys.delete(generated.id)


def test_ssh_config_parses_concrete_hosts_and_skips_wildcards() -> None:
    hosts = ssh_config.parse("""
        # my servers
        Host hetzner
            HostName 203.0.113.7
            User root
            Port 2222
            IdentityFile ~/.ssh/id_ed25519

        Host nas nas-local
          HostName=192.168.1.20
          User admin

        Host *
            ServerAliveInterval 30

        Host *.internal !bad
            User nobody

        Match host foo
            User ignored

        Host jumpy
            HostName 10.0.0.9
            ProxyJump bastion

        Host last
        """)
    assert [h.alias for h in hosts] == ["hetzner", "nas", "nas-local", "jumpy", "last"]
    assert (hosts[0].host_name, hosts[0].user, hosts[0].port) == ("203.0.113.7", "root", 2222)
    assert hosts[0].identity_files == ["~/.ssh/id_ed25519"]
    assert hosts[1].host_name == "192.168.1.20", "Key=value form"
    assert hosts[2].user == "admin", "one block can define several aliases"
    assert hosts[3].proxy_jump == "bastion"
    assert hosts[4].host_name is None


def test_ssh_config_import_shapes() -> None:
    entry = ssh_config.SSHConfigHost("hetzner", host_name="203.0.113.7", user="root", port=2222)
    mac = entry.as_mac_server("1")
    assert (mac.host, mac.ssh_config_alias, mac.user) == ("hetzner", "hetzner", None)
    web = entry.resolved("1")
    assert (web.name, web.host, web.user, web.port, web.ssh_config_alias) == ("hetzner", "203.0.113.7", "root", 2222,
                                                                              "hetzner")
    assert ssh_config.SSHConfigHost("bare").resolved("2").host == "bare"
