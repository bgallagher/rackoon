"""The Docker image carries only the parts of spec/ that web/Dockerfile copies. This rebuilds that folder from the
Dockerfile's own COPY lines and runs demo mode against it in a fresh interpreter (the spec loader caches what it
reads), so a file the app or its demo needs but the image leaves out fails here, not only in CI's image job."""

from __future__ import annotations

import os
import shlex
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
IMAGE_SPEC = "/app/spec/"


def image_spec_copies() -> list[tuple[Path, str]]:
    """(repository source, path under /app/spec/) for every COPY into the image's spec folder."""
    text = (REPO / "web" / "Dockerfile").read_text().replace("\\\n", " ")
    copies: list[tuple[Path, str]] = []
    for line in text.splitlines():
        if not line.startswith("COPY "):
            continue
        words = shlex.split(line)
        if len(words) < 3 or words[1].startswith("--") or not words[-1].startswith(IMAGE_SPEC):
            continue
        dest = words[-1][len(IMAGE_SPEC):]
        for source in words[1:-1]:
            copies.append((REPO / source, dest))
    return copies


def build_image_spec(root: Path) -> None:
    for source, dest in image_spec_copies():
        if source.is_dir():
            shutil.copytree(source, root / dest, dirs_exist_ok=True)
        elif dest == "" or dest.endswith("/"):
            (root / dest).mkdir(parents=True, exist_ok=True)
            shutil.copy(source, root / dest / source.name)
        else:
            (root / dest).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(source, root / dest)


def test_the_dockerfile_copies_into_the_image_spec_folder() -> None:
    dests = {dest for _, dest in image_spec_copies()}
    assert "" in dests and "themes.json" in dests, dests


def test_the_build_context_lets_in_everything_copied_to_the_spec_folder() -> None:
    """web/Dockerfile.dockerignore is an allow-list (`*`, then `!path`): a copied file it does not let in makes the
    image build fail with "not found"."""
    allowed = {line[1:].strip().rstrip("/") for line in (REPO / "web" / "Dockerfile.dockerignore").read_text().splitlines()
               if line.startswith("!")}
    for source, _ in image_spec_copies():
        rel = source.relative_to(REPO)
        assert any(str(p) in allowed for p in (rel, *rel.parents)), f"{rel} is copied but not let in by the dockerignore"


def test_demo_mode_works_with_only_what_the_image_copies(tmp_path: Path) -> None:
    spec = tmp_path / "spec"
    build_image_spec(spec)
    script = textwrap.dedent("""
        from pathlib import Path
        import sys
        from fastapi.testclient import TestClient
        from rackoon.app.api import create_app
        from rackoon.app.settings import Settings

        app = create_app(Settings(data_dir=Path(sys.argv[1]), demo=True), poll=False)
        with TestClient(app, base_url="https://rackoon.test") as api:
            api.headers["X-Rackoon-CSRF"] = api.get("/api/auth/state").json()["csrf"]
            lab = "/api/servers/demo-homelab"
            for path in ("/api/servers", lab, f"{lab}/security", f"{lab}/services", "/api/alerts",
                         "/api/fleet/security"):
                r = api.get(path)
                assert r.status_code < 500, (path, r.status_code, r.text[:300])
            assert api.get(f"{lab}/security").json()["status"] == "ready"
            assert api.put("/api/security/vulnerabilities", json={"serverId": "demo-homelab", "enabled": True}
                           ).status_code < 300
            v = api.post(f"{lab}/security/vulnerabilities").json()["vulnerabilities"]
            assert v["findings"], v
            r = api.post(f"{lab}/security/deeper", json={"password": "demo"})
            assert r.status_code < 500 and r.json()["deep"], r.text[:300]
        print("ok")
    """)
    env = {**os.environ, "RACKOON_SPEC": str(spec)}
    env.pop("RACKOON_THEMES", None)
    run = subprocess.run([sys.executable, "-c", script, str(tmp_path / "data")], env=env, capture_output=True,
                         text=True, timeout=120, cwd=REPO / "web" / "backend")
    assert run.returncode == 0 and run.stdout.strip().endswith("ok"), run.stdout[-2000:] + run.stderr[-4000:]
