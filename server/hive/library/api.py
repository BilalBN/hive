"""Library endpoints: Home, albums, artists, songs, search, playlists, likes."""

from __future__ import annotations

from collections.abc import Iterator
from datetime import UTC, datetime
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import Integer, delete, func, or_, select
from sqlalchemy.orm import Session

from hive.auth import Caller, CallerDep
from hive.library import catalog as C
from hive.library import languages as L
from hive.library import text as T
from hive.library.scanner import new_id
from hive.library.views import (
    album_stats,
    album_summaries,
    artist_summaries,
    playlist_detail,
    playlist_summaries,
    track_summaries,
)
from hive.models import (
    Album,
    Artist,
    Credit,
    Like,
    PlayCount,
    Playlist,
    PlaylistItem,
    RecentContext,
    Track,
)

router = APIRouter(prefix="/api/v1/library", tags=["library"])


def get_session(request: Request) -> Iterator[Session]:
    with Session(request.app.state.db.engine) as s:
        yield s


SessionDep = Annotated[Session, Depends(get_session)]
Offset = Annotated[int, Query(ge=0)]
Limit = Annotated[int, Query(ge=1, le=500)]
LanguageQ = Annotated[str | None, Query(pattern=r"^[a-z]{2,3}$")]


def _in_language(language: str | None):
    """Albums in [language]; a song is in its album's language."""
    return Album.language == language


def _tracks_in_language(language: str):
    return Track.album_id.in_(select(Album.id).where(Album.language == language))


def _now() -> datetime:
    return datetime.now(UTC)


# ------------------------------------------------------------------ Home


@router.get("/home")
def get_home(caller: CallerDep, s: SessionDep, language: LanguageQ = None) -> dict[str, Any]:
    recent = s.scalars(
        select(RecentContext)
        .where(RecentContext.user_id == caller.user_id)
        .order_by(RecentContext.last_played_at.desc())
        .limit(12)
    ).all()
    tiles: list[dict[str, Any]] = []
    for ctx in recent:
        tile = _tile(s, caller, ctx.kind, ctx.ref_id)
        if tile and language and tile["kind"] == "album":
            a = s.get(Album, tile["id"])
            if a is None or a.language != language:
                continue
        if tile:
            tiles.append(tile)
        if len(tiles) == 6:
            break
    newest_q = select(Album).order_by(Album.added_at.desc()).limit(12)
    if language:
        newest_q = newest_q.where(_in_language(language))
    newest = s.scalars(newest_q).all()
    playlists = _visible_playlists(s, caller).limit(8)
    return {
        "jumpBackIn": tiles,
        "newAtHome": album_summaries(s, newest),
        "playlists": playlist_summaries(s, caller, s.scalars(playlists).all()),
        "libraryEmpty": s.scalar(select(func.count()).select_from(Track)) == 0,
    }


def _tile(s: Session, caller: Caller, kind: str, ref_id: str) -> dict[str, Any] | None:
    if kind == "album":
        a = s.get(Album, ref_id)
        if a is None:
            return None
        return _drop_none(
            {
                "kind": "album",
                "id": a.id,
                "title": a.title,
                "subtitle": a.artist_name,
                "artworkIds": [a.artwork_id] if a.artwork_id else [],
            }  # fmt: skip
        )
    if kind == "artist":
        ar = s.get(Artist, ref_id)
        if ar is None:
            return None
        art = artist_summaries(s, [ar])[0].get("artworkId")
        return {"kind": "artist", "id": ar.id, "title": ar.name, "subtitle": "Artist",
                "artworkIds": [art] if art else []}  # fmt: skip
    if kind == "playlist":
        p = s.get(Playlist, ref_id)
        if p is None or not (p.shared or p.owner_id == caller.user_id):
            return None
        summary = playlist_summaries(s, caller, [p])[0]
        return {
            "kind": "playlist",
            "id": p.id,
            "title": p.name,
            "subtitle": f"{summary['trackCount']} songs",
            "artworkIds": summary["artworkIds"],
        }
    if kind == "liked":
        arts = [
            a
            for a in s.scalars(
                select(Track.artwork_id)
                .join(Like, Like.track_id == Track.id)
                .where(Like.user_id == caller.user_id, Track.artwork_id.isnot(None))
                .order_by(Like.created_at.desc())
                .limit(20)
            )
        ]
        unique = list(dict.fromkeys(arts))[:4]
        return {"kind": "liked", "id": "liked", "title": "Liked songs", "artworkIds": unique}
    return None


def _drop_none(d: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in d.items() if v is not None}


# ------------------------------------------------------------------ albums


@router.get("/albums")
def list_albums(
    caller: CallerDep,
    s: SessionDep,
    offset: Offset = 0,
    limit: Limit = 100,
    sort: Literal["recent", "title", "artist", "year"] = "recent",
    artistId: str | None = None,  # noqa: N803 - query name from the contract
    language: LanguageQ = None,
) -> dict[str, Any]:
    q = select(Album)
    if language:
        q = q.where(_in_language(language))
    if artistId:
        q = q.where(
            or_(
                Album.artist_id == artistId,
                Album.id.in_(select(Track.album_id).where(Track.artist_id == artistId)),
            )
        )
    order = {
        "recent": (Album.added_at.desc(), Album.title_key),
        "title": (Album.title_key,),
        "artist": (Album.artist_key, Album.year, Album.title_key),
        "year": (Album.year.desc().nulls_last(), Album.title_key),
    }[sort]
    total = s.scalar(select(func.count()).select_from(q.subquery()))
    rows = s.scalars(q.order_by(*order).offset(offset).limit(limit)).all()
    return {"items": album_summaries(s, rows), "total": total, "offset": offset}


def _album_tracks(s: Session, album_id: str) -> list[Track]:
    return list(
        s.scalars(
            select(Track)
            .where(Track.album_id == album_id)
            .order_by(
                func.coalesce(Track.disc_no, 1), func.coalesce(Track.track_no, 9999), Track.title
            )
        )
    )


@router.get("/albums/{albumId}")
def get_album(albumId: str, caller: CallerDep, s: SessionDep) -> dict[str, Any]:  # noqa: N803
    album = s.get(Album, albumId)
    if album is None:
        raise HTTPException(404, "No such album")
    body = album_summaries(s, [album])[0]
    body["durationMs"] = album_stats(s, [album.id]).get(album.id, {}).get("durationMs", 0)
    if album.genre:
        body["genre"] = album.genre
    if album.film_title:
        body["film"] = {
            k: v
            for k, v in {
                "title": album.film_title,
                "year": album.film_year,
                "wikidataId": album.film_wikidata,
            }.items()
            if v is not None
        }
    credits = C.album_credits(s, album.id)
    if credits:
        body["credits"] = credits
    body["tracks"] = track_summaries(s, caller, _album_tracks(s, album.id))
    return body


# ------------------------------------------------------------------ languages


@router.get("/languages")
def list_languages(caller: CallerDep, s: SessionDep) -> dict[str, Any]:
    rows = s.execute(
        select(Album.language, func.count(Album.id))
        .where(Album.language.isnot(None))
        .group_by(Album.language)
        .order_by(func.count(Album.id).desc())
    ).all()
    items = []
    for code, n in rows:
        lang = L.LANGUAGES.get(code)
        items.append(
            {
                "code": code,
                "name": lang.name if lang else code,
                "nativeName": lang.native if lang else code,
                "albumCount": n,
            }
        )
    return {"items": items}


# ------------------------------------------------------------------ artists


@router.get("/artists")
def list_artists(
    caller: CallerDep, s: SessionDep, offset: Offset = 0, limit: Limit = 100
) -> dict[str, Any]:
    total = s.scalar(select(func.count()).select_from(Artist))
    rows = s.scalars(select(Artist).order_by(Artist.name_key).offset(offset).limit(limit)).all()
    return {"items": artist_summaries(s, rows), "total": total, "offset": offset}


@router.get("/artists/{artistId}")
def get_artist(artistId: str, caller: CallerDep, s: SessionDep) -> dict[str, Any]:  # noqa: N803
    artist = s.get(Artist, artistId)
    if artist is None:
        raise HTTPException(404, "No such artist")
    body = artist_summaries(s, [artist])[0]
    sang = select(Credit.track_id).where(
        Credit.artist_id == artist.id, Credit.role == "singer", Credit.track_id.isnot(None)
    )
    newest_first = (Album.year.desc().nulls_last(), Album.title_key)
    albums = s.scalars(
        select(Album)
        .where(
            or_(
                Album.artist_id == artist.id,
                Album.id.in_(
                    select(Track.album_id).where(
                        or_(Track.artist_id == artist.id, Track.id.in_(sang))
                    )
                ),
            )
        )
        .order_by(*newest_first)
    ).all()
    body["albums"] = album_summaries(s, albums)
    shown = {a.id for a in albums}

    def albums_where(roles: tuple[str, ...]) -> list[Album]:
        by_album = select(Credit.album_id).where(
            Credit.artist_id == artist.id, Credit.role.in_(roles), Credit.album_id.isnot(None)
        )
        by_track = (
            select(Track.album_id)
            .join(Credit, Credit.track_id == Track.id)
            .where(Credit.artist_id == artist.id, Credit.role.in_(roles))
        )
        return list(
            s.scalars(
                select(Album)
                .where(or_(Album.id.in_(by_album), Album.id.in_(by_track)))
                .order_by(*newest_first)
            )
        )

    music_for = [a for a in albums_where(("musicDirector", "composer")) if a.id not in shown]
    films = albums_where(("actor", "director"))
    if music_for:
        body["musicFor"] = album_summaries(s, music_for)
    if films:
        body["films"] = album_summaries(s, films)
    wrote = s.scalars(
        select(Track)
        .join(Credit, Credit.track_id == Track.id)
        .where(Credit.artist_id == artist.id, Credit.role == "lyricist")
        .limit(50)
    ).all()
    if wrote:
        body["lyricsFor"] = track_summaries(s, caller, wrote)
    role_counts = s.execute(
        select(Credit.role, func.count(Credit.id))
        .where(Credit.artist_id == artist.id)
        .group_by(Credit.role)
        .order_by(func.count(Credit.id).desc())
    ).all()
    roles = [r for r, _ in role_counts]
    if roles:
        body["roles"] = roles
    plays = func.coalesce(PlayCount.count, 0)
    top = s.scalars(
        select(Track)
        .join(Album, Album.id == Track.album_id)
        .outerjoin(
            PlayCount,
            (PlayCount.track_id == Track.id) & (PlayCount.user_id == caller.user_id),
        )
        .where(or_(Track.artist_id == artist.id, Album.artist_id == artist.id, Track.id.in_(sang)))
        .order_by(plays.desc(), Album.added_at.desc(), Track.disc_no, Track.track_no)
        .limit(10)
    ).all()
    body["topTracks"] = track_summaries(s, caller, top)
    return body


# ------------------------------------------------------------------ songs


@router.get("/tracks")
def list_tracks(
    caller: CallerDep,
    s: SessionDep,
    offset: Offset = 0,
    limit: Limit = 100,
    sort: Literal["recent", "title", "artist"] = "title",
    liked: bool | None = None,
    language: LanguageQ = None,
) -> dict[str, Any]:
    q = select(Track)
    if language:
        q = q.where(_tracks_in_language(language))
    if liked:
        q = q.join(Like, Like.track_id == Track.id).where(Like.user_id == caller.user_id)
        order = (Like.created_at.desc(),)
    else:
        order = {
            "recent": (Track.added_at.desc(), Track.title),
            "title": (func.lower(Track.title),),
            "artist": (func.lower(Track.artist_name), func.lower(Track.title)),
        }[sort]
    total = s.scalar(select(func.count()).select_from(q.subquery()))
    rows = s.scalars(q.order_by(*order).offset(offset).limit(limit)).all()
    return {"items": track_summaries(s, caller, rows), "total": total, "offset": offset}


# ------------------------------------------------------------------ search


def _like_all(column, words: list[str]):
    """Every word starts a word in the text, as typed or by its sound key
    (so "kadhal" finds "kathal", the English spelling of காதல்)."""

    def like(w: str):
        escaped = w.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        return column.like(f"% {escaped}%", escape="\\")

    conds = []
    for w in words:
        key = T.phonetic(w)
        conds.append(like(w) if key == w else or_(like(w), like(key)))
    return conds


def _score(text: str, words: list[str], query: str) -> float:
    """Higher is better: whole-name matches, then names starting with the query."""
    t = " ".join(T.words(text))
    q = " ".join(words)
    if t == q:
        return 100.0
    score = 0.0
    if t.startswith(q):
        score += 50
    elif f" {q}" in f" {t}":
        score += 30
    score += 10 * sum(1 for w in words if f" {w} " in f" {t} ")  # whole words
    return score - len(t) / 100


@router.get("/search")
def search(
    caller: CallerDep,
    s: SessionDep,
    q: Annotated[str, Query(min_length=1, max_length=200)],
    limit: Annotated[int, Query(ge=1, le=50)] = 10,
    language: LanguageQ = None,
) -> dict[str, Any]:
    words = T.query_words(q)
    if not words:
        return {"tracks": [], "albums": [], "artists": [], "playlists": []}
    pool = limit * 5

    track_q = select(Track).where(*_like_all(Track.search_text, words))
    album_q = select(Album).where(*_like_all(Album.search_text, words))
    if language:
        track_q = track_q.where(_tracks_in_language(language))
        album_q = album_q.where(_in_language(language))
    tracks = s.scalars(track_q.limit(pool)).all()
    tracks = sorted(tracks, key=lambda t: -_score(t.title, words, q))[:limit]
    albums = s.scalars(album_q.limit(pool)).all()
    albums = sorted(albums, key=lambda a: -_score(a.title, words, q))[:limit]
    artists = s.scalars(
        select(Artist).where(*_like_all(Artist.search_text, words)).limit(pool)
    ).all()
    artists = sorted(artists, key=lambda a: -_score(a.name, words, q))[:limit]
    playlists = s.scalars(
        _visible_playlists(s, caller).where(*_like_all(Playlist.search_text, words)).limit(pool)
    ).all()
    playlists = sorted(playlists, key=lambda p: -_score(p.name, words, q))[:limit]

    body: dict[str, Any] = {
        "tracks": track_summaries(s, caller, tracks),
        "albums": album_summaries(s, albums),
        "artists": artist_summaries(s, artists),
        "playlists": playlist_summaries(s, caller, playlists),
    }
    candidates = [
        (_score(artists[0].name, words, q) + 5, "artist", artists[0].id) if artists else None,
        (_score(albums[0].title, words, q) + 2, "album", albums[0].id) if albums else None,
        (_score(tracks[0].title, words, q), "track", tracks[0].id) if tracks else None,
        (_score(playlists[0].name, words, q), "playlist", playlists[0].id) if playlists else None,
    ]
    best = max((c for c in candidates if c), default=None)
    if best and best[0] >= 30:
        body["top"] = {"kind": best[1], "id": best[2]}
    return body


# ------------------------------------------------------------------ playlists


def _visible_playlists(s: Session, caller: Caller):
    mine_first = (Playlist.owner_id != caller.user_id).cast(Integer)
    return (
        select(Playlist)
        .where(or_(Playlist.owner_id == caller.user_id, Playlist.shared.is_(True)))
        .order_by(mine_first, Playlist.updated_at.desc())
    )


class CamelModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class PlaylistCreate(CamelModel):
    name: str = Field(min_length=1, max_length=120)
    shared: bool = False
    trackIds: list[str] = Field(default_factory=list, max_length=5000)  # noqa: N815


class PlaylistUpdate(CamelModel):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    shared: bool | None = None


class PlaylistItemsUpdate(CamelModel):
    trackIds: list[str] = Field(max_length=5000)  # noqa: N815


def _readable(s: Session, caller: Caller, playlist_id: str) -> Playlist:
    p = s.get(Playlist, playlist_id)
    if p is None or not (p.shared or p.owner_id == caller.user_id):
        raise HTTPException(404, "No such playlist")
    return p


def _editable(s: Session, caller: Caller, playlist_id: str) -> Playlist:
    p = _readable(s, caller, playlist_id)
    if p.owner_id != caller.user_id:
        raise HTTPException(403, "Only the person who made this playlist can change it")
    return p


def _set_items(s: Session, p: Playlist, track_ids: list[str]) -> None:
    known = set(s.scalars(select(Track.id).where(Track.id.in_(set(track_ids)))))
    missing = [t for t in track_ids if t not in known]
    if missing:
        raise HTTPException(422, f"Unknown songs: {', '.join(missing[:5])}")
    existing = {
        it.track_id: it
        for it in s.scalars(select(PlaylistItem).where(PlaylistItem.playlist_id == p.id))
    }
    # Keep the date a song was first added when it stays in the playlist.
    added = {tid: it.added_at for tid, it in existing.items()}
    s.execute(delete(PlaylistItem).where(PlaylistItem.playlist_id == p.id))
    now = _now()
    for pos, tid in enumerate(track_ids):
        s.add(
            PlaylistItem(
                id=new_id(),
                playlist_id=p.id,
                track_id=tid,
                position=pos,
                added_at=added.get(tid, now),
            )
        )
    p.updated_at = now


@router.get("/playlists")
def list_playlists(caller: CallerDep, s: SessionDep) -> dict[str, Any]:
    rows = s.scalars(_visible_playlists(s, caller)).all()
    return {"items": playlist_summaries(s, caller, rows)}


@router.post("/playlists", status_code=201)
def create_playlist(body: PlaylistCreate, caller: CallerDep, s: SessionDep) -> dict[str, Any]:
    name = body.name.strip()
    if not name:
        raise HTTPException(422, "Give the playlist a name")
    p = Playlist(
        id=new_id(),
        name=name,
        owner_id=caller.user_id,
        shared=body.shared,
        search_text=T.search_text(name),
        created_at=_now(),
        updated_at=_now(),
    )
    s.add(p)
    s.flush()
    if body.trackIds:
        _set_items(s, p, body.trackIds)
    s.commit()
    return playlist_detail(s, caller, p)


@router.get("/playlists/{playlistId}")
def get_playlist(playlistId: str, caller: CallerDep, s: SessionDep) -> dict[str, Any]:  # noqa: N803
    return playlist_detail(s, caller, _readable(s, caller, playlistId))


@router.patch("/playlists/{playlistId}")
def update_playlist(
    playlistId: str,  # noqa: N803
    body: PlaylistUpdate,
    caller: CallerDep,
    s: SessionDep,
) -> dict[str, Any]:
    p = _editable(s, caller, playlistId)
    if body.name is not None:
        name = body.name.strip()
        if not name:
            raise HTTPException(422, "Give the playlist a name")
        p.name = name
        p.search_text = T.search_text(name)
    if body.shared is not None:
        p.shared = body.shared
    p.updated_at = _now()
    s.commit()
    return playlist_detail(s, caller, p)


@router.delete("/playlists/{playlistId}", status_code=204)
def delete_playlist(playlistId: str, caller: CallerDep, s: SessionDep) -> Response:  # noqa: N803
    p = _editable(s, caller, playlistId)
    s.delete(p)
    s.execute(
        delete(RecentContext).where(RecentContext.kind == "playlist", RecentContext.ref_id == p.id)
    )
    s.commit()
    return Response(status_code=204)


@router.put("/playlists/{playlistId}/items")
def set_playlist_items(
    playlistId: str,  # noqa: N803
    body: PlaylistItemsUpdate,
    caller: CallerDep,
    s: SessionDep,
) -> dict[str, Any]:
    p = _editable(s, caller, playlistId)
    _set_items(s, p, body.trackIds)
    s.commit()
    return playlist_detail(s, caller, p)


# ------------------------------------------------------------------ likes


@router.put("/likes/{trackId}", status_code=204)
def like_track(trackId: str, caller: CallerDep, s: SessionDep) -> Response:  # noqa: N803
    if s.get(Track, trackId) is None:
        raise HTTPException(404, "No such song")
    if s.get(Like, (caller.user_id, trackId)) is None:
        s.add(Like(user_id=caller.user_id, track_id=trackId, created_at=_now()))
        s.commit()
    return Response(status_code=204)


@router.delete("/likes/{trackId}", status_code=204)
def unlike_track(trackId: str, caller: CallerDep, s: SessionDep) -> Response:  # noqa: N803
    s.execute(delete(Like).where(Like.user_id == caller.user_id, Like.track_id == trackId))
    s.commit()
    return Response(status_code=204)
