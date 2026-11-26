"""The Security page's API in demo mode (nothing is sent anywhere: the demo answers from spec fixtures and spec/osv):
findings and ports, Check Deeper with sudo (password checked, never kept; the Docker unlock reused), the opt-in
vulnerability lookup, and Security findings in Alerts that never notify."""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from rackoon.app.api import create_app
from rackoon.app.settings import Settings

NUC = "/api/servers/demo-nuc"
LAB = "/api/servers/demo-homelab"


@pytest.fixture
def demo(tmp_path: Path) -> Iterator[TestClient]:
    app = create_app(Settings(data_dir=tmp_path / "unused", demo=True), poll=False)
    with TestClient(app, base_url="https://rackoon.test") as client:
        client.headers["X-Rackoon-CSRF"] = client.get("/api/auth/state").json()["csrf"]
        yield client


def rk(api: TestClient) -> Any:
    return api.app.state.rackoon  # type: ignore[attr-defined]


def by_id(page: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {f["id"]: f for f in page["findings"]}


def test_findings_ports_and_the_disclaimer(demo: TestClient) -> None:
    page = demo.get(f"{NUC}/security").json()
    assert page["status"] == "ready" and page["isRoot"] is False and not page["deep"]
    found = by_id(page)
    assert found["ssh.password_auth"]["severity"] == "unknown", "an unreadable drop-in is never a guess"
    assert found["exposure.firewall"]["severity"] == "warning"
    assert found["exposure.firewall"]["title"] == "Firewall" and found["exposure.firewall"]["advice"]
    assert found["accounts.empty_password"]["severity"] == "unknown"
    assert any(p["port"] == 22 and p["scope"] == "all" for p in page["ports"])
    assert "not \"secure\"" in page["disclaimer"]
    assert page["vulnerabilities"]["enabled"] is False and page["vulnerabilities"]["findings"] is None


def test_check_deeper_needs_a_password_checks_it_and_keeps_nothing(demo: TestClient) -> None:
    assert demo.post(f"{LAB}/security/deeper", json={}).json()["error"] == "needsPassword"
    assert demo.post(f"{LAB}/security/deeper", json={"password": "wrong"}).json()["error"] == "badPassword"
    page = demo.post(f"{LAB}/security/deeper", json={"password": "demo"}).json()
    assert page["deep"] and page["isRoot"]
    assert by_id(page)["accounts.empty_password"]["severity"] == "pass"
    # A plain read on opening the page again does not replace the deeper one; Check Now does.
    assert demo.get(f"{LAB}/security").json()["deep"]
    assert not demo.get(f"{LAB}/security", params={"refresh": True}).json()["deep"]
    assert rk(demo).elevation.until("demo-homelab") is None, "the password was not kept as an unlock"


def test_check_deeper_reuses_the_docker_unlock(demo: TestClient) -> None:
    assert demo.post(f"{LAB}/docker/unlock", json={"password": "demo"}).status_code == 200
    assert demo.post(f"{LAB}/security/deeper", json={}).json()["deep"]


def test_vulnerability_lookup_is_opt_in_and_reports_from_osv(demo: TestClient) -> None:
    assert demo.post(f"{LAB}/security/vulnerabilities").json()["error"] == "lookupOff"
    assert demo.put("/api/security/vulnerabilities", json={"serverId": "demo-homelab", "enabled": True}).json()[
        "servers"] == ["demo-homelab"]
    page = demo.post(f"{LAB}/security/vulnerabilities").json()
    v = page["vulnerabilities"]
    assert v["enabled"] and v["thisServer"] and not v["all"] and v["error"] is None
    ids = {f["id"]: f for f in v["findings"]}
    assert ids["UBUNTU-CVE-2099-0003"]["status"] == "no_fix"
    assert "UBUNTU-CVE-2099-0004" not in ids, "a record for another release is dropped"
    assert "Google" in v["privacyNote"]
    demo.put("/api/security/vulnerabilities", json={"serverId": "demo-homelab", "enabled": False})
    assert demo.get(f"{LAB}/security").json()["vulnerabilities"]["findings"] is None, "turning it off forgets it"
    demo.put("/api/security/vulnerabilities", json={"enabled": True})
    assert demo.get(f"{NUC}/security").json()["vulnerabilities"]["enabled"], "on for every server"


def test_security_findings_reach_alerts_but_never_notify(demo: TestClient) -> None:
    import asyncio

    r = rk(demo)
    server = next(s for s in r.store.load_servers() if s.id == "demo-nuc")
    asyncio.run(r.monitor.refresh(server.id))
    demo.get(f"{NUC}/security")
    sent: list[Any] = []

    async def capture(raised: list[Any]) -> None:
        sent.extend(raised)

    r.alerts.notifier.send = capture
    asyncio.run(r.alerts.record_security(server))
    asyncio.run(r.alerts.record_security(server))
    active = demo.get("/api/alerts", params={"server": "demo-nuc"}).json()["active"]
    security = [a for a in active if a["category"] == "security"]
    assert any(a["key"] == "exposure.firewall" and a["severity"] == "warning" for a in security)
    assert all(a["fix"]["screen"] == "security" for a in security)
    assert sent == [], "Security findings never notify"


def test_the_dashboard_lists_every_answering_server(demo: TestClient) -> None:
    import asyncio

    r = rk(demo)
    for s in r.store.load_servers():
        asyncio.run(r.monitor.refresh(s.id))
    fleet = demo.get("/api/fleet/security").json()
    names = {row["server"]["name"]: row for row in fleet["servers"]}
    assert "garage-nuc" in names and "homelab" in names
    assert "backup-box" not in names, "a server that refuses the login is not read"
    assert any(f["id"] == "exposure.firewall" for f in names["garage-nuc"]["toFix"])
    assert fleet["total"] >= len(fleet["servers"])
