"""M6: music videos: a link to watch one, and Hive Admin's list."""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse
from sqlalchemy import select
from sqlalchemy.orm import Session

from hive.auth import AdminDep, CallerDep, read_ticket, sign_ticket
from hive.library.api import SessionDep
from hive.library.videos import MIME
from hive.library.views import iso
from hive.models import Track, Video

router = APIRouter(prefix="/api/v1/media", tags=["media"])
admin_router = APIRouter(prefix="/api/v1/admin/library", tags=["admin"])


@router.post("/tracks/{trackId}/video")
def create_video_ticket(
    trackId: str,  # noqa: N803
    request: Request,
    caller: CallerDep,
    s: SessionDep,
) -> dict[str, Any]:
    """A signed link to the song's music video."""
    v = s.scalar(select(Video).where(Video.track_id == trackId))
    if v is None:
        raise HTTPException(404, "This song has no video")
    path = Path(v.path)
    if not path.is_file():
        raise HTTPException(404, "The video's file is missing from the music folder")
    ttl = max(6 * 3600, 3 * v.duration_ms // 1000)
    ticket, exp = sign_ticket(
        request.app.state.ticket_secret, {"vid": v.id, "u": caller.user_id}, ttl
    )
    out: dict[str, Any] = {
        "url": f"/api/v1/media/video/{ticket}",
        "expiresAt": iso(datetime.fromtimestamp(exp, UTC)),
        "mimeType": MIME.get(path.suffix.lower(), "video/mp4"),
        "sizeBytes": path.stat().st_size,
        "durationMs": v.duration_ms,
    }
    if v.width and v.height:
        out["width"], out["height"] = v.width, v.height
    return out


@router.get("/video/{ticket}")
def stream_video(ticket: str, request: Request) -> FileResponse:
    payload = read_ticket(request.app.state.ticket_secret, ticket)
    if payload is None or "vid" not in payload:
        raise HTTPException(403, "This link has expired; the app asks for a new one")
    with Session(request.app.state.db.engine) as s:
        v = s.get(Video, payload["vid"])
        if v is None:
            raise HTTPException(403, "This video is no longer in the music folders")
        path = Path(v.path)
    if not path.is_file():
        raise HTTPException(404, "The video's file is missing from the music folder")
    return FileResponse(
        path,
        media_type=MIME.get(path.suffix.lower(), "video/mp4"),
        headers={"Cache-Control": "private, max-age=3600"},
        content_disposition_type="inline",
    )


@admin_router.get("/videos")
def admin_videos(request: Request, who: AdminDep, s: SessionDep) -> dict[str, Any]:
    """Music videos in the music folders, and the song each plays with."""
    roots = [str(f) for f in request.app.state.library.folders]
    titles = dict(s.execute(select(Track.id, Track.title)).all())
    artists = dict(s.execute(select(Track.id, Track.artist_name)).all())
    items = []
    for v in s.scalars(select(Video).order_by(Video.path)):
        root = next((r for r in roots if v.path.startswith(r)), None)
        item: dict[str, Any] = {
            "id": v.id,
            "file": str(Path(v.path).relative_to(root)) if root else v.path,
            "durationMs": v.duration_ms,
        }
        if v.width and v.height:
            item["width"], item["height"] = v.width, v.height
        if v.track_id and v.track_id in titles:
            item["trackId"] = v.track_id
            item["trackTitle"] = titles[v.track_id]
            item["artistName"] = artists[v.track_id]
        items.append(item)
    return {
        "items": items,
        "matched": sum("trackId" in i for i in items),
    }
