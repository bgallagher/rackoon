"""What the confirm sheet says about each container and stack action, and when they are unavailable (`ActionPrompts`
in the Kotlin core, mirroring `DockerModel` on the Mac), so every app asks the same question the same way. Restarts are
destructive as on the Mac (Android marks only stop and recreate): the sheet's Return key never confirms them."""

from __future__ import annotations

from dataclasses import dataclass

from .docker import ComposeAction, DockerAction, DockerContainer, DockerStack
from .stack_actions import StandaloneAction, pullable_image


@dataclass(frozen=True)
class ActionPrompt:
    title: str
    message: str
    working: str
    destructive: bool


def blocked_reason(stack: DockerStack, read_only: bool, other_action_running: bool) -> str | None:
    """Why the stack's compose actions are unavailable, or None if they can run."""
    if read_only:
        return "Read-only mode is on"
    if other_action_running:
        return "Another stack action is running"
    if ComposeAction.UP.command(stack) is None:
        return ("These containers were not started with Docker Compose" if stack.is_standalone
                else "No single compose file was found for this stack")
    return None


def standalone_blocked_reason(stack: DockerStack, read_only: bool, other_action_running: bool) -> str | None:
    """Why a standalone container's own actions (pull, restart, delete) are unavailable, or None."""
    if read_only:
        return "Read-only mode is on"
    if other_action_running:
        return "Another stack action is running"
    if StandaloneAction("remove").command(stack) is None:
        return "This container can't be addressed safely"
    return None


def pull(stack: DockerStack) -> ActionPrompt | None:
    image = pullable_image(stack)
    if image is None:
        return None
    return ActionPrompt(
        f"Pull the latest {image}?",
        f"Downloads a newer copy of the image {stack.name} runs. The container is not touched and keeps running the "
        "image it has: it was started with docker run, so it only switches when it is created again with its original "
        "settings.",
        f"Pulling {image}…", False)


def container(action: DockerAction, c: DockerContainer) -> ActionPrompt | None:
    """Stop and restart ask first; start runs straight away (it cannot break anything), so it has no prompt."""
    if action is DockerAction.START:
        return None
    if action is DockerAction.STOP:
        return ActionPrompt(f"Stop {c.name}?", f"{c.name} will stop until you start it again.", f"Stopping {c.name}…", True)
    return ActionPrompt(f"Restart {c.name}?", f"{c.name} will be restarted. Connections to it drop for a moment.",
                        f"Restarting {c.name}…", True)


def stack(action: ComposeAction, s: DockerStack) -> ActionPrompt:
    n = len(s.containers)
    plural = "" if n == 1 else "s"
    if action is ComposeAction.PULL:
        return ActionPrompt(f"Pull images for {s.name}?", "Downloads newer images for the stack. Running containers are "
                            "not touched; use Update afterwards to switch to them.", f"Pulling images for {s.name}…", False)
    if action is ComposeAction.UP:
        return ActionPrompt(f"Update {s.name}?", "Recreates only the containers whose image or settings changed, and "
                            "starts any that are stopped.", f"Updating {s.name}…", False)
    if action is ComposeAction.RESTART:
        return ActionPrompt(f"Restart all {n} container{plural} in {s.name}?", "Restarts the containers in place. They "
                            "are not recreated, so image and settings changes are not applied; use Update for that.",
                            f"Restarting {s.name}…", True)
    if action is ComposeAction.REBUILD:
        return ActionPrompt(f"Rebuild {s.name}?", "Rebuilds images from the stack's Dockerfiles (services with a build "
                            "section), then recreates the containers that changed. Services that only use pulled images "
                            "are left alone. Building can take a while.", f"Rebuilding {s.name}…", False)
    return ActionPrompt(f"Recreate all {n} container{plural} in {s.name}?", "Every container is stopped and recreated "
                        "from the compose file. Volumes are kept, but anything stored only inside a container is lost.",
                        f"Recreating {s.name}…", True)


def rebuild(service: str, s: DockerStack) -> ActionPrompt:
    return ActionPrompt(
        f"Rebuild {service}?",
        f"Rebuilds the image for {service} from its Dockerfile and recreates its container if the image changed. Other "
        f"services in {s.name} are left alone. Building can take a while. If {service} has no build section, nothing "
        "is rebuilt.",
        f"Rebuilding {service}…", False)


def can_rebuild(c: DockerContainer, s: DockerStack) -> bool:
    """Whether the Rebuild item applies to this container: it needs a compose service the stack can address."""
    return c.service is not None and ComposeAction.REBUILD.command(s, c.service) is not None
