"""The compose/.env editor's rules, as `EditorChecks` and the `Draft`/`StackEditor` save gating in the Kotlin core. The
browser holds the text being typed; the backend says what the checklist shows and whether Save may go ahead, from
the server's check of exactly that text (a result for older text never counts)."""

from __future__ import annotations

import enum
from dataclasses import dataclass

from . import line_diff
from .stack_files import ComposeIssue, Severity, ValidationResult, env_syntax


class RowState(enum.Enum):
    PASS = "pass"
    FAIL = "fail"
    WARN = "warn"
    SKIPPED = "skipped"
    RUNNING = "running"


@dataclass(frozen=True)
class CheckRow:
    id: str
    state: RowState
    title: str
    detail: str


def describe(issue: ComposeIssue) -> str:
    return f"Line {issue.line}: {issue.message}" if issue.line is not None else issue.message


def _is_syntax(i: ComposeIssue) -> bool:
    m = i.message.lower()
    return i.line is not None or m.startswith("yaml:") or "go-yaml" in m or "failed to parse" in m


def _is_schema(i: ComposeIssue) -> bool:
    m = i.message.lower()
    return "validating" in m or "schema" in m or "additional property" in m


def rows(is_env: bool, server_name: str, local: list[ComposeIssue], check_error: str | None,
         validation: ValidationResult | None, validated_text: str | None, text: str) -> list[CheckRow]:
    out: list[CheckRow] = []
    if is_env:
        if local:
            return [CheckRow("syntax", RowState.FAIL, ".env syntax", describe(local[0])),
                    CheckRow("config", RowState.SKIPPED, "docker compose config", "Skipped until the syntax is fixed")]
        out.append(CheckRow("syntax", RowState.PASS, ".env syntax", "Valid"))
    if check_error is not None:
        out.append(CheckRow("check", RowState.FAIL, f"Could not check on {server_name}", check_error))
        return out
    if validation is None or validated_text != text:
        out.append(CheckRow("running", RowState.RUNNING, f"Checking on {server_name}…", ""))
        return out
    errors = validation.errors
    if is_env:
        if errors:
            out.append(CheckRow("config", RowState.FAIL, "docker compose config", describe(errors[0])))
        else:
            out.append(CheckRow("config", RowState.PASS, "docker compose config", f"Resolves cleanly on {server_name}"))
    else:
        syntax = [e for e in errors if _is_syntax(e)]
        schema = [e for e in errors if not _is_syntax(e) and _is_schema(e)]
        config = [e for e in errors if not _is_syntax(e) and not _is_schema(e)]
        if syntax:
            out += [CheckRow("syntax", RowState.FAIL, "YAML syntax", describe(syntax[0])),
                    CheckRow("schema", RowState.SKIPPED, "Compose schema", "Skipped until the syntax is fixed"),
                    CheckRow("config", RowState.SKIPPED, "docker compose config", "Skipped")]
        else:
            out.append(CheckRow("syntax", RowState.PASS, "YAML syntax", "Valid"))
            if schema:
                out += [CheckRow("schema", RowState.FAIL, "Compose schema", describe(schema[0])),
                        CheckRow("config", RowState.SKIPPED, "docker compose config", "Skipped")]
            else:
                out.append(CheckRow("schema", RowState.PASS, "Compose schema", "All keys recognised"))
                out.append(CheckRow("config", RowState.FAIL, "docker compose config", describe(config[0])) if config
                           else CheckRow("config", RowState.PASS, "docker compose config",
                                         f"Resolves cleanly on {server_name}"))
    out += [CheckRow(f"warn{i}", RowState.WARN, "Warning", w.message) for i, w in enumerate(validation.warnings)]
    return out


@dataclass(frozen=True)
class DraftVerdict:
    """What the editor shows for one draft against the text the server last checked."""

    rows: list[CheckRow]
    can_save: bool
    blocked_reason: str | None
    changed_lines: list[int]
    error_lines: list[int]
    change_count: int


def verdict(is_env: bool, server_name: str, original: str, text: str, validation: ValidationResult | None,
            validated_text: str | None, check_error: str | None, read_only: bool,
            checking: bool = False) -> DraftVerdict:
    """The Kotlin `Draft` + `StackEditor.canSave/saveBlockedReason`, as one pure function."""
    local = env_syntax(text) if is_env else []
    dirty = text != original
    current = validation is not None and validated_text == text
    passed = not local and current and validation is not None and validation.is_valid
    if read_only:
        reason: str | None = "Read-only mode is on"
    elif not dirty:
        reason = "No changes to save"
    elif local:
        reason = "Fix the syntax error first"
    elif checking or not current:
        reason = check_error or f"Waiting for the check on {server_name}"
    elif validation is not None and not validation.is_valid:
        reason = "Fix the errors above first"
    else:
        reason = None
    server_errors = validation.errors if current and validation is not None else []
    error_lines = sorted({i.line for i in local + server_errors if i.severity is Severity.ERROR and i.line is not None}) \
        if dirty else []
    return DraftVerdict(
        rows=rows(is_env, server_name, local, check_error, validation, validated_text, text) if dirty else [],
        can_save=dirty and passed and not read_only, blocked_reason=reason,
        changed_lines=sorted(line_diff.changed_line_numbers(original, text)), error_lines=error_lines,
        change_count=line_diff.change_count(original, text))
