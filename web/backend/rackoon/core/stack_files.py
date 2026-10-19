"""Reading a stack's compose or `.env` file on the server: the `file_read` parser (spec/fixtures/file_read)."""

from __future__ import annotations

import base64
import binascii
import enum
import re
from dataclasses import dataclass, replace

from . import line_diff, shell, spec
from .docker import ComposeAction, DockerStack
from .policy import Intent, Risk
from .text import split_sections, to_int

# The content travels inside one remote command argument (base64), and Linux caps one argument at 128 KiB.
MAX_BYTES = 65_536


class StackFileError(Exception):
    pass


class NotText(StackFileError):
    def __init__(self) -> None:
        super().__init__("The file is not valid UTF-8 text.")


class FileMalformed(StackFileError):
    def __init__(self, detail: str) -> None:
        super().__init__(f"Unexpected output reading the file: {detail}")


@dataclass(frozen=True)
class RemoteFile:
    content: str
    sha256: str
    mode: str
    """Octal permissions as `stat` prints them, e.g. "644"."""
    owner: str
    """`owner:group`."""
    modified_at: int


@dataclass(frozen=True)
class Missing:
    pass


@dataclass(frozen=True)
class TooLarge:
    pass


RemoteFileState = RemoteFile | Missing | TooLarge


def parse_file_read(output: str) -> RemoteFileState:
    """`##missing`, `##toolarge`, or `##meta` (`mtime mode owner`), `##sha256` and `##content` (base64)."""
    sections = split_sections(output)
    if "missing" in sections:
        return Missing()
    if "toolarge" in sections:
        return TooLarge()
    meta_lines = sections.get("meta")
    meta = meta_lines[0].split(" ", 2) if meta_lines else []
    mtime = to_int(meta[0]) if len(meta) == 3 else None
    if mtime is None:
        raise FileMalformed("no ##meta")
    sha_lines = sections.get("sha256")
    sha = sha_lines[0] if sha_lines else ""
    if len(sha) != 64:
        raise FileMalformed("no ##sha256")
    # An empty file has an empty base64 line, which split_sections drops.
    content = sections.get("content")
    b64 = content[0] if content else ""
    try:
        data = base64.b64decode(b64, validate=True)
    except (binascii.Error, ValueError):
        raise FileMalformed("content is not base64") from None
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise NotText() from None
    return RemoteFile(text, sha, meta[1], meta[2], mtime)


# --- Which files a stack offers, and what checking them found -----------------------------------------------------


@dataclass(frozen=True)
class EditableFile:
    """One of the stack's compose files (in merge order), or the `.env` beside them."""

    path: str
    is_env: bool = False

    @property
    def file_name(self) -> str:
        return self.path.rsplit("/", 1)[-1]


def env_path(directory: str) -> str:
    return f"{directory}.env" if directory.endswith("/") else f"{directory}/.env"


def editable(stack: DockerStack) -> list[EditableFile] | None:
    """Every compose file in merge order, then `.env`; None without a single usable compose layout (the same rule the
    compose actions use)."""
    if stack.working_dir is None or ComposeAction.UP.command(stack) is None:
        return None
    paths = stack.config_files or ([stack.config_file] if stack.config_file else [])
    return [EditableFile(p) for p in paths] + [EditableFile(env_path(stack.working_dir), is_env=True)]


class Severity(enum.Enum):
    ERROR = "error"
    WARNING = "warning"


@dataclass(frozen=True)
class ComposeIssue:
    severity: Severity
    line: int | None
    message: str

    def naming(self, file: EditableFile) -> ComposeIssue:
        """The server checks a temp copy (`.rackoon-check.XXXX`), which compose names; show the user's file instead."""
        return replace(self, message=_TEMP_NAME.sub(lambda _: file.file_name, self.message))

    def simplifying_scratch_paths(self) -> ComposeIssue:
        """A new stack is checked in a scratch folder; show just `compose.yaml` / `.env`."""
        return replace(self, message=_SCRATCH_PATH.sub(lambda m: m.group(1), self.message))


_TEMP_NAME = re.compile(r"""[^\s:"']*\.rackoon-(check|save)\.[A-Za-z0-9]+""")
_SCRATCH_PATH = re.compile(r"""[^\s:"']*/(compose\.yaml|\.env)""")


@dataclass(frozen=True)
class ValidationResult:
    issues: list[ComposeIssue]

    @property
    def errors(self) -> list[ComposeIssue]:
        return [i for i in self.issues if i.severity is Severity.ERROR]

    @property
    def warnings(self) -> list[ComposeIssue]:
        return [i for i in self.issues if i.severity is Severity.WARNING]

    @property
    def is_valid(self) -> bool:
        return not self.errors

    @property
    def unset_variables(self) -> list[str]:
        """`${VARIABLES}` compose says are not set, in order, each once."""
        seen: list[str] = []
        for issue in self.issues:
            m = issue.message
            open_at = m.find('The "')
            close = m.find('" variable is not set')
            if open_at < 0 or close < 0 or open_at + 5 > close:
                continue
            name = m[open_at + 5:close]
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) and name not in seen:
                seen.append(name)
        return seen


_LINE_COL = re.compile(r"\bL(\d+)\.C\d+:\s*")
_LINE_WORD = re.compile(r"(^|\s)line (\d+):\s*")


def parse_compose_issues(output: str) -> list[ComposeIssue]:
    """What `docker compose config` printed, as issues: anything on a failing run is an error; `level=warning` log
    lines are warnings (they appear on success too)."""
    issues: list[ComposeIssue] = []
    for raw in output.split("\n"):
        line = raw.strip(" \t\r")
        if not line or line.startswith("##"):
            continue
        if "level=warning" in line:
            issues.append(ComposeIssue(Severity.WARNING, None, _log_message(line) or line))
            continue
        if "level=info" in line or "level=debug" in line:
            continue
        number, text = _split_line_number(line)
        issues.append(ComposeIssue(Severity.ERROR, number, text))
    return issues


def _split_line_number(line: str) -> tuple[int | None, str]:
    m = _LINE_COL.search(line)
    if m:
        rest = line[m.end():]
        return int(m.group(1)), rest or line
    m = _LINE_WORD.search(line)
    if not m:
        return None, line
    return int(m.group(2)), line[m.end():] or line


def _log_message(line: str) -> str | None:
    start = line.find('msg="')
    if start < 0:
        return None
    tail = line[start + 5:]
    end = tail.rfind('"')
    return tail[:end].replace('\\"', '"') if end >= 0 else None


def env_names(text: str) -> list[str]:
    """The variable names a .env defines (`NAME=value`, `export NAME=value`)."""
    out = []
    for raw in text.split("\n"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].strip()
        eq = line.find("=")
        if eq >= 0 and line[:eq].strip():
            out.append(line[:eq].strip())
    return out


def env_syntax(text: str) -> list[ComposeIssue]:
    """Instant local check of `.env` lines."""
    issues = []
    for index, raw in enumerate(text.split("\n")):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].strip()
        eq = line.find("=")

        def error(message: str, n: int = index) -> None:
            issues.append(ComposeIssue(Severity.ERROR, n + 1, message))

        if eq < 0:
            error("Expected NAME=value")
            continue
        name = line[:eq].strip()
        if not name:
            error("Missing variable name before =")
        elif " " in name or "\t" in name:
            error("Variable names cannot contain spaces")
        elif not all(ord(c) < 128 and (c.isalnum() or c in "_.-") for c in name) or name[0].isdigit():
            error(f'Invalid variable name "{name}"')
    return issues


# --- Commands -----------------------------------------------------------------------------------------------------


def _b64(content: str) -> str | None:
    if not content:
        return "''"  # an empty file encodes to "", which quote refuses
    return shell.quote(base64.b64encode(content.encode()).decode())


def compose_arguments(file: EditableFile, stack: DockerStack) -> str | None:
    """`-f` for every compose file, the edited one swapped for the temp file (`"$T"`), or `--env-file "$T"` for .env."""
    paths = stack.config_files or ([stack.config_file] if stack.config_file else [])
    parts: list[str] = []
    if file.is_env:
        parts += ["--env-file", '"$T"']
    for path in paths:
        if not file.is_env and file.path == path:
            parts += ["-f", '"$T"']
        else:
            q = shell.quote_path(path)
            if q is None:
                return None
            parts += ["-f", q]
    return " ".join(parts) if parts else None


def _common(file: EditableFile, content: str, stack: DockerStack) -> tuple[str, str, str] | None:
    files = editable(stack)
    if files is None or file not in files or len(content.encode()) > MAX_BYTES or stack.working_dir is None:
        return None
    directory = shell.quote_path(stack.working_dir)
    b64 = _b64(content)
    args = compose_arguments(file, stack)
    if directory is None or b64 is None or args is None:
        return None
    return directory, b64, args


def read_command(file: EditableFile, stack: DockerStack) -> str | None:
    files = editable(stack)
    path = shell.quote_path(file.path)
    if files is None or file not in files or path is None:
        return None
    return shell.fill(spec.script("file_read"), {"file": path})


def validate_command(file: EditableFile, content: str, stack: DockerStack) -> str | None:
    """Checks `content` as the new `file` with the server's own `docker compose config`, changing nothing."""
    parts = _common(file, content, stack)
    if parts is None:
        return None
    directory, b64, args = parts
    return shell.fill(spec.script("file_validate"), {"dir": directory, "b64": b64, "project": stack.name, "args": args})


def write_command(file: EditableFile, content: str, expected_sha: str | None, stack: DockerStack) -> str | None:
    """Saves `content` over `file` if it still has `expected_sha` (None: it must not exist yet)."""
    parts = _common(file, content, stack)
    path = shell.quote_path(file.path)
    if parts is None or path is None:
        return None
    if expected_sha is not None:
        if len(expected_sha) != 64 or any(c not in "0123456789abcdef" for c in expected_sha):
            return None
        expect = shell.fill(spec.script("file_write_expect_existing"), {"sha": f"'{expected_sha}'"})
    else:
        expect = spec.script("file_write_expect_none")
    directory, b64, args = parts
    return shell.fill(spec.script("file_write"), {"file": path, "dir": directory, "b64": b64, "project": stack.name,
                                                  "args": args, "expect": expect})


@dataclass(frozen=True)
class FileEdit:
    file: EditableFile
    original: str | None
    original_sha: str | None
    content: str


def save_intent(edit: FileEdit, stack: DockerStack) -> Intent | None:
    """The save, with a readable diff as its preview (the command carries the content encoded)."""
    command = write_command(edit.file, edit.content, edit.original_sha, stack)
    if command is None:
        return None
    return Intent(f"Save {edit.file.file_name} on {stack.name}", command, Risk.MUTATE,
                  line_diff.preview(edit.original or "", edit.content))


@dataclass(frozen=True)
class Saved:
    sha256: str


@dataclass(frozen=True)
class ChangedOnServer:
    pass


@dataclass(frozen=True)
class Invalid:
    issues: list[ComposeIssue]


SaveOutcome = Saved | ChangedOnServer | Invalid


class CannotWrite(StackFileError):
    def __init__(self) -> None:
        super().__init__("Rackoon can't write in the stack's folder on the server (permissions).")


class CommandFailed(StackFileError):
    pass


def validation_of(file: EditableFile, exit_code: int, stdout: str, stderr: str) -> ValidationResult:
    """The `file_validate` result. A non-zero exit with nothing parseable (docker missing) is never "valid"."""
    if exit_code == 7 or "##cannot-write" in stdout:
        raise CannotWrite()
    output = f"{stdout}\n{stderr}"
    issues = [i.naming(file) for i in parse_compose_issues(output)]
    if exit_code != 0 and not any(i.severity is Severity.ERROR for i in issues):
        detail = output.strip()
        issues.append(ComposeIssue(Severity.ERROR, None, detail or f"docker compose config failed (exit {exit_code})"))
    return ValidationResult(issues)


def save_outcome_of(edit: FileEdit, exit_code: int, stdout: str, stderr: str) -> SaveOutcome:
    output = f"{stdout}\n{stderr}"
    if exit_code == 0:
        lines = [x for x in stdout.split("\n") if x]
        if "##saved" not in lines:
            raise FileMalformed("save did not confirm")
        i = lines.index("##saved")
        if i + 1 >= len(lines) or len(lines[i + 1]) != 64:
            raise FileMalformed("save did not confirm")
        return Saved(lines[i + 1])
    if exit_code == 3:
        return ChangedOnServer()
    if exit_code == 4:
        return Invalid([i.naming(edit.file) for i in parse_compose_issues(output) if i.severity is Severity.ERROR])
    if exit_code == 7:
        raise CannotWrite()
    raise CommandFailed(stderr.strip() or f"Saving failed (exit {exit_code})")
