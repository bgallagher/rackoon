"""SSH key pairs kept in the data folder: generate an Ed25519 key, or import an existing private key (OpenSSH or
PEM; an encrypted one with its passphrase, which is used once to decrypt it and never stored)."""

from __future__ import annotations

import asyncssh

from rackoon.ssh import HostKey

from .storage import DataStore, KeyInfo, new_id, now_iso

MAX_KEY_BYTES = 32_768
MAX_NAME = 80


class KeyError_(Exception):
    """A key could not be generated, read or used (the message is for the user)."""


def _fingerprint(key: asyncssh.SSHKey) -> str:
    return HostKey(key.get_algorithm(), key.public_data).fingerprint


def _clean_name(name: str) -> str:
    n = " ".join(name.split())
    if not n:
        raise KeyError_("Give the key a name.")
    if len(n) > MAX_NAME:
        raise KeyError_(f"Keep the name under {MAX_NAME} characters.")
    return n


class KeyStore:
    def __init__(self, store: DataStore) -> None:
        self.store = store

    def list(self) -> list[KeyInfo]:
        return self.store.load_keys()

    def get(self, key_id: str) -> KeyInfo | None:
        return next((k for k in self.list() if k.id == key_id), None)

    def _add(self, name: str, key: asyncssh.SSHKey, source: str) -> KeyInfo:
        key_id = new_id()
        comment = f"rackoon-web {name}"
        key.set_comment(comment)
        public = key.export_public_key("openssh").decode().strip()
        info = KeyInfo(key_id, name, key.get_algorithm(), _fingerprint(key), public, now_iso(), source)
        # The private file first: an index entry never points at a missing key.
        self.store.write_private_key(key_id, key.export_private_key("openssh").decode())
        self.store.save_keys(self.list() + [info])
        return info

    def generate(self, name: str) -> KeyInfo:
        return self._add(_clean_name(name), asyncssh.generate_private_key("ssh-ed25519"), "generated")

    def import_key(self, name: str, private_key: str, passphrase: str | None = None) -> KeyInfo:
        clean = _clean_name(name)
        if len(private_key.encode()) > MAX_KEY_BYTES:
            raise KeyError_("That is too large to be a private key.")
        if "PRIVATE KEY" not in private_key:
            raise KeyError_("Paste the private key (the file without .pub).")
        try:
            key = asyncssh.import_private_key(private_key, passphrase or None)
        except asyncssh.KeyEncryptionError:
            raise KeyError_("The key is encrypted: enter its passphrase, or the passphrase is wrong.") from None
        except (asyncssh.KeyImportError, ValueError) as e:
            # "Passphrase must be specified..." (OpenSSH and PEM) and "Unable to decrypt..." (a wrong PEM passphrase).
            text = str(e).lower()
            if "passphrase" in text or "decrypt" in text:
                raise KeyError_("The key is encrypted: enter its passphrase, or the passphrase is wrong.") from None
            raise KeyError_("This is not a private key Rackoon can read.") from None
        fingerprint = _fingerprint(key)
        if any(k.fingerprint == fingerprint for k in self.list()):
            raise KeyError_("This key is already in Rackoon.")
        return self._add(clean, key, "imported")

    def delete(self, key_id: str) -> bool:
        keys = self.list()
        kept = [k for k in keys if k.id != key_id]
        if len(kept) == len(keys):
            return False
        self.store.save_keys(kept)
        self.store.delete_private_key(key_id)
        return True

    def private_key(self, key_id: str) -> str:
        if self.get(key_id) is None:
            raise KeyError_("That key no longer exists.")
        return self.store.read_private_key(key_id)
