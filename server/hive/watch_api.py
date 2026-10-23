"""M4: Hive Admin → System health and Logs."""

from __future__ import annotations

from typing import Any, Literal

from fastapi import APIRouter, Query, Request
from fastapi.responses import FileResponse, PlainTextResponse

from hive.auth import AdminDep
from hive.watch import recent, report

router = APIRouter(prefix="/api/v1/admin", tags=["admin"])


@router.get("/system")
def system_health(request: Request, who: AdminDep) -> dict[str, Any]:
    return report(request.app)


@router.get("/logs")
def server_logs(
    who: AdminDep,
    level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO",
    q: str = Query("", max_length=200),
    area: str | None = Query(None, max_length=24),
    limit: int = Query(300, ge=1, le=2000),
) -> dict[str, Any]:
    return {"items": recent.query(level, q, area, limit), "areas": recent.areas()}


@router.get("/logs/file", response_model=None)
def server_log_file(request: Request, who: AdminDep) -> FileResponse | PlainTextResponse:
    path = request.app.state.settings.log_dir / "hive.log"
    if not path.is_file():
        return PlainTextResponse("No log file yet.\n")
    return FileResponse(path, media_type="text/plain", filename="hive.log")
