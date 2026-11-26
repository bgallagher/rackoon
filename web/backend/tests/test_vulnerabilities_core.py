"""The vulnerability lookup's core (rackoon.core.vulnerabilities), mirroring VulnerabilityTests in RackoonCore."""

from __future__ import annotations

import asyncio
import json

import pytest

from rackoon.core import vulnerabilities as v

from .support import load, out
from .test_shared_scenarios import ReplayOSV, run_debian_version, run_vulnerability_report


def scenario_cases(name: str) -> list[tuple[str, dict]]:  # type: ignore[type-arg]
    return [(c["name"], c) for c in load(f"scenarios/{name}")["cases"]]


def test_shared_scenarios_whatever_features_json_says() -> None:
    run_debian_version(scenario_cases("debian-version.json"))
    run_vulnerability_report(load("scenarios/vulnerability-report.json"), scenario_cases("vulnerability-report.json"))


def test_command_comes_from_the_spec() -> None:
    want = next(c["script"] for c in load("commands.json")["commands"] if c["id"] == "security_packages")
    assert v.command() == want


def test_only_names_ecosystems_and_versions_are_sent() -> None:
    client = ReplayOSV("noble-querybatch.json")
    asyncio.run(v.lookup(v.parse_inventory(out("security_packages", "synthetic-ubuntu-noble")), [], client, v.OSVCache()))
    doc = json.loads(client.posts[0])
    keys = {k for q in doc["queries"] for k in list(q) + [f"package.{p}" for p in q["package"]]}
    assert keys == {"package", "version", "package.name", "package.ecosystem"}
    assert b"noble" not in client.posts[0]


def test_a_second_lookup_within_a_day_is_answered_from_the_cache() -> None:
    cache = v.OSVCache()
    inv = v.parse_inventory(out("security_packages", "synthetic-ubuntu-noble"))
    a = asyncio.run(v.lookup(inv, [], ReplayOSV("noble-querybatch.json"), cache, now=1000.0))
    quiet = ReplayOSV(None)
    b = asyncio.run(v.lookup(inv, [], quiet, cache, now=2000.0))
    assert a == b and not quiet.posts and not quiet.gets
    later = ReplayOSV("noble-querybatch.json")
    asyncio.run(v.lookup(inv, [], later, cache, now=1000.0 + v.OSVCache.LIFETIME + 1))
    assert len(later.posts) == 1


def test_page_tokens_continue_only_the_queries_that_have_one() -> None:
    qs = [v.OSVQuery("a", "Debian:12", "1"), v.OSVQuery("b", "Debian:12", "2")]
    items = json.loads(v.batch_body(qs, [None, "tok"]))["queries"]
    assert "page_token" not in items[0] and items[1]["page_token"] == "tok"


def test_a_batch_with_the_wrong_number_of_results_is_refused() -> None:
    with pytest.raises(v.OSVError):
        v.parse_batch(b'{"results":[{}]}', 2)
