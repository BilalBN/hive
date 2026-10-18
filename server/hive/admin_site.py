"""Serves the built Hive Admin panel (admin/dist) at /admin."""

from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse

NOT_BUILT = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>Hive Admin</title><style>body{font:16px/1.5 system-ui,sans-serif;background:#121110;
color:#F5F1EB;display:grid;place-items:center;height:100vh;margin:0}code{color:#F2994A}</style>
</head><body><main><h1>Hive Admin isn't built yet</h1>
<p>Run <code>npm install</code> and <code>npm run build</code> in the <code>admin</code>
folder, then reload.</p></main></body></html>"""


def mount_admin(app: FastAPI, dist: Path) -> None:
    dist = dist.resolve()

    @app.get("/", include_in_schema=False)
    async def root() -> RedirectResponse:
        return RedirectResponse("/admin/")

    @app.get("/admin", include_in_schema=False)
    async def admin_no_slash() -> RedirectResponse:
        return RedirectResponse("/admin/")

    @app.get("/admin/{path:path}", include_in_schema=False)
    async def admin(path: str):
        index = dist / "index.html"
        if not index.is_file():
            return HTMLResponse(NOT_BUILT, status_code=503)
        if path:
            candidate = (dist / path).resolve()
            # Never serve anything outside the build folder.
            if not candidate.is_relative_to(dist):
                raise HTTPException(status_code=404)
            if candidate.is_file():
                return FileResponse(candidate)
            # A missing file with an extension is a real 404 (e.g. a stale asset).
            if "." in Path(path).name:
                raise HTTPException(status_code=404)
        # Client-side routes (e.g. /admin/devices) all load the app.
        return FileResponse(index, headers={"Cache-Control": "no-cache"})
