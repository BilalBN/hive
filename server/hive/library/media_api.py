"""Media endpoints: stream tickets, the audio itself, cover art and lyrics."""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path
from typing import Annotated, Any, Literal

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse
from pydantic import BaseModel, ConfigDict
from sqlalchemy import select
from sqlalchemy.orm import Session

from hive.auth import CallerDep, read_ticket, sign_ticket
from hive.library import audio as A
from hive.library.api import SessionDep
from hive.library.artwork import SIZES
from hive.library.lyrics import parse as parse_lyrics
from hive.library.tags import UnreadableFile, read_file
from hive.library.views import audio_format, iso, track_format
from hive.models import Album, PlayCount, RecentContext, Track

router = APIRouter(prefix="/api/v1/media", tags=["media"])

TARGET_KBPS = {"high": 256, "dataSaver": 96}


class PlayContext(BaseModel):
    model_config = ConfigDict(extra="forbid")
    kind: Literal["album", "playlist", "artist", "liked"]
    id: str


class StreamRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    quality: Literal["lossless", "high", "dataSaver"]
    player: Literal["apple", "other"] = "other"
    purpose: Literal["play", "prefetch"] = "play"
    context: PlayContext | None = None


def choose_variant(t: Track, quality: str, player: str) -> A.Variant | None:
    """The stream to send, or None for the original file untouched."""
    apple = player == "apple"
    if quality == "lossless" or not t.lossless:
        if t.lossless:
            # Non-Apple players get ALAC and AIFF as FLAC: same samples, still lossless.
            if not apple and t.codec in ("alac", "aiff"):
                return A.FLAC_COPY
            return None
        target = TARGET_KBPS.get(quality)
        small_enough = target is None or not t.bitrate_kbps or t.bitrate_kbps <= target * 1.1
        # A lossy original is sent as it is, except Ogg (Opus, Vorbis) to Apple's
        # player, which can't open it: that becomes AAC.
        if small_enough and not (apple and t.codec in ("opus", "vorbis")):
            return None
        if target is None:
            return A.AAC_HIGH
    target = TARGET_KBPS[quality]
    if apple:
        return A.AAC_HIGH if target == 256 else A.AAC_SAVER
    return A.OPUS_HIGH if target == 256 else A.OPUS_SAVER


def _ticket_ttl(duration_ms: int) -> int:
    # Long enough to play (and seek) to the end even when paused for a while.
    return int(min(12 * 3600, max(30 * 60, duration_ms / 1000 * 3 + 600)))


def _record_play(s: Session, user_id: str, t: Track, context: PlayContext | None) -> None:
    now = datetime.now(UTC)
    pc = s.get(PlayCount, (user_id, t.id))
    if pc is None:
        s.add(PlayCount(user_id=user_id, track_id=t.id, count=1, last_played_at=now))
    else:
        pc.count += 1
        pc.last_played_at = now
    kind, ref = (context.kind, context.id) if context else ("album", t.album_id)
    rc = s.get(RecentContext, (user_id, kind, ref))
    if rc is None:
        s.add(RecentContext(user_id=user_id, kind=kind, ref_id=ref, last_played_at=now))
    else:
        rc.last_played_at = now
    s.commit()


@router.post("/tracks/{trackId}/stream")
async def create_stream_ticket(
    trackId: str,  # noqa: N803
    body: StreamRequest,
    request: Request,
    caller: CallerDep,
    s: SessionDep,
) -> dict[str, Any]:
    t = s.get(Track, trackId)
    if t is None:
        raise HTTPException(404, "No such song")
    library = request.app.state.library
    variant = choose_variant(t, body.quality, body.player)
    source = Path(t.path)
    if not source.is_file():
        raise HTTPException(404, "The song's file is missing from the music folder")
    if variant is None:
        path = source
        fmt = track_format(t)
        mime = A.original_mime(t.codec, source)
    else:
        try:
            path = await run_in_threadpool(
                library.transcoder.ensure, source, t.sha256, variant, t.duration_ms / 1000
            )
        except RuntimeError as e:
            raise HTTPException(503, str(e)) from e
        if variant.codec == "flac":
            fmt = audio_format("flac", True, t.sample_rate, t.channels, t.bit_depth, None)
        elif variant.codec == "aac":
            rate = 48000 if t.sample_rate > 48000 else t.sample_rate
            fmt = audio_format("aac", False, rate, 2, None, variant.bitrate_kbps)
        else:
            fmt = audio_format("opus", False, 48000, min(t.channels, 2), None, variant.bitrate_kbps)
        mime = variant.mime

    ticket, exp = sign_ticket(
        request.app.state.ticket_secret,
        {"t": t.id, "v": variant.key if variant else "orig", "u": caller.user_id},
        _ticket_ttl(t.duration_ms),
    )
    if body.purpose == "play":
        _record_play(s, caller.user_id, t, body.context)

    result: dict[str, Any] = {
        "url": f"/api/v1/media/stream/{ticket}",
        "expiresAt": iso(datetime.fromtimestamp(exp, UTC)),
        "format": fmt,
        "mimeType": mime,
        "sizeBytes": path.stat().st_size,
        "durationMs": t.duration_ms,
        "transcoded": variant is not None,
    }
    if variant is not None:
        result["source"] = track_format(t)
    if t.lufs is not None:
        loud: dict[str, Any] = {"integratedLufs": t.lufs, "truePeakDbtp": t.true_peak or 0.0}
        album_lufs = s.scalar(select(Album.album_lufs).where(Album.id == t.album_id))
        if album_lufs is not None:
            loud["albumLufs"] = album_lufs
        result["loudness"] = loud
    return result


VARIANTS = {v.key: v for v in A.ALL_VARIANTS}


@router.get("/stream/{ticket}")
async def stream_audio(ticket: str, request: Request) -> FileResponse:
    payload = read_ticket(request.app.state.ticket_secret, ticket)
    if payload is None:
        raise HTTPException(403, "This link has expired; the app asks for a new one")
    with Session(request.app.state.db.engine) as s:
        t = s.get(Track, payload.get("t"))
        if t is None:
            raise HTTPException(403, "This song is no longer in the library")
        source, sha, codec, duration = Path(t.path), t.sha256, t.codec, t.duration_ms
    key = payload.get("v")
    if key == "orig":
        path, mime = source, A.original_mime(codec, source)
    else:
        variant = VARIANTS.get(key)
        if variant is None:
            raise HTTPException(403, "This link is damaged")
        library = request.app.state.library
        try:
            path = await run_in_threadpool(
                library.transcoder.ensure, source, sha, variant, duration / 1000
            )
        except RuntimeError as e:
            raise HTTPException(503, str(e)) from e
        mime = variant.mime
    if not path.is_file():
        raise HTTPException(404, "The song's file is missing from the music folder")
    return FileResponse(
        path,
        media_type=mime,
        headers={"Cache-Control": "private, max-age=3600"},
        content_disposition_type="inline",
    )


@router.get("/artwork/{artworkId}")
async def get_artwork(
    artworkId: str,  # noqa: N803
    request: Request,
    caller: CallerDep,
    size: Annotated[int, Query()] = 600,
) -> FileResponse:
    if size not in SIZES:
        raise HTTPException(422, f"size must be one of {', '.join(map(str, SIZES))}")
    path = await run_in_threadpool(request.app.state.library.artwork.sized, artworkId, size)
    if path is None:
        raise HTTPException(404, "No such artwork")
    # Ids are content hashes, so an image never changes under the same URL.
    return FileResponse(
        path,
        media_type="image/jpeg",
        headers={"Cache-Control": "private, max-age=31536000, immutable"},
    )


@router.get("/tracks/{trackId}/lyrics")
async def get_lyrics(trackId: str, caller: CallerDep, s: SessionDep) -> dict[str, Any]:  # noqa: N803
    t = s.get(Track, trackId)
    if t is None:
        raise HTTPException(404, "No such song")
    raw = None
    if t.has_lyrics:
        try:
            info = await run_in_threadpool(read_file, Path(t.path), Path(t.folder))
            raw = info.lyrics
        except (UnreadableFile, OSError):
            raw = None
    kind, lines = parse_lyrics(raw)
    return {
        "kind": kind,
        "lines": [
            {"text": line.text, **({"timeMs": line.time_ms} if line.time_ms is not None else {})}
            for line in lines
        ],
    }
