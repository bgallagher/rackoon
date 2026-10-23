"""Every golden file in spec/fixtures must come out of the Python parsers exactly as the Swift and Kotlin cores
produce it. Errors are encoded the way the other cores' tests encode them (`{"error": "notInstalled"}`...)."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

import pytest

from rackoon.core import docker, docker_states, overview, remote_files, services, stack_files, unraid, updates
from rackoon.core.jsonmodel import to_json

from .support import SPEC, assert_json_equals, expected, fixtures, out

# Not parsed by the web core: supporter licence keys are `na` for web in spec/features.json (self-hosted is free).
NOT_FOR_WEB = {"licence"}


def _docker(text: str) -> Any:
    try:
        return to_json(docker.parse(text))
    except docker.NotInstalled:
        return {"error": "notInstalled"}
    except docker.Daemon as e:
        return {"error": "daemon", "message": e.text}
    except Exception as e:  # noqa: BLE001 - the golden file says which error is expected
        return {"error": "other", "message": str(e)}


def _updates(text: str) -> Any:
    try:
        return to_json(updates.parse(text))
    except updates.AptNotInstalled:
        return {"error": "notInstalled"}
    except Exception as e:  # noqa: BLE001
        return {"error": "other", "message": str(e)}


def _file_read(text: str) -> Any:
    try:
        s = stack_files.parse_file_read(text)
    except stack_files.NotText:
        return {"error": "notText"}
    except Exception as e:  # noqa: BLE001
        return {"error": "other", "message": str(e)}
    if isinstance(s, stack_files.Missing):
        return {"state": "missing"}
    if isinstance(s, stack_files.TooLarge):
        return {"state": "tooLarge"}
    return {"state": "file", "content": s.content, "sha256": s.sha256, "mode": s.mode, "owner": s.owner,
            "modifiedAt": s.modified_at}


def _unraid(text: str) -> Any:
    try:
        return to_json(unraid.parse(text))
    except unraid.NotUnraid:
        return {"error": "notUnraid"}


GOLDEN: dict[str, Callable[[str], Any]] = {
    "overview": lambda t: to_json(overview.parse(t)),
    "docker": _docker,
    "updates": _updates,
    "file_read": _file_read,
    "listening_ports": lambda t: {"ports": sorted(remote_files.parse_listening_ports(t))},
    "docker_states": lambda t: docker_states.parse(t).to_golden(),
    "services": lambda t: to_json(services.parse(t)),
    "unraid": _unraid,
}


def test_every_fixture_folder_has_a_parser() -> None:
    folders = {p.name for p in (SPEC / "fixtures").iterdir() if p.is_dir()}
    missing = folders - set(GOLDEN) - {"files_list"} - NOT_FOR_WEB
    assert not missing, f"fixtures with no Python parser test: {sorted(missing)}"


@pytest.mark.parametrize("command_id", sorted(GOLDEN))
def test_golden(command_id: str) -> None:
    names = fixtures(command_id)
    assert names, command_id
    for name in names:
        assert_json_equals(expected(command_id, name), GOLDEN[command_id](out(command_id, name)),
                           f"{command_id}/{name}")


def test_golden_files_list() -> None:
    """The files_list golden file is compared field by field like the Swift test, `modified` to 1 ms."""
    for name in fixtures("files_list"):
        want = expected("files_list", name)
        listing = remote_files.parse_listing(out("files_list", name))
        assert listing is not None
        assert listing.path == want["path"]
        assert listing.truncated == want["truncated"]
        assert len(listing.entries) == len(want["entries"])
        for got, w in zip(listing.entries, want["entries"]):
            assert (got.name, got.kind.value, got.link_target, got.links_to_directory, got.size, got.permissions,
                    got.owner) == (w["name"], w["kind"], w["linkTarget"], w["linksToDirectory"], w["size"],
                                   w["permissions"], w["owner"])
            assert abs(got.modified - w["modified"]) < 0.001
        assert [e.is_directory for e in listing.entries] == [True, False, False, False, True, False]
