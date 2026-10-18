"""The real MusicBrainz, Cover Art Archive and Wikidata, read the way Hive
reads them. Skipped unless HIVE_LIVE_LOOKUP=1 (CI runs it in its own job, so
an outage of those services never blocks a build)."""

from __future__ import annotations

import os

import pytest

from hive.library.lookup import match as M
from hive.library.lookup import sources as S
from hive.library.lookup.http import Http

pytestmark = pytest.mark.skipif(
    os.environ.get("HIVE_LIVE_LOOKUP") != "1", reason="set HIVE_LIVE_LOOKUP=1 to use the internet"
)


@pytest.fixture(scope="module")
def http() -> Http:
    return Http()


def test_musicbrainz_album_tracks_and_cover(http: Http) -> None:
    heads = S.mb_search(http, "Kind of Blue", "Miles Davis")
    assert heads, "no search results"
    home = M.HomeAlbum(
        "x", "Kind of Blue", "Miles Davis", 1959, None, True,
        [M.HomeTrack("So What", 562_000, 1, 1, "Miles Davis"),
         M.HomeTrack("Freddie Freeloader", 586_000, 2, 1, "Miles Davis")],
    )  # fmt: skip
    best = None
    for head in heads[:3]:
        full = S.mb_release(http, head.id)
        if full and (best is None or M.release_score(home, full) > M.release_score(home, best)):
            best = full
    assert best is not None
    assert M.release_score(home, best) >= M.FOUND, (best.title, best.tracks[:3])
    assert any(t.title == "So What" for t in best.tracks)
    assert best.year and best.year >= 1959
    cover = S.cover_art(http, best.id, best.release_group_id)
    assert cover and len(cover) > 1000


def test_musicbrainz_soundtrack_credits(http: Http) -> None:
    heads = S.mb_search(http, "Roja", "A.R. Rahman")
    assert any(h.kind == "soundtrack" for h in heads), [(h.title, h.kind) for h in heads]


def test_wikidata_film_with_cast(http: Http) -> None:
    hits = S.wikidata_search(http, "Premam")
    ids = [h["id"] for h in hits if "film" in (h.get("description") or "").lower()]
    films = S.wikidata_films(http, ids)
    premam = [f for f in films if f.year == 2015]
    assert premam, [(f.title, f.year) for f in films]
    f = premam[0]
    assert "Q36236" in f.language_qids  # Malayalam
    assert any("Nivin" in name for name in f.cast), f.cast
    assert f.directors, "director"
    home = M.HomeAlbum("x", "Premam", "Rajesh Murugesan", 2015, "ml", True, [])
    assert M.film_score(home, f, "Q36236") >= M.FOUND
