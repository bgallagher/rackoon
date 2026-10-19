"""Stage W7's core rules: the Swift core's AlertsTests and SearchTests, the Files commands (FileOperationCommands,
uploads and downloads, through a real /bin/sh in a temporary folder), the Commands library's readable scripts and
password variants, and the services' actions and visibility."""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

from rackoon.core import alerts, command_library, docker, docker_states, overview, remote_files as rf, search
from rackoon.core import service_actions as sa, services, spec, unraid
from rackoon.core.alerts import AlertBook, Category, Fix, Signal, Source
from rackoon.core.docker import Bookmark
from rackoon.core.models import Server, Severity
from rackoon.core.policy import Risk

T0 = 1_800_000_000.0
FIX = spec.spec_dir() / "fixtures"


def later(minutes: float) -> float:
    return T0 + minutes * 60


def disk(percent: int, mount: str = "/") -> Signal:
    return Signal(f"disk_high:{mount}", Category.DISK, Severity.CRITICAL if percent >= 95 else Severity.WARNING,
                  "Disk almost full", f"{mount} is {percent}% full.", Fix("docker"))


# --- the alert book -----------------------------------------------------------------------------------------------


def test_the_first_reading_is_a_baseline_then_new_alerts_notify() -> None:
    book = AlertBook()
    assert book.apply("a", "lab", Source.OVERVIEW, [disk(90)], T0) == [], "listed, not notified"
    second = book.apply("a", "lab", Source.OVERVIEW, [disk(90), disk(88, "/data")], later(1))
    assert [a.key for a in second] == ["disk_high:/data"] and len(book.active()) == 2
    assert book.apply("a", "lab", Source.OVERVIEW, [disk(90), disk(88, "/data")], later(2)) == []
    root = next(a for a in book.active() if a.key == "disk_high:/")
    assert root.last_seen == later(2) and root.first_seen == T0


def test_getting_worse_notifies_and_clears_the_seen_mark() -> None:
    book = AlertBook()
    book.apply("a", "lab", Source.OVERVIEW, [disk(90)], T0)
    book.acknowledge(alerts.alert_id("a", Source.OVERVIEW, "disk_high:/"))
    assert book.unseen_count() == 0
    raised = book.apply("a", "lab", Source.OVERVIEW, [disk(97)], later(1))
    assert [a.severity for a in raised] == [Severity.CRITICAL]
    assert book.unseen_count() == 1 and book.worst_unseen() is Severity.CRITICAL


def test_a_reading_only_resolves_its_own_source_and_coming_back_is_new() -> None:
    book = AlertBook()
    book.apply("a", "lab", Source.OVERVIEW, [disk(90)], T0)
    book.apply("a", "lab", Source.SERVICES, [Signal("service_failed:x", Category.SERVICES, Severity.CRITICAL, "x failed")], T0)
    book.apply("a", "lab", Source.SERVICES, [], later(5))
    assert [a.key for a in book.active()] == ["disk_high:/"]
    assert [a.key for a in book.history()] == ["service_failed:x"] and book.history()[0].resolved_at == later(5)
    book.apply("b", "nuc", Source.OVERVIEW, [], later(6))
    assert len(book.active("a")) == 1
    again = AlertBook()
    again.apply("a", "lab", Source.OVERVIEW, [], T0)
    assert len(again.apply("a", "lab", Source.OVERVIEW, [disk(90)], later(1))) == 1
    again.apply("a", "lab", Source.OVERVIEW, [], later(2))
    back = again.apply("a", "lab", Source.OVERVIEW, [disk(91)], later(3))
    assert back[0].first_seen == later(3) and len(again.history()) == 1 and len(again.active()) == 1


def test_muted_and_info_alerts_are_never_counted_or_notified() -> None:
    book = AlertBook()
    book.apply("a", "lab", Source.OVERVIEW, [], T0)
    book.apply("a", "lab", Source.OVERVIEW, [disk(90)], later(1))
    aid = alerts.alert_id("a", Source.OVERVIEW, "disk_high:/")
    book.mute(aid)
    assert book.unseen_count() == 0 and book.active() == [] and [a.id for a in book.muted_alerts()] == [aid]
    assert book.apply("a", "lab", Source.OVERVIEW, [disk(97)], later(2)) == [], "muted: not even when worse"
    book.mute(aid, False)
    assert len(book.active()) == 1
    info = AlertBook()
    info.apply("a", "lab", Source.CONTAINERS, [], T0)
    sig = Signal("docker_needs_sudo", Category.CONTAINERS, Severity.INFO, "Containers not checked")
    assert info.apply("a", "lab", Source.CONTAINERS, [sig], later(1)) == []
    assert len(info.active()) == 1 and info.unseen_count() == 0


def test_ordering_forget_history_limits_and_json() -> None:
    book = AlertBook()
    book.apply("a", "lab", Source.OVERVIEW, [disk(90, "/old")], T0)
    book.apply("a", "lab", Source.OVERVIEW, [disk(90, "/old"), disk(96)], later(1))
    assert [a.key for a in book.active()] == ["disk_high:/", "disk_high:/old"], "critical first"
    copy = AlertBook.from_json(json.loads(json.dumps(book.json())))
    assert copy.json() == book.json()
    book.acknowledge_all("a")
    assert book.unseen_count("a") == 0
    book.mute(alerts.alert_id("a", Source.OVERVIEW, "disk_high:/"))
    assert book.forget("a") and not book.alerts and not book.muted and not book.forget("a")
    long = AlertBook()
    long.apply("a", "lab", Source.OVERVIEW, [disk(90)], T0)
    long.apply("a", "lab", Source.OVERVIEW, [], later(1))
    long.apply("a", "lab", Source.OVERVIEW, [], T0 + 8 * 86400)
    assert long.history() == [], "resolved more than a week ago"
    for i in range(alerts.HISTORY_LIMIT + 20):
        long.apply("a", "lab", Source.OVERVIEW, [disk(90, f"/m{i}")], later(i * 2))
        long.apply("a", "lab", Source.OVERVIEW, [], later(i * 2 + 1))
    assert len(long.history()) == alerts.HISTORY_LIMIT


# --- the alert rules ----------------------------------------------------------------------------------------------


def test_connection_rules() -> None:
    assert alerts.connection(None, None) == []
    down = alerts.connection("ssh: connect to host 10.0.0.9 port 22: No route to host", None)
    assert [s.key for s in down] == ["not_answering"] and down[0].severity is Severity.CRITICAL
    assert alerts.connection("user@h: Permission denied (publickey).", None)[0].key == "login_refused"
    assert alerts.connection(None, "The host key changed since you trusted it.")[0].severity is Severity.CRITICAL
    assert alerts.connection(None, "Waiting for you to trust its host key.")[0].severity is Severity.INFO


def test_service_container_overview_storage_and_certificate_rules() -> None:
    snap = services.parse((FIX / "services" / "synthetic-root-failed.out.txt").read_text())
    every = alerts.services(snap, lambda s: s.visible_by_default)
    assert {s.key for s in every} == {"service_failed:system/backup-sync.service",
                                      "service_crashing:system/cloudflared.service",
                                      "service_stopped:system/beszel-agent.service"}
    assert next(s for s in every if s.key.startswith("service_failed")).fix == Fix("services", "system/backup-sync.service")
    assert len(alerts.services(snap, lambda s: s.id != "system/backup-sync.service" and s.visible_by_default)) == 2

    def states(name: str) -> docker_states.DockerStatesReading:
        return docker_states.parse((FIX / "docker_states" / f"{name}.out.txt").read_text())
    problems = alerts.containers(states("synthetic-problems"))
    assert [s.key for s in problems] == ["container_down:immich_redis", "container_down:paperless-worker",
                                         "container_down:old-thing"]
    assert [s.severity for s in problems] == [Severity.CRITICAL, Severity.WARNING, Severity.CRITICAL]
    assert problems[0].fix == Fix("docker", "immich") and problems[-1].fix == Fix("docker", "standalone/old-thing")
    assert alerts.containers(states("unraid-healthy")) == []
    assert [s.severity for s in alerts.containers(states("permission-denied"))] == [Severity.INFO]
    assert alerts.containers(states("not-installed")) == []

    o = overview.parse((FIX / "overview" / "synthetic-security-updates.out.txt").read_text())
    assert any(s.key == "security_updates" and s.category is Category.UPDATES for s in alerts.overview(o))
    nas = unraid.parse((FIX / "unraid" / "synthetic-check-running-disabled.out.txt").read_text())
    st = alerts.storage(nas)
    assert st and all(s.category is Category.STORAGE for s in st) and any(s.severity is Severity.CRITICAL for s in st)

    checks = [alerts.CertificateCheck(f"https://{h}.example.com/", f"{h}.example.com",
                                      None if d is None else T0 + d * 86400, T0)
              for h, d in (("a", -1), ("b", 3), ("c", 14), ("d", 60), ("e", None))]
    sig = alerts.certificates(checks, T0)
    assert [s.key for s in sig] == ["cert:a.example.com", "cert:b.example.com", "cert:c.example.com"]
    assert [s.severity for s in sig] == [Severity.CRITICAL, Severity.CRITICAL, Severity.WARNING]
    assert sig[2].detail == "It expires in 14 days."
    assert alerts.certificate_targets(["https://a.example.com/x", "https://A.example.com/y", "http://b.example.com",
                                       "https://a.example.com:8443/", "not a url"]) == \
        ["https://a.example.com/", "https://a.example.com:8443/"]


# --- search -------------------------------------------------------------------------------------------------------

LAB = Server("a", "homelab", "192.168.1.20", user="alice")
NAS = Server("b", "nas", "nas.local")


def everything() -> list[search.SearchItem]:
    snap = services.parse((FIX / "services" / "synthetic-root-failed.out.txt").read_text())
    states = docker_states.parse((FIX / "docker_states" / "synthetic-problems.out.txt").read_text())
    shown = [s for s in snap.services if s.visible_by_default]
    items = [search.server_item(LAB, "Online", True, "Ubuntu 24.04", ["100.64.0.10"]),
             search.server_item(NAS, "Not answering", False, None, [])]
    items += search.docker_state_items(states, LAB)
    items += search.service_items(snap, LAB, shown)
    items += search.bookmark_items([(Bookmark("https://photos.example.com", "Immich", "Media"), "immich_server")], LAB)
    items += search.command_items(command_library.all_commands())
    book = AlertBook()
    book.apply("a", "homelab", Source.SERVICES, alerts.services(snap, lambda s: s.visible_by_default), T0)
    items += search.alert_items(book.active())
    return items


def section(results: list[tuple[str, list[search.SearchItem]]], group: str) -> list[search.SearchItem]:
    return next((items for g, items in results if g == group), [])


def test_search_needs_two_letters_and_keeps_its_group_order() -> None:
    items = everything()
    assert search.run("", items) == [] and search.run("n ", items) == [] and not search.is_searchable(" a ")
    assert search.run("ng", items)
    results = search.run("backup", items)
    groups = [g for g, _ in results]
    assert groups == [g for g in search.GROUPS if g in groups]
    assert section(results, "services")[0].title == "backup-sync" and section(results, "services")[0].tone == "danger"
    assert section(results, "alerts")[0].title == "backup-sync failed"


def test_every_group_is_reachable_and_titles_rank_first() -> None:
    items = everything()
    assert search.run("homelab", items)[0][0] == "servers"
    assert search.run("100.64", items)[0][1][0].target == {"kind": "server", "server": "a", "id": "a"}, "by address"
    immich = search.run("immich", items)
    assert section(immich, "docker")[0].target == {"kind": "stack", "server": "a", "id": "immich"}
    assert section(immich, "docker")[0].title == "immich"
    assert section(immich, "bookmarks")[0].link == "https://photos.example.com"
    assert section(search.run("pi-hole", items), "services")[0].target["id"] == "system/pihole-FTL.service"
    assert section(search.run("443", items), "services")[0].title == "nginx", "found by port"
    assert section(search.run("disk usage", items), "commands")[0].target["id"] == "disk_usage"
    assert section(search.run("old-thing", items), "docker")
    assert section(search.run("homelab nginx", items), "services")[0].title == "nginx"
    assert search.run("nginx zzz", items) == []
    assert search.run("NGÍNX", items), "case and accents don't matter"


def test_hidden_services_are_not_searched_and_full_docker_readings_have_stacks() -> None:
    snap = services.parse((FIX / "services" / "synthetic-root-failed.out.txt").read_text())
    items = search.service_items(snap, LAB, [s for s in snap.services if s.visible_by_default])
    assert search.run("ssh", items) == [] and search.run("cron", items) == []
    stacks = docker.parse((FIX / "docker" / "ubuntu-24.04-compose.out.txt").read_text()).stacks
    d = search.docker_items(stacks, LAB)
    assert all(i.group == "docker" and i.server_name == "homelab" for i in d)
    assert all(any(i.target["id"] == s.id and i.title == s.name for i in d) for s in stacks)


# --- files --------------------------------------------------------------------------------------------------------


def test_paths_names_and_keep_both() -> None:
    assert rf.join("/", "etc") == "/etc" and rf.join("/opt", "x") == "/opt/x"
    assert rf.parent("/") is None and rf.parent("/opt/stacks") == "/opt" and rf.parent("/opt") == "/"
    assert rf.crumbs("/opt/stacks") == [("/", "/"), ("opt", "/opt"), ("stacks", "/opt/stacks")]
    assert not any(rf.valid_name(n) for n in ("", ".", "..", "a/b", "a\x00b"))
    assert rf.valid_name("my file (1).txt")
    assert rf.keep_both_name("report.pdf", {"report.pdf"}) == "report 2.pdf"
    assert rf.keep_both_name("report.pdf", {"report.pdf", "report 2.pdf"}) == "report 3.pdf"
    assert rf.keep_both_name("Makefile", {"Makefile"}) == "Makefile 2"
    assert rf.keep_both_name(".env", {".env"}) == ".env 2"


def test_folder_deletes_are_refused_high_up_and_for_settings_and_service_data() -> None:
    for path in ("/", "/opt", "/opt/stacks", "/srv/data", "/var/lib/docker/x", "/var/lib/mysql/db", "/var/www/site",
                 "/home/alice/.ssh", "/root/.config", "/etc/nginx/conf.d", "/home/alice"):
        assert rf.delete_problem(path) is not None, path
        assert rf.FileOperation("delete", rf.parent(path) or "/", path.rsplit("/", 1)[-1] or "x", is_folder=True).command \
            is None, path
    for path in ("/opt/stacks/old", "/srv/data/2024", "/home/alice/Downloads/x", "/var/www/site/cache"):
        assert rf.delete_problem(path) is None, path
    assert rf.FileOperation("rename", "/srv", "a", to="a").command is None, "a rename to the same name"
    assert rf.FileOperation("rename", "/srv", "a", to="../b").command is None


def sh(command: str, cwd: Path, stdin: bytes = b"") -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(["/bin/sh", "-c", command], input=stdin, capture_output=True, cwd=cwd, timeout=30,
                          env={**os.environ, "LC_ALL": "C"})


def test_the_real_commands_in_a_shell(tmp_path: Path) -> None:
    root = Path(os.path.realpath(tmp_path))
    d = str(root)
    up = rf.upload_file_command(d, "notes.txt", 5)
    assert up is not None and sh(up, root, b"hello").returncode == 0 and (root / "notes.txt").read_text() == "hello"
    short = rf.upload_file_command(d, "notes.txt", 10)
    assert short is not None
    p = sh(short, root, b"half")
    assert p.returncode == 1 and b"interrupted" in p.stderr
    assert (root / "notes.txt").read_text() == "hello", "a short upload never replaces the real file"
    assert not (root / ".notes.txt.rackoon-part").exists()
    mk = rf.FileOperation("mkdir", d, "docs").command
    assert mk is not None and sh(mk, root).returncode == 0 and (root / "docs").is_dir()
    assert sh(mk, root).returncode == 5, "never reuses a taken name"
    ren = rf.FileOperation("rename", d, "notes.txt", to="docs").command
    assert ren is not None and sh(ren, root).returncode == 5, "a rename never replaces"
    dl = rf.download_command(d, "notes.txt", False)
    assert dl is not None and sh(dl, root).stdout == b"hello"
    (root / "docs" / "a.txt").write_text("a")
    tar = rf.download_command(d, "docs", True)
    assert tar is not None and sh(tar, root).returncode == 0 and b"a.txt" in sh(tar, root).stdout
    rm = rf.FileOperation("delete", d, "notes.txt").command
    assert rm is not None and sh(rm, root).returncode == 0 and not (root / "notes.txt").exists()
    weird = "it's \"odd\" $(id).txt"
    up2 = rf.upload_file_command(d, weird, 2)
    assert up2 is not None and sh(up2, root, b"ok").returncode == 0 and (root / weird).read_text() == "ok"


# --- commands and service actions ---------------------------------------------------------------------------------


def test_readable_scripts_and_password_variants() -> None:
    by = {c.id: c for c in command_library.all_commands()}
    ports = by["listening_ports"]
    assert ports.readable_script() == "sudo ss -tulpn" and "PATH=" not in ports.readable_script()
    nonce = "0" * 32
    pw = ports.password_intent(nonce)
    assert pw is not None and f"sudo -p '##rackoon-sudo-{nonce}:' -v" in pw.command and pw != ports.intent()
    assert by["disk_usage"].password_intent(nonce) is None, "no sudo, no password variant"
    logs = by["container_logs"]
    assert logs.readable_script() == "docker logs --tail 200 <container> 2>&1"
    assert logs.readable_script(params={"container": "web-1"}) == "docker logs --tail 200 'web-1' 2>&1"
    assert logs.intent(params={"container": "web; reboot"}) is None


def service(kind: services.Kind, status: services.Status, unit: str | None = "nginx.service",
            product: str | None = None) -> services.DiscoveredService:
    return services.DiscoveredService(f"{kind.value}/{unit or 'x'}", kind, unit, "nginx", "", product, status, "", None,
                                      True, None, None, 0, [], None, False, True)


def test_service_actions_build_safe_commands() -> None:
    running = service(services.Kind.SYSTEM, services.Status.RUNNING)
    restart = sa.command(sa.ServiceAction.RESTART, running)
    assert restart is not None and restart.risk is Risk.MUTATE and restart.root
    assert restart.script.startswith("$S systemctl restart 'nginx.service'")
    assert restart.readable_script().startswith("sudo systemctl restart 'nginx.service'")
    user = sa.command(sa.ServiceAction.STOP, service(services.Kind.USER, services.Status.RUNNING))
    assert user is not None and user.script.startswith("systemctl --user stop") and not user.root
    assert sa.command(sa.ServiceAction.STATUS, service(services.Kind.PROCESS, services.Status.RUNNING, None)) is None
    assert not sa.is_unit_name("-x.service") and not sa.is_unit_name("a b.service") and not sa.is_unit_name("x")
    assert sa.is_unit_name("getty@tty1.service")
    assert sa.ServiceAction.START.applies(service(services.Kind.SYSTEM, services.Status.FAILED))
    assert not sa.ServiceAction.STOP.applies(service(services.Kind.SYSTEM, services.Status.STOPPED))
    tail = sa.command(sa.ServiceAction.STOP, service(services.Kind.SYSTEM, services.Status.RUNNING,
                                                     "tailscaled.service", "tailscale"))
    assert tail is not None and tail.warning and "Tailscale" in tail.warning
    assert (sa.follow_logs_command(running) or "").endswith("else sudo journalctl -u 'nginx.service' -f -n 100; fi")


def test_service_visibility() -> None:
    s = service(services.Kind.SYSTEM, services.Status.RUNNING)
    v = sa.ServiceVisibility()
    assert v.is_visible(s, "a") and not v.is_chosen(s, "a")
    v.set(False, s.id, "*", everywhere=True)
    assert not v.is_visible(s, "a") and not v.is_visible(s, "b")
    v.set(True, s.id, "a")
    assert v.is_visible(s, "a") and not v.is_visible(s, "b")
    v.set(False, s.id, "a", everywhere=True)
    assert v.overrides == {f"*|{s.id}": False}, "everywhere drops each server's own choice"
    v.set(True, s.id, "b")
    assert v.forget("b") and not v.forget("b")
