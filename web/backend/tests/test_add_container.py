"""Adding a container: the Kotlin core's ContainerSpecTests and NewStackTests (including the real create scripts
under /bin/sh with a stub docker)."""

from __future__ import annotations

import os
import stat
import subprocess
from dataclasses import replace
from pathlib import Path

import pytest

from rackoon.core import add_container as ac
from rackoon.core.add_container import ContainerSpec, EnvRow, ImageStatus, NewStackPlan, PortRow, RestartPolicy, VolumeRow
from rackoon.core.docker import ComposeAction, DockerContainer, DockerStack, PortMapping
from rackoon.core.editor import CheckRow, RowState
from rackoon.core.policy import Risk
from rackoon.core.remote_files import parse_listening_ports
from rackoon.core.stack_files import CannotWrite, ComposeIssue, FileMalformed, Severity, ValidationResult, env_syntax

from .support import out


def kuma() -> ContainerSpec:
    return ContainerSpec("uptime-kuma", "louislam/uptime-kuma:1", [PortRow("3001", "3001"), PortRow()],
                         [VolumeRow("./data", "/app/data")], [EnvRow("TZ", "Europe/Dublin")])


def test_generates_the_compose_from_the_design() -> None:
    assert kuma().compose_text == ('services:\n  uptime-kuma:\n    image: louislam/uptime-kuma:1\n    restart: unless-stopped\n'
                                   '    ports:\n      - "3001:3001"\n    volumes:\n      - ./data:/app/data\n'
                                   '    environment:\n      TZ: ${TZ}\n')
    assert kuma().env_text == "TZ=Europe/Dublin\n" and kuma().blocking_problem is None
    plain = ContainerSpec("web", "nginx:alpine", restart=RestartPolicy.NO)
    assert plain.compose_text == 'services:\n  web:\n    image: nginx:alpine\n    restart: "no"\n' and plain.env_text == ""


def test_problems_are_reported_per_field() -> None:
    for s in (replace(kuma(), name="Bad Name!"), replace(kuma(), image="nginx; reboot"),
              replace(kuma(), ports=[PortRow("99999", "80")]), replace(kuma(), ports=[PortRow("80", "")]),
              replace(kuma(), volumes=[VolumeRow("data", "/x")]), replace(kuma(), volumes=[VolumeRow("./d", "rel")]),
              replace(kuma(), env=[EnvRow("1X", "a")]), replace(kuma(), env=[EnvRow("A", "1"), EnvRow("A", "2")])):
        assert s.blocking_problem is not None, s
    assert ContainerSpec().blocking_problem == "Enter a container name"


def test_env_lines_are_quoted_safely() -> None:
    s = ContainerSpec("a", "a", env=[EnvRow("PLAIN", "abc"), EnvRow("SPACE", "a b"), EnvRow("DOLLAR", "p$ss#1"),
                                     EnvRow("QUOTE", "it's"), EnvRow("EMPTY", "")])
    assert s.env_text == "PLAIN=abc\nSPACE='a b'\nDOLLAR='p$ss#1'\nQUOTE=\"it's\"\nEMPTY=\n"
    assert env_syntax(s.env_text) == []


def test_env_merge_keeps_what_is_there() -> None:
    assert ac.merge_env("# comment\nTZ=UTC\nexport KEEP=1", [EnvRow("TZ", "Europe/Dublin"), EnvRow("NEW", "x")]) == \
        ("# comment\nTZ=UTC\nexport KEEP=1\nNEW=x\n", ["TZ"])
    assert ac.merge_env("A=1\n", [EnvRow("A", "2")])[0] == "A=1\n"
    assert ac.merge_env("", [EnvRow("A", "2")])[0] == "A=2\n"


def test_bind_address_validation() -> None:
    assert ac.port_problem(PortRow("127.0.0.1:8080", "80")) is None
    assert ac.port_problem(PortRow("${TS_IP}:8080", "80")) is None
    assert ac.port_problem(PortRow("evil;x:8080", "80")) is not None
    assert ac.port_problem(PortRow("1.2.3:8080", "80")) is not None
    assert PortRow("${TS_IP}:8080", "80").host_port == 8080 and PortRow("${TS_IP}:8080", "80").bind_address == "${TS_IP}"


def test_adds_after_the_last_service_and_leaves_the_rest_alone() -> None:
    f = '# my stack\nservices:\n  nginx:\n    image: nginx:alpine\n    ports:\n      - "8085:80"\n\nvolumes:\n  data: {}\n'
    result = ac.adding(kuma(), f)
    assert result == ('# my stack\nservices:\n  nginx:\n    image: nginx:alpine\n    ports:\n      - "8085:80"\n'
                      '  uptime-kuma:\n    image: louislam/uptime-kuma:1\n    restart: unless-stopped\n    ports:\n'
                      '      - "3001:3001"\n    volumes:\n      - ./data:/app/data\n    environment:\n      TZ: ${TZ}\n'
                      '\nvolumes:\n  data: {}\n')
    from rackoon.core.compose_edit import services
    assert services(result) == ["nginx", "uptime-kuma"]
    assert ac.adding(ContainerSpec("db", "postgres:16"), "services:\n    web:\n        image: nginx\n") == \
        "services:\n    web:\n        image: nginx\n    db:\n        image: postgres:16\n        restart: unless-stopped\n"


def test_refuses_duplicates_and_inline_services_and_adds_a_missing_key() -> None:
    with pytest.raises(ac.InsertError, match="already has a service called web"):
        ac.adding(ContainerSpec("web", "x"), "services:\n  web:\n    image: a\n")
    with pytest.raises(ac.InsertError, match="one line"):
        ac.adding(ContainerSpec("web", "x"), "services: {}\n")
    assert ac.adding(ContainerSpec("web", "x"), "volumes:\n  d: {}\n") == \
        "volumes:\n  d: {}\n\nservices:\n  web:\n    image: x\n    restart: unless-stopped\n"
    assert ac.adding(ContainerSpec("web", "x"), "services:\n") == "services:\n  web:\n    image: x\n    restart: unless-stopped\n"


def test_image_command_and_status() -> None:
    assert ac.image_command("nginx:alpine") == ("timeout 20 docker manifest inspect 'nginx:alpine' >/dev/null 2>&1; case $? "
                                                "in 0) echo found;; 124) echo timeout;; *) echo notfound;; esac")
    for bad in ("", "nginx; reboot", "a b", "$(id)", "-rm"):
        assert ac.image_command(bad) is None, bad
    assert ac.parse_image_status("found\n") is ImageStatus.FOUND
    assert ac.parse_image_status("timeout\n") is ImageStatus.TIMED_OUT
    assert ac.parse_image_status("notfound\n") is ImageStatus.NOT_FOUND
    assert ac.registry_name("louislam/uptime-kuma:1") == "Docker Hub" and ac.registry_name("ghcr.io/x/y:1") == "ghcr.io"
    assert ac.registry_name("localhost:5000/y") == "localhost:5000"
    assert parse_listening_ports(out("listening_ports", "basic")) == {22, 53, 80, 3001}


def test_port_rows_name_the_owner_and_suggest_a_free_port() -> None:
    owner = DockerContainer("abcdef012345", "boycott-nginx-1", "nginx", "running", "none", "Up", [PortMapping(8085, 80, "tcp")],
                            project="boycottcadbury", service="nginx")
    s = replace(kuma(), ports=[PortRow("8085", "80"), PortRow("3001", "3001")])
    rows = ac.port_rows(s, {22, 8085}, [owner], "hetzner")
    assert [r.state for r in rows] == [RowState.FAIL, RowState.PASS]
    assert rows[0].title == "Port 8085 is already in use" and rows[0].detail == "By nginx in boycottcadbury. Try 8086."
    assert rows[1].detail == "Free on hetzner"
    assert [r.state for r in ac.port_rows(s, None, [], "h")] == [RowState.RUNNING, RowState.RUNNING]
    twice = replace(s, ports=[PortRow("80", "80"), PortRow("80", "81")])
    assert [r.state for r in ac.port_rows(twice, set(), [], "h")] == [RowState.FAIL]


def test_name_and_compose_rows() -> None:
    existing = DockerContainer("abcdef012345", "media-uptime-kuma-1", "x", "running", "none", "Up", [], project="media",
                               service="uptime-kuma")
    assert ac.name_row(kuma(), "media", [existing]).state is RowState.FAIL
    assert ac.name_row(kuma(), "other", [existing]).state is RowState.PASS
    assert ac.name_row(ContainerSpec(), None, []).state is RowState.SKIPPED
    passing = [CheckRow(str(i), RowState.PASS, "t", "") for i in range(3)]
    assert [r.title for r in ac.compose_row(passing, "h")] == ["YAML syntax"]
    assert [r.title for r in ac.compose_row(passing + [CheckRow("f", RowState.FAIL, "docker compose config", "bad")], "h")] \
        == ["docker compose config"]


# --- new stacks ---------------------------------------------------------------------------------------------------


def plan(name: str = "media", parent: str = "/opt/stacks", env: str = "") -> NewStackPlan:
    return NewStackPlan(name, parent, env=env)


def test_plan_paths_and_validation() -> None:
    assert plan().directory == "/opt/stacks/media" and plan(parent="/opt/stacks/").directory == "/opt/stacks/media"
    assert plan(parent="/").directory == "/media" and plan().compose_path == "/opt/stacks/media/compose.yaml"
    st = plan().stack
    assert st is not None and st.working_dir == "/opt/stacks/media" and ComposeAction.UP.command(st) is not None
    for bad in ("", "Media", "-x", "a b", "a/b", "a;reboot", "../x"):
        assert plan(name=bad).name_problem is not None, bad
    for bad in ("", "relative", "stacks", "/opt/../etc"):
        assert plan(parent=bad).folder_problem is not None and plan(parent=bad).directory is None, bad
    assert ac.new_stack_create_command(plan(name="x; reboot")) is None
    assert ac.new_stack_check_command(plan(name="Bad")) is None


def test_default_parent_is_learned_from_the_server() -> None:
    def st(name: str, d: str | None, standalone: bool = False) -> DockerStack:
        return DockerStack(name, d, None, [], [], standalone)
    stacks = [st("a", "/opt/stacks/a"), st("b", "/opt/stacks/b"), st("c", "/srv/c"), st("d", None), st("e", "/mnt/x/e", True)]
    assert ac.default_parent(stacks, "root") == "/opt/stacks"
    assert ac.default_parent([st("a", "/srv/long/a"), st("b", "/opt/b")], None) == "/opt"
    assert ac.default_parent([], "root") == "/opt/stacks" and ac.default_parent([], None) == "/opt/stacks"
    assert ac.default_parent([], "brian") == "/home/brian/stacks"


def test_intent_preview_and_outcomes() -> None:
    intent = ac.new_stack_intent(plan(env="A=1\n"))
    assert intent is not None and intent.risk is Risk.MUTATE and intent.preview
    assert "Create folder /opt/stacks/media" in intent.preview and ".env" in intent.preview and "nginx:alpine" in intent.preview
    assert ac.create_outcome_of(0, "##created\n", "") == "created"
    assert ac.create_outcome_of(3, "##exists\n", "") == "exists"
    assert ac.create_outcome_of(4, "##invalid\nyaml: line 3: bad\n", "") == \
        ValidationResult([ComposeIssue(Severity.ERROR, 3, "bad")])
    with pytest.raises(CannotWrite):
        ac.create_outcome_of(7, "##cannot-write\n", "")
    with pytest.raises(FileMalformed):
        ac.create_outcome_of(0, "", "")
    checked = ac.check_result(1, "failed to parse /tmp/tmp.AbC/compose.yaml: bad\n", "")
    assert not checked.is_valid and checked.errors[0].message == "failed to parse compose.yaml: bad"
    issue = ComposeIssue(Severity.ERROR, 3, "yaml: /tmp/tmp.AbC123/compose.yaml: bad; see /opt/stacks/x/.env")
    assert issue.simplifying_scratch_paths().message == "yaml: compose.yaml: bad; see .env"


def run_create(p: NewStackPlan, docker_exit: int, root: Path) -> tuple[int, str]:
    bin_dir = root / "bin"
    bin_dir.mkdir(exist_ok=True)
    stub = bin_dir / "docker"
    stub.write_text(f"#!/bin/sh\n[ \"{docker_exit}\" = 0 ] || echo 'yaml: line 3: bad' >&2\nexit {docker_exit}\n")
    stub.chmod(0o755)
    command = ac.new_stack_create_command(p)
    assert command is not None
    r = subprocess.run(["/bin/sh", "-c", command], capture_output=True, text=True, timeout=60,
                       env={**os.environ, "PATH": f"{bin_dir}:/usr/bin:/bin"})
    return r.returncode, r.stdout + r.stderr


def test_create_writes_files_and_refuses_an_existing_folder(tmp_path: Path) -> None:
    root = Path(os.path.realpath(tmp_path))
    p = plan(parent=str(root / "stacks"), env="TOKEN=abc\n")
    code, text = run_create(p, 0, root)
    assert code == 0 and "##created" in text, text
    d = Path(p.directory or "")
    assert (d / "compose.yaml").read_text() == p.compose and (d / ".env").read_text() == "TOKEN=abc\n"
    assert stat.S_IMODE((d / ".env").stat().st_mode) == 0o600
    code, text = run_create(NewStackPlan(p.name, p.parent_directory, "services: {}\n"), 0, root)
    assert code == 3 and "##exists" in text and (d / "compose.yaml").read_text() == p.compose


def test_a_failed_check_leaves_nothing_behind(tmp_path: Path) -> None:
    root = Path(os.path.realpath(tmp_path))
    p = plan(parent=str(root / "stacks"), env="A=1\n")
    code, text = run_create(p, 1, root)
    assert code == 4 and "##invalid" in text and not Path(p.directory or "").exists()
