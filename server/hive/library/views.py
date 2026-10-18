"""Turning library rows into API bodies (camelCase, as in api/openapi.yaml).

Tests validate every body against the contract's schemas, so the shapes here
can't drift from what the apps were generated against.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from datetime import UTC, datetime
from typing import Any

from sqlalchemy import Integer, and_, case, func, select
from sqlalchemy.orm import Session

from hive.auth import Caller
from hive.models import Album, Artist, Like, Playlist, PlaylistItem, Track


def iso(dt: datetime | None) -> str | None:
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt.astimezone(UTC).isoformat().replace("+00:00", "Z")


def _khz(rate: int) -> str:
    k = rate / 1000
    return f"{k:g}" if k != int(k) else str(int(k))


def tier_of(lossless: bool, bit_depth: int | None, sample_rate: int) -> str:
    if not lossless:
        return "lossy"
    if (bit_depth or 16) > 16 or sample_rate > 48000:
        return "hires"
    return "lossless"


LOSSY_NAMES = {"mp3": "MP3", "aac": "AAC", "opus": "Opus", "vorbis": "Ogg"}


def audio_format(
    codec: str,
    lossless: bool,
    sample_rate: int,
    channels: int,
    bit_depth: int | None = None,
    bitrate_kbps: int | None = None,
) -> dict[str, Any]:
    tier = tier_of(lossless, bit_depth, sample_rate)
    if tier == "hires":
        label = f"Hi-Res {bit_depth or 24}/{_khz(sample_rate)}"
    elif tier == "lossless":
        label = f"Lossless {bit_depth or 16}/{_khz(sample_rate)}"
    else:
        name = LOSSY_NAMES.get(codec, codec.upper())
        label = f"{name} {bitrate_kbps}" if bitrate_kbps else name
    body: dict[str, Any] = {
        "codec": codec,
        "lossless": lossless,
        "sampleRate": sample_rate,
        "channels": channels,
        "tier": tier,
        "label": label,
    }
    if bit_depth and lossless:
        body["bitDepth"] = bit_depth
    if bitrate_kbps:
        body["bitrateKbps"] = bitrate_kbps
    return body


def track_format(t: Track) -> dict[str, Any]:
    return audio_format(t.codec, t.lossless, t.sample_rate, t.channels, t.bit_depth, t.bitrate_kbps)


def _clean(d: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in d.items() if v is not None}


def liked_ids(s: Session, caller: Caller, track_ids: Iterable[str]) -> set[str]:
    ids = list(set(track_ids))
    if not ids:
        return set()
    return set(
        s.scalars(
            select(Like.track_id).where(Like.user_id == caller.user_id, Like.track_id.in_(ids))
        )
    )


def track_summaries(s: Session, caller: Caller, tracks: Sequence[Track]) -> list[dict[str, Any]]:
    album_ids = {t.album_id for t in tracks}
    titles = dict(s.execute(select(Album.id, Album.title).where(Album.id.in_(album_ids))).all())
    liked = liked_ids(s, caller, (t.id for t in tracks))
    return [
        _clean(
            {
                "id": t.id,
                "title": t.title,
                "artistId": t.artist_id,
                "artistName": t.artist_name,
                "albumId": t.album_id,
                "albumTitle": titles.get(t.album_id, ""),
                "trackNumber": t.track_no,
                "discNumber": t.disc_no,
                "durationMs": t.duration_ms,
                "artworkId": t.artwork_id,
                "format": track_format(t),
                "liked": t.id in liked,
                "hasLyrics": t.has_lyrics,
            }
        )
        for t in tracks
    ]


def album_stats(s: Session, album_ids: Sequence[str]) -> dict[str, dict[str, Any]]:
    if not album_ids:
        return {}
    hires = case(
        (
            and_(
                Track.lossless,
                (func.coalesce(Track.bit_depth, 16) > 16) | (Track.sample_rate > 48000),
            ),
            2,
        ),
        (Track.lossless, 1),
        else_=0,
    )
    rows = s.execute(
        select(
            Track.album_id,
            func.count(Track.id),
            func.max(hires.cast(Integer)),
            func.sum(Track.duration_ms),
        )
        .where(Track.album_id.in_(album_ids))
        .group_by(Track.album_id)
    ).all()
    tiers = {2: "hires", 1: "lossless", 0: "lossy"}
    return {
        aid: {"trackCount": n, "tier": tiers[int(best or 0)], "durationMs": int(dur or 0)}
        for aid, n, best, dur in rows
    }


def album_summaries(s: Session, albums: Sequence[Album]) -> list[dict[str, Any]]:
    stats = album_stats(s, [a.id for a in albums])
    out = []
    for a in albums:
        st = stats.get(a.id, {"trackCount": 0, "tier": "lossy"})
        out.append(
            _clean(
                {
                    "id": a.id,
                    "title": a.title,
                    "artistId": a.artist_id,
                    "artistName": a.artist_name,
                    "year": a.year,
                    "artworkId": a.artwork_id,
                    "trackCount": st["trackCount"],
                    "tier": st["tier"],
                    "addedAt": iso(a.added_at),
                }
            )
        )
    return out


def artist_summaries(s: Session, artists: Sequence[Artist]) -> list[dict[str, Any]]:
    ids = [a.id for a in artists]
    if not ids:
        return []
    album_counts = dict(
        s.execute(
            select(Album.artist_id, func.count(Album.id))
            .where(Album.artist_id.in_(ids))
            .group_by(Album.artist_id)
        ).all()
    )
    track_counts = dict(
        s.execute(
            select(Track.artist_id, func.count(Track.id))
            .where(Track.artist_id.in_(ids))
            .group_by(Track.artist_id)
        ).all()
    )
    # A face for each artist: the newest album cover they have.
    covers: dict[str, str] = {}
    for artist_id, artwork_id in s.execute(
        select(Album.artist_id, Album.artwork_id)
        .where(Album.artist_id.in_(ids), Album.artwork_id.isnot(None))
        .order_by(Album.added_at.desc())
    ):
        covers.setdefault(artist_id, artwork_id)
    for artist_id, artwork_id in s.execute(
        select(Track.artist_id, Track.artwork_id).where(
            Track.artist_id.in_(ids), Track.artwork_id.isnot(None)
        )
    ):
        covers.setdefault(artist_id, artwork_id)
    return [
        _clean(
            {
                "id": a.id,
                "name": a.name,
                "artworkId": covers.get(a.id),
                "albumCount": album_counts.get(a.id, 0),
                "trackCount": track_counts.get(a.id, 0),
            }
        )
        for a in artists
    ]


def owner_name(caller: Caller, owner_id: str) -> str:
    # M2 brings people with names; in M1 every playlist belongs to the one user.
    return caller.display_name if owner_id == caller.user_id else "Family"


def playlist_summaries(s: Session, caller: Caller, playlists: Sequence[Playlist]) -> list[dict]:
    ids = [p.id for p in playlists]
    if not ids:
        return []
    counts = {
        pid: (n, int(d or 0))
        for pid, n, d in s.execute(
            select(
                PlaylistItem.playlist_id, func.count(PlaylistItem.id), func.sum(Track.duration_ms)
            )
            .join(Track, Track.id == PlaylistItem.track_id)
            .where(PlaylistItem.playlist_id.in_(ids))
            .group_by(PlaylistItem.playlist_id)
        )
    }
    mosaics: dict[str, list[str]] = {pid: [] for pid in ids}
    rows = s.execute(
        select(PlaylistItem.playlist_id, Album.artwork_id)
        .join(Track, Track.id == PlaylistItem.track_id)
        .join(Album, Album.id == Track.album_id)
        .where(PlaylistItem.playlist_id.in_(ids), Album.artwork_id.isnot(None))
        .order_by(PlaylistItem.playlist_id, PlaylistItem.position)
    )
    for pid, art in rows:
        m = mosaics[pid]
        if art not in m and len(m) < 4:
            m.append(art)
    return [
        {
            "id": p.id,
            "name": p.name,
            "ownerName": owner_name(caller, p.owner_id),
            "mine": p.owner_id == caller.user_id,
            "shared": p.shared,
            "trackCount": counts.get(p.id, (0, 0))[0],
            "durationMs": counts.get(p.id, (0, 0))[1],
            "artworkIds": mosaics[p.id],
            "updatedAt": iso(p.updated_at),
        }
        for p in playlists
    ]


def playlist_detail(s: Session, caller: Caller, p: Playlist) -> dict[str, Any]:
    body = playlist_summaries(s, caller, [p])[0]
    rows = s.execute(
        select(PlaylistItem, Track)
        .join(Track, Track.id == PlaylistItem.track_id)
        .where(PlaylistItem.playlist_id == p.id)
        .order_by(PlaylistItem.position)
    ).all()
    tracks = track_summaries(s, caller, [t for _, t in rows])
    body["items"] = [
        {"itemId": item.id, "track": tr, "addedAt": iso(item.added_at)}
        for (item, _), tr in zip(rows, tracks, strict=True)
    ]
    return body
