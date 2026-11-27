"""Config transfer (spec/config-transfer.md): the `rackoon-config` document, plain and encrypted files, the QR parts
and the import plan. Ported in step with RackoonCore's ConfigTransfer.swift and android/core's ConfigTransfer.kt; the
shared cases are spec/scenarios/config-codec.json, config-merge.json and spec/fixtures/config/.

Pure apart from reading spec/config-transfer.json (the settings catalog). Randomness is passed in, so fixtures can be
made deterministically."""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import math
import os
import re
import unicodedata
import zlib
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field, replace
from functools import cache
from typing import Any

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from .models import server_input_problem
from .spec import load_json

FORMAT = "rackoon-config"
ENCRYPTED_FORMAT = "rackoon-config-encrypted"
VERSION = 1
PLATFORMS = ("mac", "android", "ios", "web")
SIGN_IN_METHODS = ("tailscale", "key", "password", "system")

ITERATIONS = 600_000
MIN_ITERATIONS = 100_000
MAX_ITERATIONS = 5_000_000
MIN_PASSPHRASE = 10
MAX_INFLATED = 16 * 1024 * 1024
FILE_AAD = b"rackoon-config-encrypted/1"
QR_AAD = b"rackoon-config-qr/1"
QR_PREFIX = "RK1"
QR_PAYLOAD_VERSION = 1
MAX_PART_BYTES = 450
MAX_PARTS = 99
SALT_BYTES = 16
NONCE_BYTES = 12
TAG_BYTES = 16

CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
BASE45 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"
HOST_KEY_ORDER = ("ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa")
SERVER_FIELDS = ("name", "host", "user", "port", "sshConfigAlias", "identityFile")
EVERYWHERE = "*"

Random = Callable[[int], bytes]


class ConfigError(Exception):
    """`code` is shared by every core (spec/fixtures/config/*.expected.json); the message is this app's own."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def _damaged(why: str) -> ConfigError:
    return ConfigError("damaged", f"This file is damaged or was not made by Rackoon ({why}).")


# MARK: - The document

@dataclass(frozen=True)
class ResolvedAddress:
    host: str
    user: str | None = None
    port: int | None = None


@dataclass(frozen=True)
class ConfigServer:
    id: str
    name: str
    host: str
    user: str | None = None
    port: int | None = None
    ssh_config_alias: str | None = None
    identity_file: str | None = None
    resolved: ResolvedAddress | None = None

    def field_value(self, name: str) -> Any:
        return {"name": self.name, "host": self.host, "user": self.user, "port": self.port,
                "sshConfigAlias": self.ssh_config_alias, "identityFile": self.identity_file}[name]


@dataclass(frozen=True)
class ConfigHostKey:
    host: str
    port: int
    type: str
    key: str

    @property
    def address(self) -> tuple[str, int]:
        return (self.host.lower(), self.port)


@dataclass(frozen=True)
class ConfigSignIn:
    method: str
    key_name: str | None = None


@dataclass
class ConfigServerSettings:
    icons: dict[str, str] = field(default_factory=dict)
    services: dict[str, bool] = field(default_factory=dict)
    vulnerability_lookup: bool | None = None
    muted_alerts: list[str] = field(default_factory=list)

    @property
    def is_empty(self) -> bool:
        return not self.icons and not self.services and self.vulnerability_lookup is None and not self.muted_alerts


@dataclass(frozen=True)
class ConfigSecret:
    password: str | None = None
    private_key: str | None = None
    passphrase: str | None = None
    key_name: str | None = None


@dataclass
class ConfigDocument:
    servers: list[ConfigServer] = field(default_factory=list)
    host_keys: list[ConfigHostKey] = field(default_factory=list)
    sign_in: dict[str, ConfigSignIn] = field(default_factory=dict)
    preferences: dict[str, Any] = field(default_factory=dict)
    server_settings: dict[str, ConfigServerSettings] = field(default_factory=dict)
    custom_icons: dict[str, str] = field(default_factory=dict)
    secrets: dict[str, ConfigSecret] = field(default_factory=dict)
    exported_at: str | None = None
    source_platform: str | None = None
    source_app: str | None = None


# MARK: - The settings catalog

@dataclass(frozen=True)
class CatalogSetting:
    id: str
    part: str | None
    type: str | None
    transfer: bool
    keys: dict[str, str | None]
    values: tuple[Any, ...] | None = None
    min: int | None = None
    max: int | None = None
    max_length: int | None = None


@cache
def catalog() -> tuple[CatalogSetting, ...]:
    doc = load_json("config-transfer.json")
    return tuple(CatalogSetting(id=s["id"], part=s.get("part"), type=s.get("type"), transfer=bool(s.get("transfer")),
                                keys=dict(s.get("keys", {})), values=tuple(s["values"]) if "values" in s else None,
                                min=s.get("min"), max=s.get("max"), max_length=s.get("maxLength"))
                 for s in doc["settings"])


def preference_settings() -> dict[str, CatalogSetting]:
    return {s.id: s for s in catalog() if s.part == "preferences" and s.transfer}


def _preference_value(setting: CatalogSetting, value: Any) -> Any | None:
    """The value if it has the catalog's type and limits, else None (dropped)."""
    if setting.type == "bool":
        ok = isinstance(value, bool)
    elif setting.type == "int":
        ok = isinstance(value, int) and not isinstance(value, bool)
    elif setting.type == "string":
        ok = isinstance(value, str)
    else:
        ok = False
    if not ok:
        return None
    if setting.values is not None and value not in setting.values:
        return None
    if setting.min is not None and value < setting.min:
        return None
    if setting.max is not None and value > setting.max:
        return None
    if setting.max_length is not None and len(value) > setting.max_length:
        return None
    return value


# MARK: - Reading and writing the document

def _str(obj: dict[str, Any], key: str) -> str | None:
    value = obj.get(key)
    return value if isinstance(value, str) else None


def _port(value: Any, where: str) -> int | None:
    if value is None:
        return None
    if not isinstance(value, int) or isinstance(value, bool) or not 1 <= value <= 65535:
        raise _damaged(f"{where} has a bad port")
    return value


def _is_base64(text: str) -> bool:
    try:
        base64.b64decode(text, validate=True)
        return bool(text)
    except (binascii.Error, ValueError):
        return False


def _read_server(raw: Any, index: int) -> ConfigServer:
    where = f"server {index + 1}"
    if not isinstance(raw, dict):
        raise _damaged(f"{where} is not an object")
    sid, name, host = _str(raw, "id"), _str(raw, "name"), _str(raw, "host")
    if not sid or len(sid) > 100 or name is None or not host:
        raise _damaged(f"{where} needs an id, a name and a host")
    user = _str(raw, "user") or None
    port = _port(raw.get("port"), where)
    if server_input_problem(host, user or "", "") is not None or (user is not None and user != user.strip()) \
            or host != host.strip():
        raise _damaged(f"{where} has an address Rackoon cannot use")
    resolved = None
    rraw = raw.get("resolved")
    if isinstance(rraw, dict):
        rhost, ruser = _str(rraw, "host"), _str(rraw, "user")
        if not rhost or server_input_problem(rhost, ruser or "", "") is not None:
            raise _damaged(f"{where} has a resolved address Rackoon cannot use")
        resolved = ResolvedAddress(rhost, ruser or None, _port(rraw.get("port"), where))
    return ConfigServer(id=sid, name=name, host=host, user=user, port=port,
                        ssh_config_alias=_str(raw, "sshConfigAlias") or None,
                        identity_file=_str(raw, "identityFile") or None, resolved=resolved)


HOST_KEY_TYPE = re.compile(r"[a-z0-9@.-]+")
# A plain name or address: never a known_hosts pattern (* ? !) or list (,), which a Mac writes into ~/.ssh/known_hosts.
HOST_KEY_HOST = re.compile(r"[A-Za-z0-9._:-]+")


def _read_host_key(raw: Any, index: int) -> ConfigHostKey:
    where = f"host key {index + 1}"
    if not isinstance(raw, dict):
        raise _damaged(f"{where} is not an object")
    host, ktype, key = _str(raw, "host"), _str(raw, "type"), _str(raw, "key")
    port = _port(raw.get("port"), where)
    if not host or not HOST_KEY_HOST.fullmatch(host) or port is None or not ktype or not HOST_KEY_TYPE.fullmatch(ktype) \
            or not key or not _is_base64(key):
        raise _damaged(f"{where} is incomplete")
    return ConfigHostKey(host, port, ktype, key)


def _read_settings(raw: Any, everywhere: bool) -> ConfigServerSettings:
    s = ConfigServerSettings()
    if not isinstance(raw, dict):
        return s
    services = raw.get("services")
    if isinstance(services, dict):
        s.services = {k: v for k, v in services.items() if isinstance(v, bool) and k}
    if everywhere:
        return s
    icons = raw.get("icons")
    if isinstance(icons, dict):
        s.icons = {k: v for k, v in icons.items() if isinstance(v, str) and k}
    if isinstance(raw.get("vulnerabilityLookup"), bool):
        s.vulnerability_lookup = raw["vulnerabilityLookup"]
    muted = raw.get("mutedAlerts")
    if isinstance(muted, list):
        s.muted_alerts = sorted({m for m in muted if isinstance(m, str) and m})
    return s


CUSTOM_ICON_ID = re.compile(r"[0-9a-f]{16,64}")


def read_document(obj: Any, *, secrets: bool, custom_icons: bool = True) -> ConfigDocument:
    """Reads a parsed JSON document. `secrets` is true only for an encrypted file; a QR transfer passes
    `custom_icons=False`. Raises ConfigError."""
    if not isinstance(obj, dict) or obj.get("format") != FORMAT:
        raise ConfigError("notRackoonConfig", "This is not a Rackoon configuration file.")
    version = obj.get("version")
    if not isinstance(version, int) or isinstance(version, bool) or version < 1:
        raise _damaged("no version")
    if version > VERSION:
        raise ConfigError("newerVersion", "This configuration was made by a newer version of Rackoon. Update this app "
                                          "and try again.")
    doc = ConfigDocument(exported_at=_str(obj, "exportedAt"))
    source = obj.get("source")
    if isinstance(source, dict):
        platform = _str(source, "platform")
        doc.source_platform = platform if platform in PLATFORMS else None
        doc.source_app = _str(source, "app")

    servers = obj.get("servers", [])
    if not isinstance(servers, list):
        raise _damaged("servers is not a list")
    doc.servers = [_read_server(s, i) for i, s in enumerate(servers)]
    ids = {s.id for s in doc.servers}
    if len(ids) != len(doc.servers):
        raise _damaged("two servers share an id")

    keys = obj.get("hostKeys", [])
    if not isinstance(keys, list):
        raise _damaged("hostKeys is not a list")
    seen: set[ConfigHostKey] = set()
    for i, k in enumerate(keys):
        key = _read_host_key(k, i)
        if key not in seen:
            seen.add(key)
            doc.host_keys.append(key)

    sign_in = obj.get("signIn", {})
    if isinstance(sign_in, dict):
        for sid, raw in sign_in.items():
            if sid in ids and isinstance(raw, dict) and raw.get("method") in SIGN_IN_METHODS:
                doc.sign_in[sid] = ConfigSignIn(raw["method"], _str(raw, "keyName") or None)

    prefs = obj.get("preferences", {})
    if isinstance(prefs, dict):
        settings = preference_settings()
        for pid, value in prefs.items():
            if pid in settings and (v := _preference_value(settings[pid], value)) is not None:
                doc.preferences[pid] = v

    per_server = obj.get("serverSettings", {})
    if isinstance(per_server, dict):
        for sid, raw in per_server.items():
            if sid in ids or sid == EVERYWHERE:
                s = _read_settings(raw, sid == EVERYWHERE)
                if not s.is_empty:
                    doc.server_settings[sid] = s

    icons = obj.get("customIcons", {})
    if custom_icons and isinstance(icons, dict):
        doc.custom_icons = {k: v for k, v in icons.items()
                            if CUSTOM_ICON_ID.fullmatch(k) and isinstance(v, str) and _is_base64(v)}

    raw_secrets = obj.get("secrets", {})
    if secrets and isinstance(raw_secrets, dict):
        for sid, raw in raw_secrets.items():
            if sid in ids and isinstance(raw, dict):
                secret = ConfigSecret(_str(raw, "password"), _str(raw, "privateKey"), _str(raw, "passphrase"),
                                      _str(raw, "keyName"))
                if secret.password or secret.private_key:
                    doc.secrets[sid] = secret
    return doc


def _drop_none(d: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in d.items() if v is not None}


def server_json(s: ConfigServer) -> dict[str, Any]:
    out = _drop_none({"id": s.id, "name": s.name, "host": s.host, "user": s.user, "port": s.port,
                      "sshConfigAlias": s.ssh_config_alias, "identityFile": s.identity_file})
    if s.resolved is not None:
        out["resolved"] = _drop_none({"host": s.resolved.host, "user": s.resolved.user, "port": s.resolved.port})
    return out


def settings_json(s: ConfigServerSettings) -> dict[str, Any]:
    out: dict[str, Any] = {}
    if s.icons:
        out["icons"] = dict(s.icons)
    if s.services:
        out["services"] = dict(s.services)
    if s.vulnerability_lookup is not None:
        out["vulnerabilityLookup"] = s.vulnerability_lookup
    if s.muted_alerts:
        out["mutedAlerts"] = sorted(set(s.muted_alerts))
    return out


def document_json(doc: ConfigDocument, *, secrets: bool = True, custom_icons: bool = True) -> dict[str, Any]:
    """The canonical JSON: what a file holds and what the shared fixtures and scenarios compare."""
    out: dict[str, Any] = {"format": FORMAT, "version": VERSION}
    if doc.exported_at is not None:
        out["exportedAt"] = doc.exported_at
    if doc.source_platform is not None or doc.source_app is not None:
        out["source"] = _drop_none({"platform": doc.source_platform, "app": doc.source_app})
    out["servers"] = [server_json(s) for s in doc.servers]
    out["hostKeys"] = [{"host": k.host, "port": k.port, "type": k.type, "key": k.key} for k in doc.host_keys]
    out["signIn"] = {sid: _drop_none({"method": s.method, "keyName": s.key_name}) for sid, s in doc.sign_in.items()}
    out["preferences"] = dict(doc.preferences)
    out["serverSettings"] = {sid: settings_json(s) for sid, s in doc.server_settings.items() if not s.is_empty}
    if custom_icons and doc.custom_icons:
        out["customIcons"] = dict(doc.custom_icons)
    if secrets and doc.secrets:
        out["secrets"] = {sid: _drop_none({"password": s.password, "privateKey": s.private_key,
                                           "passphrase": s.passphrase, "keyName": s.key_name})
                          for sid, s in doc.secrets.items()}
    return out


# MARK: - Files

def _nfc(text: str) -> bytes:
    return unicodedata.normalize("NFC", text).encode()


def passphrase_problem(passphrase: str) -> str | None:
    if len(unicodedata.normalize("NFC", passphrase)) < MIN_PASSPHRASE:
        return f"Use a passphrase of at least {MIN_PASSPHRASE} characters."
    return None


def _derive(secret: bytes, salt: bytes, iterations: int) -> bytes:
    return hashlib.pbkdf2_hmac("sha256", secret, salt, iterations, 32)


def _deflate(data: bytes) -> bytes:
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return c.compress(data) + c.flush()


def _inflate(data: bytes) -> bytes:
    d = zlib.decompressobj(-15)
    try:
        out = d.decompress(data, MAX_INFLATED + 1)
    except zlib.error as e:
        raise _damaged("it does not decompress") from e
    if len(out) > MAX_INFLATED or d.unconsumed_tail:
        raise ConfigError("tooLarge", "This configuration is too large.")
    if not d.eof:
        raise _damaged("it is cut short")
    return out


def _json_bytes(obj: Any, pretty: bool = False) -> bytes:
    if pretty:
        return (json.dumps(obj, indent=2, ensure_ascii=False) + "\n").encode()
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode()


def plain_file(doc: ConfigDocument) -> bytes:
    return _json_bytes(document_json(doc, secrets=False), pretty=True)


def encrypted_file(doc: ConfigDocument, passphrase: str, random: Random = os.urandom,
                   iterations: int = ITERATIONS) -> bytes:
    if (problem := passphrase_problem(passphrase)) is not None:
        raise ConfigError("passphraseTooShort", problem)
    salt, nonce = random(SALT_BYTES), random(NONCE_BYTES)
    key = _derive(_nfc(passphrase), salt, iterations)
    sealed = AESGCM(key).encrypt(nonce, _deflate(_json_bytes(document_json(doc))), FILE_AAD)
    envelope = {"format": ENCRYPTED_FORMAT, "version": VERSION,
                "kdf": {"name": "PBKDF2-SHA256", "iterations": iterations, "salt": base64.b64encode(salt).decode()},
                "cipher": "AES-256-GCM", "compression": "deflate-raw",
                "nonce": base64.b64encode(nonce).decode(), "ciphertext": base64.b64encode(sealed).decode()}
    return _json_bytes(envelope, pretty=True)


def is_encrypted(data: bytes) -> bool:
    try:
        obj = json.loads(data)
    except ValueError:
        return False
    return isinstance(obj, dict) and obj.get("format") == ENCRYPTED_FORMAT


def read_file(data: bytes, passphrase: str | None = None) -> ConfigDocument:
    """A plain or encrypted file. An encrypted one without a passphrase raises `needsPassphrase`."""
    try:
        obj = json.loads(data)
    except ValueError as e:
        raise ConfigError("notRackoonConfig", "This is not a Rackoon configuration file.") from e
    if not isinstance(obj, dict) or obj.get("format") != ENCRYPTED_FORMAT:
        return read_document(obj, secrets=False)
    version = obj.get("version")
    if isinstance(version, int) and not isinstance(version, bool) and version > VERSION:
        raise ConfigError("newerVersion", "This configuration was made by a newer version of Rackoon. Update this app "
                                          "and try again.")
    kdf = obj.get("kdf")
    if version != VERSION or not isinstance(kdf, dict) or kdf.get("name") != "PBKDF2-SHA256" \
            or obj.get("cipher") != "AES-256-GCM" or obj.get("compression") != "deflate-raw":
        raise _damaged("unknown encryption")
    iterations = kdf.get("iterations")
    if not isinstance(iterations, int) or isinstance(iterations, bool) \
            or not MIN_ITERATIONS <= iterations <= MAX_ITERATIONS:
        raise _damaged("bad key settings")
    try:
        salt = base64.b64decode(str(kdf.get("salt")), validate=True)
        nonce = base64.b64decode(str(obj.get("nonce")), validate=True)
        sealed = base64.b64decode(str(obj.get("ciphertext")), validate=True)
    except (binascii.Error, ValueError) as e:
        raise _damaged("bad base64") from e
    if len(salt) != SALT_BYTES or len(nonce) != NONCE_BYTES or len(sealed) < TAG_BYTES:
        raise _damaged("bad sizes")
    if passphrase is None:
        raise ConfigError("needsPassphrase", "This file is encrypted. Enter its passphrase.")
    try:
        plain = AESGCM(_derive(_nfc(passphrase), salt, iterations)).decrypt(nonce, sealed, FILE_AAD)
    except InvalidTag as e:
        raise ConfigError("wrongPassphrase", "Wrong passphrase, or the file was changed.") from e
    try:
        inner = json.loads(_inflate(plain))
    except ValueError as e:
        raise _damaged("the contents are not JSON") from e
    return read_document(inner, secrets=True)


# MARK: - Base45, unlock codes, QR parts

def base45_encode(data: bytes) -> str:
    out = []
    for i in range(0, len(data) - 1, 2):
        n = data[i] * 256 + data[i + 1]
        c, rest = n % 45, n // 45
        out += [BASE45[c], BASE45[rest % 45], BASE45[rest // 45]]
    if len(data) % 2:
        n = data[-1]
        out += [BASE45[n % 45], BASE45[n // 45]]
    return "".join(out)


def base45_decode(text: str) -> bytes:
    values = []
    for ch in text:
        i = BASE45.find(ch)
        if i < 0:
            raise ValueError("not Base45")
        values.append(i)
    if len(values) % 3 == 1:
        raise ValueError("bad Base45 length")
    out = bytearray()
    for i in range(0, len(values), 3):
        chunk = values[i:i + 3]
        if len(chunk) == 3:
            n = chunk[0] + chunk[1] * 45 + chunk[2] * 45 * 45
            if n > 0xFFFF:
                raise ValueError("Base45 value too large")
            out += bytes([n // 256, n % 256])
        else:
            n = chunk[0] + chunk[1] * 45
            if n > 0xFF:
                raise ValueError("Base45 value too large")
            out.append(n)
    return bytes(out)


def crockford(random: Random, count: int) -> str:
    return "".join(CROCKFORD[b & 31] for b in random(count))


def new_unlock_code(random: Random = os.urandom) -> str:
    return crockford(random, 10)


def format_unlock_code(code: str) -> str:
    return f"{code[:5]}-{code[5:]}"


def normalize_unlock_code(text: str) -> str | None:
    s = "".join(c for c in text.upper() if c not in " -\t")
    s = s.replace("O", "0").replace("I", "1").replace("L", "1")
    if len(s) != 10 or any(c not in CROCKFORD for c in s):
        return None
    return s


def qr_parts(payload: bytes, transfer_id: str, max_part_bytes: int = MAX_PART_BYTES) -> list[str]:
    total = max(1, math.ceil(len(payload) / max_part_bytes))
    if total > MAX_PARTS:
        raise ConfigError("tooLarge", "Too many servers and settings for QR codes. Export a file instead.")
    size = math.ceil(len(payload) / total)
    return [f"{QR_PREFIX}:{transfer_id}:{n + 1}/{total}:{base45_encode(payload[n * size:(n + 1) * size])}"
            for n in range(total)]


PART = re.compile(r"^RK1:([0-9A-HJKMNP-TV-Z]{6}):([1-9][0-9]?)/([1-9][0-9]?):(.*)$", re.S)


@dataclass(frozen=True)
class QRPart:
    transfer_id: str
    n: int
    total: int
    data: bytes


def parse_part(text: str) -> QRPart:
    m = PART.match(text.strip())
    if not m:
        raise ConfigError("badPart", "This QR code is not part of a Rackoon transfer.")
    n, total = int(m.group(2)), int(m.group(3))
    if n > total:
        raise ConfigError("badPart", "This QR code is not part of a Rackoon transfer.")
    try:
        data = base45_decode(m.group(4))
    except ValueError as e:
        raise ConfigError("badPart", "This QR code is damaged.") from e
    if not data:
        raise ConfigError("badPart", "This QR code is damaged.")
    return QRPart(m.group(1), n, total, data)


class QRCollector:
    """Keeps scanned parts until every one is in."""

    def __init__(self) -> None:
        self.transfer_id: str | None = None
        self.total = 0
        self.parts: dict[int, bytes] = {}

    def add(self, text: str) -> bool:
        """Adds a scanned part; true when it was new. Raises ConfigError for a part of another transfer."""
        part = parse_part(text)
        if self.transfer_id is None:
            self.transfer_id, self.total = part.transfer_id, part.total
        elif part.transfer_id != self.transfer_id or part.total != self.total:
            raise ConfigError("otherTransfer", "That code belongs to a different transfer.")
        old = self.parts.get(part.n)
        if old is not None:
            if old != part.data:
                raise ConfigError("partConflict", "Two different codes claim the same place. Start the scan again.")
            return False
        self.parts[part.n] = part.data
        return True

    @property
    def is_complete(self) -> bool:
        return self.total > 0 and len(self.parts) == self.total

    @property
    def missing(self) -> list[int]:
        return [n for n in range(1, self.total + 1) if n not in self.parts]

    def payload(self) -> bytes:
        if not self.is_complete:
            raise ConfigError("missingParts", "Some codes have not been scanned yet.")
        data = b"".join(self.parts[n] for n in range(1, self.total + 1))
        if data[0] != QR_PAYLOAD_VERSION or len(data) < 1 + SALT_BYTES + NONCE_BYTES + TAG_BYTES:
            raise ConfigError("badPart", "These QR codes are not a Rackoon transfer this app can read.")
        return data


def qr_payload(doc: ConfigDocument, code: str, random: Random = os.urandom) -> bytes:
    salt, nonce = random(SALT_BYTES), random(NONCE_BYTES)
    key = _derive(code.encode(), salt, ITERATIONS)
    body = _deflate(_json_bytes(document_json(doc, secrets=False, custom_icons=False)))
    return bytes([QR_PAYLOAD_VERSION]) + salt + nonce + AESGCM(key).encrypt(nonce, body, QR_AAD)


def qr_export(doc: ConfigDocument, random: Random = os.urandom,
              max_part_bytes: int = MAX_PART_BYTES) -> tuple[str, list[str]]:
    """(unlock code, the QR texts in order)."""
    code = new_unlock_code(random)
    transfer_id = crockford(random, 6)
    return code, qr_parts(qr_payload(doc, code, random), transfer_id, max_part_bytes)


def read_qr_payload(payload: bytes, typed_code: str) -> ConfigDocument:
    code = normalize_unlock_code(typed_code)
    if len(payload) < 1 + SALT_BYTES + NONCE_BYTES + TAG_BYTES or payload[0] != QR_PAYLOAD_VERSION:
        raise ConfigError("badPart", "These QR codes are not a Rackoon transfer this app can read.")
    if code is None:
        raise ConfigError("badUnlockCode", "An unlock code is 10 letters and digits, shown beside the QR code.")
    salt = payload[1:1 + SALT_BYTES]
    nonce = payload[1 + SALT_BYTES:1 + SALT_BYTES + NONCE_BYTES]
    try:
        plain = AESGCM(_derive(code.encode(), salt, ITERATIONS)).decrypt(
            nonce, payload[1 + SALT_BYTES + NONCE_BYTES:], QR_AAD)
    except InvalidTag as e:
        raise ConfigError("wrongUnlockCode", "Wrong unlock code.") from e
    try:
        inner = json.loads(_inflate(plain))
    except ValueError as e:
        raise _damaged("the contents are not JSON") from e
    return read_document(inner, secrets=False, custom_icons=False)


def fingerprint(key_base64: str) -> str:
    digest = hashlib.sha256(base64.b64decode(key_base64)).digest()
    return "SHA256:" + base64.b64encode(digest).decode().rstrip("=")


# MARK: - Import planning

def fit_server(server: ConfigServer, platform: str) -> ConfigServer:
    """Rule 1: what an incoming server becomes on this platform."""
    if platform == "mac":
        return server
    s = server
    if s.resolved is not None:
        r = s.resolved
        s = replace(s, host=r.host, user=r.user if r.user is not None else s.user,
                    port=r.port if r.port is not None else s.port)
    return replace(s, ssh_config_alias=None, identity_file=None, resolved=None)


def fit_sign_in(sign_in: ConfigSignIn | None, platform: str) -> ConfigSignIn | None:
    """`system` (a Mac's own ssh setup) means nothing elsewhere: the server keeps its own sign-in there."""
    if sign_in is None or (sign_in.method == "system" and platform != "mac"):
        return None
    return sign_in


def _address(s: ConfigServer) -> tuple[str, str, int]:
    return (s.host.lower(), s.user or "", s.port or 22)


MAC_ONLY = ("sshConfigAlias", "identityFile")


def _effective(s: ConfigServer) -> ConfigServer:
    """Where a local server really connects: its `resolved` host, user and port when it has them (a Mac alias)."""
    if s.resolved is None:
        return s
    r = s.resolved
    return replace(s, host=r.host, user=r.user if r.user is not None else s.user,
                   port=r.port if r.port is not None else s.port)


def _differences(local: ConfigServer, incoming: ConfigServer) -> list[str]:
    here = _effective(local)
    out = []
    for name in SERVER_FIELDS:
        a, b = here.field_value(name), incoming.field_value(name)
        if name in MAC_ONLY and b is None:
            continue  # the document leaves out a Mac-only field: not a change, and an update keeps it
        if name == "host":
            same = a.lower() == b.lower()
        elif name == "port":
            same = (a or 22) == (b or 22)
        else:
            same = (a or "") == (b or "")
        if not same:
            out.append(name)
    return out


@dataclass(frozen=True)
class ServerPlan:
    incoming: ConfigServer
    """Fitted to this platform, with its incoming id."""
    kind: str
    """new, identical or change."""
    local_id: str | None = None
    matched_by: str | None = None
    """id or address."""
    changes: tuple[str, ...] = ()

    @property
    def result_id(self) -> str:
        return self.local_id or self.incoming.id


@dataclass(frozen=True)
class HostKeyPlan:
    key: ConfigHostKey
    status: str
    """add, trusted, blocked or skipped."""
    trusted: ConfigHostKey | None = None
    """The key this device trusts, when blocked."""


@dataclass(frozen=True)
class ImportPlan:
    servers: tuple[ServerPlan, ...]
    host_keys: tuple[HostKeyPlan, ...]
    preferences: tuple[str, ...]
    """Ids whose incoming value differs from this device's, sorted."""
    read_only_turns_on: bool
    removed: tuple[str, ...]
    """Local server ids that Replace everything would remove."""
    secrets: tuple[str, ...]
    """Incoming server ids that come with a password or key."""


@dataclass(frozen=True)
class ImportChoices:
    replace: bool = False
    keep: frozenset[str] = frozenset()
    """Incoming ids of matched servers to leave as they are here (Keep mine)."""
    apply_preferences: bool = True
    trust_host_keys: bool = True


def _key_rank(key_type: str) -> int:
    return HOST_KEY_ORDER.index(key_type) if key_type in HOST_KEY_ORDER else len(HOST_KEY_ORDER)


def plan_host_keys(local: Iterable[ConfigHostKey], incoming: Iterable[ConfigHostKey],
                   platform: str) -> list[HostKeyPlan]:
    by_address: dict[tuple[str, int], list[ConfigHostKey]] = {}
    for k in local:
        by_address.setdefault(k.address, []).append(k)
    incoming = list(incoming)
    single = platform != "mac"
    chosen: dict[tuple[str, int], ConfigHostKey] = {}
    if single:
        for k in sorted(incoming, key=lambda k: _key_rank(k.type)):
            if k.address not in by_address:
                chosen.setdefault(k.address, k)
    out = []
    for k in incoming:
        trusted = by_address.get(k.address, [])
        same_type = [t for t in trusted if t.type == k.type]
        if any(t.key == k.key for t in same_type):
            out.append(HostKeyPlan(k, "trusted"))
        elif same_type:
            out.append(HostKeyPlan(k, "blocked", same_type[0]))
        elif trusted or (single and chosen.get(k.address) != k):
            out.append(HostKeyPlan(k, "skipped"))
        else:
            out.append(HostKeyPlan(k, "add"))
    return out


def plan_import(local: ConfigDocument, incoming: ConfigDocument, platform: str) -> ImportPlan:
    fitted = [fit_server(s, platform) for s in incoming.servers]
    local_by_id = {s.id: s for s in local.servers}
    used: set[str] = set()
    matches: dict[str, tuple[ConfigServer, str]] = {}
    for s in fitted:
        if s.id in local_by_id:
            matches[s.id] = (local_by_id[s.id], "id")
            used.add(s.id)
    for s in fitted:
        if s.id in matches:
            continue
        for candidate in local.servers:
            if candidate.id not in used and _address(s) in (_address(candidate), _address(_effective(candidate))):
                matches[s.id] = (candidate, "address")
                used.add(candidate.id)
                break
    plans = []
    for s in fitted:
        if s.id not in matches:
            plans.append(ServerPlan(s, "new"))
            continue
        here, how = matches[s.id]
        changes = _differences(here, s)
        plans.append(ServerPlan(s, "change" if changes else "identical", here.id, how, tuple(changes)))

    prefs = tuple(sorted(k for k, v in incoming.preferences.items() if local.preferences.get(k) != v))
    turns_on = incoming.preferences.get("readOnly") is True and local.preferences.get("readOnly") is not True
    removed = tuple(s.id for s in local.servers if s.id not in used)
    return ImportPlan(tuple(plans), tuple(plan_host_keys(local.host_keys, incoming.host_keys, platform)), prefs,
                      turns_on, removed, tuple(sid for sid in (s.id for s in fitted) if sid in incoming.secrets))


def updated_server(local: ConfigServer, incoming: ConfigServer, changes: Iterable[str]) -> ConfigServer:
    """The local server with only the changed fields taken from the document. A new host ends a Mac alias link, and
    a changed address makes the old `resolved` stale."""
    values = {name: incoming.field_value(name) for name in changes}
    s = replace(local, name=values.get("name", local.name), host=values.get("host", local.host),
                user=values.get("user", local.user), port=values.get("port", local.port),
                ssh_config_alias=values.get("sshConfigAlias", local.ssh_config_alias),
                identity_file=values.get("identityFile", local.identity_file))
    if "host" in values and "sshConfigAlias" not in values:
        s = replace(s, ssh_config_alias=None)
        if local.resolved is not None:  # the user and port the alias gave become explicit
            s = replace(s, user=s.user if s.user is not None else local.resolved.user,
                        port=s.port if s.port is not None else local.resolved.port)
    if values.keys() & {"host", "user", "port"}:
        s = replace(s, resolved=None)
    return s


def _merge_settings(here: ConfigServerSettings | None, new: ConfigServerSettings) -> ConfigServerSettings:
    base = here or ConfigServerSettings()
    return ConfigServerSettings(
        icons={**base.icons, **new.icons}, services={**base.services, **new.services},
        vulnerability_lookup=new.vulnerability_lookup if new.vulnerability_lookup is not None
        else base.vulnerability_lookup,
        muted_alerts=sorted(set(base.muted_alerts) | set(new.muted_alerts)))


def _preferences(local: dict[str, Any], incoming: dict[str, Any]) -> dict[str, Any]:
    out = {**local, **incoming}
    if "readOnly" in local or "readOnly" in incoming:
        out["readOnly"] = local.get("readOnly") is True or incoming.get("readOnly") is True
    return out


def apply_import(local: ConfigDocument, incoming: ConfigDocument, plan: ImportPlan, choices: ImportChoices,
                 platform: str) -> ConfigDocument:
    """The configuration after the import. Its `secrets` are only the imported ones, filed under the ids they now
    belong to, for the app to save; `host_keys` are this device's plus the ones added."""
    added_keys = [p.key for p in plan.host_keys if p.status == "add"] if choices.trust_host_keys else []
    result = ConfigDocument(host_keys=list(local.host_keys) + added_keys,
                            custom_icons={**local.custom_icons, **incoming.custom_icons},
                            exported_at=local.exported_at, source_platform=local.source_platform,
                            source_app=local.source_app)

    if choices.replace:
        # Every server is the document's (matched ones keep their local id), in the document's order.
        here = {s.id: s for s in local.servers}
        result.servers = [p.incoming if p.local_id is None
                          else updated_server(here[p.local_id], p.incoming, p.changes) for p in plan.servers]
        for p in plan.servers:
            source, target = p.incoming.id, p.result_id
            if (sign_in := fit_sign_in(incoming.sign_in.get(source), platform)) is not None:
                result.sign_in[target] = sign_in
            if source in incoming.server_settings:
                result.server_settings[target] = incoming.server_settings[source]
            if source in incoming.secrets:
                result.secrets[target] = incoming.secrets[source]
        if EVERYWHERE in incoming.server_settings:
            result.server_settings[EVERYWHERE] = incoming.server_settings[EVERYWHERE]
        result.preferences = _preferences(local.preferences, incoming.preferences)
        return result

    taken = [p for p in plan.servers if p.kind == "new" or p.incoming.id not in choices.keep]
    updated = {p.local_id: p for p in taken if p.local_id is not None and p.kind == "change"}
    result.servers = [updated_server(s, updated[s.id].incoming, updated[s.id].changes) if s.id in updated else s
                      for s in local.servers]
    result.servers += [p.incoming for p in plan.servers if p.kind == "new"]
    result.sign_in = dict(local.sign_in)
    result.server_settings = {k: v for k, v in local.server_settings.items()}
    for p in taken:
        source, target = p.incoming.id, p.result_id
        if (sign_in := fit_sign_in(incoming.sign_in.get(source), platform)) is not None:
            result.sign_in[target] = sign_in
        if source in incoming.server_settings:
            result.server_settings[target] = _merge_settings(result.server_settings.get(target),
                                                             incoming.server_settings[source])
        if source in incoming.secrets:
            result.secrets[target] = incoming.secrets[source]

    if choices.apply_preferences:
        result.preferences = _preferences(local.preferences, incoming.preferences)
        if EVERYWHERE in incoming.server_settings:
            result.server_settings[EVERYWHERE] = _merge_settings(result.server_settings.get(EVERYWHERE),
                                                                 incoming.server_settings[EVERYWHERE])
    else:
        result.preferences = dict(local.preferences)
    return result
