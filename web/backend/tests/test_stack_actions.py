"""Deleting a stack and a standalone container's actions: the Kotlin core's StackRemovalTests (including the real
command under /bin/sh with a stub `docker`, symlink traps too) and StandaloneTests."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

from rackoon.core import spec
from rackoon.core.docker import ComposeAction, DockerContainer, DockerSnapshot, DockerStack
from rackoon.core.policy import Risk
from rackoon.core.stack_actions import StackRemoval, StandaloneAction, folder_problem
from rackoon.core.stack_files import editable


def stack(directory: str = "/opt/stacks/media", files: list[str] | None = None, standalone: bool = False,
          name: str = "media") -> DockerStack:
    f = files if files is not None else [f"{directory}/compose.yaml"]
    c = DockerContainer("abcdef012345", "media-web-1", "nginx", "running", "none", "Up", [], project=name, service="web",
                        working_dir=directory, config_file=f[0] if f else None, config_files=f)
    return DockerStack(name, directory, f[0] if f else None, f, [c], standalone)


def test_removal_commands_are_exact() -> None:
    base = "cd '/opt/stacks/media' && docker compose -p media -f '/opt/stacks/media/compose.yaml' down --remove-orphans"
    assert StackRemoval().command(stack()) == base
    assert StackRemoval(remove_volumes=True).command(stack()) == base + " -v"
    folder = StackRemoval(delete_folder=True).command(stack()) or ""
    assert folder.startswith(base + " && cd / && { [ -f '/opt/stacks/media/compose.yaml' ] || {"), folder
    assert "[ ! -L '/opt/stacks/media' ] || {" in folder
    assert "R=$(readlink -f -- '/opt/stacks/media')" in folder
    assert "case \"$(readlink -f -- '/opt/stacks/media/compose.yaml')\" in \"$R\"/*) true;;" in folder
    assert "rm -rf -- '/opt/stacks/media' || { [ \"$(id -u)\" -ne 0 ] && sudo -n rm -rf -- '/opt/stacks/media'; }" in folder
    intent = StackRemoval(remove_volumes=True, delete_folder=True).intent(stack())
    assert intent is not None and intent.summary == "Delete stack media and its folder" and intent.risk is Risk.MUTATE


@pytest.mark.parametrize("directory", [
    "/", "/opt", "/home", "/home/brian", "/root", "/var", "/var/lib", "/var/lib/docker", "/usr/local", "/etc", "/tmp",
    "/srv", "/opt/../etc", "/opt/./x", "/opt//x", "/opt/stacks/", "/data", "/Users/brian", "/mnt/disk", "/media/usb",
    "/usr/local/bin", "/var/lib/docker/volumes", "/etc/stacks/x", "/boot/x", "/snap/x"])
def test_folder_deletion_is_refused_for_system_and_home_folders(directory: str) -> None:
    s = stack(directory, [directory + "compose.yaml" if directory.endswith("/") else f"{directory}/compose.yaml"])
    assert folder_problem(s) is not None
    assert StackRemoval(delete_folder=True).command(s) is None


def test_folder_deletion_is_allowed_for_stack_folders() -> None:
    for d in ("/opt/stacks/media", "/opt/media", "/srv/media", "/home/brian/stacks/media", "/mnt/data/stacks/x",
              "/data/media", "/Users/brian/stacks"):
        assert folder_problem(stack(d)) is None, d
    outside = stack(files=["/opt/stacks/media/compose.yaml", "/etc/other.yaml"])
    assert folder_problem(stack(files=["/opt/stacks/media/../../x/compose.yaml"])) is not None
    assert folder_problem(stack(files=["/opt/stacks/media/./compose.yaml"])) is not None
    assert folder_problem(outside) is not None
    assert StackRemoval(delete_folder=True).command(outside) is None
    assert StackRemoval(remove_volumes=True).command(outside) is not None


def test_standalone_and_unsafe_projects_are_refused() -> None:
    assert StackRemoval().command(stack(standalone=True)) is None
    assert StackRemoval().command(stack(name="media; reboot")) is None
    assert StackRemoval().command(stack("relative", ["relative/compose.yaml"])) is None


# --- the real command under /bin/sh with a stub docker ------------------------------------------------------------


def run(removal: StackRemoval, directory: Path, docker_exit: int, tmp_path: Path) -> tuple[int, str]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    stub = bin_dir / "docker"
    stub.write_text(f"#!/bin/sh\nexit {docker_exit}\n")
    stub.chmod(0o755)
    command = removal.command(stack(str(directory)))
    assert command is not None
    p = subprocess.run(["/bin/sh", "-c", command], capture_output=True, text=True, timeout=60,
                       env={**os.environ, "PATH": f"{bin_dir}:/usr/bin:/bin"})
    return p.returncode, p.stdout + p.stderr


@pytest.fixture
def root(tmp_path: Path) -> Path:
    # Real paths: the guard compares them (macOS keeps temp folders under the /var -> /private/var symlink).
    r = (tmp_path / "root").resolve()
    r.mkdir()
    return Path(os.path.realpath(r))


def make(root: Path, name: str, compose: bool) -> Path:
    d = root / "stacks" / name
    (d / "data").mkdir(parents=True)
    (d / "data" / "file").write_text("x")
    if compose:
        (d / "compose.yaml").write_text("services: {}")
    return d


def test_the_folder_is_deleted_only_after_down_succeeds_and_only_with_its_compose_file(root: Path, tmp_path: Path) -> None:
    ok = make(root, "ok", True)
    assert run(StackRemoval(delete_folder=True), ok, 0, tmp_path)[0] == 0
    assert not ok.exists() and (root / "stacks").exists()
    failing = make(root, "failing", True)
    assert run(StackRemoval(delete_folder=True), failing, 1, tmp_path)[0] != 0
    assert (failing / "data" / "file").exists(), "down failed: nothing deleted"
    no_compose = make(root, "nocompose", False)
    assert run(StackRemoval(delete_folder=True), no_compose, 0, tmp_path)[0] != 0
    assert (no_compose / "data" / "file").exists()
    keep = make(root, "keep", True)
    assert run(StackRemoval(), keep, 0, tmp_path)[0] == 0
    assert (keep / "compose.yaml").exists(), "plain removal keeps the files"


def test_a_symlink_cannot_redirect_the_delete(root: Path, tmp_path: Path) -> None:
    precious = root / "precious"
    precious.mkdir()
    (precious / "compose.yaml").write_text("services: {}")
    (root / "stacks").mkdir()
    link = root / "stacks" / "linked"
    link.symlink_to(precious)
    assert run(StackRemoval(delete_folder=True), link, 0, tmp_path)[0] != 0
    assert (precious / "compose.yaml").exists()
    real = root / "stacks" / "real"
    (real / "data").mkdir(parents=True)
    (real / "compose.yaml").symlink_to(precious / "compose.yaml")
    assert run(StackRemoval(delete_folder=True), real, 0, tmp_path)[0] != 0
    assert (real / "data").exists()


def test_a_symlinked_parent_is_fine_and_guard_failures_say_so(root: Path, tmp_path: Path) -> None:
    real = root / "real" / "stacks" / "app"
    (real / "data").mkdir(parents=True)
    (real / "compose.yaml").write_text("services: {}")
    (root / "link").symlink_to(root / "real")
    code, out = run(StackRemoval(delete_folder=True), root / "link" / "stacks" / "app", 0, tmp_path)
    assert code == 0, out
    assert not real.exists() and real.parent.exists()
    bare = root / "real" / "stacks" / "bare"
    bare.mkdir()
    code, out = run(StackRemoval(delete_folder=True), bare, 0, tmp_path)
    assert code == 6 and "its compose file is missing" in out and bare.exists()
    target = root / "real" / "stacks" / "target"
    target.mkdir()
    (target / "compose.yaml").write_text("services: {}")
    linked = root / "real" / "stacks" / "linked"
    linked.symlink_to(target)
    code, out = run(StackRemoval(delete_folder=True), linked, 0, tmp_path)
    assert code == 6 and "it is a symbolic link" in out and (target / "compose.yaml").exists()
    outside = root / "real" / "stacks" / "outside"
    outside.mkdir()
    elsewhere = root / "elsewhere.yaml"
    elsewhere.write_text("services: {}")
    (outside / "compose.yaml").symlink_to(elsewhere)
    code, out = run(StackRemoval(delete_folder=True), outside, 0, tmp_path)
    assert code == 6 and "not inside it" in out and elsewhere.exists()


# --- standalone containers ----------------------------------------------------------------------------------------


def container(name: str, project: str | None = None, image: str = "nginx:1.27", cid: str = "abcdef012345") -> DockerContainer:
    return DockerContainer(cid, name, image, "running", "none", "Up", [], project=project,
                           service="web" if project else None, working_dir=f"/srv/{project}" if project else None,
                           config_file=f"/srv/{project}/compose.yaml" if project else None)


def test_every_standalone_container_gets_its_own_stack_with_a_unique_id() -> None:
    stacks = DockerSnapshot([container("Portainer", cid="111111111111"),
                             container("media-web-1", project="media", cid="222222222222"),
                             container("adguard", cid="333333333333"), container("media", cid="444444444444")]).stacks
    assert [s.name for s in stacks] == ["adguard", "media", "media", "Portainer"]
    assert [s.is_standalone for s in stacks] == [True, False, True, True]
    assert [s.id for s in stacks] == ["standalone/adguard", "media", "standalone/media", "standalone/Portainer"]
    assert [s.kind_label for s in stacks] == ["Standalone", "Compose Stack", "Standalone", "Standalone"]


def test_compose_actions_refuse_standalone_stacks() -> None:
    s = DockerSnapshot([container("adguard")]).stacks[0]
    assert all(a.command(s) is None for a in ComposeAction)
    assert StackRemoval().command(s) is None and editable(s) is None


def solo(image: str = "nginx:1.27", cid: str = "abcdef012345", standalone: bool = True) -> DockerStack:
    return DockerStack("adguard", None, None, [], [DockerContainer(cid, "adguard", image, "running", "none", "Up", [])],
                       standalone)


def test_standalone_commands_come_from_the_spec_and_are_exact() -> None:
    assert spec.script("docker_pull_image") == "docker pull {image}"
    assert spec.script("docker_remove") == "docker rm -f{volumes} {id}"
    assert StandaloneAction("pull").command(solo()) == "docker pull 'nginx:1.27'"
    digest = "a" * 64
    assert StandaloneAction("pull").command(solo(f"ghcr.io/org/app@sha256:{digest}")) == \
        f"docker pull 'ghcr.io/org/app@sha256:{digest}'"
    assert StandaloneAction("remove").command(solo()) == "docker rm -f abcdef012345"
    assert StandaloneAction("remove", volumes=True).command(solo()) == "docker rm -f -v abcdef012345"
    intent = StandaloneAction("remove", volumes=True).intent(solo())
    assert intent is not None and intent.summary == "Delete container adguard and its anonymous volumes"


def test_unsafe_or_unpullable_values_are_refused() -> None:
    for bad in ("", "-flag", "nginx; reboot", "nginx $(id)", "a'b", "nginx\nreboot", "sha256:" + "a" * 64,
                "abcdef012345", "b" * 64, "ünïcode"):
        assert StandaloneAction("pull").command(solo(bad)) is None, bad
    for bad in ("abc", "ABCDEF012345", "abcdef012345; rm -rf /", "$(whoami)abcdef"):
        assert StandaloneAction("remove").command(solo(cid=bad)) is None, bad
    assert StandaloneAction("pull").command(solo("registry.local:5000/team/app:v1.2_rc-3")) is not None
    assert StandaloneAction("pull").command(solo(standalone=False)) is None
