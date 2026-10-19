"""Compose labels (Homepage bookmarks), favicon links and Docker presentation: the Kotlin core's
ComposeLabelsTests, FaviconLinksTests and DockerPresentationTests."""

from __future__ import annotations

import pytest

from rackoon.core import compose_edit, docker_view, favicon
from rackoon.core.compose_edit import ComposeEditError, LabelChange
from rackoon.core.docker import Bookmark, DockerContainer, DockerSnapshot, DockerStack
from rackoon.core.docker_view import LinkScope, Severity

BOOKMARK = Bookmark("https://aiostreams.xrray.net/", "AIOStreams", "Media")


def set_(b: Bookmark | None, text: str, service: str = "web") -> str:
    changes = compose_edit.bookmark_changes(b) if b else compose_edit.bookmark_removal()
    return compose_edit.setting_labels(changes, service, text)


def test_adds_a_labels_block_to_a_service_with_none() -> None:
    f = '# keep me\nservices:\n  web:\n    image: nginx\n    ports:\n      - "80:80"\n  db:\n    image: pg\n'
    assert set_(BOOKMARK, f) == ('# keep me\nservices:\n  web:\n    image: nginx\n    ports:\n      - "80:80"\n    labels:\n'
                                 '      - homepage.group=Media\n      - homepage.name=AIOStreams\n'
                                 '      - homepage.href=https://aiostreams.xrray.net/\n  db:\n    image: pg\n')


def test_replaces_adds_and_keeps_other_labels_in_a_list_block() -> None:
    f = ('services:\n  web:\n    image: nginx\n    labels:\n      - traefik.enable=true\n      - homepage.href=http://old\n'
         '      - "homepage.name=Old"\n      - homepage.weight=5\n    restart: always\n')
    assert set_(BOOKMARK, f) == ('services:\n  web:\n    image: nginx\n    labels:\n      - traefik.enable=true\n'
                                 '      - homepage.href=https://aiostreams.xrray.net/\n      - homepage.name=AIOStreams\n'
                                 '      - homepage.weight=5\n      - homepage.group=Media\n    restart: always\n')


def test_map_style_labels() -> None:
    f = 'services:\n  web:\n    image: nginx\n    labels:\n      traefik.enable: "true"\n      homepage.href: http://old\n'
    assert set_(BOOKMARK, f) == ('services:\n  web:\n    image: nginx\n    labels:\n      traefik.enable: "true"\n'
                                 '      homepage.href: https://aiostreams.xrray.net/\n      homepage.group: Media\n'
                                 '      homepage.name: AIOStreams\n')


def test_removing_keeps_other_labels_or_drops_an_empty_block() -> None:
    other = ('services:\n  web:\n    image: nginx\n    labels:\n      - traefik.enable=true\n      - homepage.href=http://x\n'
             '      - homepage.name=X\n')
    assert set_(None, other) == "services:\n  web:\n    image: nginx\n    labels:\n      - traefik.enable=true\n"
    only = "services:\n  web:\n    image: nginx\n    labels:\n      - homepage.href=http://x\n    restart: always\n"
    assert set_(None, only) == "services:\n  web:\n    image: nginx\n    restart: always\n"
    none = "services:\n  web:\n    image: nginx\n"
    assert set_(None, none) == none


def test_follows_the_files_indentation_and_targets_the_right_service() -> None:
    f = "services:\n    db:\n        image: pg\n    web:\n        image: nginx\n"
    assert set_(Bookmark("http://web"), f) == ("services:\n    db:\n        image: pg\n    web:\n        image: nginx\n"
                                              "        labels:\n            - homepage.href=http://web\n")
    assert set_(Bookmark("http://db"), f, "db") == ("services:\n    db:\n        image: pg\n        labels:\n"
                                                   "            - homepage.href=http://db\n    web:\n        image: nginx\n")


@pytest.mark.parametrize("text,service,word", [
    ("services:\n  web:\n    image: x\n", "nope", "no service called nope"),
    ("services: {}\n", "web", "on one line"),
    ("volumes:\n  d: {}\n", "web", "no service called web"),
    ("services:\n  web:\n    image: x\n    labels: {a: b}\n", "web", "inline"),
    ("services:\n  web:\n    <<: *base\n    image: x\n", "web", "merge key"),
    ("services:\r\n  web:\n    image: x\r\n", "web", "mixes"),
])
def test_refuses_what_it_cannot_edit_safely(text: str, service: str, word: str) -> None:
    with pytest.raises(ComposeEditError, match=word):
        compose_edit.setting_labels(compose_edit.bookmark_changes(BOOKMARK), service, text)


def test_quoting_and_dollar_signs() -> None:
    out = set_(Bookmark("https://x.com/?a=1", "Plex: Media", description="50% off #1 $HOME"), "services:\n  web:\n    image: x\n")
    assert '- "homepage.name=Plex: Media"' in out and '- "homepage.description=50% off #1 $$HOME"' in out
    assert "- homepage.href=https://x.com/?a=1" in out


def test_list_dashes_at_the_same_indent_as_the_labels_key() -> None:
    f = "services:\n  web:\n    image: nginx\n    labels:\n    - traefik.enable=true\n    - homepage.href=http://old\n    restart: always\n"
    assert set_(Bookmark("http://new", "N"), f) == ("services:\n  web:\n    image: nginx\n    labels:\n    - traefik.enable=true\n"
                                                   "    - homepage.href=http://new\n    - homepage.name=N\n    restart: always\n")
    assert set_(None, f) == "services:\n  web:\n    image: nginx\n    labels:\n    - traefik.enable=true\n    restart: always\n"
    last = "services:\n  web:\n    image: nginx\n    labels:\n    - a=b\n  db:\n    image: pg\n"
    assert set_(Bookmark("http://x"), last) == ("services:\n  web:\n    image: nginx\n    labels:\n    - a=b\n"
                                               "    - homepage.href=http://x\n  db:\n    image: pg\n")


def test_removing_the_last_label_keeps_comments_and_blank_lines_that_follow() -> None:
    f = "services:\n  web:\n    image: nginx\n    labels:\n      - homepage.href=http://x\n\n# footer comment\nvolumes:\n  d: {}\n"
    assert set_(None, f) == "services:\n  web:\n    image: nginx\n\n# footer comment\nvolumes:\n  d: {}\n"
    at_end = "services:\n  web:\n    image: nginx\n    labels:\n      - homepage.href=http://x\n# external edit\n"
    assert set_(None, at_end) == "services:\n  web:\n    image: nginx\n# external edit\n"
    assert set_(Bookmark("http://y"), "services:\n  web:\n    image: nginx\n    labels:\n      - a=b\n# note\n") == \
        "services:\n  web:\n    image: nginx\n    labels:\n      - a=b\n      - homepage.href=http://y\n# note\n"


def test_crlf_files_keep_their_endings() -> None:
    crlf = "services:\r\n  web:\r\n    image: nginx\r\n    labels:\r\n      - traefik.enable=true\r\n    restart: always\r\n"
    assert set_(Bookmark("http://x"), crlf) == ("services:\r\n  web:\r\n    image: nginx\r\n    labels:\r\n"
                                               "      - traefik.enable=true\r\n      - homepage.href=http://x\r\n"
                                               "    restart: always\r\n")
    assert compose_edit.defines_service("web", crlf)


def test_values_yaml_would_read_as_non_strings_are_quoted() -> None:
    for v in ("0x1F", "1_000", ".inf", "-.INF", ".nan", "0o7", "0b101", "2001-12-14", "2001-12-14t21:59:43", "1:30",
              "1e3", "12", "1.5", ".5", "1.", "true", "Yes", "n", "~", "null"):
        assert compose_edit.scalar(v) == f'"{v}"', v
    for v in ("3 Body", "v1.2", "1.2.3", "nan", "Infinity", "AdGuard", "https://x.com/", "app-1"):
        assert compose_edit.scalar(v) == v, v
    f = "services:\n  web:\n    image: x\n    labels:\n      homepage.href: http://old\n"
    assert 'homepage.name: "0x1F"' in compose_edit.setting_labels([LabelChange("homepage.name", "0x1F")], "web", f)


def test_label_changes_drop_empty_fields() -> None:
    changes = compose_edit.bookmark_changes(Bookmark(" https://x.com ", "X", "", None, "  "))
    assert [c.key for c in changes] == list(compose_edit.BOOKMARK_KEYS)
    assert [c.value for c in changes] == [None, "X", None, "https://x.com", None]
    assert compose_edit.normalized_address("app.example.com") == "https://app.example.com"


# --- favicons -----------------------------------------------------------------------------------------------------

BASE = "https://app.example.com/dash/index.html"


def test_origin_is_the_cache_key() -> None:
    assert favicon.origin("https://App.Example.com/x?y=1") == "https://app.example.com"
    assert favicon.origin("https://a.com:443/") == "https://a.com"
    assert favicon.origin("http://100.125.183.84:8080/path") == "http://100.125.183.84:8080"
    assert favicon.origin("http://a.com:80") == "http://a.com"
    assert favicon.origin("ftp://a.com") is None and favicon.origin("not a url") is None
    assert favicon.default_icon("http://a.com:8080") == "http://a.com:8080/favicon.ico"


def test_ranks_apple_touch_then_png_then_svg_then_ico() -> None:
    html = """<link rel="stylesheet" href="/s.css">
    <link rel="shortcut icon" href="/favicon.ico">
    <link rel="icon" type="image/svg+xml" href="logo.svg">
    <LINK REL="icon" TYPE="image/png" sizes="32x32" HREF='/img/32.png'>
    <link rel="icon" type="image/png" sizes="16x16 48x48" href="/img/48.png">
    <link rel="apple-touch-icon" sizes="180x180" href="//cdn.example.com/touch.png">
    <link rel="mask-icon" href="/mask.svg" color="#000">"""
    assert [c.url for c in favicon.candidates(html, BASE)] == [
        "https://cdn.example.com/touch.png", "https://app.example.com/img/48.png", "https://app.example.com/img/32.png",
        "https://app.example.com/dash/logo.svg", "https://app.example.com/favicon.ico"]


def test_skips_non_http_non_icon_and_duplicates() -> None:
    html = ('<link rel="icon" href="data:image/png;base64,AAAA"><link rel="icon" href="javascript:alert(1)">'
            '<link rel="canonical" href="https://app.example.com/"><link rel="icon" href="/a.png">'
            '<link rel="icon" href="/a.png"><link rel="icon">')
    assert [c.url for c in favicon.candidates(html, BASE)] == ["https://app.example.com/a.png"]
    attrs = favicon.attributes('<link href="/i.png?a=1&amp;b=2" rel=icon type=\'image/png\' sizes=64x64>')
    assert attrs == {"href": "/i.png?a=1&b=2", "rel": "icon", "type": "image/png", "sizes": "64x64"}
    many = "".join(f'<link rel="icon" sizes="{i}x{i}" href="/{i}.png">' for i in range(1, 10))
    assert len(favicon.candidates(many, BASE, limit=3)) == 3 and favicon.candidates(many, BASE, 3)[0].size == 9


# --- presentation -------------------------------------------------------------------------------------------------


def c(name: str, state: str = "running", health: str = "none", project: str | None = "p") -> DockerContainer:
    return DockerContainer("a" * 12, name, "img", state, health, "", [], project=project)


def test_link_scope_matches_the_mac_rules() -> None:
    cases = {"http://dockge": LinkScope.LOCAL, "http://grafana.local:3000": LinkScope.LOCAL,
             "http://192.168.1.5:8080": LinkScope.LOCAL, "http://172.20.0.4": LinkScope.LOCAL,
             "http://172.40.0.4": LinkScope.PUBLIC, "https://immich.tailnet-name.ts.net": LinkScope.TAILSCALE,
             "http://100.125.183.84:9090": LinkScope.TAILSCALE, "http://100.200.1.1": LinkScope.PUBLIC,
             "https://aiometadata.example.com": LinkScope.PUBLIC, "not a url": LinkScope.PUBLIC,
             "http://203.0.113.5": LinkScope.PUBLIC}
    for href, scope in cases.items():
        assert docker_view.link_scope(href) is scope, href


def test_stack_status_summary_letter_and_image() -> None:
    def stack(*cs: DockerContainer) -> DockerStack:
        return DockerStack("p", None, None, [], list(cs))
    assert docker_view.stack_status(stack(c("a", health="unhealthy"), c("b"))) == ("1 unhealthy", Severity.DANGER)
    assert docker_view.stack_status(stack()) == ("Not started", Severity.IDLE)
    assert docker_view.stack_status(stack(c("a", state="exited"))) == ("Stopped", Severity.IDLE)
    assert docker_view.stack_status(stack(c("a"), c("b", state="exited"))) == ("1 stopped", Severity.WARNING)
    assert docker_view.stack_status(stack(c("a"), c("b"))) == ("", Severity.OK)
    snap = DockerSnapshot([c("a"), c("b", health="unhealthy"), c("c", project=None), c("d", state="exited")])
    assert docker_view.summary(snap) == "1 stack · 4 containers · 2 healthy, 1 unhealthy, 1 stopped"
    assert docker_view.summary(DockerSnapshot([c("x", project=None)])) == "1 container · 1 healthy"
    assert docker_view.letter("dockge") == "D" and docker_view.letter("") == "?"
    assert docker_view.hue("a") == 190, "djb2: 5381*33 + 97 = 177670; % 360 = 190"
    assert all(0 <= docker_view.hue(n) < 360 for n in ("a", "monitoring", "cloudflared", "ü", "x" * 400))
    from dataclasses import replace
    fmt = lambda b: f"{b} B"  # noqa: E731
    assert docker_view.usage_text(replace(c("a"), cpu_percent=5.6, memory_used_bytes=147), fmt) == "6% · 147 B"
    assert docker_view.usage_text(c("a"), fmt) == "—" and docker_view.usage_text(c("a", state="exited"), fmt) == "exited"
    assert docker_view.image_name("ghcr.io/immich-app/immich-machine-learning:release") == \
        ("ghcr.io/immich-app/immich-machine-learning", ":release")
    assert docker_view.image_name("redis") == ("redis", None)
    assert docker_view.image_name("localhost:5000/app") == ("localhost:5000/app", None)
    assert docker_view.image_name("localhost:5000/app:2") == ("localhost:5000/app", ":2")
    assert docker_view.image_name("nginx@sha256:0123456789abcdef0123") == ("nginx", "@sha256:0123456789ab")
