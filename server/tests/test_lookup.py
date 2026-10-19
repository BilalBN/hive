"""M1.5 online lookup, against stand-ins for MusicBrainz, Cover Art Archive and
Wikidata that answer with their real JSON shapes. (CI also runs a smaller
check against the real services: tests/live_lookup.py.)"""

from __future__ import annotations

import json
from collections.abc import Iterator
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest
from fastapi.testclient import TestClient

from hive.app import create_app
from hive.config import Settings
from hive.library.lookup.http import Http

from .audio_fixtures import cover_png
from .conftest import Home, assert_matches, needs_ffmpeg
from .test_know_your_music import _album, _write_soundtrack


def _artist(name: str, joinphrase: str = "") -> dict:
    return {"name": name, "joinphrase": joinphrase, "artist": {"id": name.lower(), "name": name}}


def _work(composer: str, lyricist: str) -> dict:
    return {
        "type": "performance",
        "target-type": "work",
        "work": {
            "id": "w",
            "title": "w",
            "relations": [
                {"type": "composer", "target-type": "artist", "artist": {"name": composer}},
                {"type": "lyricist", "target-type": "artist", "artist": {"name": lyricist}},
            ],
        },
    }


KN_HEAD = {
    "id": "rel-kn",
    "score": 100,
    "title": "Kumbalangi Nights (Original Motion Picture Soundtrack)",
    "artist-credit": [_artist("Sushin Shyam")],
    "date": "2019-01-25",
    "text-representation": {"language": "mal", "script": "Mlym"},
    "release-group": {
        "id": "rg-kn",
        "primary-type": "Album",
        "secondary-types": ["Soundtrack"],
        "title": "Kumbalangi Nights",
    },
    "track-count": 3,
}
KN_RELEASE = {
    **{k: v for k, v in KN_HEAD.items() if k != "score"},
    "relations": [],
    "media": [
        {
            "position": 1,
            "tracks": [
                {
                    "position": i + 1,
                    "number": str(i + 1),
                    "title": title,
                    "length": 2000,
                    "artist-credit": [_artist(singer)],
                    "recording": {
                        "id": f"rec-{i}",
                        "title": title,
                        "relations": [_work("Sushin Shyam", "Anwar Ali")],
                    },
                }  # fmt: skip
                for i, (title, singer) in enumerate(
                    [
                        ("Cherathukal", "Sithara Krishnakumar"),
                        ("Uyiril Thodum", "Sooraj Santhosh"),
                        ("Ezhuthaakkatha", "Sushin Shyam"),
                    ]
                )
            ],
        }
    ],
}
KOB_HEAD = {
    "id": "rel-kob",
    "score": 95,
    "title": "Kind of Blue",
    "artist-credit": [_artist("Miles Davis")],
    "date": "1959-08-17",
    "text-representation": {"language": "eng"},
    "release-group": {"id": "rg-kob", "primary-type": "Album", "secondary-types": []},
    "track-count": 1,
}
KOB_RELEASE = {
    **{k: v for k, v in KOB_HEAD.items() if k != "score"},
    "media": [
        {
            "position": 1,
            "tracks": [
                {
                    "position": 2,
                    "title": "Freddie Freeloader",
                    "length": 586000,
                    "artist-credit": [_artist("Miles Davis")],
                    "recording": {"id": "rec-ff"},
                }
            ],
        }  # fmt: skip
    ],
}


def _claim(*ids: str) -> list[dict]:
    return [
        {
            "mainsnak": {
                "snaktype": "value",
                "datavalue": {
                    "type": "wikibase-entityid",
                    "value": {"entity-type": "item", "id": i},
                },
            },
            "rank": "normal",
        }  # fmt: skip
        for i in ids
    ]


FILM = {
    "id": "Q100",
    "labels": {"en": {"language": "en", "value": "Kumbalangi Nights"}},
    "aliases": {},
    "claims": {
        "P31": _claim("Q11424"),
        "P577": [
            {
                "mainsnak": {
                    "datavalue": {
                        "type": "time",
                        "value": {"time": "+2019-02-07T00:00:00Z", "precision": 11},
                    }
                },
                "rank": "normal",
            }
        ],  # fmt: skip
        "P364": _claim("Q36236"),
        "P57": _claim("Q200"),
        "P161": _claim("Q201", "Q202"),
        "P86": _claim("Q203"),
    },
}
PEOPLE = {
    "Q200": "Madhu C. Narayanan",
    "Q201": "Fahadh Faasil",
    "Q202": "Soubin Shahir",
    "Q203": "Sushin Shyam",
}


class FakeInternet:
    """MusicBrainz, Cover Art Archive and Wikidata, as far as these tests need."""

    def __init__(self) -> None:
        self.requests: list[str] = []
        self.down = False
        self.archive_broken = False

    def __call__(self, request: httpx.Request) -> httpx.Response:
        url = urlsplit(str(request.url))
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        self.requests.append(f"{url.hostname}{url.path}?{url.query}")
        if self.down:
            raise httpx.ConnectError("no internet", request=request)
        assert request.headers["user-agent"].startswith("Hive/")
        if url.hostname == "musicbrainz.org":
            if url.path == "/ws/2/release/":
                query = q["query"]
                if "Kumbalangi Nights" in query:
                    return httpx.Response(200, json={"releases": [KN_HEAD]})
                if "Kind of Blue" in query:
                    return httpx.Response(200, json={"releases": [KOB_HEAD]})
                return httpx.Response(200, json={"releases": []})
            if url.path == "/ws/2/release/rel-kn":
                return httpx.Response(200, json=KN_RELEASE)
            if url.path == "/ws/2/release/rel-kob":
                return httpx.Response(200, json=KOB_RELEASE)
            if url.path == "/ws/2/release-group/rg-kn":
                return httpx.Response(200, json={"relations": [{"type": "wikidata",
                    "url": {"resource": "https://www.wikidata.org/wiki/Q100"}}]})  # fmt: skip
            return httpx.Response(200, json={"relations": []})
        if url.hostname == "api.acoustid.org":
            form = parse_qs(request.content.decode())
            if form["client"][0] != "good-key":
                return httpx.Response(
                    400,
                    json={"status": "error", "error": {"code": 4, "message": "invalid API key"}},
                )
            return httpx.Response(200, json={"status": "ok", "results": [{"score": 0.95,
                "recordings": [{"id": "rec-1", "releases": [{"id": "rel-kob"}]}]}]})  # fmt: skip
        if url.hostname == "coverartarchive.org":
            if self.archive_broken:
                return httpx.Response(500)
            if "rel-kn" in url.path or "rel-kob" in url.path:
                return httpx.Response(
                    200, content=cover_png((10, 200, 30)), headers={"content-type": "image/png"}
                )
            return httpx.Response(404)
        if url.hostname == "www.wikidata.org":
            if q.get("action") == "wbsearchentities":
                if q["search"] == "Kumbalangi Nights":
                    return httpx.Response(200, json={"search": [
                        {"id": "Q100", "label": "Kumbalangi Nights",
                         "description": "2019 film directed by Madhu C. Narayanan"},
                        {"id": "Q101", "label": "Kumbalangi", "description": "village in Kerala"},
                    ]})  # fmt: skip
                return httpx.Response(200, json={"search": []})
            if q.get("action") == "wbgetentities":
                ids = q["ids"].split("|")
                ents = {}
                for i in ids:
                    if i == "Q100":
                        ents[i] = FILM
                    elif i in PEOPLE:
                        ents[i] = {"id": i, "labels": {"en": {"value": PEOPLE[i]}}}
                return httpx.Response(200, json={"entities": ents})
        return httpx.Response(404)


@pytest.fixture
def internet() -> FakeInternet:
    return FakeInternet()


@pytest.fixture
def looked_home(settings: Settings, built_library, internet: FakeInternet) -> Iterator[Home]:
    import os
    import shutil
    import time

    src, paths = built_library
    music = settings.music_folders[0]
    shutil.copytree(src, music)
    old = time.time() - 600
    for p in sorted(music.rglob("*")):
        if p.is_file():
            stamp = old + 60 if p.name.startswith("Copy of") else old
            os.utime(p, (stamp, stamp))
    http = Http(transport=httpx.MockTransport(internet))
    http.spacing = {}
    with TestClient(create_app(settings, lookup_http=http)) as c:
        h = Home(c, {k: music / v.relative_to(src) for k, v in paths.items()}, music)
        h.wait()
        yield h


def _lookup(home: Home) -> dict:
    lk = home.client.app.state.lookup
    lk.configure(enabled=True)
    lk.run_until_idle()
    body = home.get("/api/v1/admin/library/lookup").json()
    assert_matches(body, "LookupStatus")
    return body


def _admin_album(home: Home, title: str) -> dict:
    album = _album(home, title)
    body = home.get(f"/api/v1/admin/library/albums/{album['id']}").json()
    assert_matches(body, "AdminAlbum")
    return body


@needs_ffmpeg
def test_soundtrack_gets_film_cast_cover_and_language(looked_home: Home) -> None:
    home = looked_home
    _write_soundtrack(home)
    status = _lookup(home)
    assert status["enabled"] is True
    assert status["waiting"] == 0
    assert status["found"] >= 1
    assert "Never the music itself" in status["sends"]

    album = _album(home, "Kumbalangi Nights")
    assert album["kind"] == "soundtrack"
    assert album["film"] == {"title": "Kumbalangi Nights", "year": 2019, "wikidataId": "Q100"}
    assert album["language"] == "ml"
    assert album["year"] == 2019
    assert album.get("artworkId"), "cover from Cover Art Archive"
    roles = {(c["role"], c["name"]) for c in album["credits"]}
    assert {("director", "Madhu C. Narayanan"), ("actor", "Fahadh Faasil"),
            ("musicDirector", "Sushin Shyam")} <= roles  # fmt: skip

    admin = _admin_album(home, "Kumbalangi Nights")
    assert admin["lookup"] == "found"
    assert admin["sources"]["artwork"] == "lookup"
    assert "Wikidata" in admin["lookupNote"]

    # Search by the lead actor finds the film's songs.
    r = home.get("/api/v1/library/search", params={"q": "fahadh"}).json()
    assert [a["title"] for a in r["albums"]] == ["Kumbalangi Nights"]
    fahadh = [a for a in r["artists"] if a["name"] == "Fahadh Faasil"][0]
    page = home.get(f"/api/v1/library/artists/{fahadh['id']}").json()
    assert_matches(page, "Artist")
    assert [a["title"] for a in page["films"]] == ["Kumbalangi Nights"]
    assert page["roles"] == ["actor"]


@needs_ffmpeg
def test_unsure_match_waits_for_review_then_applies(looked_home: Home) -> None:
    home = looked_home
    _lookup(home)
    admin = _admin_album(home, "Kind of Blue")
    assert admin["lookup"] == "review"
    found = admin["found"]
    assert found["title"] == "Kind of Blue" and 0.45 <= found["score"] < 0.75
    assert found["link"] == "https://musicbrainz.org/release/rel-kob"
    assert "artworkId" in found  # the cover it would use, to judge by eye
    listed = home.get("/api/v1/admin/library/albums", params={"filter": "review"}).json()
    assert_matches(listed, "AdminAlbumPage")
    assert [i["album"]["title"] for i in listed["items"]] == ["Kind of Blue"]

    aid = admin["album"]["id"]
    r = home.post(f"/api/v1/admin/library/albums/{aid}/match", json={"accept": True})
    assert r.status_code == 200, r.text
    after = r.json()
    assert after["lookup"] == "found"
    assert after["album"]["year"] == 1959
    assert after["album"]["artworkId"] == found["artworkId"]
    again = home.post(f"/api/v1/admin/library/albums/{aid}/match", json={"accept": True})
    assert again.status_code == 409


@needs_ffmpeg
def test_rejecting_a_match_and_not_found(looked_home: Home) -> None:
    home = looked_home
    _lookup(home)
    aid = _admin_album(home, "Kind of Blue")["album"]["id"]
    r = home.post(f"/api/v1/admin/library/albums/{aid}/match", json={"accept": False})
    assert r.json()["lookup"] == "notFound"
    assert _admin_album(home, "Kind of Blue")["album"].get("year") is None
    assert _admin_album(home, "Thalapathi")["lookup"] == "notFound"
    status = home.get("/api/v1/admin/library/lookup").json()
    assert status["notFound"] >= 2
    r = home.post("/api/v1/admin/library/lookup/retry", json={"all": True})
    assert r.json()["waiting"] >= 2


@needs_ffmpeg
def test_offline_is_reported_plainly(looked_home: Home, internet: FakeInternet) -> None:
    internet.down = True
    status = _lookup(looked_home)
    assert "can't be reached" in status["lastError"]
    assert status["failed"] >= 1


@needs_ffmpeg
def test_lookup_switch_and_key(looked_home: Home) -> None:
    home = looked_home
    r = home.patch("/api/v1/admin/library/lookup", json={"enabled": False, "acoustidKey": "abc"})
    body = r.json()
    assert body["enabled"] is False and body["acoustidKey"] is True
    assert "abc" not in json.dumps(body)
    admin = _admin_album(home, "Premam")
    assert admin["lookup"] == "off"
    r = home.patch("/api/v1/admin/library/lookup", json={"acoustidKey": ""})
    assert r.json()["acoustidKey"] is False


@needs_ffmpeg
def test_fpcalc_installed_while_running_is_found(
    looked_home: Home, monkeypatch: pytest.MonkeyPatch
) -> None:
    from hive.library.lookup import sources

    service = looked_home.client.app.state.lookup
    service.fpcalc = None
    monkeypatch.setattr(sources, "find_fpcalc", lambda: None)
    assert _lookup(looked_home)["fingerprinting"] is False
    # brew install chromaprint, with Hive still running:
    monkeypatch.setattr(sources, "find_fpcalc", lambda: "/opt/homebrew/bin/fpcalc")
    assert _lookup(looked_home)["fingerprinting"] is True


@pytest.fixture
def fake_fpcalc(monkeypatch: pytest.MonkeyPatch) -> None:
    from hive.library.lookup import sources

    monkeypatch.setattr(sources, "find_fpcalc", lambda: "/usr/bin/fpcalc")
    monkeypatch.setattr(sources, "fingerprint", lambda fpcalc, path: (180, "AQADtEmUaEkS"))


@needs_ffmpeg
def test_acoustid_test_shows_whether_it_works(looked_home: Home, fake_fpcalc) -> None:
    home = looked_home
    home.client.app.state.lookup.fpcalc = None  # found again through the fake
    r = home.post("/api/v1/admin/library/lookup/test-acoustid").json()
    assert_matches(r, "AcoustidTest")
    assert r["ok"] is False and "key" in r["message"]

    home.patch("/api/v1/admin/library/lookup", json={"acoustidKey": "typo-key"})
    r = home.post("/api/v1/admin/library/lookup/test-acoustid").json()
    assert r["ok"] is False and "doesn't recognise this key" in r["message"]
    assert "doesn't recognise" in r["status"]["acoustidProblem"]

    home.patch("/api/v1/admin/library/lookup", json={"acoustidKey": "good-key"})
    status = _lookup(home)
    assert "acoustidProblem" not in status  # a new key clears it
    r = home.post("/api/v1/admin/library/lookup/test-acoustid").json()
    assert r["ok"] is True and r["message"].startswith("Working")
    assert "acoustidUsedAt" in r["status"]


@needs_ffmpeg
def test_albums_recognised_by_sound_are_counted(looked_home: Home, fake_fpcalc) -> None:
    from hive.library.lookup import match as M

    service = looked_home.client.app.state.lookup
    service.fpcalc = None
    service.configure(acoustid_key="good-key")
    track = M.HomeTrack("Track 01", 120_000, 1, 1, "Unknown artist")
    home_album = M.HomeAlbum("x", "Unknown album", "Unknown artist", None, None, False, [track])
    release, _score, via = service._find_release(home_album, None, ["/music/Track 01.mp3"])
    assert release is not None and release.id == "rel-kob" and via == "fingerprint"
    assert service.status()["soundMatches"] == 1


@needs_ffmpeg
def test_a_broken_cover_does_not_stop_the_lookup(
    looked_home: Home, internet: FakeInternet, monkeypatch: pytest.MonkeyPatch
) -> None:
    import time as _time

    monkeypatch.setattr(_time, "sleep", lambda s: None)
    internet.archive_broken = True
    status = _lookup(looked_home)
    assert status["found"] + status["review"] >= 1  # details still applied
    assert "lastError" not in status


@needs_ffmpeg
def test_admin_edits_win_and_can_be_undone(looked_home: Home) -> None:
    home = looked_home
    aid = _album(home, "Premam")["id"]
    r = home.patch(
        f"/api/v1/admin/library/albums/{aid}",
        json={"language": "ta", "year": 2016, "filmTitle": "Premam"},
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert_matches(body, "AdminAlbum")
    assert set(body["edited"]) == {"language", "year", "filmTitle"}
    assert body["album"]["language"] == "ta" and body["album"]["year"] == 2016
    assert body["sources"]["language"] == "admin"
    # A rescan doesn't undo it.
    home.client.app.state.library.enqueue(home.paths["malare"], force=True)
    home.wait()
    assert _album(home, "Premam")["language"] == "ta"
    # Undo: back to what the titles say.
    r = home.patch(f"/api/v1/admin/library/albums/{aid}", json={"language": None, "year": None})
    assert r.json()["album"]["language"] == "ml"
    assert r.json()["album"]["year"] == 2015

    png = cover_png((1, 2, 3))
    r = home.put(
        f"/api/v1/admin/library/albums/{aid}/artwork",
        content=png,
        headers={"content-type": "image/png"},
    )
    assert r.status_code == 200, r.text
    assert r.json()["sources"]["artwork"] == "admin"
    assert "artwork" in r.json()["edited"]
    bad = home.put(
        f"/api/v1/admin/library/albums/{aid}/artwork",
        content=b"nope",
        headers={"content-type": "image/png"},
    )
    assert bad.status_code == 422
    assert (
        home.patch(f"/api/v1/admin/library/albums/{aid}", json={"language": "Tamil"}).status_code
        == 422
    )
