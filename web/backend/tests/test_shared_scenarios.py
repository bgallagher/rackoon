"""Runs the language-neutral behaviour scenarios in spec/scenarios/*.json (docs/parity.md), like SharedScenarioTests
in RackoonCore (Swift) and android/core (Kotlin). A file with a `feature` runs only while that feature is done for
web in spec/features.json, so marking a feature done turns its scenarios on; a file without one runs everywhere.
`RACKOON_PARITY_ALL=1` also runs the files whose feature is not done yet (never counted as proof)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import pytest

from rackoon.core import docker, shell, stream
from rackoon.core.models import server_input_problem
from rackoon.core.policy import ActionPolicy, Confirmation, Intent, NotConfirmed, ReadOnly, Risk

from .support import PLATFORM, SPEC, done_features, load, run_everything

SUBJECTS = {"shell_quote", "template_fill", "action_policy", "compose_command", "stream_output", "server_input",
            "docker_ids"}


@dataclass
class Scenario:
    file: str
    feature: str | None
    subject: str
    cases: list[dict[str, Any]]


def scenarios() -> list[Scenario]:
    """Every scenario file that applies to this platform."""
    done = done_features()
    out: list[Scenario] = []
    for path in sorted((SPEC / "scenarios").glob("*.json")):
        doc = load(f"scenarios/{path.name}")
        feature = doc.get("feature")
        if feature is not None and feature not in done and not run_everything():
            continue
        out.append(Scenario(path.name, feature, doc["subject"], doc["cases"]))
    return out


def cases(subject: str) -> list[tuple[str, dict[str, Any]]]:
    found = [(f"{s.file}: {c['name']}", c) for s in scenarios() if s.subject == subject for c in s.cases]
    if not found:
        pytest.skip(f"{subject}: its feature is not done on {PLATFORM}")
    return found


def test_every_applicable_scenario_has_a_runner() -> None:
    for s in scenarios():
        assert s.subject in SUBJECTS, f"{s.file}: subject {s.subject} has no Python runner, but its feature is done on web"
        assert s.cases, s.file


def test_shell_quote() -> None:
    for name, c in cases("shell_quote"):
        got = shell.quote_path(c["input"]) if c["fn"] == "quotePath" else shell.quote(c["input"])
        assert got == c.get("expect"), name


def test_template_fill() -> None:
    for name, c in cases("template_fill"):
        assert shell.fill(c["template"], c["values"]) == c["expect"], name


def _intent(value: Any) -> Intent | None:
    if value is None:
        return None
    return Intent(value["summary"], value["command"], Risk.MUTATE if value["risk"] == "mutate" else Risk.READ,
                  value.get("preview"))


def test_action_policy() -> None:
    for name, c in cases("action_policy"):
        policy = ActionPolicy(read_only=c["readOnly"])
        confirmation: Confirmation | None = None
        shown = _intent(c.get("confirm"))
        if shown is not None:
            try:
                confirmation = policy.confirm(shown)
                got = "ok"
            except ReadOnly:
                got = "read_only"
            assert got == c.get("expectConfirm", "ok"), f"{name} (confirm)"
        if c.get("readOnlyAtRun") is not None:
            policy.is_read_only = c["readOnlyAtRun"]
        run = _intent(c["run"])
        assert run is not None, name
        try:
            policy.authorize(run, confirmation)
            outcome = "ok"
        except ReadOnly:
            outcome = "read_only"
        except NotConfirmed:
            outcome = "not_confirmed"
        assert outcome == c["expect"], name


def test_compose_command() -> None:
    for name, c in cases("compose_command"):
        s = c["stack"]
        files: list[str] = s["configFiles"]
        containers = [
            docker.DockerContainer(
                id=f"abcdef{i:06d}", name=f"{s['name']}-{service}-1", image="nginx", state="running", health="none",
                status="Up", ports=[], project=s["name"], service=service, working_dir=s.get("workingDir"),
                config_file=files[0] if files else None, config_files=files)
            for i, service in enumerate(s["services"])]
        stack = docker.DockerStack(s["name"], s.get("workingDir"), files[0] if files else None, files, containers,
                                   is_standalone=s.get("standalone", False))
        action = docker.ComposeAction.from_raw(c["action"])
        assert action is not None, name
        assert action.command(stack, c.get("service")) == c.get("expect"), name


def test_stream_output() -> None:
    for name, c in cases("stream_output"):
        parser = stream.StreamOutputParser()
        shown = "".join(parser.push(chunk) for chunk in c["chunks"])
        rest, exit_code = parser.finish()
        assert shown + rest == c["text"], name
        assert exit_code == c.get("exitCode"), name


def test_server_input() -> None:
    for name, c in cases("server_input"):
        problem = server_input_problem(c["host"], c["user"], c["port"])
        assert (problem is None) == c["ok"], f"{name}: {problem or 'accepted'}"


def test_docker_ids() -> None:
    for name, c in cases("docker_ids"):
        ok = docker.is_container_id(c["value"]) if c["kind"] == "container_id" else docker.is_service_name(c["value"])
        assert ok == c["ok"], name
