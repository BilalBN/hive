"""M3: Listen (what's this song?), its history, and asking for songs that
aren't at home; and Hive Admin's Recognition page and song requests."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any, Literal

from fastapi import APIRouter, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from hive.auth import AdminDep, CallerDep
from hive.library.api import SessionDep
from hive.library.scanner import new_id
from hive.library.views import iso, track_summaries
from hive.models import ListenEvent, SongRequest, Track, User
from hive.people import mail

router = APIRouter(prefix="/api/v1", tags=["listen"])

MAX_CLIP_BYTES = 3 * 1024 * 1024
MIN_CLIP_SECONDS = 3.0


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class SongRequestBody(Strict):
    source: Literal["listen", "search"]
    title: str | None = Field(None, max_length=512)
    artist: str | None = Field(None, max_length=512)
    note: str | None = Field(None, max_length=500)
    listenEventId: int | None = None  # noqa: N815


class DecisionBody(Strict):
    status: Literal["waiting", "added", "dismissed"]


def _event_body(s: Session, caller, events: list[ListenEvent]) -> list[dict[str, Any]]:
    ids = [e.track_id for e in events if e.track_id]
    tracks = {t.id: t for t in s.scalars(select(Track).where(Track.id.in_(ids)))} if ids else {}
    summaries = dict(zip(tracks, track_summaries(s, caller, list(tracks.values())), strict=True))
    requested = set(
        s.scalars(
            select(SongRequest.listen_event_id).where(
                SongRequest.listen_event_id.in_([e.id for e in events])
            )
        )
    )
    out = []
    for e in events:
        body: dict[str, Any] = {
            "id": e.id,
            "at": iso(e.at),
            "source": e.source,
            "matched": e.track_id is not None or e.title is not None,
        }
        if e.track_id and e.track_id in summaries:
            body["track"] = summaries[e.track_id]
        if e.position_ms is not None:
            body["positionMs"] = e.position_ms
        if e.title:
            body["title"] = e.title
        if e.artist:
            body["artist"] = e.artist
        if e.id in requested:
            body["requested"] = True
        out.append(body)
    return out


@router.post("/listen/match")
async def match_clip(
    request: Request, caller: CallerDep, s: SessionDep, last: bool = True
) -> dict[str, Any]:
    """[last] false: one of the checks Listen makes as it goes. Those that
    find nothing aren't kept in the history; only the final try is."""
    clip = await request.body()
    if len(clip) > MAX_CLIP_BYTES:
        raise HTTPException(413, "Send 5 to 15 seconds of sound, up to 3 MB")
    if len(clip) < 1024:
        raise HTTPException(422, "That recording is empty")
    recognition = request.app.state.recognition
    try:
        match, seconds = await run_in_threadpool(recognition.match, clip)
    except RuntimeError as e:
        raise HTTPException(503, str(e)) from e
    except ValueError as e:
        raise HTTPException(422, "Hive couldn't read that recording") from e
    if seconds < MIN_CLIP_SECONDS:
        raise HTTPException(422, "That recording is too short; listen for a few seconds")
    return _result(s, caller, match, seconds, last)


class LandmarksBody(Strict):
    """M6: what Listen heard, as landmarks made on the device."""

    hashes: list[int] = Field(max_length=40_000)
    starts: list[int] = Field(max_length=40_000)
    seconds: float = Field(ge=0, le=60)


@router.post("/listen/match-landmarks")
async def match_landmarks(
    body: LandmarksBody, request: Request, caller: CallerDep, s: SessionDep, last: bool = True
) -> dict[str, Any]:
    """Like /listen/match, but the device sends landmarks instead of sound,
    so the recording never leaves it."""
    if len(body.hashes) != len(body.starts):
        raise HTTPException(422, "Each landmark needs its start")
    if body.seconds < MIN_CLIP_SECONDS:
        raise HTTPException(422, "That recording is too short; listen for a few seconds")
    if any(h < 0 or h >= 1 << 24 for h in body.hashes) or any(t < 0 for t in body.starts):
        raise HTTPException(422, "Those aren't Hive landmarks")
    recognition = request.app.state.recognition
    match = await run_in_threadpool(recognition.match_landmarks, body.hashes, body.starts)
    return _result(s, caller, match, body.seconds, last)


def _result(s: Session, caller, match, seconds: float, last: bool) -> dict[str, Any]:
    track = s.get(Track, match.track_id) if match else None
    if track is None and not last:
        return {"matched": False, "source": "library"}
    event = ListenEvent(user_id=caller.user_id, source="library")
    if track is not None and match is not None:
        event.track_id = track.id
        event.position_ms = int((match.position_s + seconds) * 1000)
        event.confidence = match.confidence
    s.add(event)
    s.commit()
    s.refresh(event)
    body: dict[str, Any] = {"id": event.id, "matched": track is not None, "source": "library"}
    if track is not None and match is not None:
        body["track"] = track_summaries(s, caller, [track])[0]
        body["positionMs"] = min(event.position_ms or 0, track.duration_ms)
        body["confidence"] = match.confidence
    return body


@router.get("/listen/history")
def listen_history(caller: CallerDep, s: SessionDep) -> dict[str, Any]:
    events = list(
        s.scalars(
            select(ListenEvent)
            .where(ListenEvent.user_id == caller.user_id)
            .order_by(ListenEvent.at.desc(), ListenEvent.id.desc())
            .limit(50)
        )
    )
    return {"items": _event_body(s, caller, events)}


def _request_body(r: SongRequest, person: str | None = None) -> dict[str, Any]:
    body: dict[str, Any] = {
        "id": r.id,
        "at": iso(r.at),
        "source": r.source,
        "status": r.status,
    }
    for key, value in (("title", r.title), ("artist", r.artist), ("note", r.note)):
        if value:
            body[key] = value
    if r.heard_at:
        body["heardAt"] = iso(r.heard_at)
    if r.decided_at:
        body["decidedAt"] = iso(r.decided_at)
    if person:
        body["personName"] = person
    return body


@router.post("/listen/requests")
def create_song_request(
    body: SongRequestBody, request: Request, caller: CallerDep, s: SessionDep
) -> dict[str, Any]:
    title = (body.title or "").strip() or None
    note = (body.note or "").strip() or None
    heard_at = None
    if body.listenEventId is not None:
        event = s.get(ListenEvent, body.listenEventId)
        if event is None or event.user_id != caller.user_id:
            raise HTTPException(404, "No such Listen attempt")
        heard_at = event.at
    if not (title or note or heard_at):
        raise HTTPException(422, "Say which song, or ask from Listen")
    r = SongRequest(
        id=new_id(),
        user_id=caller.user_id,
        source=body.source,
        title=title,
        artist=(body.artist or "").strip() or None,
        note=note,
        heard_at=heard_at,
        listen_event_id=body.listenEventId,
    )
    s.add(r)
    s.commit()
    people = request.app.state.people
    people._notify_admins(mail.song_request_note(people.home.home_name))
    return _request_body(r)


# ------------------------------------------------------------------ admin

admin_router = APIRouter(prefix="/api/v1/admin", tags=["admin"])


@admin_router.get("/song-requests")
def admin_song_requests(who: AdminDep, s: SessionDep) -> dict[str, Any]:
    since = datetime.now(UTC) - timedelta(days=60)
    rows = s.execute(
        select(SongRequest, User.name)
        .join(User, User.id == SongRequest.user_id, isouter=True)
        .where((SongRequest.status == "waiting") | (SongRequest.at > since))
        .order_by((SongRequest.status != "waiting"), SongRequest.at.desc())
        .limit(200)
    ).all()
    return {"items": [_request_body(r, name or "Someone") for r, name in rows]}


@admin_router.patch("/song-requests/{songRequestId}")
def admin_decide_song_request(
    songRequestId: str,  # noqa: N803
    body: DecisionBody,
    request: Request,
    who: AdminDep,
    s: SessionDep,
) -> dict[str, Any]:
    r = s.get(SongRequest, songRequestId)
    if r is None:
        raise HTTPException(404, "No such song request")
    r.status = body.status
    actor = who.user.name if who.user else request.app.state.settings.admin_display_name
    r.decided_at = None if body.status == "waiting" else datetime.now(UTC)
    r.decided_by = None if body.status == "waiting" else actor
    s.commit()
    name = s.scalar(select(User.name).where(User.id == r.user_id))
    return _request_body(r, name or "Someone")


def recognition_body(request: Request, s: Session) -> dict[str, Any]:
    body = request.app.state.recognition.status()
    week = datetime.now(UTC) - timedelta(days=7)
    counts = dict(
        s.execute(
            select(
                (ListenEvent.track_id.is_not(None) | ListenEvent.title.is_not(None)),
                func.count(),
            )
            .where(ListenEvent.at > week, ListenEvent.source == "library")
            .group_by(ListenEvent.track_id.is_not(None) | ListenEvent.title.is_not(None))
        ).all()
    )
    body["matchesThisWeek"] = int(counts.get(True, 0))
    body["noMatchThisWeek"] = int(counts.get(False, 0))
    body["shazamThisWeek"] = int(
        s.scalar(
            select(func.count())
            .select_from(ListenEvent)
            .where(ListenEvent.at > week, ListenEvent.source == "shazam")
        )
        or 0
    )
    body["requestsWaiting"] = int(
        s.scalar(
            select(func.count()).select_from(SongRequest).where(SongRequest.status == "waiting")
        )
        or 0
    )
    return body


@admin_router.get("/recognition")
def admin_recognition(request: Request, who: AdminDep, s: SessionDep) -> dict[str, Any]:
    return recognition_body(request, s)


@admin_router.post("/recognition/rebuild")
def admin_rebuild_recognition(request: Request, who: AdminDep, s: SessionDep) -> dict[str, Any]:
    request.app.state.recognition.rebuild()
    return recognition_body(request, s)
