"""Serving the built frontend (web/frontend/dist) at /, with every unknown non-API path answered by index.html so the
app's own routes work on reload. Pages carry a strict Content-Security-Policy: scripts, styles and requests only from
this origin, no framing."""

from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, Response

CSP = ("default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
       "font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; "
       "frame-ancestors 'none'")


def mount_frontend(app: FastAPI, folder: Path) -> None:
    root = folder.resolve()
    index = root / "index.html"

    @app.get("/{path:path}", include_in_schema=False)
    async def frontend(path: str) -> Response:
        if path.startswith("api/") or path == "api":
            raise HTTPException(404)
        candidate = (root / path).resolve() if path else index
        if not candidate.is_relative_to(root) or not candidate.is_file():
            candidate = index
        if not candidate.is_file():
            raise HTTPException(404)
        headers = {"Content-Security-Policy": CSP}
        if candidate.parent.name == "assets":  # Vite's hashed file names never change content
            headers["Cache-Control"] = "public, max-age=31536000, immutable"
        else:
            headers["Cache-Control"] = "no-cache"
        return FileResponse(candidate, headers=headers)
