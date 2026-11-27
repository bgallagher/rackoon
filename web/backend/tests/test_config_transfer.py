"""Config transfer (spec/config-transfer.md): the shared fixtures in spec/fixtures/config/, round trips through files
and QR codes, and the settings catalog. The shared rules are in test_shared_scenarios (config_codec, config_merge)."""

from __future__ import annotations

import json
import os
from typing import Any

import pytest

from rackoon.core import config_transfer as ct

from .support import SPEC, load

FIXTURES = SPEC / "fixtures" / "config"


def names(suffix: str) -> list[str]:
    return sorted(p.name.removesuffix(suffix) for p in FIXTURES.iterdir() if p.name.endswith(suffix))


def outcome(read: Any) -> dict[str, Any]:
    try:
        doc, secrets, icons = read()
        return {"document": ct.document_json(doc, secrets=secrets, custom_icons=icons)}
    except ct.ConfigError as e:
        return {"error": e.code}


def without_inputs(expected: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in expected.items() if k in ("document", "error")}


@pytest.mark.parametrize("name", names(".rackoon"))
def test_file_fixtures(name: str) -> None:
    expected = load(f"fixtures/config/{name}.expected.json")
    data = (FIXTURES / f"{name}.rackoon").read_bytes()
    encrypted = ct.is_encrypted(data)
    got = outcome(lambda: (ct.read_file(data, expected.get("passphrase")), encrypted, True))
    assert got == without_inputs(expected)


@pytest.mark.parametrize("name", names(".qr.json"))
def test_qr_fixtures(name: str) -> None:
    expected = load(f"fixtures/config/{name}.expected.json")
    collector = ct.QRCollector()
    for part in load(f"fixtures/config/{name}.qr.json")["parts"]:
        collector.add(part)
    got = outcome(lambda: (ct.read_qr_payload(collector.payload(), expected["unlockCode"]), False, False))
    assert got == without_inputs(expected)


def sample() -> ct.ConfigDocument:
    doc = json.loads((FIXTURES / "mac-plain.rackoon").read_text())
    doc["secrets"] = {doc["servers"][1]["id"]: {"password": "pässwörd"}}
    return ct.read_document(doc, secrets=True)


def test_an_encrypted_file_round_trips_with_its_secrets() -> None:
    doc = sample()
    data = ct.encrypted_file(doc, "a passphrase", iterations=ct.MIN_ITERATIONS)
    assert ct.is_encrypted(data) and b"p\\u00e4ssw" not in data and "pässwörd".encode() not in data
    assert ct.document_json(ct.read_file(data, "a passphrase")) == ct.document_json(doc)
    with pytest.raises(ct.ConfigError) as e:
        ct.read_file(data)
    assert e.value.code == "needsPassphrase"


def test_the_passphrase_is_compared_after_unicode_normalisation() -> None:
    doc = sample()
    data = ct.encrypted_file(doc, "café au lait!", iterations=ct.MIN_ITERATIONS)
    assert ct.read_file(data, "café au lait!").servers == doc.servers


def test_a_short_passphrase_is_refused() -> None:
    with pytest.raises(ct.ConfigError) as e:
        ct.encrypted_file(sample(), "123456789")
    assert e.value.code == "passphraseTooShort"
    assert ct.passphrase_problem("1234567890") is None


def test_a_plain_file_never_carries_secrets() -> None:
    data = ct.plain_file(sample())
    assert b"secrets" not in data and "pässwörd".encode() not in data
    assert ct.read_file(data).secrets == {}


def test_a_qr_transfer_round_trips_without_secrets_or_custom_icons() -> None:
    doc = sample()
    code, parts = ct.qr_export(doc, max_part_bytes=200)
    assert len(code) == 10 and all(c in ct.CROCKFORD for c in code)
    assert len(parts) > 1 and all(set(p) <= set(ct.BASE45 + ":/") for p in parts)
    collector = ct.QRCollector()
    for part in reversed(parts):
        collector.add(part)
    got = ct.read_qr_payload(collector.payload(), ct.format_unlock_code(code).lower())
    assert got.secrets == {} and got.custom_icons == {}
    assert ct.document_json(got) == ct.document_json(doc, secrets=False, custom_icons=False)


def test_too_much_for_qr_codes_says_so() -> None:
    with pytest.raises(ct.ConfigError) as e:
        ct.qr_parts(os.urandom(100 * 450), "ABC123")
    assert e.value.code == "tooLarge"


def test_a_zip_bomb_is_refused() -> None:
    bomb = ct._deflate(b"{" + b" " * (ct.MAX_INFLATED + 10) + b"}")
    with pytest.raises(ct.ConfigError) as e:
        ct._inflate(bomb)
    assert e.value.code == "tooLarge"


def test_the_catalog_types_every_transferred_preference() -> None:
    prefs = ct.preference_settings()
    assert "readOnly" in prefs and "vulnerabilityLookupAll" in prefs
    assert all(s.type in ("bool", "int", "string") for s in prefs.values())
    schema = load("config-transfer.schema.json")["properties"]["preferences"]["properties"]
    assert set(schema) == set(prefs)


def test_every_web_setting_is_in_the_catalog() -> None:
    """The web app's own saved preferences (the coverage rule; tools/check-spec scans every platform's source)."""
    web = {s.keys["web"] for s in ct.catalog() if s.keys.get("web")}
    assert {"preferences.json:theme", "preferences.json:readOnly", "preferences.json:autoReadOnly",
            "preferences.json:highlightOutput", "security/settings.json:osvAll",
            "security/settings.json:osvServers"} <= web
