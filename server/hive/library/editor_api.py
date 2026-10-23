"""M4: Hive Admin's song tag editor, and the same song in two files.

Corrections are Hive's own: the music files are never changed. The same
song found twice (an MP3 and a FLAC on different albums, say) can be
resolved by keeping the better copy: likes, plays and playlist entries move
to it, and the other copy's file is deleted. Or both are kept."""

from __future__ import annotations

import json
import logging
import re
from collections import defaultdict
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import delete, func, select, update
from sqlalchemy.orm import Session

from hive.auth import AdminDep
from hive.library import catalog as C
from hive.library import text as T
from hive.library.api import SessionDep
from hive.library.scanner import apply_track_overrides, track_overrides
from hive.models import (
    Album,
    AuditEntry,
    Like,
    ListenEvent,
    PlayCount,
    PlaylistItem,
    Track,
)

log = logging.getLogger("hive.library")
router = APIRouter(prefix="/api/v1/admin/library", tags=["admin"])


class TrackEdit(BaseModel):
    """Set a field to change it; null puts back what the file says."""

    model_config = ConfigDict(extra="forbid")
    title: str | None = Field(None, min_length=1, max_length=512)
    artistName: str | None = Field(None, min_length=1, max_length=512)  # noqa: N815
    trackNumber: int | None = Field(None, ge=1, le=999)  # noqa: N815
    discNumber: int | None = Field(None, ge=1, le=99)  # noqa: N815
    composer: str | None = Field(None, max_length=512)
    lyricist: str | None = Field(None, max_length=512)


def _audit(
    s: Session, request: Request, who, action: str, text: str, target: str | None = None
) -> None:
    actor = who.user.name if who.user else request.app.state.settings.admin_display_name
    s.add(
        AuditEntry(
            actor=actor,
            actor_id=who.user.id if who.user else None,
            action=action,
            text=text.format(actor=actor),
            target_id=target,
        )
    )


@router.patch("/tracks/{trackId}")
def admin_update_track(
    trackId: str,  # noqa: N803
    body: TrackEdit,
    request: Request,
    who: AdminDep,
    s: SessionDep,
) -> dict[str, Any]:
    from hive.library.admin_api import _admin_album

    track = s.get(Track, trackId)
    if track is None:
        raise HTTPException(404, "No such song")
    edits = track_overrides(track)
    given = body.model_dump(exclude_unset=True)
    back_to_file = False
    for field, value in given.items():
        if isinstance(value, str):
            value = value.strip() or None
        if value is None:
            back_to_file |= field in edits
            edits.pop(field, None)
        else:
            edits[field] = value
    track.overrides = json.dumps(edits)
    apply_track_overrides(s, track)
    if "title" in given and "title" not in edits:
        track.title = track.title_override or track.file_title or track.title
    album = s.get(Album, track.album_id)
    C.refresh_search(s, album)
    _audit(s, request, who, "track.edit", "{actor} corrected the details of a song.", track.id)
    s.commit()
    if back_to_file:
        # Read the file again for the details put back.
        request.app.state.library.enqueue(Path(track.path), force=True)
    return _admin_album(request, s, who, album)


# ------------------------------------------------------------------ same song twice


def _quality(t: Track) -> tuple:
    """Better first: lossless, then more bits, a higher rate, a higher bitrate."""
    return (bool(t.lossless), t.bit_depth or 0, t.sample_rate or 0, t.bitrate_kbps or 0, t.size)


def _label(t: Track) -> str:
    if t.lossless:
        bits = f"{t.bit_depth}-bit " if t.bit_depth else ""
        return f"{t.codec.upper()} {bits}{(t.sample_rate or 0) / 1000:g} kHz"
    return f"{t.codec.upper()} {t.bitrate_kbps or '?'} kbps"


def _key(t: Track) -> str:
    title = re.sub(r"\s*[\(\[].*?[\)\]]", "", t.title or "")
    return f"{T.name_key(title)}|{T.name_key(T.primary_artist(t.artist_name))}"


def same_song_groups(request: Request, s: Session) -> list[dict[str, Any]]:
    ignored = set(json.loads(request.app.state.people.home.get("same_songs_kept") or "[]"))
    by_key: dict[str, list[Track]] = defaultdict(list)
    for t in s.scalars(select(Track)):
        by_key[_key(t)].append(t)
    albums = dict(s.execute(select(Album.id, Album.title)).all())
    likes = dict(s.execute(select(Like.track_id, func.count()).group_by(Like.track_id)).all())
    plays = dict(
        s.execute(
            select(PlayCount.track_id, func.sum(PlayCount.count)).group_by(PlayCount.track_id)
        ).all()
    )
    listed = dict(
        s.execute(select(PlaylistItem.track_id, func.count()).group_by(PlaylistItem.track_id)).all()
    )
    roots = [str(f) for f in request.app.state.library.folders]
    groups = []
    for key, tracks in by_key.items():
        if len(tracks) < 2 or key.startswith("|"):
            continue
        # The same length, give or take 3 seconds, and not the very same file
        # (identical files are under Library → Duplicate copies).
        tracks.sort(key=lambda t: t.duration_ms)
        if tracks[-1].duration_ms - tracks[0].duration_ms > 3000:
            continue
        if len({t.sha256 for t in tracks}) < len(tracks):
            continue
        group_key = "+".join(sorted(t.id for t in tracks))
        if group_key in ignored:
            continue
        best = max(tracks, key=_quality)
        copies = []
        for t in sorted(tracks, key=_quality, reverse=True):
            root = next((r for r in roots if t.path.startswith(r)), str(Path(t.path).parent))
            copies.append(
                {
                    "trackId": t.id,
                    "title": t.title,
                    "artistName": t.artist_name,
                    "albumId": t.album_id,
                    "albumTitle": albums.get(t.album_id, ""),
                    "format": _label(t),
                    "lossless": bool(t.lossless),
                    "sizeBytes": t.size,
                    "durationMs": t.duration_ms,
                    "file": str(Path(t.path).relative_to(root))
                    if t.path.startswith(root)
                    else t.path,
                    "likes": int(likes.get(t.id, 0)),
                    "plays": int(plays.get(t.id, 0) or 0),
                    "inPlaylists": int(listed.get(t.id, 0)),
                    "best": t.id == best.id,
                }
            )
        groups.append({"key": group_key, "copies": copies})
    groups.sort(key=lambda g: g["copies"][0]["title"].lower())
    return groups


class Resolve(BaseModel):
    model_config = ConfigDict(extra="forbid")
    keep: str = Field(max_length=32)
    remove: list[str] = Field(min_length=1, max_length=10)


class KeepBoth(BaseModel):
    model_config = ConfigDict(extra="forbid")
    key: str = Field(max_length=400)


@router.get("/same-songs")
def admin_same_songs(request: Request, who: AdminDep, s: SessionDep) -> dict[str, Any]:
    return {"items": same_song_groups(request, s)}


def move_listening(s: Session, keep: str, gone: str) -> dict[str, int]:
    """Likes, plays, playlist entries and Listen history move to [keep]."""
    moved = {"likes": 0, "plays": 0, "playlistEntries": 0}
    for like in s.scalars(select(Like).where(Like.track_id == gone)).all():
        if s.get(Like, (like.user_id, keep)) is None:
            s.add(Like(user_id=like.user_id, track_id=keep, created_at=like.created_at))
            moved["likes"] += 1
    s.execute(delete(Like).where(Like.track_id == gone))
    for pc in s.scalars(select(PlayCount).where(PlayCount.track_id == gone)).all():
        mine = s.get(PlayCount, (pc.user_id, keep))
        if mine is None:
            s.add(
                PlayCount(
                    user_id=pc.user_id,
                    track_id=keep,
                    count=pc.count,
                    last_played_at=pc.last_played_at,
                )
            )
        else:
            mine.count += pc.count
            mine.last_played_at = max(mine.last_played_at, pc.last_played_at)
        moved["plays"] += pc.count
    s.execute(delete(PlayCount).where(PlayCount.track_id == gone))
    moved["playlistEntries"] = (
        s.execute(
            update(PlaylistItem).where(PlaylistItem.track_id == gone).values(track_id=keep)
        ).rowcount
        or 0
    )
    s.execute(update(ListenEvent).where(ListenEvent.track_id == gone).values(track_id=keep))
    return moved


@router.post("/same-songs/resolve")
async def admin_resolve_same_song(body: Resolve, request: Request, who: AdminDep) -> dict[str, Any]:
    library = request.app.state.library
    db = request.app.state.db

    def work() -> dict[str, Any]:
        with Session(db.engine) as s:
            if body.keep in body.remove:
                raise HTTPException(422, "Keep one copy")
            keep = s.get(Track, body.keep)
            gone = [s.get(Track, t) for t in body.remove]
            if keep is None or any(t is None for t in gone):
                raise HTTPException(404, "That song changed meanwhile; look again")
            if not Path(keep.path).is_file():
                raise HTTPException(409, "The copy to keep isn't on disk any more")
            if any(_key(t) != _key(keep) for t in gone):
                raise HTTPException(422, "Those aren't the same song")
            total = {"likes": 0, "plays": 0, "playlistEntries": 0}
            paths = []
            for t in gone:
                for k, v in move_listening(s, keep.id, t.id).items():
                    total[k] += v
                paths.append(Path(t.path))
            _audit(
                s,
                request,
                who,
                "library.same_song",
                f"{{actor}} kept one copy of a song and deleted {len(paths)} other "
                f"{'copy' if len(paths) == 1 else 'copies'}.",
                keep.id,
            )
            s.commit()
        deleted = 0
        for p in paths:
            try:
                if p.is_file():
                    p.unlink()
                    deleted += 1
            except OSError as e:
                log.warning("couldn't delete a copy: %s", e.strerror)
            library.forget(p)
        return {"moved": total, "deleted": deleted}

    return await run_in_threadpool(work)


@router.post("/same-songs/keep-both")
def admin_keep_both(body: KeepBoth, request: Request, who: AdminDep) -> dict[str, Any]:
    home = request.app.state.people.home
    kept = set(json.loads(home.get("same_songs_kept") or "[]"))
    kept.add(body.key)
    home.set("same_songs_kept", json.dumps(sorted(kept)))
    with Session(request.app.state.db.engine) as s:
        return {"items": same_song_groups(request, s)}
