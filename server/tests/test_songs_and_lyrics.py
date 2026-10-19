"""Loose downloaded songs found one by one; lyrics from Hive Admin and LRCLIB;
Home's rows for a person who has played a few things."""

from __future__ import annotations

import os
import time
from collections.abc import Iterator
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest
from fastapi.testclient import TestClient

from hive.app import create_app
from hive.config import Settings
from hive.library.lookup.http import Http
from hive.library.lookup.songs import best_release, queries, tidy
from hive.library.lookup.sources import MbSong, MbSongRelease

from .audio_fixtures import FFMPEG, _tone, cover_png
from .conftest import Home, assert_matches, needs_ffmpeg
from .test_lookup import _artist

PERFECT_LRC = "[00:00.50]I found a love for me\n[00:02.00]Darling, just dive right in\n"

DIVIDE_RELEASE = {
    "id": "rel-divide",
    "title": "÷",
    "artist-credit": [_artist("Ed Sheeran")],
    "date": "2017-03-03",
    "text-representation": {"language": "eng"},
    "release-group": {"id": "rg-divide", "primary-type": "Album", "secondary-types": []},
    "track-count": 1,
    "media": [
        {
            "position": 1,
            "tracks": [
                {
                    "position": 5,
                    "title": "Perfect",
                    "length": 3000,
                    "artist-credit": [_artist("Ed Sheeran")],
                    "recording": {"id": "rec-perfect", "title": "Perfect"},
                }
            ],
        }  # fmt: skip
    ],
}
PERFECT = {
    "id": "rec-perfect",
    "score": 100,
    "title": "Perfect",
    "length": 3000,
    "artist-credit": [_artist("Ed Sheeran")],
    "releases": [
        {
            "id": "rel-now",
            "title": "Now That's What I Call Music! 97",
            "status": "Official",
            "date": "2017-07-21",
            "release-group": {
                "id": "rg-now",
                "primary-type": "Album",
                "secondary-types": ["Compilation"],
            },
        },  # fmt: skip
        {
            "id": "rel-divide",
            "title": "÷",
            "status": "Official",
            "date": "2017-03-03",
            "artist-credit": [_artist("Ed Sheeran")],
            "release-group": {"id": "rg-divide", "primary-type": "Album", "secondary-types": []},
        },
    ],
}


class SongsInternet:
    def __init__(self) -> None:
        self.requests: list[str] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        url = urlsplit(str(request.url))
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        self.requests.append(f"{url.hostname}{url.path}?{url.query}")
        if url.hostname == "musicbrainz.org":
            if url.path == "/ws/2/recording/":
                query = q["query"]
                if 'recording:"Perfect"' in query and "Ed Sheeran" in query:
                    return httpx.Response(200, json={"recordings": [PERFECT]})
                return httpx.Response(200, json={"recordings": []})
            if url.path == "/ws/2/release/rel-divide":
                return httpx.Response(200, json=DIVIDE_RELEASE)
            if url.path == "/ws/2/release/":
                return httpx.Response(200, json={"releases": []})
            return httpx.Response(200, json={"relations": []})
        if url.hostname == "coverartarchive.org" and "rel-divide" in url.path:
            return httpx.Response(
                200, content=cover_png((30, 120, 200)), headers={"content-type": "image/png"}
            )
        if url.hostname == "www.wikidata.org":
            return httpx.Response(200, json={"search": [], "entities": {}})
        if url.hostname == "lrclib.net" and url.path == "/api/get":
            if q.get("track_name") == "Perfect" and q.get("artist_name") == "Ed Sheeran":
                return httpx.Response(
                    200, json={"syncedLyrics": PERFECT_LRC, "plainLyrics": "x", "duration": 3}
                )
            return httpx.Response(404, json={"message": "not found"})
        if url.hostname == "lrclib.net" and url.path == "/api/search":
            return httpx.Response(200, json=[])
        return httpx.Response(404)


@pytest.fixture
def internet() -> SongsInternet:
    return SongsInternet()


@pytest.fixture
def loose_home(settings: Settings, internet: SongsInternet) -> Iterator[Home]:
    if FFMPEG is None:
        pytest.skip("FFmpeg is not installed")
    music = settings.music_folders[0]
    folder = music / "Uploads" / "English"
    paths = {
        "perfect": folder / "Ed_Sheeran_-_Perfect[www.Mp3MaD.Com].mp3",
        "kiss": folder / "Kiss me.mp3",
    }
    _tone(paths["perfect"], 500, 3, ["-c:a", "libmp3lame", "-b:a", "128k"])
    _tone(paths["kiss"], 610, 2, ["-c:a", "libmp3lame", "-b:a", "128k"])
    old = time.time() - 600
    for p in paths.values():
        os.utime(p, (old, old))
    http = Http(transport=httpx.MockTransport(internet))
    http.spacing = {}
    with TestClient(create_app(settings, lookup_http=http)) as c:
        h = Home(c, paths, music)
        h.wait()
        yield h


def _albums(home: Home) -> dict[str, dict]:
    body = home.get("/api/v1/library/albums", params={"limit": 500}).json()
    return {a["title"]: a for a in body["items"]}


def _look_up(home: Home) -> None:
    lookup = home.client.app.state.lookup
    lookup.configure(enabled=True)
    for _ in range(3):  # the song moves album, and its new album is looked up
        lookup.run_until_idle()
        home.wait()


# ------------------------------------------------------------------ cleaning


def test_website_clutter_is_tidied() -> None:
    assert tidy("Ee_Puzhayum_-Vijay_Yesudas[www.Mp3MaD.Com]") == "Ee Puzhayum -Vijay Yesudas"
    tomorrow = "If Tomorrow Starts Without Me"
    assert tidy(f"{tomorrow} ( 720 X 1280 )-mc") == tomorrow
    assert tidy("Ee Puzhayum (Unplugged)-Vijay Yesudas--Raag.Me--") == (
        "Ee Puzhayum (Unplugged)-Vijay Yesudas"
    )
    assert tidy("Malare (Official Video) 320kbps") == "Malare"
    assert tidy("Mr. Brightside") == "Mr. Brightside"


def test_a_dash_splits_singer_and_title_either_way() -> None:
    asked = [(q.title, q.artist) for q in queries("Ed Sheeran - Perfect", None, ["English"])]
    assert ("Perfect", "Ed Sheeran") in asked and ("Ed Sheeran", "Perfect") in asked
    # A language or "Uploads" folder says nothing about the singer.
    assert all(a != "English" for _t, a in asked)
    asked = [(q.title, q.artist) for q in queries("A Sky Full Of Stars", None, ["Coldplay"])]
    assert asked[0] == ("A Sky Full Of Stars", "Coldplay")


def test_the_real_album_beats_compilations() -> None:
    def rel(i: str, kind: str, year: int, *secondary: str) -> MbSongRelease:
        return MbSongRelease(i, i, None, year, "Official", None, kind, list(secondary))

    song = MbSong("r", "Perfect", "Ed Sheeran", 263000, 100, [
        rel("now", "Album", 2017, "Compilation"),
        rel("single", "Single", 2017),
        rel("divide", "Album", 2017),
        rel("deluxe", "Album", 2018),
    ])  # fmt: skip
    assert best_release(song).id == "divide"


# ------------------------------------------------------------------ songs


@needs_ffmpeg
def test_loose_songs_are_found_one_by_one(loose_home: Home) -> None:
    home = loose_home
    assert "English" in _albums(home)
    _look_up(home)

    albums = _albums(home)
    assert "÷" in albums, albums.keys()
    divide = home.get(f"/api/v1/library/albums/{albums['÷']['id']}").json()
    assert divide["artistName"] == "Ed Sheeran"
    assert [t["title"] for t in divide["tracks"]] == ["Perfect"]
    assert divide["tracks"][0]["artistName"] == "Ed Sheeran"
    assert divide["artworkId"]  # the cover came with it
    # Kiss me wasn't found: it stays where it was.
    english = home.get(f"/api/v1/library/albums/{albums['English']['id']}").json()
    assert [t["title"] for t in english["tracks"]] == ["Kiss me"]
    admin = home.get(f"/api/v1/admin/library/albums/{albums['English']['id']}").json()
    assert "1 of 2" in admin["lookupNote"]

    # A rescan keeps the song where the lookup put it.
    home.client.app.state.library.enqueue(home.paths["perfect"], force=True)
    home.wait()
    assert "÷" in _albums(home)


# ------------------------------------------------------------------ lyrics


@needs_ffmpeg
def test_lyrics_found_online_then_set_in_admin(loose_home: Home) -> None:
    home = loose_home
    _look_up(home)
    lookup = home.client.app.state.lookup
    lookup.run_lyrics_until_idle()

    perfect = home.track_id("Perfect")
    lyrics = home.get(f"/api/v1/media/tracks/{perfect}/lyrics").json()
    assert lyrics["kind"] == "synced"
    assert lyrics["lines"][0] == {"timeMs": 500, "text": "I found a love for me"}
    admin = home.get(f"/api/v1/admin/library/tracks/{perfect}/lyrics").json()
    assert_matches(admin, "AdminLyrics")
    assert admin["source"] == "online" and admin["fileHasLyrics"] is False

    # Typed in Hive Admin: plain lines win over what was found online.
    r = home.put(
        f"/api/v1/admin/library/tracks/{perfect}/lyrics",
        json={"text": "My own words\nSecond line"},
    )
    assert r.status_code == 200 and r.json()["source"] == "admin"
    lyrics = home.get(f"/api/v1/media/tracks/{perfect}/lyrics").json()
    assert lyrics == {"kind": "plain", "lines": [{"text": "My own words"}, {"text": "Second line"}]}

    # Emptied: back to nothing kept by the admin; online is tried again.
    r = home.put(f"/api/v1/admin/library/tracks/{perfect}/lyrics", json={"text": ""})
    assert r.json()["source"] == "none"
    assert lookup.run_lyrics_until_idle() >= 1
    assert home.get(f"/api/v1/admin/library/tracks/{perfect}/lyrics").json()["source"] == "online"


@needs_ffmpeg
def test_find_lyrics_shows_them_without_saving(loose_home: Home) -> None:
    home = loose_home
    _look_up(home)
    perfect = home.track_id("Perfect")
    found = home.post(f"/api/v1/admin/library/tracks/{perfect}/lyrics/find").json()
    assert_matches(found, "LyricsFound")
    assert found["found"] is True and found["kind"] == "synced"
    assert "I found a love" in found["text"]
    assert home.get(f"/api/v1/admin/library/tracks/{perfect}/lyrics").json()["source"] == "none"
    kiss = home.track_id("Kiss me")
    found = home.post(f"/api/v1/admin/library/tracks/{kiss}/lyrics/find").json()
    assert found["found"] is False and "doesn't have" in found["message"]


@needs_ffmpeg
def test_admin_lyrics_survive_a_rescan_and_file_lyrics_return(loose_home: Home) -> None:
    home = loose_home
    kiss = home.track_id("Kiss me")
    home.put(f"/api/v1/admin/library/tracks/{kiss}/lyrics", json={"text": "[00:01.00]La la"})
    home.client.app.state.library.enqueue(home.paths["kiss"], force=True)
    home.wait()
    track = next(
        t
        for t in home.get("/api/v1/library/tracks", params={"limit": 50}).json()["items"]
        if t["title"] == "Kiss me"
    )
    assert track["hasLyrics"] is True
    lyrics = home.get(f"/api/v1/media/tracks/{kiss}/lyrics").json()
    assert lyrics["lines"] == [{"timeMs": 1000, "text": "La la"}]


# ------------------------------------------------------------------ Home


@needs_ffmpeg
def test_home_rows_fill_in_as_you_listen(home: Home) -> None:
    body = home.get("/api/v1/library/home").json()
    assert_matches(body, "Home")
    assert body["recentlyPlayed"] == [] and body["onRepeat"] == []
    assert len(body["forYou"]) >= 3  # something to offer from the first day
    assert body["artists"]

    dreams = home.track_id("Dreams")
    for _ in range(3):
        r = home.post(
            f"/api/v1/media/tracks/{dreams}/stream",
            json={"quality": "lossless", "player": "other", "purpose": "play"},
        )
        assert r.status_code == 200, r.text
    body = home.get("/api/v1/library/home").json()
    assert [t["title"] for t in body["recentlyPlayed"]] == ["Dreams"]
    assert [t["title"] for t in body["onRepeat"]] == ["Dreams"]
    assert body["artists"][0]["name"] == "Fleetwood Mac"
    # Rumours was just played, so other albums come first in the picks.
    assert body["forYou"][0]["title"] != "Rumours"
    # The same picks all day.
    assert home.get("/api/v1/library/home").json()["forYou"] == body["forYou"]
    # Within a language: only its albums.
    ml = home.get("/api/v1/library/home", params={"language": "ml"}).json()
    assert all(a["language"] == "ml" for a in ml["forYou"])
    assert ml["recentlyPlayed"] == []


def test_home_rows_are_optional_for_older_apps() -> None:
    from .conftest import load_contract

    home = load_contract()["components"]["schemas"]["Home"]
    assert set(home["required"]) == {"jumpBackIn", "newAtHome", "playlists", "libraryEmpty"}
    assert {"recentlyPlayed", "onRepeat", "forYou", "films", "artists"} <= set(home["properties"])
