"""The Security screen's core (rackoon.core.security), mirroring SecurityTests in RackoonCore (Swift)."""

from __future__ import annotations

from rackoon.core import security
from rackoon.core.security import Listener, Published, Scope, SecurityContext, Severity, SSHDSource

from .support import SPEC, load, out


def fixture(name: str) -> security.SecuritySnapshot:
    return security.parse(out("security", name))


def finding(findings: list[security.SecurityFinding], fid: str) -> security.SecurityFinding:
    got = next((f for f in findings if f.id == fid), None)
    assert got is not None, f"no {fid} in {[f.id for f in findings]}"
    return got


def test_command_comes_from_the_spec() -> None:
    want = next(c["script"] for c in load("commands.json")["commands"] if c["id"] == "security")
    assert security.command() == want


def test_checks_are_the_spec_catalog_and_groups_have_titles() -> None:
    doc = load("security-checks.json")
    assert [c.id for c in security.checks()] == [c["id"] for c in doc["checks"]]
    assert {g["id"]: g["title"] for g in doc["groups"]} == security.GROUP_TITLES


def test_every_finding_names_a_check_in_the_catalog() -> None:
    ids = {c.id for c in security.checks()}
    for name in ["synthetic-ubuntu-hardened", "synthetic-ubuntu-default", "synthetic-debian-exposed"]:
        for f in security.evaluate(fixture(name), SecurityContext(1, True)):
            assert f.check in ids, f"{name}: {f.check}"
            assert f.id == f.check or f.id.startswith(f.check + ":"), f.id


def test_drop_ins_come_first_where_the_include_is() -> None:
    s = fixture("synthetic-ubuntu-hardened")
    assert s.sshd.source == SSHDSource.FILES
    assert s.sshd.settings["x11forwarding"] == "no"
    assert s.sshd.origin["x11forwarding"] == "/etc/ssh/sshd_config.d/10-hardening.conf"
    assert s.sshd.settings["kbdinteractiveauthentication"] == "no"
    assert s.sshd.uncertain == []


def test_an_unreadable_drop_in_makes_later_values_uncertain() -> None:
    s = fixture("synthetic-ubuntu-default")
    assert s.sshd.unreadable == ["/etc/ssh/sshd_config.d/50-cloud-init.conf"]
    assert s.sshd.settings["permitrootlogin"] == "no"
    assert "permitrootlogin" in s.sshd.uncertain and "passwordauthentication" in s.sshd.uncertain
    findings = security.evaluate(s)
    assert finding(findings, "ssh.password_auth").severity == Severity.UNKNOWN
    assert "50-cloud-init.conf" in (finding(findings, "ssh.root_login").evidence or "")


def test_root_reads_the_effective_settings() -> None:
    s = fixture("synthetic-debian-exposed")
    assert s.is_root
    assert s.sshd.source == SSHDSource.EFFECTIVE
    assert s.sshd.settings["port"] == "2222"
    assert s.root_accounts == ["root", "toor"]


def test_listener_scopes() -> None:
    cases = {"0.0.0.0": Scope.ALL, "*": Scope.ALL, "::": Scope.ALL, "127.0.0.53": Scope.LOOPBACK,
             "::1": Scope.LOOPBACK, "100.100.40.7": Scope.TAILSCALE, "fd7a:115c:a1e0::1": Scope.TAILSCALE,
             "192.168.1.20": Scope.LAN, "172.20.0.1": Scope.LAN, "fe80::1": Scope.LAN, "203.0.113.24": Scope.PUBLIC,
             "100.63.0.1": Scope.PUBLIC}
    for address, scope in cases.items():
        assert security.scope_of(address) == scope, address
    assert security.host_port("127.0.0.53%lo:53") == ("127.0.0.53", "53")
    assert security.host_port("[::ffff:127.0.0.1]:631") == ("127.0.0.1", "631")
    assert security.host_port(":::8080") == ("::", "8080")


def test_include_globs() -> None:
    g = security.glob_matches
    assert g("/etc/ssh/sshd_config.d/*.conf", "/etc/ssh/sshd_config.d/50-cloud-init.conf")
    assert not g("/etc/ssh/sshd_config.d/*.conf", "/etc/ssh/sshd_config.d/x/y.conf")
    assert not g("/etc/ssh/sshd_config.d/*.conf", "/etc/ssh/sshd_config.d/notes.txt")
    assert g("/etc/ssh/sshd_config.d/1?-a.conf", "/etc/ssh/sshd_config.d/10-a.conf")


def test_docker_published_on_every_interface_gets_past_ufw() -> None:
    s = fixture("synthetic-ubuntu-hardened")
    s.docker.published.append(Published("web", "0.0.0.0", "8443", "tcp", Scope.ALL))
    bypass = finding(security.evaluate(s), "exposure.docker_bypass")
    assert bypass.severity == Severity.WARNING
    assert bypass.evidence == "8443/tcp (web)"


def test_counts_by_severity() -> None:
    counts = security.counts(security.evaluate(fixture("synthetic-debian-exposed")))
    assert counts[Severity.CRITICAL] == 4  # root login, a second UID 0 account, an empty password, Docker's API


def test_ipv4_and_ipv6_of_one_port_are_one_row_and_the_widest_reach_wins() -> None:
    ports = security.exposed_ports(fixture("synthetic-debian-exposed"), ufw_on=False)
    mysql = next(p for p in ports if p.port == 3306)
    assert mysql.addresses == ["0.0.0.0", "::"]
    assert mysql.containers == ["mariadb"]
    assert mysql.service == "MySQL/MariaDB"
    assert mysql.flags == ["database or cache"]
    assert len([p for p in ports if p.port == 3306]) == 1
    assert next(p for p in ports if p.port == 2375).flags == ["no TLS"]
    assert ports[0].scope == Scope.ALL
    assert ports[-1].port == 9000


def test_docker_ports_past_ufw_are_flagged_only_with_ufw_on() -> None:
    s = fixture("synthetic-ubuntu-hardened")
    s.listeners.append(Listener("tcp", "0.0.0.0", 8443, Scope.ALL))
    s.docker.published.append(Published("web", "0.0.0.0", "8443", "tcp", Scope.ALL))
    assert next(p for p in security.exposed_ports(s, True) if p.port == 8443).flags == ["past ufw"]
    assert next(p for p in security.exposed_ports(s, False) if p.port == 8443).flags == []
    tailscale_only = next(p for p in security.exposed_ports(s, True) if p.port == 8080)
    assert not tailscale_only.is_exposed
    assert tailscale_only.containers == ["paperless"]


def test_spec_dir_is_the_repository_spec() -> None:
    assert (SPEC / "security-checks.json").is_file()
