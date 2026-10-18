"""Hive Admin's library endpoints: status, rescans and the development key."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from fastapi import APIRouter, Request
from sqlalchemy import func, select

from hive.auth import CallerDep
from hive.library.api import SessionDep
from hive.library.views import album_summaries, iso
from hive.models import Album, Artist, ImportItem, Track

router = APIRouter(prefix="/api/v1/admin", tags=["admin"])


def _rel(path: str, folder: str) -> str:
    try:
        return str(Path(path).relative_to(folder))
    except ValueError:
        return Path(path).name


def _item(i: ImportItem) -> dict[str, Any]:
    body: dict[str, Any] = {
        "id": str(i.id),
        "path": _rel(i.path, i.folder),
        "status": "working" if i.status == "working" else i.status,
        "updatedAt": iso(i.updated_at),
    }
    if i.problem:
        body["problem"] = i.problem
    return body


def library_status(request: Request, s) -> dict[str, Any]:
    library = request.app.state.library
    settings = request.app.state.settings
    tracks, size, duration = s.execute(
        select(
            func.count(Track.id),
            func.coalesce(func.sum(Track.size), 0),
            func.coalesce(func.sum(Track.duration_ms), 0),
        )  # fmt: skip
    ).one()
    per_folder = dict(
        s.execute(select(Track.folder, func.count(Track.id)).group_by(Track.folder)).all()
    )
    queued = s.scalar(
        select(func.count())
        .select_from(ImportItem)
        .where(ImportItem.status.in_(("queued", "working")))
    )
    queue = s.scalars(
        select(ImportItem)
        .where(ImportItem.status.in_(("queued", "working")))
        .order_by(ImportItem.status.desc(), ImportItem.id)
        .limit(50)
    ).all()
    failed = s.scalars(
        select(ImportItem)
        .where(ImportItem.status == "failed")
        .order_by(ImportItem.updated_at.desc())
        .limit(200)
    ).all()
    recent = s.scalars(select(Album).order_by(Album.added_at.desc()).limit(10)).all()
    body: dict[str, Any] = {
        "tracks": tracks,
        "albums": s.scalar(select(func.count()).select_from(Album)),
        "artists": s.scalar(select(func.count()).select_from(Artist)),
        "sizeBytes": int(size),
        "hoursOfMusic": round(duration / 3_600_000, 1),
        "scanning": library.scanning or bool(queued),
        "queued": queued,
        "folders": [
            {"path": str(f), "exists": f.is_dir(), "trackCount": per_folder.get(str(f), 0)}
            for f in library.folders
        ],
        "uploadFolder": str(settings.uploads_path),
        "ffmpeg": library.ffmpeg is not None,
        "queue": [_item(i) for i in queue],
        "needsAttention": [_item(i) for i in failed],
        "recentlyAdded": album_summaries(s, recent),
    }
    if library.last_scan_at is not None:
        body["lastScanAt"] = iso(library.last_scan_at)
    return body


@router.get("/library/imports")
def admin_list_imports(request: Request, caller: CallerDep, s: SessionDep) -> dict[str, Any]:
    return library_status(request, s)


@router.post("/library/scan")
def admin_start_scan(request: Request, caller: CallerDep, s: SessionDep) -> dict[str, Any]:
    request.app.state.library.scan_in_background()
    return library_status(request, s)


@router.get("/development-key")
def admin_get_development_key(request: Request, caller: CallerDep) -> dict[str, str]:
    return {"key": request.app.state.dev_key}
