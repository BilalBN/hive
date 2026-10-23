"""The online sources and what Hive reads from each.

- MusicBrainz: albums (releases), their songs, artists, composers, lyricists,
  language and type (soundtrack, compilation…).
- Cover Art Archive: the album's front cover.
- Wikidata: the film behind a soundtrack: its year, director, cast, music
  director and original language.
- AcoustID: songs recognised by a fingerprint of their sound, for files with
  no useful tags (needs a free application key).

Everything here only parses; deciding what fits an album is in match.py.
"""

from __future__ import annotations

import json
import logging
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from hive.library.lookup.http import Http, Offline

log = logging.getLogger("hive.lookup")

MB = "https://musicbrainz.org/ws/2"
CAA = "https://coverartarchive.org"
WIKIDATA = "https://www.wikidata.org/w/api.php"
ACOUSTID = "https://api.acoustid.org/v2/lookup"
LRCLIB = "https://lrclib.net/api"

FILM_TYPES = {"Q11424", "Q24869", "Q202866", "Q506240", "Q229390", "Q24862", "Q93204"}


# ------------------------------------------------------------------ shapes


@dataclass
class MbTrack:
    position: int
    disc: int
    title: str
    length_ms: int | None
    recording_id: str | None
    artists: list[str] = field(default_factory=list)
    composers: list[str] = field(default_factory=list)
    lyricists: list[str] = field(default_factory=list)


@dataclass
class MbRelease:
    id: str
    title: str
    artist: str
    year: int | None
    language: str | None  # ISO 639-3, as MusicBrainz gives it
    release_group_id: str | None
    primary_type: str | None
    secondary_types: list[str]
    track_count: int
    score: int = 0  # MusicBrainz's own search score, 0-100
    tracks: list[MbTrack] = field(default_factory=list)
    composers: list[str] = field(default_factory=list)  # release-level credits
    lyricists: list[str] = field(default_factory=list)

    @property
    def kind(self) -> str:
        secondary = {t.lower() for t in self.secondary_types}
        if "soundtrack" in secondary:
            return "soundtrack"
        if "compilation" in secondary:
            return "compilation"
        if "live" in secondary:
            return "live"
        primary = (self.primary_type or "").lower()
        return {"album": "album", "single": "single", "ep": "ep"}.get(primary, "other")


@dataclass
class Film:
    qid: str
    title: str
    year: int | None
    language_qids: list[str] = field(default_factory=list)
    directors: list[str] = field(default_factory=list)
    cast: list[str] = field(default_factory=list)
    composers: list[str] = field(default_factory=list)
    aliases: list[str] = field(default_factory=list)


def _year(date: str | None) -> int | None:
    m = re.match(r"\+?(\d{4})", date or "")
    return int(m.group(1)) if m else None


def _credit_name(credits: list[dict[str, Any]] | None) -> str:
    return "".join(c.get("name", "") + c.get("joinphrase", "") for c in credits or []).strip()


def _credit_people(credits: list[dict[str, Any]] | None) -> list[str]:
    return [c.get("name") or c.get("artist", {}).get("name", "") for c in credits or []]


def _lucene(text: str) -> str:
    return re.sub(r'([+\-&|!(){}\[\]^"~*?:\\/])', r"\\\1", text)


# ------------------------------------------------------------------ MusicBrainz


def mb_search(http: Http, title: str, artist: str | None, limit: int = 5) -> list[MbRelease]:
    q = f'release:"{_lucene(title)}"'
    if artist:
        q += f' AND artist:"{_lucene(artist)}"'
    data = http.json(f"{MB}/release/", query=q, fmt="json", limit=limit)
    out: list[MbRelease] = []
    for r in (data or {}).get("releases", []):
        out.append(_release_head(r))
    return out


def _release_head(r: dict[str, Any]) -> MbRelease:
    rg = r.get("release-group") or {}
    tr = r.get("text-representation") or {}
    count = r.get("track-count")
    if count is None:
        count = sum(m.get("track-count", 0) for m in r.get("media", []))
    return MbRelease(
        id=r["id"],
        title=r.get("title", ""),
        artist=_credit_name(r.get("artist-credit")),
        year=_year(r.get("date")),
        language=tr.get("language"),
        release_group_id=rg.get("id"),
        primary_type=rg.get("primary-type"),
        secondary_types=list(rg.get("secondary-types") or []),
        track_count=int(count or 0),
        score=int(r.get("score", 0) or 0),
    )


def mb_release(http: Http, release_id: str) -> MbRelease | None:
    data = http.json(
        f"{MB}/release/{release_id}",
        inc="recordings+artist-credits+release-groups+artist-rels"
        "+recording-level-rels+work-rels+work-level-rels",
        fmt="json",
    )
    if not data:
        return None
    rel = _release_head(data)
    rel.composers, rel.lyricists = _people_from_relations(data.get("relations"))
    for medium in data.get("media", []):
        disc = int(medium.get("position", 1) or 1)
        for t in medium.get("tracks", []):
            rec = t.get("recording") or {}
            composers: list[str] = []
            lyricists: list[str] = []
            for rr in rec.get("relations", []) or []:
                if rr.get("target-type") == "work" and rr.get("work"):
                    c, ly = _people_from_relations(rr["work"].get("relations"))
                    composers += c
                    lyricists += ly
            rel.tracks.append(
                MbTrack(
                    position=int(t.get("position", 0) or 0),
                    disc=disc,
                    title=t.get("title") or rec.get("title", ""),
                    length_ms=t.get("length") or rec.get("length"),
                    recording_id=rec.get("id"),
                    artists=_credit_people(t.get("artist-credit") or rec.get("artist-credit")),
                    composers=list(dict.fromkeys(composers)),
                    lyricists=list(dict.fromkeys(lyricists)),
                )
            )
    rel.track_count = rel.track_count or len(rel.tracks)
    return rel


def _people_from_relations(rels: list[dict[str, Any]] | None) -> tuple[list[str], list[str]]:
    composers: list[str] = []
    lyricists: list[str] = []
    for r in rels or []:
        if r.get("target-type") != "artist" or not r.get("artist"):
            continue
        name = r["artist"].get("name")
        kind = (r.get("type") or "").lower()
        if kind in ("composer", "writer", "music"):
            composers.append(name)
        elif kind in ("lyricist", "librettist"):
            lyricists.append(name)
    return list(dict.fromkeys(composers)), list(dict.fromkeys(lyricists))


def mb_release_group_wikidata(http: Http, release_group_id: str) -> str | None:
    data = http.json(f"{MB}/release-group/{release_group_id}", inc="url-rels", fmt="json")
    for r in (data or {}).get("relations", []) or []:
        if r.get("type") == "wikidata":
            m = re.search(r"(Q\d+)$", (r.get("url") or {}).get("resource", ""))
            if m:
                return m.group(1)
    return None


# ------------------------------------------------------------------ Cover Art Archive


def cover_art(http: Http, release_id: str, release_group_id: str | None) -> bytes | None:
    for path in (
        f"release/{release_id}/front-500",
        f"release-group/{release_group_id}/front-500" if release_group_id else None,
    ):
        if not path:
            continue
        try:
            r = http.request("GET", f"{CAA}/{path}", headers={"Accept": "image/*"})
        except Offline as e:
            # The images live on archive.org, whose servers sometimes fail one
            # file for hours. The album's other details still count; "Look up
            # again" fetches the cover later.
            log.info("cover not downloaded: %s", e)
            return None
        if r is not None and r.headers.get("content-type", "").startswith("image/"):
            return r.content
    return None


# ------------------------------------------------------------------ Wikidata


def _claim_ids(entity: dict[str, Any], prop: str) -> list[str]:
    out = []
    for c in entity.get("claims", {}).get(prop, []) or []:
        if c.get("rank") == "deprecated":
            continue
        v = ((c.get("mainsnak") or {}).get("datavalue") or {}).get("value")
        if isinstance(v, dict) and v.get("id"):
            out.append(v["id"])
    return out


def _claim_year(entity: dict[str, Any], prop: str) -> int | None:
    years = []
    for c in entity.get("claims", {}).get(prop, []) or []:
        v = ((c.get("mainsnak") or {}).get("datavalue") or {}).get("value")
        if isinstance(v, dict) and v.get("time"):
            y = _year(v["time"])
            if y:
                years.append(y)
    return min(years) if years else None


def _label(entity: dict[str, Any]) -> str | None:
    labels = entity.get("labels") or {}
    if "en" in labels:
        return labels["en"]["value"]
    for v in labels.values():
        return v["value"]
    return None


def wikidata_entities(http: Http, ids: list[str], props: str) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for i in range(0, len(ids), 50):
        data = http.json(
            WIKIDATA,
            action="wbgetentities",
            ids="|".join(ids[i : i + 50]),
            props=props,
            languages="en|ml|hi|ta|te|kn|bn",
            languagefallback="1",
            format="json",
        )
        out.update((data or {}).get("entities", {}) or {})
    return out


def wikidata_search(http: Http, text: str, limit: int = 10) -> list[dict[str, Any]]:
    data = http.json(
        WIKIDATA,
        action="wbsearchentities",
        search=text,
        language="en",
        uselang="en",
        type="item",
        limit=limit,
        format="json",
    )
    return list((data or {}).get("search", []) or [])


def wikidata_films(http: Http, ids: list[str]) -> list[Film]:
    """The films among [ids], with director, cast and music director named."""
    entities = wikidata_entities(http, ids, "claims|labels|aliases")
    films: list[Film] = []
    people: set[str] = set()
    for qid in ids:
        e = entities.get(qid)
        if not e or not FILM_TYPES & set(_claim_ids(e, "P31")):
            continue
        aliases = [a["value"] for vals in (e.get("aliases") or {}).values() for a in vals]
        f = Film(
            qid=qid,
            title=_label(e) or "",
            year=_claim_year(e, "P577"),
            language_qids=_claim_ids(e, "P364"),
            directors=_claim_ids(e, "P57"),
            cast=_claim_ids(e, "P161")[:8],
            composers=_claim_ids(e, "P86"),
            aliases=aliases,
        )
        people |= {*f.directors, *f.cast, *f.composers}
        films.append(f)
    if people:
        names = {q: _label(e) for q, e in wikidata_entities(http, sorted(people), "labels").items()}
        for f in films:
            f.directors = [n for q in f.directors if (n := names.get(q))]
            f.cast = [n for q in f.cast if (n := names.get(q))]
            f.composers = [n for q in f.composers if (n := names.get(q))]
    return films


# ------------------------------------------------------------------ AcoustID


def find_fpcalc() -> str | None:
    from hive.config import bundled_tool

    bundled = bundled_tool("fpcalc")
    if bundled:
        return str(bundled)
    for candidate in ("fpcalc", "/opt/homebrew/bin/fpcalc", "/usr/local/bin/fpcalc"):
        found = shutil.which(candidate)
        if found:
            return found
    return None


def fingerprint(fpcalc: str, path: Path) -> tuple[int, str] | None:
    try:
        out = subprocess.run(
            [fpcalc, "-json", "-length", "120", str(path)],
            capture_output=True,
            timeout=60,
            check=True,
        ).stdout
        data = json.loads(out)
        return int(round(float(data["duration"]))), str(data["fingerprint"])
    except (OSError, subprocess.SubprocessError, ValueError, KeyError) as e:
        log.info("couldn't fingerprint %s: %s", path.name, e)
        return None


class AcoustIdRefused(Exception):
    """AcoustID answered with an error, such as a key it doesn't know."""


def _acoustid(http: Http, key: str, duration: int, fp: str) -> dict[str, Any]:
    r = http.request(
        "POST",
        ACOUSTID,
        keep_errors=True,
        data={
            "client": key,
            "duration": str(duration),
            "fingerprint": fp,
            "meta": "recordings releaseids",
        },
    )
    if r is None:
        raise AcoustIdRefused("AcoustID didn't answer")
    try:
        data = r.json()
    except ValueError:
        raise AcoustIdRefused(f"AcoustID answered HTTP {r.status_code}") from None
    if data.get("status") != "ok":
        err = data.get("error") or {}
        if err.get("code") == 4:
            raise AcoustIdRefused(
                "AcoustID doesn't accept this key. Hive needs an application key, "
                "not the key for your own account: register an application at "
                "acoustid.org/new-application (any name, such as Hive) and paste "
                "the API key it shows for that application"
            )
        raise AcoustIdRefused(f"AcoustID said: {err.get('message') or 'error'}")
    return data


def acoustid_releases(http: Http, key: str, duration: int, fp: str) -> list[tuple[str, float]]:
    """(release id, score) for the recordings this fingerprint matches.
    AcoustIdRefused when AcoustID turns the request down."""
    data = _acoustid(http, key, duration, fp)
    out: list[tuple[str, float]] = []
    for res in data.get("results", []) or []:
        score = float(res.get("score", 0))
        for rec in res.get("recordings", []) or []:
            for rel in rec.get("releases", []) or []:
                if rel.get("id"):
                    out.append((rel["id"], score))
    return out


# ------------------------------------------------------------------ songs


@dataclass
class MbSongRelease:
    id: str
    title: str
    artist: str | None
    year: int | None
    status: str | None
    release_group_id: str | None
    primary_type: str | None
    secondary_types: list[str]


@dataclass
class MbSong:
    """A MusicBrainz recording: one song, and the releases it's on."""

    id: str
    title: str
    artist: str
    length_ms: int | None
    score: int  # MusicBrainz's search score, 0-100 (100 for a direct lookup)
    releases: list[MbSongRelease] = field(default_factory=list)


def _song(r: dict[str, Any], score: int | None = None) -> MbSong:
    releases = []
    for rel in r.get("releases") or []:
        rg = rel.get("release-group") or {}
        releases.append(
            MbSongRelease(
                id=rel["id"],
                title=rel.get("title", ""),
                artist=_credit_name(rel.get("artist-credit")) or None,
                year=_year(rel.get("date")),
                status=rel.get("status"),
                release_group_id=rg.get("id"),
                primary_type=rg.get("primary-type"),
                secondary_types=list(rg.get("secondary-types") or []),
            )
        )
    return MbSong(
        id=r["id"],
        title=r.get("title", ""),
        artist=_credit_name(r.get("artist-credit")),
        length_ms=r.get("length"),
        score=int(r.get("score", 0) if score is None else score),
        releases=releases,
    )


def mb_recordings(http: Http, title: str, artist: str | None, limit: int = 8) -> list[MbSong]:
    """Songs called [title] (by [artist]), with the releases each is on."""
    q = f'recording:"{_lucene(title)}"'
    if artist:
        q += f' AND artist:"{_lucene(artist)}"'
    data = http.json(f"{MB}/recording/", query=q, fmt="json", limit=limit)
    return [_song(r) for r in (data or {}).get("recordings", []) if r.get("id")]


def mb_recording(http: Http, recording_id: str) -> MbSong | None:
    data = http.json(
        f"{MB}/recording/{recording_id}", inc="releases+artist-credits+release-groups", fmt="json"
    )
    return _song(data, score=100) if data and data.get("id") else None


def acoustid_recordings(http: Http, key: str, duration: int, fp: str) -> list[tuple[str, float]]:
    """(recording id, score) for the songs this fingerprint matches.
    AcoustIdRefused when AcoustID turns the request down."""
    data = _acoustid(http, key, duration, fp)
    out: list[tuple[str, float]] = []
    for res in data.get("results", []) or []:
        score = float(res.get("score", 0))
        for rec in res.get("recordings", []) or []:
            if rec.get("id"):
                out.append((rec["id"], score))
    return out


# ------------------------------------------------------------------ LRCLIB


def lrclib_lyrics(
    http: Http, title: str, artist: str, album: str | None, duration_s: int
) -> str | None:
    """Lyrics from LRCLIB (an open, free lyrics database): timed when it has
    them. None when it doesn't know the song or it's an instrumental."""
    params: dict[str, Any] = {"track_name": title, "artist_name": artist, "duration": duration_s}
    if album:
        params["album_name"] = album
    data = http.json(f"{LRCLIB}/get", **params)
    if not data:
        # Looser: any version of the song within a few seconds of this one.
        hits = http.json(f"{LRCLIB}/search", track_name=title, artist_name=artist) or []
        close = [
            h
            for h in hits
            if isinstance(h, dict) and abs(float(h.get("duration") or 0) - duration_s) <= 3
        ]
        data = close[0] if close else None
    if not data or data.get("instrumental"):
        return None
    return (data.get("syncedLyrics") or data.get("plainLyrics") or "").strip() or None
