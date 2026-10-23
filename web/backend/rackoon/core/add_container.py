"""Adding a container (`ContainerSpec`, `EnvMerge`, `ComposeInsert`, `ContainerChecks`, `NewStackPlan`,
`NewStackCommands` and the `AddContainerDraft` rules in the Kotlin core). The form becomes compose YAML and `.env`
lines; a new stack is created by `stack_create` (which refuses an existing folder and removes what it made if the
server's compose check fails), an existing stack gets new lines appended through the sha-guarded file save. The
whole draft is evaluated by one pure function from what the server reported."""

from __future__ import annotations

import base64
import enum
import re
import string
from dataclasses import dataclass, field

from . import compose_edit, editor, line_diff, shell, spec
from .docker import DockerContainer, DockerStack, is_compose_project_name, is_service_name
from .editor import CheckRow, RowState
from .policy import Intent, Risk
from .stack_files import (
    MAX_BYTES,
    CannotWrite,
    CommandFailed,
    ComposeIssue,
    FileMalformed,
    Severity,
    ValidationResult,
    editable,
    env_names,
    env_syntax,
    parse_compose_issues,
)

IMAGE_CHARACTERS = set(string.ascii_letters + string.digits + "._/:@-")
PLAIN_ENV = set(string.ascii_letters + string.digits + "_./:@,+=-")
COMPOSE_FILE_NAME = "compose.yaml"
STARTER_COMPOSE = 'services:\n  app:\n    image: nginx:alpine\n    restart: unless-stopped\n    ports:\n      - "8080:80"\n'


class RestartPolicy(enum.Enum):
    NO = "no"
    ALWAYS = "always"
    UNLESS_STOPPED = "unless-stopped"
    ON_FAILURE = "on-failure"


@dataclass(frozen=True)
class PortRow:
    host: str = ""
    container: str = ""

    @property
    def is_blank(self) -> bool:
        return not self.host and not self.container

    @property
    def bind_address(self) -> str | None:
        return self.host.rsplit(":", 1)[0] if ":" in self.host else None

    @property
    def host_port(self) -> int | None:
        tail = self.host.rsplit(":", 1)[-1]
        return int(tail) if tail.isdigit() and tail.isascii() else None


@dataclass(frozen=True)
class VolumeRow:
    source: str = ""
    target: str = ""

    @property
    def is_blank(self) -> bool:
        return not self.source and not self.target


@dataclass(frozen=True)
class EnvRow:
    key: str = ""
    value: str = ""

    @property
    def is_blank(self) -> bool:
        return not self.key and not self.value


def _scalar(s: str) -> str:
    plain = bool(s) and all(c in IMAGE_CHARACTERS for c in s)
    return s if plain else '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def port_problem(p: PortRow) -> str | None:
    if p.is_blank:
        return None
    cport = int(p.container) if p.container.isdigit() and p.container.isascii() else None
    if not (p.host_port is not None and 1 <= p.host_port <= 65535 and cport is not None and 1 <= cport <= 65535):
        return "Ports are numbers from 1 to 65535"
    address = p.bind_address
    if address is not None:
        if not (re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", address) or re.fullmatch(r"\$\{[A-Za-z_][A-Za-z0-9_]*}", address)):
            return "Use port, or address:port with an IPv4 address or ${NAME}"
    return None


def volume_problem(v: VolumeRow) -> str | None:
    if v.is_blank:
        return None
    if not (v.source.startswith("./") or v.source.startswith("/")):
        return "Use a path such as ./data or /srv/data"
    if not v.target.startswith("/"):
        return "The container path must start with /"
    if any(c in "\n\r\"'\\" for c in v.source + v.target) or ":" in v.source or ":" in v.target:
        return "Paths can't contain quotes, backslashes or colons"
    return None


def env_problem(e: EnvRow) -> str | None:
    if e.is_blank:
        return None
    ok = bool(e.key) and all(ord(c) < 128 and (c.isalnum() or c == "_") for c in e.key) and not e.key[0].isdigit()
    if not ok:
        return "Names use letters, digits and _ and can't start with a digit"
    if "\n" in e.value or "\r" in e.value:
        return "A value must be on one line"
    return None


@dataclass(frozen=True)
class ContainerSpec:
    name: str = ""
    image: str = ""
    ports: list[PortRow] = field(default_factory=list)
    volumes: list[VolumeRow] = field(default_factory=list)
    env: list[EnvRow] = field(default_factory=list)
    restart: RestartPolicy = RestartPolicy.UNLESS_STOPPED

    @property
    def active_ports(self) -> list[PortRow]:
        return [p for p in self.ports if not p.is_blank]

    @property
    def active_volumes(self) -> list[VolumeRow]:
        return [v for v in self.volumes if not v.is_blank]

    @property
    def active_env(self) -> list[EnvRow]:
        return [e for e in self.env if not e.is_blank]

    @property
    def name_problem(self) -> str | None:
        return None if not self.name or is_service_name(self.name) else "Use letters, digits, - _ and ."

    @property
    def image_problem(self) -> str | None:
        if not self.image:
            return None
        ok = len(self.image) <= 255 and all(c in IMAGE_CHARACTERS for c in self.image) and self.image[0].isalnum()
        return None if ok else "That doesn't look like an image name, such as nginx:alpine"

    @property
    def blocking_problem(self) -> str | None:
        if not self.name:
            return "Enter a container name"
        if self.name_problem:
            return self.name_problem
        if not self.image:
            return "Enter an image"
        if self.image_problem:
            return self.image_problem
        for problem in ([port_problem(p) for p in self.active_ports] + [volume_problem(v) for v in self.active_volumes]
                        + [env_problem(e) for e in self.active_env]):
            if problem:
                return problem
        keys = [e.key for e in self.active_env]
        if len(set(keys)) != len(keys):
            return "An environment name is used twice"
        return None

    def yaml_lines(self, base_indent: int = 2, step: int = 2) -> list[str]:
        def pad(level: int) -> str:
            return " " * (base_indent + step * level)
        out = [pad(0) + self.name + ":", pad(1) + "image: " + _scalar(self.image),
               pad(1) + "restart: " + ('"no"' if self.restart is RestartPolicy.NO else self.restart.value)]
        if self.active_ports:
            out += [pad(1) + "ports:"] + [pad(2) + f'- "{p.host}:{p.container}"' for p in self.active_ports]
        if self.active_volumes:
            out += [pad(1) + "volumes:"] + [pad(2) + "- " + _scalar(v.source + ":" + v.target) for v in self.active_volumes]
        if self.active_env:
            out += [pad(1) + "environment:"] + [pad(2) + f"{e.key}: ${{{e.key}}}" for e in self.active_env]
        return out

    @property
    def compose_text(self) -> str:
        return "\n".join(["services:"] + self.yaml_lines()) + "\n"

    @property
    def env_text(self) -> str:
        return "".join(env_line(e.key, e.value) + "\n" for e in self.active_env)


def env_line(key: str, value: str) -> str:
    """`KEY=value`; anything but plain characters is single-quoted (literal, no `$`), or double-quoted with a `'`."""
    if all(c in PLAIN_ENV for c in value):
        return f"{key}={value}"
    if "'" not in value:
        return f"{key}='{value}'"
    return f'{key}="' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def merge_env(existing: str, adding: list[EnvRow]) -> tuple[str, list[str]]:
    """Appends only the variables `.env` doesn't define; returns the text and the names left alone."""
    defined = set()
    for raw in existing.split("\n"):
        line = raw.strip()
        if line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:]
        if "=" in line:
            defined.add(line[:line.index("=")].strip())
    fresh = [e for e in adding if e.key not in defined]
    kept = [e.key for e in adding if e.key in defined]
    if not fresh:
        return existing, kept
    text = existing
    if text and not text.endswith("\n"):
        text += "\n"
    return text + "".join(env_line(e.key, e.value) + "\n" for e in fresh), kept


class InsertError(Exception):
    pass


def adding(spec_: ContainerSpec, text: str) -> str:
    """The service as new lines at the end of the `services:` block (following the file's indent); nothing else
    changes."""
    lines = text.split("\n")
    block = compose_edit.services_block(lines)
    if block is None:
        while lines and lines[-1] == "":
            lines.pop()
        if lines:
            lines.append("")
        return "\n".join(lines + ["services:"] + spec_.yaml_lines()) + "\n"
    if block.inline:
        raise InsertError("This file writes services on one line, so a container can't be added automatically. "
                          "Edit the file by hand.")
    step = compose_edit.child_indent(lines, block) or 2
    if spec_.name in compose_edit.service_names(lines, block, step):
        raise InsertError(f"This stack already has a service called {spec_.name}.")
    last = next((i for i in range(block.end - 1, block.start, -1) if lines[i].strip()), block.start)
    lines[last + 1:last + 1] = spec_.yaml_lines(step, step)
    return "\n".join(lines)


# --- checks on the server -----------------------------------------------------------------------------------------


class ImageStatus(enum.Enum):
    FOUND = "found"
    NOT_FOUND = "notFound"
    TIMED_OUT = "timedOut"


def image_command(image: str) -> str | None:
    if not image or ContainerSpec("x", image).image_problem is not None:
        return None
    quoted = shell.quote(image)
    return shell.fill(spec.script("image_exists"), {"image": quoted}) if quoted else None


def listening_ports_command() -> str:
    return spec.script("listening_ports")


def parse_image_status(output: str) -> ImageStatus:
    t = output.strip()
    return ImageStatus.FOUND if t == "found" else ImageStatus.TIMED_OUT if t == "timeout" else ImageStatus.NOT_FOUND


def registry_name(image: str) -> str:
    parts = image.split("/")
    first = parts[0] if parts else ""
    return first if len(parts) > 1 and ("." in first or ":" in first or first == "localhost") else "Docker Hub"


def image_row(s: ContainerSpec, status: ImageStatus | None) -> CheckRow:
    if s.image_problem or not s.image:
        return CheckRow("image", RowState.SKIPPED, "Image", s.image_problem or "Enter an image")
    where = registry_name(s.image)
    if status is None:
        return CheckRow("image", RowState.RUNNING, "Image", f"Looking for {s.image}…")
    if status is ImageStatus.FOUND:
        return CheckRow("image", RowState.PASS, "Image", f"{s.image} found on {where}")
    if status is ImageStatus.NOT_FOUND:
        return CheckRow("image", RowState.FAIL, "Image", f"{s.image} not found on {where}, or it needs a login")
    return CheckRow("image", RowState.WARN, "Image", f"The registry didn't answer in time, so {s.image} is unchecked")


def port_rows(s: ContainerSpec, listening: set[int] | None, containers: list[DockerContainer],
              server: str) -> list[CheckRow]:
    wanted = [p.host_port for p in s.active_ports if port_problem(p) is None and p.host_port is not None]
    out: list[CheckRow] = []
    seen: set[int] = set()
    for port in wanted:
        if port in seen:
            continue
        seen.add(port)
        if listening is None:
            out.append(CheckRow(f"port{port}", RowState.RUNNING, f"Port {port}", f"Checking {server}…"))
        elif wanted.count(port) > 1:
            out.append(CheckRow(f"port{port}", RowState.FAIL, f"Port {port} is used twice", "Two mappings publish it"))
        elif port in listening:
            owner = next((c for c in containers if any(p.host_port == port for p in c.ports)), None)
            by = (f"By {owner.service or owner.name}" + (f" in {owner.project}" if owner.project else "") + "."
                  if owner else f"Something on {server} is already listening on it.")
            free = next((x for x in range(port + 1, min(port + 200, 65535) + 1) if x not in listening and x not in wanted),
                        None)
            out.append(CheckRow(f"port{port}", RowState.FAIL, f"Port {port} is already in use",
                                by + (f" Try {free}." if free else "")))
        else:
            out.append(CheckRow(f"port{port}", RowState.PASS, f"Port {port}", f"Free on {server}"))
    return out


def name_row(s: ContainerSpec, stack: str | None, containers: list[DockerContainer]) -> CheckRow:
    if not s.name or s.name_problem:
        return CheckRow("name", RowState.SKIPPED, "Container name", s.name_problem or "Enter a name")
    taken = [s.name] + ([f"{stack}-{s.name}-1"] if stack else [])
    clash = next((c for c in containers if c.name in taken), None)
    if clash:
        return CheckRow("name", RowState.FAIL, "Container name", f"A container named {clash.name} already exists")
    return CheckRow("name", RowState.PASS, "Container name", f"{s.name} is free")


def compose_row(rows: list[CheckRow], server: str) -> list[CheckRow]:
    """One "YAML syntax" line when all is well; the failing rows otherwise."""
    if any(r.state is RowState.RUNNING for r in rows):
        return [CheckRow("yaml", RowState.RUNNING, "YAML syntax", f"Checking on {server}…")]
    if all(r.state in (RowState.PASS, RowState.WARN) for r in rows):
        return [CheckRow("yaml", RowState.PASS, "YAML syntax", f"Valid, and resolves cleanly on {server}")] + \
            [r for r in rows if r.state is RowState.WARN]
    return [r for r in rows if r.state in (RowState.FAIL, RowState.WARN)]


# --- a new stack --------------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class NewStackPlan:
    name: str
    parent_directory: str
    compose: str = STARTER_COMPOSE
    env: str = ""

    @property
    def name_problem(self) -> str | None:
        if not self.name:
            return "Enter a name"
        if not is_compose_project_name(self.name):
            return "Use lowercase letters, digits, - and _, starting with a letter or digit"
        return None

    @property
    def normalized_parent(self) -> str:
        p = self.parent_directory.strip(" \t")
        while len(p) > 1 and p.endswith("/"):
            p = p[:-1]
        return p

    @property
    def folder_problem(self) -> str | None:
        p = self.normalized_parent
        if not p.startswith("/"):
            return "Enter an absolute path, such as /opt/stacks"
        if ".." in p.split("/"):
            return "The path can't contain .."
        if shell.quote_path(p) is None:
            return "That path can't be used"
        return None

    @property
    def directory(self) -> str | None:
        if self.name_problem or self.folder_problem:
            return None
        return f"/{self.name}" if self.normalized_parent == "/" else f"{self.normalized_parent}/{self.name}"

    @property
    def compose_path(self) -> str | None:
        return f"{self.directory}/{COMPOSE_FILE_NAME}" if self.directory else None

    @property
    def stack(self) -> DockerStack | None:
        """The stack as the app sees it once created (no containers yet), so `up -d` runs through the same checks."""
        if self.directory is None or self.compose_path is None:
            return None
        return DockerStack(self.name, self.directory, self.compose_path, [self.compose_path], [])


def default_parent(stacks: list[DockerStack], user: str | None) -> str:
    """The most common parent of the existing stacks' folders; else ~/stacks for a non-root user, /opt/stacks."""
    counts: dict[str, int] = {}
    for st in stacks:
        if st.is_standalone or not st.working_dir or not st.working_dir.startswith("/"):
            continue
        parent = st.working_dir.rsplit("/", 1)[0] or "/"
        if parent != "/":
            counts[parent] = counts.get(parent, 0) + 1
    if counts:
        return sorted(counts.items(), key=lambda kv: (-kv[1], len(kv[0]), kv[0]))[0][0]
    return f"/home/{user}/stacks" if user and user != "root" else "/opt/stacks"


def _b64(text: str) -> str | None:
    return "''" if not text else shell.quote(base64.b64encode(text.encode()).decode())


def new_stack_check_command(plan: NewStackPlan) -> str | None:
    if plan.name_problem or len(plan.compose.encode()) > MAX_BYTES or len(plan.env.encode()) > MAX_BYTES:
        return None
    b64 = _b64(plan.compose)
    env_b64 = _b64(plan.env) if plan.env else None
    if b64 is None:
        return None
    env = shell.fill(spec.script("stack_new_check_env"), {"envb64": env_b64}) if env_b64 else ""
    return shell.fill(spec.script("stack_new_check"), {"b64": b64, "project": plan.name, "env": env})


def new_stack_create_command(plan: NewStackPlan) -> str | None:
    directory = shell.quote_path(plan.directory) if plan.directory else None
    parent = shell.quote_path(plan.normalized_parent)
    if directory is None or parent is None or len(plan.compose.encode()) > MAX_BYTES or len(plan.env.encode()) > MAX_BYTES:
        return None
    b64 = _b64(plan.compose)
    env_b64 = _b64(plan.env) if plan.env else None
    if b64 is None:
        return None
    env = shell.fill(spec.script("stack_create_env"), {"envb64": env_b64}) if env_b64 else ""
    return shell.fill(spec.script("stack_create"), {"dir": directory, "parent": parent, "b64": b64,
                                                    "project": plan.name, "env": env})


def new_stack_intent(plan: NewStackPlan) -> Intent | None:
    command = new_stack_create_command(plan)
    if command is None or plan.directory is None:
        return None
    lines = [f"Create folder {plan.directory}", f"+ {COMPOSE_FILE_NAME}"] + (["+ .env (readable only by its owner)"]
                                                                            if plan.env else [])
    return Intent(f"Create stack {plan.name}", command, Risk.MUTATE,
                  "\n".join(lines) + "\n\n" + line_diff.preview("", plan.compose))


def check_result(exit_code: int, stdout: str, stderr: str) -> ValidationResult:
    """A new stack's scratch check, as validation issues (paths shown as just compose.yaml / .env)."""
    output = f"{stdout}\n{stderr}"
    if exit_code == 7 or "##cannot-write" in stdout:
        raise CannotWrite()
    issues = [i.simplifying_scratch_paths() for i in parse_compose_issues(output)]
    if exit_code != 0 and not any(i.severity is Severity.ERROR for i in issues):
        issues.append(ComposeIssue(Severity.ERROR, None, output.strip() or f"docker compose config failed (exit {exit_code})"))
    return ValidationResult(issues)


# --- the whole draft ----------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class AddDraft:
    """What the page holds. `target` is "new" or "existing"."""

    target: str = "new"
    spec: ContainerSpec = field(default_factory=ContainerSpec)
    stack_name: str = ""
    folder: str = "/opt/stacks"
    existing_name: str | None = None
    paste: bool = False
    paste_compose: str = ""
    paste_env: str = ""


@dataclass(frozen=True)
class Existing:
    """The chosen existing stack's files as read from the server."""

    compose: str | None
    compose_sha: str | None
    env: str
    env_sha: str | None
    error: str | None = None


def pasted(d: AddDraft) -> bool:
    return d.paste and d.target == "new"


def _env_ok(s: ContainerSpec) -> bool:
    keys = [e.key for e in s.active_env]
    return all(env_problem(e) is None for e in s.active_env) and len(set(keys)) == len(keys)


def compose_text(d: AddDraft, ex: Existing | None) -> str:
    if pasted(d):
        return d.paste_compose
    s = d.spec
    if d.target == "new":
        if not s.name or s.name_problem or not s.image or s.image_problem:
            return "services:\n  # Enter a container name and an image\n"
        return s.compose_text
    original = ex.compose if ex else None
    if original is None:
        return ""
    if s.blocking_problem:
        return original
    try:
        return adding(s, original)
    except InsertError:
        return original


def env_text(d: AddDraft, ex: Existing | None) -> str:
    if pasted(d):
        return d.paste_env
    if d.target == "new":
        return d.spec.env_text if _env_ok(d.spec) else ""
    original = ex.env if ex else ""
    return merge_env(original, d.spec.active_env)[0] if _env_ok(d.spec) else original


def plan_of(d: AddDraft, ex: Existing | None = None) -> NewStackPlan:
    return NewStackPlan(d.stack_name, d.folder, compose_text(d, ex), env_text(d, ex))


def insert_problem(d: AddDraft, ex: Existing | None) -> str | None:
    if d.target != "existing" or ex is None or ex.compose is None or d.spec.blocking_problem:
        return None
    try:
        adding(d.spec, ex.compose)
        return None
    except InsertError as e:
        return str(e)


def compose_skip_reason(d: AddDraft, ex: Existing | None, server: str) -> str | None:
    if not pasted(d) and d.spec.blocking_problem:
        return d.spec.blocking_problem
    if d.target == "new":
        if pasted(d) and not d.paste_compose.strip():
            return "Paste a compose.yaml"
        p = plan_of(d, ex)
        if p.name_problem:
            return "Enter a stack name" if not d.stack_name else p.name_problem
        return p.folder_problem
    if d.existing_name is None:
        return "Choose a stack"
    if ex is not None and ex.error:
        return ex.error
    if ex is None or ex.compose is None:
        return f"Reading the stack from {server}…"
    return None


def check_key(d: AddDraft, ex: Existing | None) -> str:
    """What a server check is a verdict on; a check of anything else never counts."""
    return "\0".join([d.target, d.stack_name, d.existing_name or "", d.folder, compose_text(d, ex), env_text(d, ex)])


@dataclass(frozen=True)
class Readings:
    """What the server told us, each for what it looked at."""

    validation: ValidationResult | None = None
    validated_key: str | None = None
    check_error: str | None = None
    image_status: ImageStatus | None = None
    listening: set[int] | None = None


def rows(d: AddDraft, ex: Existing | None, r: Readings, containers: list[DockerContainer], server: str) -> list[CheckRow]:
    out: list[CheckRow] = []
    skip = compose_skip_reason(d, ex, server)
    env_issue = next(iter(env_syntax(env_text(d, ex))), None)
    if skip:
        out.append(CheckRow("yaml", RowState.SKIPPED, "YAML syntax", skip))
    elif env_issue:
        out.append(CheckRow("env", RowState.FAIL, ".env syntax", editor.describe(env_issue)))
    else:
        k = check_key(d, ex)
        out += compose_row(editor.rows(False, server, [], r.check_error, r.validation,
                                       k if r.validated_key == k else None, k), server)
    problem = insert_problem(d, ex)
    if problem:
        out.append(CheckRow("insert", RowState.FAIL, "Add to stack", problem))
    if pasted(d):
        out.append(CheckRow("services", RowState.SKIPPED, "Pasted file", "Image, port and name checks cover the form "
                            "only. The server's compose check above covers the whole file."))
    else:
        out.append(image_row(d.spec, r.image_status))
        out += port_rows(d.spec, r.listening, containers, server)
        out.append(name_row(d.spec, d.stack_name if d.target == "new" else d.existing_name, containers))
    if d.target == "existing" and ex is not None:
        _, kept = merge_env(ex.env, d.spec.active_env)
        if kept:
            out.append(CheckRow("envkept", RowState.WARN, "Already in .env", f"{', '.join(kept)} keeps its current value"))
    return out


def missing_variables(d: AddDraft, ex: Existing | None, r: Readings) -> list[str]:
    if r.validated_key != check_key(d, ex) or r.validation is None:
        return []
    defined = set(env_names(env_text(d, ex)))
    return [v for v in r.validation.unset_variables if v not in defined]


def blocked_reason(d: AddDraft, ex: Existing | None, r: Readings, stacks: list[DockerStack],
                   containers: list[DockerContainer], server: str, read_only: bool) -> str | None:
    if read_only:
        return "Read-only mode is on"
    if d.target == "new":
        if not d.stack_name:
            return "Enter a stack name"
        p = plan_of(d, ex)
        if p.name_problem:
            return p.name_problem
        if any(s.name == d.stack_name for s in stacks):
            return f"A stack named {d.stack_name} already exists"
        if p.folder_problem:
            return p.folder_problem
    else:
        if d.existing_name is None:
            return "Choose a stack to add the container to"
        if ex is not None and ex.error:
            return ex.error
        if ex is None or ex.compose is None:
            return f"Reading the stack from {server}…"
    if not pasted(d) and d.spec.blocking_problem:
        return d.spec.blocking_problem
    if pasted(d) and not d.paste_compose.strip():
        return "Paste a compose.yaml"
    problem = insert_problem(d, ex)
    if problem:
        return problem
    env_issue = next(iter(env_syntax(env_text(d, ex))), None)
    if env_issue:
        return f"Fix .env: {editor.describe(env_issue)}"
    all_rows = rows(d, ex, r, containers, server)
    failing = next((x for x in all_rows if x.state is RowState.FAIL), None)
    if failing:
        return f"{failing.title}: {failing.detail}"
    if any(x.state is RowState.RUNNING for x in all_rows) or r.validated_key != check_key(d, ex):
        return r.check_error or f"Waiting for the checks on {server}"
    return None


def existing_candidates(stacks: list[DockerStack]) -> list[DockerStack]:
    return [s for s in stacks if not s.is_standalone and editable(s) is not None]


def create_outcome_of(exit_code: int, stdout: str, stderr: str) -> str | ValidationResult:
    """`stack_create`: "created", "exists" (nothing was written), or the server's refusal (everything it made was
    removed again)."""
    if exit_code == 0:
        if "##created" not in stdout:
            raise FileMalformed("creating did not confirm")
        return "created"
    if exit_code == 3:
        return "exists"
    if exit_code == 4:
        output = f"{stdout}\n{stderr}"
        return ValidationResult([i.simplifying_scratch_paths() for i in parse_compose_issues(output)
                                 if i.severity is Severity.ERROR])
    if exit_code == 7:
        raise CannotWrite()
    raise CommandFailed(stderr.strip() or f"Creating the stack failed (exit {exit_code})")
