"""What Hive knows about an album beyond one file's tags.

Shared by the scanner (tags, folders, scripts), the online lookup and Hive
Admin's album editor, so every path keeps the same rules:

- Details you set in Hive Admin always win, and stay through rescans and
  lookups (``Album.overrides``).
- Each detail remembers where it came from (``Album.sources``), so a rescan
  replaces what the tags said but not what the lookup or you said.
- People (singers, composers, lyricists, music directors, actors, directors)
  are Artist rows with credits, so each has a page and is found by search.
"""

from __future__ import annotations

import json
from collections import Counter
from pathlib import Path
from typing import Any

from sqlalchemy import delete, select, update
from sqlalchemy.orm import Session

from hive.library import languages as L
from hive.library import text as T
from hive.models import Album, Artist, Credit, PlaylistItem, Track

VARIOUS = "Various Artists"

# Who decides each detail, strongest first.
RANK = {"admin": 5, "albumArtistTag": 4, "tags": 4, "lookup": 3, "script": 2, "folder": 1}


def jload(text: str | None) -> dict[str, Any]:
    try:
        value = json.loads(text or "{}")
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


def sources(album: Album) -> dict[str, str]:
    return {k: str(v) for k, v in jload(album.sources).items()}


def overrides(album: Album) -> dict[str, Any]:
    return jload(album.overrides)


def set_source(album: Album, field: str, source: str | None) -> None:
    src = sources(album)
    if source is None:
        src.pop(field, None)
    else:
        src[field] = source
    album.sources = json.dumps(src, sort_keys=True)


def may_set(album: Album, field: str, source: str) -> bool:
    """True if [source] may change [field] (it's at least as trusted as what's there)."""
    if field in overrides(album) and source != "admin":
        return False
    current = sources(album).get(field)
    return current is None or RANK.get(source, 0) >= RANK.get(current, 0) or current == source


def artist_row(s: Session, name: str) -> Artist:
    key = T.name_key(name)
    a = s.scalar(select(Artist).where(Artist.name_key == key))
    if a is None:
        import secrets

        a = Artist(
            id=secrets.token_hex(8), name=name, name_key=key, search_text=T.search_text(name)
        )
        s.add(a)
        s.flush()
    return a


def people(credit: str | None) -> list[str]:
    """ "K. S. Chithra, Vijay Yesudas & Shweta" → each name (keeps "Simon & Garfunkel"
    together only when there's no comma)."""
    if not credit:
        return []
    parts = T._SPLIT_ARTISTS.split(credit.strip())
    out: list[str] = []
    for p in parts:
        p = p.strip()
        if p and p.casefold() not in {x.casefold() for x in out}:
            out.append(p)
    return out


# ------------------------------------------------------------------ credits


def set_track_credits(s: Session, track: Track, singers: str | None) -> None:
    """Credits from the file's tags (singers, composer, lyricist)."""
    s.execute(delete(Credit).where(Credit.track_id == track.id, Credit.source == "tags"))
    for role, value in (
        ("singer", singers),
        ("composer", track.composer),
        ("lyricist", track.lyricist),
    ):
        for i, name in enumerate(people(value)):
            s.add(
                Credit(
                    track_id=track.id,
                    artist_id=artist_row(s, name).id,
                    role=role,
                    position=i,
                    source="tags",
                )
            )


def set_album_credits(
    s: Session, album: Album, role: str, names: list[str], source: str = "lookup"
) -> None:
    s.execute(
        delete(Credit).where(
            Credit.album_id == album.id, Credit.role == role, Credit.source == source
        )
    )
    for i, name in enumerate(names):
        s.add(
            Credit(
                album_id=album.id,
                artist_id=artist_row(s, name).id,
                role=role,
                position=i,
                source=source,
            )
        )


def album_credits(s: Session, album_id: str) -> list[dict[str, Any]]:
    """Music directors, composers, lyricists of the album, and its film's
    director and cast, in that order, each person once per role."""
    rows = s.execute(
        select(Credit.role, Credit.position, Artist.id, Artist.name)
        .join(Artist, Artist.id == Credit.artist_id)
        .where(Credit.album_id == album_id)
        .order_by(Credit.position)
    ).all()
    track_rows = s.execute(
        select(Credit.role, Credit.position, Artist.id, Artist.name)
        .join(Artist, Artist.id == Credit.artist_id)
        .join(Track, Track.id == Credit.track_id)
        .where(Track.album_id == album_id, Credit.role.in_(("composer", "lyricist")))
        .order_by(Track.disc_no, Track.track_no, Credit.position)
    ).all()
    order = ["musicDirector", "composer", "lyricist", "director", "actor"]
    seen: set[tuple[str, str]] = set()
    out: list[dict[str, Any]] = []
    for role in order:
        for r, _pos, aid, name in [*rows, *track_rows]:
            if r != role or (role, aid) in seen:
                continue
            seen.add((role, aid))
            out.append({"role": role, "name": name, "artistId": aid})
    return out


# ------------------------------------------------------------------ language


def refresh_language(s: Session, album: Album) -> None:
    """Tags, then lookup, then the script of the titles, then folder names."""
    if "language" in overrides(album):
        return
    src = sources(album).get("language")
    tracks = s.scalars(select(Track).where(Track.album_id == album.id)).all()
    tagged = Counter(t.language for t in tracks if t.language)
    if tagged:
        album.language = tagged.most_common(1)[0][0]
        set_source(album, "language", "tags")
        return
    if src == "lookup" and album.language:
        return
    by_script = L.from_script(
        [album.title, album.film_title, *(t.title for t in tracks), album.artist_name]
    )
    if by_script:
        album.language = by_script
        set_source(album, "language", "script")
        return
    if album.folder_path:
        by_folder = L.from_folders(Path(album.folder_path).parts[-3:])
        if by_folder:
            album.language = by_folder
            set_source(album, "language", "folder")
            return
    if src in (None, "script", "folder", "tags"):
        album.language = None
        set_source(album, "language", None)


# ------------------------------------------------------------------ search


def refresh_search(s: Session, album: Album) -> None:
    """Album: title, artist, film, language and everyone credited.
    Songs: title, singers, album, composer, lyricist, and the album's film."""
    names = [c["name"] for c in album_credits(s, album.id)]
    album.search_text = T.search_text(
        album.title,
        album.artist_name,
        album.film_title,
        L.search_words(album.language),
        *names,
    )
    for t in s.scalars(select(Track).where(Track.album_id == album.id)):
        t.search_text = T.search_text(
            t.title, t.artist_name, album.title, album.film_title, t.composer, t.lyricist
        )


# ------------------------------------------------------------------ grouping


def find_folder_album(s: Session, title_key: str, folder: str) -> Album | None:
    """An album of this title whose songs are in the same folder: songs of one
    soundtrack with different singers and no album-artist tag."""
    return s.scalar(
        select(Album).where(Album.title_key == title_key, Album.folder_path == folder).limit(1)
    )


def common_value(values: list[str | None]) -> str | None:
    vals = [v for v in values if v]
    if vals and len(vals) == len(values) and len({T.name_key(v) for v in vals}) == 1:
        return vals[0]
    return None


def merge_albums(s: Session, keep: Album, other: Album) -> None:
    """Move [other]'s songs and credits into [keep] and drop [other]."""
    if keep.id == other.id:
        return
    s.execute(update(Track).where(Track.album_id == other.id).values(album_id=keep.id))
    s.execute(update(Credit).where(Credit.album_id == other.id).values(album_id=keep.id))
    keep.artwork_id = keep.artwork_id or other.artwork_id
    keep.year = keep.year or other.year
    keep.added_at = min(keep.added_at, other.added_at) if other.added_at else keep.added_at
    s.delete(other)
    s.flush()


def prune(s: Session) -> None:
    """Drop albums with no songs, and people with nothing left to their name."""
    s.execute(delete(Album).where(~Album.id.in_(select(Track.album_id).distinct())))
    s.execute(delete(PlaylistItem).where(~PlaylistItem.track_id.in_(select(Track.id))))
    s.execute(delete(Credit).where(Credit.album_id.is_(None), Credit.track_id.is_(None)))
    s.execute(
        delete(Artist).where(
            ~Artist.id.in_(select(Album.artist_id).where(Album.artist_id.isnot(None))),
            ~Artist.id.in_(select(Track.artist_id).where(Track.artist_id.isnot(None))),
            ~Artist.id.in_(select(Credit.artist_id)),
        )
    )


def apply_overrides(album: Album) -> None:
    """Put back what was set in Hive Admin (after a rescan or lookup)."""
    o = overrides(album)
    if "title" in o:
        album.title = o["title"]
    if "artistName" in o:
        album.artist_name = o["artistName"]
    if "year" in o:
        album.year = o["year"]
    if "language" in o:
        album.language = o["language"]
    if "filmTitle" in o:
        album.film_title = o["filmTitle"]
    if "filmYear" in o:
        album.film_year = o["filmYear"]
