"""Songs with no album tag, looked up one by one.

Downloaded songs often arrive as loose files in folders like "English" or
"New", named "Ee_Puzhayum_-Vijay_Yesudas[www.Mp3MaD.Com].mp3". As an album
they match nothing. Here each song is cleaned of website clutter, split into
singer and title, and found as a MusicBrainz recording, so it can join its
real album with its real cover.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from hive.library import languages as L
from hive.library import text as T
from hive.library.lookup.match import title_similarity
from hive.library.lookup.sources import MbSong, MbSongRelease

# A song is applied by itself at this score (0-1); below it, it stays as it is.
SURE = 0.8

_DOMAIN = re.compile(
    r"(?:www\.)?\w+(?:-\w+)*\.(?:com|net|org|in|me|co|info|cc|pk|io|fm|to|ws|biz|mobi|site|xyz)\b",
    re.IGNORECASE,
)
# Bracketed clutter: sites, sizes, "Official Video", "320kbps", "Lyrics"…
_JUNK_BRACKET = re.compile(
    r"[\(\[\{][^\)\]\}]*(?:www|\.com|\.in|\.me|kbps|\d{3,4}\s*[x×]\s*\d{3,4}|\bhd\b|\bhq\b|"
    r"official|video|lyric|audio|full\s*song|mp3|download)[^\)\]\}]*[\)\]\}]",
    re.IGNORECASE,
)
_JUNK_WORDS = re.compile(
    r"\b(?:official\s+(?:music\s+)?(?:video|audio)|lyrical\s+video|lyric(?:s)?\s+video|"
    r"full\s+(?:video\s+)?song|video\s+song|audio\s+song|hd|hq|320\s*kbps|128\s*kbps)\b",
    re.IGNORECASE,
)
# "-mc", "_-_", trailing dashes and dots left behind.
_TRAILING = re.compile(r"(?:[_\-–.]+(?:mc|www))?[\s_\-–.|]*$", re.IGNORECASE)
_SEPARATORS = re.compile(r"\s*(?:\s[-–]\s|\s?--+\s?|_-_|\s-(?=\S)|(?<=\S)-\s|(?<=[)\]])-|\|)\s*")

# Folder names that say nothing about the singer.
_GENERIC = {
    "uploads", "upload", "new", "songs", "song", "music", "mp3", "mp3s", "downloads",
    "download", "misc", "other", "others", "old", "latest", "hits", "favourites",
    "favorites", "unknown artist", "unknown album", "various", "various artists",
    "singles", "single", "playlist", "collection", "hive",
}  # fmt: skip


def _generic(name: str | None) -> bool:
    if not name:
        return True
    key = T.name_key(name)
    if key in _GENERIC:
        return True
    return any(key in (T.name_key(x.name), T.name_key(x.native)) for x in L.LANGUAGES.values())


def tidy(text: str) -> str:
    """A file name or tag without website clutter: "Ee_Puzhayum_-Vijay_Yesudas
    [www.Mp3MaD.Com]" → "Ee Puzhayum -Vijay Yesudas"."""
    out = re.sub(r"_{2,}", " | ", text).replace("_", " ")
    out = _JUNK_BRACKET.sub(" ", out)
    out = _DOMAIN.sub(" ", out)
    out = _JUNK_WORDS.sub(" ", out)
    out = re.sub(r"[\(\[\{]\s*[\)\]\}]", " ", out)  # brackets emptied above
    out = re.sub(r"\s{2,}", " ", out).strip()
    previous = None
    while previous != out:
        previous = out
        out = _TRAILING.sub("", out).strip()
    return out or text.strip()


@dataclass
class Query:
    title: str
    artist: str | None


def queries(title: str, artist: str | None, hints: list[str]) -> list[Query]:
    """Ways to ask for a song: the title as tagged, or split at a dash into
    singer and title (either way round), with singers from tags and folders."""
    clean = tidy(title)
    parts = [p for p in _SEPARATORS.split(clean) if p.strip()]
    artists = [a for a in [artist, *hints] if a and not _generic(a)]
    out: list[Query] = []

    def add(t: str, a: str | None) -> None:
        t = t.strip(" -–_.|")
        if a and T.name_key(a) == T.name_key(t):
            return
        if t and Query(t, a) not in out:
            out.append(Query(t, a))

    if len(parts) >= 2:
        first, rest = parts[0], " ".join(parts[1:])
        add(rest, first)  # "Ed Sheeran - Perfect"
        add(first, rest)  # "Perfect - Ed Sheeran"
        # "Pablo Neruda - If You Forget Me __ Spoken Poetry…": the middle part
        add(parts[1], first)
    for a in artists:
        add(parts[0] if len(parts) >= 2 else clean, a)
        add(clean, a)
    add(clean, None)
    return out[:6]


def _artist_similarity(a: str | None, b: str | None) -> float:
    if not a or not b:
        return 0.3  # unknown: neither for nor against
    ka, kb = T.name_key(a), T.name_key(b)
    if not ka or not kb:
        return 0.3
    if ka == kb or ka in kb or kb in ka:
        return 1.0
    wa, wb = set(ka.split()), set(kb.split())
    return len(wa & wb) / len(wa | wb)


def song_score(q: Query, duration_ms: int, song: MbSong) -> float:
    title = title_similarity(q.title, song.title)
    artist = _artist_similarity(q.artist, song.artist)
    if song.length_ms and duration_ms:
        diff = abs(song.length_ms - duration_ms) / 1000
        length = 1.0 if diff <= 3 else 0.6 if diff <= 10 else 0.0
    else:
        length = 0.5
    return round(0.5 * title + 0.3 * artist + 0.2 * length, 3)


_AVOID = {"compilation", "live", "dj-mix", "remix", "mixtape/street", "karaoke"}


def release_rank(r: MbSongRelease) -> tuple:
    """Lower is better: an official album first (a film's soundtrack counts),
    then a single or EP, earliest first; compilations and live albums last."""
    secondary = {t.lower() for t in r.secondary_types}
    primary = (r.primary_type or "").lower()
    return (
        1 if secondary & _AVOID else 0,
        0 if (r.status or "Official") == "Official" else 1,
        {"album": 0, "single": 1, "ep": 1}.get(primary, 2),
        r.year or 9999,
    )


def best_release(song: MbSong) -> MbSongRelease | None:
    """The album the song belongs to (see release_rank)."""
    return min(song.releases, key=release_rank) if song.releases else None


def pick(scored: list[tuple[MbSong, float]]) -> tuple[MbSong | None, float]:
    """The song to use among the matches. A hit song exists as many
    recordings (album, single, radio edit, each compilation); among the ones
    that match about as well as the best, the one on a real album wins."""
    if not scored:
        return None, 0.0
    top = max(score for _s, score in scored)
    close = [(s, sc) for s, sc in scored if sc >= top - 0.05 and s.releases]
    if not close:
        return max(scored, key=lambda x: x[1])
    return min(close, key=lambda x: (release_rank(best_release(x[0])), -x[1]))


def found_record(song: MbSong, release: MbSongRelease | None) -> dict:
    """What's kept on the song (Track.lookup) and applied over its tags."""
    body: dict = {"title": song.title, "artist": song.artist, "recording": song.id}
    if release is not None:
        body |= {
            "album": release.title,
            "albumArtist": release.artist or song.artist,
            "release": release.id,
        }
        if release.year:
            body["year"] = release.year
        if release.release_group_id:
            body["releaseGroup"] = release.release_group_id
    return body
