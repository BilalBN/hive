"""Hive Admin's library endpoints: status, rescans and the development key."""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path
from typing import Annotated, Any, Literal

from fastapi import APIRouter, HTTPException, Query, Request
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from hive.auth import CallerDep
from hive.library import catalog as C
from hive.library import text as T
from hive.library.api import SessionDep, _like_all, album_body
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


# ------------------------------------------------------------------ M1.5 lookup


class LookupSettingsBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    enabled: bool | None = None
    acoustidKey: str | None = Field(None, max_length=64)  # noqa: N815 - contract name


class LookupRetryBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    albumIds: list[str] | None = Field(None, max_length=500)  # noqa: N815
    all: bool | None = None


class MatchDecisionBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    accept: bool


EDITABLE = ("title", "artistName", "year", "language", "filmTitle", "filmYear", "artwork")


class AlbumEditBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: str | None = Field(None, min_length=1, max_length=512)
    artistName: str | None = Field(None, min_length=1, max_length=512)  # noqa: N815
    year: int | None = Field(None, ge=1000, le=2100)
    language: str | None = Field(None, pattern=r"^[a-z]{2,3}$")
    filmTitle: str | None = Field(None, max_length=512)  # noqa: N815
    filmYear: int | None = Field(None, ge=1890, le=2100)  # noqa: N815
    artwork: None = None


def _lookup(request: Request):
    return request.app.state.lookup


@router.get("/library/lookup")
def admin_get_lookup(request: Request, caller: CallerDep) -> dict[str, Any]:
    return _lookup(request).status()


@router.patch("/library/lookup")
def admin_update_lookup(
    request: Request, body: LookupSettingsBody, caller: CallerDep
) -> dict[str, Any]:
    _lookup(request).configure(enabled=body.enabled, acoustid_key=body.acoustidKey)
    return _lookup(request).status()


@router.post("/library/lookup/retry")
def admin_retry_lookup(request: Request, body: LookupRetryBody, caller: CallerDep) -> dict:
    _lookup(request).retry(body.albumIds, bool(body.all))
    return _lookup(request).status()


FILTERS = {
    "all": None,
    "review": Album.lookup_state == "review",
    "noArt": Album.artwork_id.is_(None),
    "noLanguage": Album.language.is_(None),
    "notFound": Album.lookup_state.in_(("notFound", "failed")),
}


@router.get("/library/albums")
def admin_list_albums(
    caller: CallerDep,
    s: SessionDep,
    offset: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=500)] = 100,
    filter: Literal["all", "review", "noArt", "noLanguage", "notFound"] = "all",  # noqa: A002
    q: Annotated[str | None, Query(max_length=200)] = None,
) -> dict[str, Any]:
    query = select(Album)
    cond = FILTERS[filter]
    if cond is not None:
        query = query.where(cond)
    if q and (words := T.query_words(q)):
        query = query.where(*_like_all(Album.search_text, words))
    total = s.scalar(select(func.count()).select_from(query.subquery()))
    rows = s.scalars(
        query.order_by(Album.added_at.desc(), Album.title_key).offset(offset).limit(limit)
    ).all()
    items = []
    for a, summary in zip(rows, album_summaries(s, rows), strict=True):
        item: dict[str, Any] = {"album": summary, "lookup": a.lookup_state}
        if a.lookup_note:
            item["lookupNote"] = a.lookup_note
        items.append(item)
    return {"items": items, "total": total, "offset": offset}


def _admin_album(request: Request, s, caller, album: Album) -> dict[str, Any]:
    body: dict[str, Any] = {
        "album": album_body(s, caller, album),
        "lookup": album.lookup_state,
        "edited": [k for k in EDITABLE if k in C.overrides(album)],
        "sources": C.sources(album),
    }
    if not request.app.state.lookup.enabled and album.lookup_state == "waiting":
        body["lookup"] = "off"
    if album.lookup_note:
        body["lookupNote"] = album.lookup_note
    if album.lookup_state == "review" and album.lookup_candidate:
        body["found"] = json.loads(album.lookup_candidate)["found"]
    if album.folder_path:
        body["folder"] = _rel(album.folder_path, _root_of(request, album.folder_path))
    return body


def _root_of(request: Request, path: str) -> str:
    for f in request.app.state.library.folders:
        if path.startswith(str(f)):
            return str(f)
    return str(Path(path).parent)


def _album_or_404(s, album_id: str) -> Album:
    album = s.get(Album, album_id)
    if album is None:
        raise HTTPException(404, "No such album")
    return album


@router.get("/library/albums/{albumId}")
def admin_get_album(
    albumId: str,  # noqa: N803
    request: Request,
    caller: CallerDep,
    s: SessionDep,
) -> dict[str, Any]:
    return _admin_album(request, s, caller, _album_or_404(s, albumId))


@router.patch("/library/albums/{albumId}")
def admin_update_album(
    albumId: str,  # noqa: N803
    body: AlbumEditBody,
    request: Request,
    caller: CallerDep,
    s: SessionDep,
) -> dict[str, Any]:
    library = request.app.state.library
    with library._write_lock:
        album = _album_or_404(s, albumId)
        o = C.overrides(album)
        sent = body.model_dump(exclude_unset=True)
        for field, value in sent.items():
            if value is None:
                o.pop(field, None)
            elif field != "artwork":
                o[field] = value
        if "artwork" in sent:
            o.pop("artwork", None)
            src = C.sources(album).get("artwork")
            if src == "admin":
                # Back to the cover from the files (or none until the next rescan/lookup).
                first = s.scalar(
                    select(Track.artwork_id)
                    .where(Track.album_id == album.id, Track.artwork_id.isnot(None))
                    .limit(1)
                )
                album.artwork_id = first
                C.set_source(album, "artwork", "tags" if first else None)
        if "artistName" in o:
            album.artist_id = C.artist_row(s, o["artistName"]).id
        album.overrides = json.dumps(o, sort_keys=True, ensure_ascii=False)
        for field in sent:
            if field in o:
                C.set_source(album, field, "admin")
            elif field != "artwork":
                C.set_source(album, field, None)
        # Undone fields go back to what the files and lookup say.
        _restore_defaults(s, album, [f for f in sent if f not in o and f != "artwork"])
        C.apply_overrides(album)
        C.refresh_language(s, album)
        C.refresh_search(s, album)
        if o:
            album.lookup_state = "edited" if album.lookup_state != "review" else "review"
        s.commit()
    s.refresh(album)
    return _admin_album(request, s, caller, album)


def _restore_defaults(s, album: Album, fields: list[str]) -> None:
    """Re-derive [fields] after their override is removed."""
    tracks = s.scalars(select(Track).where(Track.album_id == album.id)).all()
    if "year" in fields:
        years = Counter(t.year for t in tracks if t.year)
        album.year = years.most_common(1)[0][0] if years else None
    if "filmTitle" in fields and not album.film_wikidata:
        album.film_title = None
    if "filmYear" in fields and not album.film_wikidata:
        album.film_year = None
    if "language" in fields:
        album.language = None  # refresh_language works it out again
    # Title and artist: a rescan re-reads them; until then keep what's shown.


MAX_COVER = 20 * 1024 * 1024


@router.put("/library/albums/{albumId}/artwork")
async def admin_set_album_artwork(
    albumId: str,  # noqa: N803
    request: Request,
    caller: CallerDep,
) -> dict[str, Any]:
    ctype = request.headers.get("content-type", "").split(";")[0].strip()
    if ctype not in ("image/jpeg", "image/png", "image/webp"):
        raise HTTPException(415, "Send a JPEG, PNG or WebP image")
    data = await request.body()
    if len(data) > MAX_COVER:
        raise HTTPException(413, "The image is larger than 20 MB")
    library = request.app.state.library
    artwork_id = library.artwork.save(data)
    if artwork_id is None:
        raise HTTPException(422, "That file isn't an image Hive can read")
    with library._write_lock, Session(request.app.state.db.engine) as s:
        album = _album_or_404(s, albumId)
        album.artwork_id = artwork_id
        C.set_source(album, "artwork", "admin")
        o = C.overrides(album)
        o["artwork"] = artwork_id
        album.overrides = json.dumps(o, sort_keys=True, ensure_ascii=False)
        for t in s.scalars(select(Track).where(Track.album_id == album.id)):
            t.artwork_id = artwork_id
        s.commit()
        return _admin_album(request, s, caller, album)


@router.post("/library/albums/{albumId}/match")
def admin_decide_match(
    albumId: str,  # noqa: N803
    body: MatchDecisionBody,
    request: Request,
    caller: CallerDep,
    s: SessionDep,
) -> dict[str, Any]:
    _album_or_404(s, albumId)
    if not request.app.state.lookup.decide(albumId, body.accept):
        raise HTTPException(409, "Nothing is waiting for review on this album")
    s.expire_all()
    return _admin_album(request, s, caller, _album_or_404(s, albumId))
