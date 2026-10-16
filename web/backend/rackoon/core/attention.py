"""The needs-attention strip: spec/attention-rules.json as a pure function of an Overview (`Attention.evaluate` in
the Swift and Kotlin cores), plus how each item is shown (`AttentionPresentation`)."""

from __future__ import annotations

from .models import AttentionItem, Severity
from .overview import Overview

DISK_THRESHOLD_PERCENT = 85


def evaluate(o: Overview) -> list[AttentionItem]:
    items: list[AttentionItem] = []
    for disk in o.disks:
        if disk.use_percent > DISK_THRESHOLD_PERCENT:
            items.append(AttentionItem(f"disk_high:{disk.mount}",
                                       Severity.CRITICAL if disk.use_percent >= 95 else Severity.WARNING,
                                       f"{disk.mount} is {disk.use_percent}% full.", "docker"))
    for name in o.unhealthy_containers:
        items.append(AttentionItem(f"container_unhealthy:{name}", Severity.WARNING, f"{name} is unhealthy.", "docker"))
    if o.security_updates > 0:
        n = o.security_updates
        items.append(AttentionItem("security_updates", Severity.WARNING,
                                   "1 security update is available." if n == 1 else f"{n} security updates are available.",
                                   "updates"))
    if o.reboot_required:
        items.append(AttentionItem("reboot_required", Severity.WARNING, "A reboot is required to finish applying updates.",
                                   "updates"))
    return items


def is_red(item: AttentionItem) -> bool:
    """Failing things are red; an unhealthy container is red here though the shared rules call it a warning."""
    return item.severity is Severity.CRITICAL or item.id.startswith("container_unhealthy")


def short_message(item: AttentionItem) -> str:
    """`cloudflared is unhealthy`, `2 security updates`, `Reboot required`, `/ is 91% full`."""
    if item.id == "reboot_required":
        return "Reboot required"
    if item.id == "security_updates":
        return item.message.removesuffix(".").replace(" are available", "").replace(" is available", "")
    return item.message.removesuffix(".")


def sorted_items(items: list[AttentionItem]) -> list[AttentionItem]:
    """Red first, then amber; each group keeps its order."""
    return sorted(items, key=lambda i: 0 if is_red(i) else 1)
