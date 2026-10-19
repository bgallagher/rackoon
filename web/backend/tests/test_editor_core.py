"""The compose/.env editor's core: the Kotlin StackFilesTests (compose issues, line diff, file commands, save
outcomes) and EditorTests (.env syntax, the checklist), plus the save gating that the browser's editor shows."""

from __future__ import annotations

import base64
import random
import re

import pytest

from rackoon.core import editor, line_diff
from rackoon.core.docker import DockerContainer, DockerStack
from rackoon.core.editor import RowState
from rackoon.core.policy import Risk
from rackoon.core.stack_files import (
    MAX_BYTES,
    CannotWrite,
    ChangedOnServer,
    ComposeIssue,
    EditableFile,
    FileEdit,
    FileMalformed,
    Invalid,
    Saved,
    Severity,
    ValidationResult,
    editable,
    env_names,
    env_syntax,
    parse_compose_issues,
    read_command,
    save_intent,
    save_outcome_of,
    validate_command,
    validation_of,
    write_command,
)

SHA = "a" * 64
COMPOSE = EditableFile("/srv/media/compose.yaml")
ENV = EditableFile("/srv/media/.env", is_env=True)


def stack(files: list[str] | None = None, directory: str = "/srv/media", standalone: bool = False) -> DockerStack:
    f = files or ["/srv/media/compose.yaml"]
    c = DockerContainer("abcdef012345", "media-web-1", "nginx", "running", "none", "Up", [], project="media",
                        service="web", working_dir=directory, config_file=f[0], config_files=f)
    return DockerStack("media", directory, f[0], f, [c], standalone)


# --- compose issues -----------------------------------------------------------------------------------------------


def test_yaml_syntax_error_has_its_line() -> None:
    assert parse_compose_issues("yaml: line 5: could not find expected ':'\n") == [
        ComposeIssue(Severity.ERROR, 5, "could not find expected ':'")]


def test_indented_unmarshal_lines_and_schema_errors() -> None:
    issues = parse_compose_issues("yaml: unmarshal errors:\n  line 3: field imagee not found in type types.ServiceConfig\n"
                                  "validating /srv/a/compose.yaml: services.web Additional property foo is not allowed")
    assert [i.line for i in issues] == [None, 3, None]
    assert issues[1].message == "field imagee not found in type types.ServiceConfig"


def test_newer_compose_format_and_temp_names() -> None:
    raw = parse_compose_issues("failed to parse /srv/a/.rackoon-check.AfWne0: go-yaml load error in scanner at L4.C12: "
                               "mapping values are not allowed in this context\n")
    assert raw[0].line == 4 and raw[0].message == "mapping values are not allowed in this context"
    schema = parse_compose_issues("validating /srv/a/.rackoon-save.y1DKDz: services.web.imagee false schema\n")[0]
    assert schema.naming(COMPOSE).message == "validating compose.yaml: services.web.imagee false schema"
    bad = parse_compose_issues("failed to parse /srv/a/.rackoon-save.y1DKDz: bad\n")[0]
    assert bad.naming(EditableFile("/srv/a/.env", True)).message == "failed to parse .env: bad"


def test_warnings_are_not_errors_and_markers_are_ignored() -> None:
    issues = parse_compose_issues('time="2026-10-10T03:08:33Z" level=warning msg="/opt/stacks/m/compose.yaml: the '
                                  'attribute `version` is obsolete, it will be ignored"\n')
    assert len(issues) == 1 and issues[0].severity is Severity.WARNING and issues[0].message.endswith("ignored")
    assert ValidationResult(issues).is_valid
    assert parse_compose_issues("##invalid\n\n   \n") == []


# --- line diff ----------------------------------------------------------------------------------------------------


def test_changed_added_removed_and_same() -> None:
    assert line_diff.changed_line_numbers("a\nb\nc\n", "a\nB\nc\nd\n") == {2, 4}
    assert line_diff.change_count("a\nb\nc\n", "a\nB\nc\nd\n") == 3
    assert line_diff.change_count("a\nb", "a\nb\n") == 0, "a trailing newline is not a change"
    assert [x.kind for x in line_diff.lines("", "x\n")] == [line_diff.Kind.ADDED]


def test_preview_shows_only_changes_with_context() -> None:
    old = "".join(f"line{i}\n" for i in range(1, 21))
    new = old.replace("line10\n", "changed\n")
    p = line_diff.preview(old, new)
    assert "- line10" in p and "+ changed" in p and "  line8" in p and "line1\n" not in p
    assert line_diff.preview(old, old) == "No changes."


def test_the_diff_always_rebuilds_both_sides() -> None:
    rng = random.Random(42)
    alphabet = ["a", "b", "c", "", "  x", "y"]
    for _ in range(300):
        old = [rng.choice(alphabet) for _ in range(rng.randint(0, 12))]
        new = [rng.choice(alphabet) for _ in range(rng.randint(0, 12))]
        old_text = "\n".join(old) + "\n" if old else ""
        new_text = "\n".join(new) + "\n" if new else ""
        ls = line_diff.lines(old_text, new_text)
        assert [x.text for x in ls if x.kind is not line_diff.Kind.REMOVED] == new
        assert [x.text for x in ls if x.kind is not line_diff.Kind.ADDED] == old
        assert [x.new_number for x in ls if x.new_number] == list(range(1, len(new) + 1))
        assert [x.old_number for x in ls if x.old_number] == list(range(1, len(old) + 1))


# --- file commands ------------------------------------------------------------------------------------------------


def test_editable_files_are_compose_files_then_env() -> None:
    s = stack(["/srv/media/compose.yaml", "/srv/media/compose.override.yaml"])
    assert editable(s) == [COMPOSE, EditableFile("/srv/media/compose.override.yaml"), ENV]
    assert editable(stack(directory="/srv/media/")) == [COMPOSE, ENV]


def test_only_the_stacks_own_files_can_be_touched() -> None:
    s = stack()
    for evil in (EditableFile("/etc/passwd"), EditableFile("/etc/shadow", True),
                 EditableFile("/srv/media/../../etc/passwd"), EditableFile("/srv/media/other.env", True),
                 EditableFile("/srv/media/.env")):
        assert read_command(evil, s) is None, evil
        assert validate_command(evil, "x", s) is None
        assert write_command(evil, "x", None, s) is None
    assert read_command(COMPOSE, s) and read_command(ENV, s)


def test_validate_swaps_the_edited_file_for_the_temp_file() -> None:
    s = stack(["/srv/media/compose.yaml", "/srv/media/compose.override.yaml"])
    c = validate_command(EditableFile("/srv/media/compose.override.yaml"), "services: {}\n", s) or ""
    assert "-f '/srv/media/compose.yaml' -f \"$T\" config -q" in c and "--env-file" not in c
    env = validate_command(ENV, "A=1\n", s) or ""
    assert "--env-file \"$T\" -f '/srv/media/compose.yaml' -f '/srv/media/compose.override.yaml' config -q" in env


def test_content_travels_as_quoted_base64_and_round_trips() -> None:
    content = "services:\n  web:\n    image: \"it's $(whoami) `id`; rm -rf /\"\n"
    c = validate_command(COMPOSE, content, stack()) or ""
    assert "whoami" not in c
    m = re.search(r"echo '([A-Za-z0-9+/=]*)' \| base64", c)
    assert m and base64.b64decode(m.group(1)).decode() == content


def test_write_guards_against_changes_and_new_files() -> None:
    existing = write_command(COMPOSE, "x\n", SHA, stack()) or ""
    assert f"= '{SHA}' ] || {{ echo '##changed'; exit 3; }}" in existing
    assert 'cp -p "$F" "$F.rackoon.bak"' in existing and 'mv -f "$T" "$F"' in existing
    assert existing.index("config -q") < existing.index("mv -f")
    new = write_command(ENV, "A=1\n", None, stack()) or ""
    assert '[ ! -e "$F" ] || { echo \'##changed\'; exit 3; }' in new
    for bad in ("", "abc", "A" * 64, "a" * 63 + "'"):
        assert write_command(COMPOSE, "x", bad, stack()) is None


def test_an_empty_file_and_the_size_cap() -> None:
    assert "echo '' | base64 -d" in (validate_command(ENV, "", stack()) or "")
    assert write_command(ENV, "", SHA, stack()) is not None
    assert validate_command(COMPOSE, "a" * MAX_BYTES, stack()) is not None
    assert validate_command(COMPOSE, "a" * (MAX_BYTES + 1), stack()) is None
    tricky = stack(["/srv/{b64}/compose.yaml"], "/srv/{b64}")
    assert (read_command(EditableFile("/srv/{b64}/compose.yaml"), tricky) or "").startswith("F='/srv/{b64}/compose.yaml';")


def test_validation_never_reads_a_failure_as_valid() -> None:
    assert validation_of(COMPOSE, 1, "yaml: line 5: could not find expected ':'\n", "").errors[0].line == 5
    warn = validation_of(COMPOSE, 0, 'time="t" level=warning msg="version is obsolete"\n', "")
    assert warn.is_valid and len(warn.warnings) == 1
    missing = validation_of(COMPOSE, 127, "", "docker: command not found")
    assert not missing.is_valid and "command not found" in missing.errors[0].message
    with pytest.raises(CannotWrite):
        validation_of(COMPOSE, 7, "##cannot-write\n", "")


def edit(content: str = "services:\n  web:\n    image: nginx:1\n") -> FileEdit:
    return FileEdit(COMPOSE, "services:\n  web:\n    image: nginx\n", "b" * 64, content)


def test_the_save_intent_preview_is_the_diff_not_the_command() -> None:
    intent = save_intent(edit(), stack())
    assert intent is not None and intent.risk is Risk.MUTATE
    assert intent.preview and "+     image: nginx:1" in intent.preview and "-     image: nginx" in intent.preview
    assert save_intent(edit("a" * (MAX_BYTES + 1)), stack()) is None


def test_save_outcomes() -> None:
    new_sha = "c" * 64
    assert save_outcome_of(edit(), 0, f"##saved\n{new_sha}\n", "") == Saved(new_sha)
    assert save_outcome_of(edit(), 3, "##changed\n", "") == ChangedOnServer()
    assert save_outcome_of(edit(), 4, "##invalid\nyaml: line 3: mapping values are not allowed here\n", "") == \
        Invalid([ComposeIssue(Severity.ERROR, 3, "mapping values are not allowed here")])
    with pytest.raises(CannotWrite):
        save_outcome_of(edit(), 7, "##cannot-write\n", "")
    with pytest.raises(FileMalformed):
        save_outcome_of(edit(), 0, "", "")


# --- .env syntax and the checklist --------------------------------------------------------------------------------


def test_env_syntax() -> None:
    assert env_syntax("# c\n\nTZ=Europe/Dublin\nexport A_B=1\nA.B-C=x\nEMPTY=\n") == [] and env_syntax("") == []
    issues = env_syntax("OK=1\nLOG LEVEL=info\nnoequals\n=value\n9BAD=x\n")
    assert [i.line for i in issues] == [2, 3, 4, 5]
    assert [i.message for i in issues[:3]] == ["Variable names cannot contain spaces", "Expected NAME=value",
                                               "Missing variable name before ="]
    assert issues[3].message.startswith("Invalid variable name")
    assert env_names("# c\nA=1\nexport B=2\nnoequals\n=x\n") == ["A", "B"]


def err(message: str, line: int | None = None) -> ComposeIssue:
    return ComposeIssue(Severity.ERROR, line, message)


def checklist(is_env: bool = False, local: list[ComposeIssue] | None = None, check_error: str | None = None,
              issues: list[ComposeIssue] | None = None, validated: str | None = "t", text: str = "t") -> list[RowState]:
    return [r.state for r in editor.rows(is_env, "hetzner", local or [], check_error,
                                         ValidationResult(issues) if issues is not None else None, validated, text)]


P, F, S, W, R = RowState.PASS, RowState.FAIL, RowState.SKIPPED, RowState.WARN, RowState.RUNNING


def test_the_checklist() -> None:
    assert checklist(issues=[]) == [P, P, P]
    assert checklist(issues=[err("mapping values are not allowed here", 4)]) == [F, S, S]
    assert editor.rows(False, "h", [], None, ValidationResult([err("x", 4)]), "t", "t")[0].detail == "Line 4: x"
    assert checklist(issues=[err("validating compose.yaml: services.web.imagee false schema")]) == [P, F, S]
    assert checklist(issues=[err("error while interpolating services.web.image: required variable TAG")]) == [P, P, F]
    assert checklist(issues=[ComposeIssue(Severity.WARNING, None, "version is obsolete")]) == [P, P, P, W]
    assert checklist(issues=[], validated="old", text="new") == [R], "a result for older text is never current"
    assert checklist(check_error="Rackoon can't write") == [F]
    assert checklist(True, local=[err("Variable names cannot contain spaces", 3)]) == [F, S]
    assert checklist(True, issues=[]) == [P, P]
    assert checklist(True, issues=[err("required variable TAG is missing a value")]) == [P, F]


def test_unset_variables_once_each_in_order() -> None:
    w = [ComposeIssue(Severity.WARNING, None, f'The "{n}" variable is not set. Defaulting to a blank string.')
         for n in ("DB_PASSWORD", "UPLOAD_LOCATION", "DB_PASSWORD", "bad name")]
    assert ValidationResult(w).unset_variables == ["DB_PASSWORD", "UPLOAD_LOCATION"]


def test_save_gating_follows_the_check_of_exactly_this_text() -> None:
    v = editor.verdict
    ok = ValidationResult([])
    assert v(False, "h", "a\n", "a\n", None, None, None, False).blocked_reason == "No changes to save"
    waiting = v(False, "h", "a\n", "b\n", None, None, None, False)
    assert not waiting.can_save and waiting.blocked_reason == "Waiting for the check on h"
    stale = v(False, "h", "a\n", "c\n", ok, "b\n", None, False)
    assert not stale.can_save, "a check of older text doesn't count"
    passed = v(False, "h", "a\n", "b\n", ok, "b\n", None, False)
    assert passed.can_save and passed.blocked_reason is None and passed.changed_lines == [1] and passed.change_count == 2
    assert not v(False, "h", "a\n", "b\n", ok, "b\n", None, True).can_save, "read-only"
    failing = v(False, "h", "a\n", "b\n", ValidationResult([err("bad", 1)]), "b\n", None, False)
    assert not failing.can_save and failing.blocked_reason == "Fix the errors above first" and failing.error_lines == [1]
    env_bad = v(True, "h", "", "LOG LEVEL=1\n", None, None, None, False)
    assert env_bad.blocked_reason == "Fix the syntax error first" and env_bad.error_lines == [1]
