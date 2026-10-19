"""The Add container page's rules (the Kotlin AddContainerDraftTests' cases), as the pure functions the backend uses:
what the files become, the checklist, and why Create is off."""

from __future__ import annotations

from rackoon.core import add_container as ac
from rackoon.core.add_container import AddDraft, ContainerSpec, EnvRow, Existing, ImageStatus, PortRow, Readings, VolumeRow
from rackoon.core.docker import DockerContainer, DockerStack, PortMapping
from rackoon.core.editor import RowState
from rackoon.core.stack_files import ComposeIssue, Severity, ValidationResult

KUMA = ContainerSpec("uptime-kuma", "louislam/uptime-kuma:1", [PortRow("3001", "3001")],
                     [VolumeRow("./data", "/app/data")], [EnvRow("TZ", "Europe/Dublin")])
WEB = DockerContainer("abcdef012345", "media-web-1", "nginx", "running", "none", "Up", [PortMapping(8080, 80, "tcp")],
                      project="media", service="web", working_dir="/opt/stacks/media",
                      config_file="/opt/stacks/media/compose.yaml", config_files=["/opt/stacks/media/compose.yaml"])
MEDIA = DockerStack("media", "/opt/stacks/media", "/opt/stacks/media/compose.yaml", ["/opt/stacks/media/compose.yaml"], [WEB])


def ready(d: AddDraft, ex: Existing | None = None, issues: list[ComposeIssue] | None = None,
          listening: set[int] | None = None, image: ImageStatus = ImageStatus.FOUND) -> Readings:
    """What the server would have said about exactly this draft."""
    return Readings(ValidationResult(issues or []), ac.check_key(d, ex), None, image, listening or set())


def test_a_new_stack_from_the_form_passes_all_checks_and_can_be_created() -> None:
    d = AddDraft("new", KUMA, "kuma", "/opt/stacks")
    r = ready(d)
    rows = ac.rows(d, None, r, [WEB], "lab")
    assert [x.title for x in rows] == ["YAML syntax", "Image", "Port 3001", "Container name"]
    assert all(x.state is RowState.PASS for x in rows)
    assert ac.blocked_reason(d, None, r, [MEDIA], [WEB], "lab", False) is None
    p = ac.plan_of(d)
    assert p.directory == "/opt/stacks/kuma" and p.env == "TZ=Europe/Dublin\n" and "uptime-kuma:" in p.compose
    intent = ac.new_stack_intent(p)
    assert intent and intent.preview and "Create folder /opt/stacks/kuma" in intent.preview


def test_problems_block_the_button_with_a_reason() -> None:
    blocked = ac.blocked_reason
    assert blocked(AddDraft("new", KUMA), None, Readings(), [MEDIA], [WEB], "lab", False) == "Enter a stack name"
    assert blocked(AddDraft("new", KUMA, "media"), None, Readings(), [MEDIA], [WEB], "lab", False) == \
        "A stack named media already exists"
    assert blocked(AddDraft("new", ContainerSpec(), "kuma"), None, Readings(), [MEDIA], [WEB], "lab", False) == \
        "Enter a container name"
    clash = AddDraft("new", ContainerSpec("app", "nginx", [PortRow("8080", "80")]), "kuma")
    r = ready(clash, listening={8080})
    port = next(x for x in ac.rows(clash, None, r, [WEB], "lab") if x.id == "port8080")
    assert port.state is RowState.FAIL and port.detail == "By web in media. Try 8081."
    assert (blocked(clash, None, r, [MEDIA], [WEB], "lab", False) or "").startswith("Port 8080 is already in use")
    assert blocked(AddDraft("new", KUMA, "kuma"), None, ready(AddDraft("new", KUMA, "kuma")), [], [], "lab", True) == \
        "Read-only mode is on"


def test_a_missing_image_blocks_and_a_slow_registry_only_warns() -> None:
    d = AddDraft("new", KUMA, "kuma")
    missing = ready(d, image=ImageStatus.NOT_FOUND)
    assert next(x for x in ac.rows(d, None, missing, [], "lab") if x.id == "image").state is RowState.FAIL
    assert (ac.blocked_reason(d, None, missing, [], [], "lab", False) or "").startswith("Image:")
    slow = ready(d, image=ImageStatus.TIMED_OUT)
    assert next(x for x in ac.rows(d, None, slow, [], "lab") if x.id == "image").state is RowState.WARN
    assert ac.blocked_reason(d, None, slow, [], [], "lab", False) is None


def test_a_server_that_rejects_the_compose_blocks_and_a_stale_check_waits() -> None:
    d = AddDraft("new", KUMA, "kuma")
    bad = ready(d, issues=[ComposeIssue(Severity.ERROR, 4, "mapping values are not allowed here")])
    first = ac.rows(d, None, bad, [], "lab")[0]
    assert first.state is RowState.FAIL and "Line 4" in first.detail
    assert ac.blocked_reason(d, None, bad, [], [], "lab", False) is not None
    stale = Readings(ValidationResult([]), "something older", None, ImageStatus.FOUND, set())
    assert ac.blocked_reason(d, None, stale, [], [], "lab", False) == "Waiting for the checks on lab"


def test_pasting_a_compose_file_replaces_the_form() -> None:
    compose = 'services:\n  hello:\n    image: nginxdemos/hello\n    ports:\n      - "${TS_IP}:8081:80"\n'
    d = AddDraft("new", ContainerSpec(), "hello", "/opt/stacks", paste=True, paste_compose=compose,
                 paste_env="TS_IP=100.64.0.1\n")
    r = ready(d)
    assert [x.title for x in ac.rows(d, None, r, [], "lab")] == ["YAML syntax", "Pasted file"]
    assert ac.blocked_reason(d, None, r, [], [], "lab", False) is None
    assert ac.plan_of(d).compose == compose and ac.plan_of(d).env == "TS_IP=100.64.0.1\n"
    broken = AddDraft("new", ContainerSpec(), "hello", paste=True, paste_compose=compose, paste_env="BAD LINE\n")
    assert (ac.blocked_reason(broken, None, ready(broken), [], [], "lab", False) or "").startswith("Fix .env")


def test_unset_variables_in_a_pasted_file_are_offered() -> None:
    d = AddDraft("new", ContainerSpec(), "db", paste=True, paste_compose="services:\n  db:\n    image: pg\n")
    warn = ComposeIssue(Severity.WARNING, None, 'The "DB_PASSWORD" variable is not set. Defaulting to a blank string.')
    assert ac.missing_variables(d, None, ready(d, issues=[warn])) == ["DB_PASSWORD"]
    defined = AddDraft("new", ContainerSpec(), "db", paste=True, paste_compose=d.paste_compose, paste_env="DB_PASSWORD=\n")
    assert ac.missing_variables(defined, None, ready(defined, issues=[warn])) == []


def test_adding_to_an_existing_stack_inserts_the_service_and_merges_the_env() -> None:
    ex = Existing("services:\n  web:\n    image: nginx\n", "a" * 64, "TZ=UTC\n", "b" * 64)
    d = AddDraft("existing", KUMA, existing_name="media")
    compose = ac.compose_text(d, ex)
    assert compose.startswith("services:\n  web:\n    image: nginx\n  uptime-kuma:\n")
    assert ac.env_text(d, ex) == "TZ=UTC\n", "TZ is already there: its value is kept"
    r = ready(d, ex)
    assert any(x.id == "envkept" and "TZ" in x.detail for x in ac.rows(d, ex, r, [WEB], "lab"))
    assert ac.blocked_reason(d, ex, r, [MEDIA], [WEB], "lab", False) is None
    new_var = AddDraft("existing", ContainerSpec("x", "nginx", env=[EnvRow("NEW", "1")]), existing_name="media")
    assert ac.env_text(new_var, ex) == "TZ=UTC\nNEW=1\n"


def test_inline_services_or_a_duplicate_name_is_refused_with_the_reason() -> None:
    inline = Existing("services: {}\n", "a" * 64, "", None)
    d = AddDraft("existing", KUMA, existing_name="media")
    assert "one line" in (ac.blocked_reason(d, inline, ready(d, inline), [MEDIA], [WEB], "lab", False) or "")
    assert next(x for x in ac.rows(d, inline, ready(d, inline), [WEB], "lab") if x.id == "insert").state is RowState.FAIL
    dup = Existing("services:\n  uptime-kuma:\n    image: x\n", "a" * 64, "", None)
    assert "already has a service called uptime-kuma" in (ac.blocked_reason(d, dup, ready(d, dup), [MEDIA], [WEB], "lab",
                                                                             False) or "")
    assert ac.blocked_reason(d, None, Readings(), [MEDIA], [WEB], "lab", False) == "Reading the stack from lab…"
    assert ac.blocked_reason(AddDraft("existing", KUMA), None, Readings(), [MEDIA], [WEB], "lab", False) == \
        "Choose a stack to add the container to"
    assert [s.name for s in ac.existing_candidates([MEDIA, DockerStack("solo", None, None, [], [WEB], True)])] == ["media"]
