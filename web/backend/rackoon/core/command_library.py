"""The Commands library, read from spec/command-library.json (the only copy). `read` entries run straight away;
`mutate` entries show a dry run (`preview`) and ask first."""

from __future__ import annotations

import enum
import string
from dataclasses import dataclass, field
from functools import cache
from typing import Any

from . import shell, spec
from .policy import Intent, Risk
from .text import trim_blanks

_ALNUM = set(string.ascii_letters + string.digits)


class ParamKind(enum.Enum):
    CONTAINER = "container"
    HOSTNAME = "hostname"


@dataclass(frozen=True)
class LibraryParam:
    id: str
    label: str
    kind: ParamKind
    placeholder: str = ""

    def quoted(self, value: str) -> str | None:
        """The value shell-quoted, or None if it is not a valid value of this kind."""
        v = trim_blanks(value)
        if self.kind is ParamKind.CONTAINER:
            # A container name or id: letters, digits, `_`, `.`, `-`, starting with a letter or digit.
            if not v or len(v) > 128 or v[0] not in _ALNUM or not all(c in _ALNUM or c in "_.-" for c in v):
                return None
        else:
            if not v or len(v) > 253 or v[0] in "-." or v[-1] in "-." or ".." in v \
                    or not all(c in _ALNUM or c in "-." for c in v):
                return None
        return shell.quote(v)


@dataclass(frozen=True)
class LibraryCommand:
    id: str
    title: str
    group: str
    summary: str
    script: str
    risk: Risk = Risk.READ
    root: bool = False
    """The script uses `$S`: `sudo -n`, or nothing when the ssh user is root."""
    needs: str | None = None
    """A program the script needs; without it the script says so and exits 0."""
    preview: str | None = None
    warning: str | None = None
    params: list[LibraryParam] = field(default_factory=list)
    interactive: bool = False

    @property
    def is_mutating(self) -> bool:
        return self.risk is Risk.MUTATE

    def full_script(self, body: str | None = None, params: dict[str, str] | None = None) -> str | None:
        """The runnable script (or its preview) with its guards, or None if a parameter is missing or invalid."""
        filled: dict[str, str] = {}
        for p in self.params:
            q = p.quoted((params or {}).get(p.id, ""))
            if q is None:
                return None
            filled[p.id] = q
        # A non-root ssh command gets a PATH without the sbin directories on Debian (ufw, swapon live there).
        out = 'PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"; export PATH; '
        if self.root:
            out += """if [ "$(id -u)" -eq 0 ]; then S=; else S='sudo -n'; fi; """
        if self.needs is not None:
            out += f"command -v {self.needs} >/dev/null 2>&1 || {{ echo '{self.needs} is not installed on this server.'; exit 0; }}; "
        return out + shell.fill(body if body is not None else self.script, filled)

    def readable_script(self, body: str | None = None, params: dict[str, str] | None = None) -> str:
        """The script as a person reads it: no PATH and "not installed" guards, `$S` shown as `sudo`, each parameter
        quoted or `<label>` while it is missing or invalid. Never run this: `full_script` is what runs."""
        filled = {p.id: p.quoted((params or {}).get(p.id, "")) or f"<{p.label.lower()}>" for p in self.params}
        text = body if body is not None else self.script
        if self.root:
            text = text.replace("$S ", "sudo ")
        return shell.fill(text, filled)

    def intent(self, params: dict[str, str] | None = None, preview: str | None = None) -> Intent | None:
        script = self.full_script(params=params)
        return Intent(self.title, script, self.risk, preview) if script is not None else None

    def password_intent(self, nonce: str, params: dict[str, str] | None = None,
                        preview: str | None = None) -> Intent | None:
        """The same entry for a user whose sudo wants a password, or None for entries that don't use sudo."""
        from .sudo import with_password
        plain = self.intent(params, preview) if self.root else None
        script = with_password(plain.command, nonce) if plain else None
        return Intent(self.title + " (with sudo password)", script, self.risk, preview) if script else None


def custom_intent(text: str) -> Intent | None:
    """Anything typed by hand can't be classified, so it counts as a change and always asks."""
    t = text.strip()
    if not t or len(t) > 4000 or "\0" in t:
        return None
    return Intent("Run a custom command", t, Risk.MUTATE)


def _command(raw: dict[str, Any]) -> LibraryCommand:
    params = [LibraryParam(p["id"], p["label"], ParamKind(p["kind"]), p.get("placeholder", ""))
              for p in raw.get("params", [])]
    return LibraryCommand(
        id=raw["id"], title=raw["title"], group=raw["group"], summary=raw["summary"], script=raw["script"],
        risk=Risk.MUTATE if raw.get("risk") == "mutate" else Risk.READ, root=raw.get("root") is True,
        needs=raw.get("needs"), preview=raw.get("preview"), warning=raw.get("warning"), params=params,
        interactive=raw.get("interactive") is True)


@cache
def _loaded() -> tuple[tuple[str, ...], tuple[LibraryCommand, ...]]:
    doc = spec.load_json("command-library.json")
    return tuple(doc["groups"]), tuple(_command(c) for c in doc["commands"])


def groups() -> list[str]:
    return list(_loaded()[0])


def all_commands() -> list[LibraryCommand]:
    return list(_loaded()[1])


def commands_in(group: str) -> list[LibraryCommand]:
    return [c for c in _loaded()[1] if c.group == group]
