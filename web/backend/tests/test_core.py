"""The Python core against spec/: models validate against spec/models.schema.json, commands and the command library
come from spec/ (no copies), themes load and validate, plus the parser details the Kotlin core's unit tests pin."""

from __future__ import annotations

import ast
from pathlib import Path

import jsonschema
import pytest

from rackoon.core import command_library, docker, overview, remote_files, services, shell, spec, stream, themes, updates
from rackoon.core.jsonmodel import to_json
from rackoon.core.models import Server
from rackoon.core.policy import ActionPolicy, Confirmation, Intent, NotConfirmed, ReadOnly, Risk

from .support import fixtures, load, out

SCHEMA = load("models.schema.json")


def _validate(definition: str, value: object) -> None:
    jsonschema.validate(value, {"$ref": f"#/$defs/{definition}", "$defs": SCHEMA["$defs"]})


# --- models.schema.json -------------------------------------------------------------------------------------------


def test_overview_matches_schema() -> None:
    for name in fixtures("overview"):
        _validate("Overview", to_json(overview.parse(out("overview", name))))


def test_docker_snapshot_matches_schema() -> None:
    for name in fixtures("docker"):
        try:
            snapshot = docker.parse(out("docker", name))
        except docker.DockerParseError:
            continue
        _validate("DockerSnapshot", to_json(snapshot))


def test_updates_snapshot_matches_schema() -> None:
    for name in fixtures("updates"):
        try:
            snapshot = updates.parse(out("updates", name))
        except updates.UpdatesParseError:
            continue
        _validate("UpdatesSnapshot", to_json(snapshot))


def test_server_matches_schema() -> None:
    _validate("Server", to_json(Server("1", "lab", "127.0.0.1", user="rk", port=2222, identity_file="~/.ssh/id")))
    _validate("Server", to_json(Server("2", "alias", "minilab", ssh_config_alias="minilab")))


# --- spec/ is the only copy ---------------------------------------------------------------------------------------


def test_commands_come_from_spec() -> None:
    raw = {c["id"]: c["script"] for c in load("commands.json")["commands"]}
    assert spec.command_ids() == set(raw)
    for cid, script in raw.items():
        assert spec.script(cid) == script
    assert overview.command() == raw["overview"]
    assert docker.command() == raw["docker"]
    assert updates.command() == raw["updates"]


def test_no_shell_command_is_copied_into_python() -> None:
    """No string literal in rackoon/core holds a whole spec script (guards the library adds around a script, like
    the `$S` sudo prefix Kotlin also writes, are not scripts)."""
    scripts = [c["script"] for c in load("commands.json")["commands"]] + \
              [c["script"] for c in load("command-library.json")["commands"]]
    long_scripts = [s for s in scripts if len(s) >= 40]
    core = Path(spec.__file__).parent
    for path in core.glob("*.py"):
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and len(node.value) >= 40:
                for s in long_scripts:
                    assert s not in node.value, f"{path.name} copies a spec command"


def test_command_library_loads_every_entry() -> None:
    raw = load("command-library.json")
    loaded = command_library.all_commands()
    assert [c.id for c in loaded] == [c["id"] for c in raw["commands"]]
    assert command_library.groups() == raw["groups"]
    for c in loaded:
        assert c.group in raw["groups"], c.id
        if c.params:
            assert c.full_script() is None, f"{c.id}: a missing parameter must refuse the script"
        else:
            script = c.full_script()
            assert script is not None and script.endswith(c.script), c.id
        if c.is_mutating:
            assert c.preview, f"{c.id}: a mutating entry needs a dry run"


def test_library_params_are_validated_and_quoted() -> None:
    container = command_library.LibraryParam("c", "Container", command_library.ParamKind.CONTAINER)
    host = command_library.LibraryParam("h", "Host", command_library.ParamKind.HOSTNAME)
    assert container.quoted(" web-1 ") == "'web-1'"
    for bad in ["", "-x", "a b", "a;b", "a'b", "x" * 129]:
        assert container.quoted(bad) is None, bad
    assert host.quoted("example.com") == "'example.com'"
    for bad in ["-x.com", ".a", "a.", "a..b", "a b", "a_b"]:
        assert host.quoted(bad) is None, bad
    assert command_library.custom_intent("  ") is None
    intent = command_library.custom_intent("uptime")
    assert intent is not None and intent.risk is Risk.MUTATE


def test_themes_load_and_validate() -> None:
    bundled = themes.bundled()
    assert len(bundled) == 45
    assert themes.resolve("automatic", True, bundled).id == "rackoon-dark"  # type: ignore[union-attr]
    assert themes.resolve("automatic", False, bundled).id == "rackoon-light"  # type: ignore[union-attr]
    assert themes.resolve("no-such-theme", True, bundled).id == "rackoon-dark"  # type: ignore[union-attr]
    assert themes.RGB.from_hex("#fff") is None
    assert themes.RGB.from_hex("#0A0b0C") == themes.RGB(10, 11, 12)
    with pytest.raises(themes.ThemeCatalogError):
        themes.load('[{"id": "x", "name": "x", "family": "x", "appearance": "dark", "background": "#ffffff", '
                    '"foreground": "#000000", "ansi": []}]')


# --- details the Kotlin unit tests pin ----------------------------------------------------------------------------


def test_missing_overview_section_raises() -> None:
    text = out("overview", "ubuntu-24.04").replace("##loadavg", "##notloadavg")
    with pytest.raises(overview.MissingSection):
        overview.parse(text)


def test_ipv4_only_accepts_dotted_quads() -> None:
    assert overview.ipv4(" 100.64.1.2 ") == "100.64.1.2"
    for bad in ["300.1.1.1", "fe80::1", "1.2.3", None]:
        assert overview.ipv4(bad) is None


def test_cpu_percent_from_two_readings() -> None:
    a = overview.parse(out("overview", "ubuntu-24.04"))
    from dataclasses import replace
    b = replace(a, cpu=overview.CPUCounters(a.cpu.total + 1000, a.cpu.idle + 750))
    assert b.cpu_percent(a) == pytest.approx(25.0)
    assert a.cpu_percent(a) is None


def test_docker_ports_sizes_health_labels() -> None:
    ports = docker.parse_ports("127.0.0.1:8087->8080/tcp, [::]:8087->8080/tcp, 172.17.0.1:8087->8080/tcp, 5432/tcp, "
                               "67-68/udp, 0.0.0.0:53->53/udp, 0.0.0.0:8000-8010->8000-8010/tcp")
    assert ports == [docker.PortMapping(8087, 8080, "tcp"), docker.PortMapping(53, 53, "udp")]
    assert docker.parse_size("255.8MiB") == 268_225_741
    assert docker.parse_size("7.57GiB") == 8_128_225_608
    assert docker.parse_size("115kB") == 115_000
    assert docker.parse_size("0B") == 0
    assert docker.parse_size("lots") is None
    assert docker.parse_percent("0.03%") == 0.03
    assert docker.parse_percent("--") is None
    assert docker.health(None, "Up 2 hours (healthy)") == "healthy"
    assert docker.health("", "Up 1 minute (unhealthy)") == "unhealthy"
    assert docker.health(None, "Up 3 seconds (health: starting)") == "starting"
    assert docker.health(None, "Up 2 hours") == "none"
    labels = docker.parse_labels("a=1,com.docker.compose.project.config_files=/x/a.yaml,/x/b.yaml,b=2")
    assert labels["com.docker.compose.project.config_files"] == "/x/a.yaml,/x/b.yaml"
    assert labels["b"] == "2"


def test_stacks_group_by_project_and_each_standalone_container_is_its_own_stack() -> None:
    stacks = docker.parse(out("docker", "synthetic-mixed-states")).stacks
    assert [s.name for s in stacks] == ["dockge", "monitoring", "scratch", "shlink", "watchtower"]
    monitoring = next(s for s in stacks if s.name == "monitoring")
    assert (monitoring.config_file_name, monitoring.kind_label, monitoring.id) == ("compose.yaml", "Compose Stack",
                                                                                   "monitoring")
    assert (monitoring.stopped_count, monitoring.unhealthy_count) == (1, 1)
    scratch = next(s for s in stacks if s.name == "scratch")
    assert scratch.is_standalone and scratch.id == "standalone/scratch" and scratch.working_dir is None
    assert docker.ComposeAction.UP.command(scratch) is None


def test_bookmark_urls() -> None:
    for good in ["https://a.example.com/", "http://10.0.0.2:8080/x?y=1"]:
        assert docker.is_valid_url(good), good
    for bad in ["ftp://x", "https://", "javascript:alert(1)", "https://a b", "https://a\nb", "x" * 3000, "https://a|b"]:
        assert not docker.is_valid_url(bad), bad


def test_container_commands_refuse_bad_ids() -> None:
    assert docker.logs_command("abc") is None
    assert docker.DockerAction.RESTART.command("abcdef012345;rm") is None
    restart = docker.DockerAction.RESTART.intent("abcdef012345")
    assert restart is not None and restart.risk is Risk.MUTATE and "abcdef012345" in restart.command


def test_policy_needs_a_confirmation_for_the_exact_intent() -> None:
    policy = ActionPolicy()
    restart = Intent("Restart", "docker restart abcdef012345", Risk.MUTATE)
    other = Intent("Restart", "docker restart 000000000000", Risk.MUTATE)
    policy.authorize(Intent("List", "docker ps", Risk.READ), None)
    with pytest.raises(NotConfirmed):
        policy.authorize(restart, policy.confirm(other))
    confirmation = policy.confirm(restart)
    policy.authorize(restart, confirmation)
    policy.is_read_only = True
    with pytest.raises(ReadOnly):
        policy.authorize(restart, confirmation)
    with pytest.raises(TypeError):
        Confirmation(restart)


def test_template_fill_is_one_pass() -> None:
    assert shell.fill("{a} {b}", {"a": "{b}", "b": "x"}) == "{b} x"


def test_stream_wrap_clamps_the_size() -> None:
    wrapped = stream.wrap("true", 1, 1000)
    assert wrapped.startswith("stty cols 20 rows 200")


def test_listing_refuses_relative_paths() -> None:
    assert remote_files.list_command("relative") is None
    command = remote_files.list_command("/srv/it's here")
    assert command is not None and command.startswith("cd -P -- '/srv/it'\\''s here' ")


def test_service_catalog_comes_from_the_spec() -> None:
    raw = spec.load_json("service-catalog.json")
    catalog = services.catalog()
    assert [p.id for p in catalog.products] == [p["id"] for p in raw["products"]]
    tailscale = services.product_for("tailscaled.service")
    runner = services.product_for("actions.runner.org-repo.box.service")
    assert tailscale is not None and tailscale.id == "tailscale"
    assert runner is not None and runner.id == "github-runner"
    assert services.product_for("getty@tty1.service") is None
    assert services.is_plumbing("getty@tty1.service") and services.is_plumbing("systemd-journald")
    assert services.is_container_helper("containerd-shim-runc-v2")
    assert services.process_name("python3.12", "python3.12 /opt/app/paperless.py") == "paperless"
