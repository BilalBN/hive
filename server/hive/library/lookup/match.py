"""How sure Hive is that an online album or film is the one at home.

An album matches a MusicBrainz release when the titles agree, the artist
agrees (or the album is a soundtrack of many singers), and the songs line up
by title or length. Titles are compared by name key, English spelling of
Indian scripts and sound key, so "മലരേ" at home meets "Malare" online.

Scores run 0-1. FOUND is applied by itself; REVIEW waits for the admin.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from hive.library import text as T
from hive.library.lookup.sources import Film, MbRelease
from hive.library.translit import romanise

FOUND = 0.75
REVIEW = 0.45

# "(Original Motion Picture Soundtrack)", "- OST", "[Deluxe Edition]"…
_NOISE = re.compile(
    r"\s*[\(\[\-–:]\s*(original\s+)?(motion\s+picture\s+)?(sound\s*track|ost|music\s+from.*|"
    r"(deluxe|expanded|remastered|special|anniversary)(\s+edition)?|from\s+the\s+.*)[\)\]]?\s*$",
    re.IGNORECASE,
)


def clean_title(title: str) -> str:
    previous = None
    while previous != title:
        previous = title
        title = _NOISE.sub("", title).strip()
    return title or previous or ""


def keys(text: str | None) -> set[str]:
    """Ways a title can be written: name key, English spelling, sound keys."""
    if not text:
        return set()
    base = clean_title(text)
    out = {T.name_key(base)}
    roman = " ".join(romanise(base))
    if roman:
        out.add(T.name_key(roman))
    for k in list(out):
        out.add(" ".join(T.phonetic(w) for w in k.split()))
    # "മലരേ (Malare)": either half alone is the title too.
    for part in re.split(r"[()\[\]]", text):
        if part.strip() and part.strip() != text.strip():
            out |= {T.name_key(part), " ".join(T.phonetic(w) for w in T.name_key(part).split())}
    out.discard("")
    out.discard("unknown")
    return out


def title_similarity(a: str | None, b: str | None) -> float:
    ka, kb = keys(a), keys(b)
    if not ka or not kb:
        return 0.0
    if ka & kb:
        return 1.0
    wa = {w for k in ka for w in k.split()}
    wb = {w for k in kb for w in k.split()}
    if not wa or not wb:
        return 0.0
    return len(wa & wb) / len(wa | wb)


@dataclass
class HomeTrack:
    title: str
    duration_ms: int
    track_no: int | None
    disc_no: int | None
    artist: str


@dataclass
class HomeAlbum:
    id: str
    title: str
    artist: str
    year: int | None
    language: str | None
    title_from_tags: bool
    tracks: list[HomeTrack] = field(default_factory=list)


def pair_tracks(album: HomeAlbum, release: MbRelease) -> dict[int, int]:
    """Our track index → release track index, by title, then by length and number."""
    pairs: dict[int, int] = {}
    used: set[int] = set()
    for i, t in enumerate(album.tracks):
        best, best_score = None, 0.0
        for j, rt in enumerate(release.tracks):
            if j in used:
                continue
            score = title_similarity(t.title, rt.title)
            if rt.length_ms and t.duration_ms and abs(rt.length_ms - t.duration_ms) <= 3000:
                score += 0.4
            if t.track_no and t.track_no == rt.position and (t.disc_no or 1) == rt.disc:
                score += 0.2
            if score > best_score:
                best, best_score = j, score
        if best is not None and best_score >= 0.8:
            pairs[i] = best
            used.add(best)
    return pairs


def release_score(album: HomeAlbum, release: MbRelease) -> float:
    title = title_similarity(album.title, release.title)
    various = T.name_key(album.artist) in ("various artists", "various")
    artist = 1.0 if various else title_similarity(album.artist, release.artist)
    if not various and artist < 1.0:
        # A track artist or the composer credited as the album artist still counts.
        names = {T.name_key(t.artist) for t in album.tracks} | {T.name_key(album.artist)}
        rel_names = {T.name_key(n) for rt in release.tracks for n in rt.artists}
        rel_names |= {T.name_key(n) for n in release.composers}
        rel_names.add(T.name_key(release.artist))
        if names & rel_names:
            artist = max(artist, 0.8)
    if release.tracks:
        paired = len(pair_tracks(album, release))
        songs = paired / max(1, len(album.tracks))
        if len(album.tracks) > release.track_count:
            songs *= 0.7  # more songs at home than on the release
    else:
        # Search results carry no track list: judge by count only.
        n, m = len(album.tracks), release.track_count
        songs = 1.0 if n == m else 0.7 if 0 < n <= m else 0.3
    year = 0.5
    if album.year and release.year:
        year = 1.0 if abs(album.year - release.year) <= 1 else 0.0
    score = 0.35 * title + 0.2 * artist + 0.35 * songs + 0.1 * year
    if title < 0.5:
        score = min(score, 0.4)  # a different album with similar songs isn't this one
    return round(min(1.0, score), 3)


def film_score(album: HomeAlbum, film: Film, language_qid: str | None) -> float:
    names = [film.title, *film.aliases]
    title = max((title_similarity(album.title, n) for n in names), default=0.0)
    if title < 1.0:
        return round(title * 0.4, 3)
    score = 0.6
    if album.year and film.year:
        score += 0.3 if abs(album.year - film.year) <= 1 else -0.4
    if language_qid and film.language_qids:
        score += 0.2 if language_qid in film.language_qids else -0.3
    elif not album.year:
        score -= 0.1
    return round(max(0.0, min(1.0, score)), 3)
