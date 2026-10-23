"""Deleting a stack (`StackRemoval`) and a standalone container's own actions (`StandaloneAction`), ported from the
Kotlin core. Command texts come from spec/commands.json (`compose_down`, `compose_down_folder`, `docker_pull_image`,
`docker_remove`).

The folder step of a delete is the dangerous one: never a system or home folder, every compose file must live inside
it, and the shell only runs it after `down` succeeded and while the stack's own compose file is still there."""

from __future__ import annotations

import string
from dataclasses import dataclass

from . import shell, spec
from .docker import DockerStack, _fill, is_container_id
from .policy import Intent, Risk

SYSTEM_TREES = ("/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/boot", "/dev", "/proc", "/sys", "/etc", "/run",
                "/snap", "/var/lib/docker", "/var/lib/containerd")
PROTECTED = frozenset({"/", "/home", "/root", "/opt", "/srv", "/mnt", "/media", "/tmp", "/var", "/data", "/Users",
                       "/var/lib", "/var/log", "/var/tmp", "/var/www", "/var/opt", "/var/run", "/var/cache"})
NEEDS_COMPOSE_REASON = ("Not available: this container was started with docker run, so there is no compose file to "
                        "recreate it from")


def compose_files(stack: DockerStack) -> list[str]:
    return stack.config_files or ([stack.config_file] if stack.config_file else [])


def is_normal(path: str) -> bool:
    """Absolute, no empty, `.` or `..` parts, no doubled or trailing slash."""
    if not path.startswith("/") or "//" in path or (path.endswith("/") and path != "/"):
        return False
    return not any(p in ("..", ".") for p in path.split("/"))


def unsafe_folder_reason(path: str) -> str | None:
    if not is_normal(path):
        return "That folder path is not in a normal form"
    parts = [p for p in path.split("/") if p]
    if len(parts) < 2:
        return f"{path} is too high up to delete"
    if any(path == t or path.startswith(t + "/") for t in SYSTEM_TREES) or path in PROTECTED:
        return f"{path} is a system folder"
    if len(parts) == 2 and parts[0] in ("home", "Users", "mnt", "media"):
        return f"{path} is a home folder or a mount point"
    return None


def folder_problem(stack: DockerStack) -> str | None:
    """Why the stack's folder can't be offered for deletion, or None."""
    directory = stack.working_dir
    if directory is None or not directory.startswith("/"):
        return "The stack's folder is unknown"
    reason = unsafe_folder_reason(directory)
    if reason:
        return reason
    files = compose_files(stack)
    if not files or not all(f.startswith(directory + "/") and is_normal(f) for f in files):
        return "The compose files are not all inside that folder"
    return None


@dataclass(frozen=True)
class StackRemoval:
    remove_volumes: bool = False
    delete_folder: bool = False

    @property
    def loses_data(self) -> bool:
        """Anything beyond containers and networks goes: the UI asks for the stack's name."""
        return self.remove_volumes or self.delete_folder

    def command(self, stack: DockerStack) -> str | None:
        folder = ""
        if self.delete_folder:
            if folder_problem(stack) is not None or stack.working_dir is None:
                return None
            directory = shell.quote_path(stack.working_dir)
            files = compose_files(stack)
            file = shell.quote_path(files[0]) if files else None
            if directory is None or file is None:
                return None
            folder = shell.fill(spec.script("compose_down_folder"), {"file": file, "dir": directory})
        return _fill(spec.script("compose_down"), stack, {"volumes": " -v" if self.remove_volumes else "",
                                                           "folder": folder})

    def intent(self, stack: DockerStack) -> Intent | None:
        cmd = self.command(stack)
        what = f"Delete stack {stack.name} and its folder" if self.delete_folder else f"Delete stack {stack.name}"
        return Intent(what, cmd, Risk.MUTATE) if cmd else None


_ALNUM = set(string.ascii_letters + string.digits)


def is_image_reference(image: str) -> bool:
    """Something `docker pull` can fetch again: not an image id, nothing an image reference never has."""
    if not image or len(image) > 512 or image.startswith("sha256:") or image[0] not in _ALNUM:
        return False
    if not all(c in _ALNUM or c in "._-/:@" for c in image):
        return False
    hexy = all(c in "0123456789abcdef" for c in image)
    return not (hexy and len(image) in (12, 64))


def pullable_image(stack: DockerStack) -> str | None:
    if not stack.is_standalone or len(stack.containers) != 1:
        return None
    image = stack.containers[0].image
    return image if is_image_reference(image) else None


@dataclass(frozen=True)
class StandaloneAction:
    """`pull` (a newer image; the running container keeps its own) or `remove` (`docker rm -f [-v]`)."""

    kind: str
    volumes: bool = False

    def command(self, stack: DockerStack) -> str | None:
        if not stack.is_standalone or len(stack.containers) != 1:
            return None
        if self.kind == "pull":
            image = pullable_image(stack)
            quoted = shell.quote(image) if image else None
            return shell.fill(spec.script("docker_pull_image"), {"image": quoted}) if quoted else None
        if self.kind == "remove":
            cid = stack.containers[0].id
            if not is_container_id(cid):
                return None
            return shell.fill(spec.script("docker_remove"), {"volumes": " -v" if self.volumes else "", "id": cid})
        return None

    def intent(self, stack: DockerStack) -> Intent | None:
        cmd = self.command(stack)
        if cmd is None:
            return None
        summary = (f"Pull the image of {stack.name}" if self.kind == "pull" else
                   f"Delete container {stack.name}" + (" and its anonymous volumes" if self.volumes else ""))
        return Intent(summary, cmd, Risk.MUTATE)
