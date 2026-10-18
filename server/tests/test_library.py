"""Scanning a real (generated) library and reading it back through the API."""

from __future__ import annotations

import os
import time

import pytest

from .conftest import Home, assert_matches, needs_ffmpeg

pytestmark = needs_ffmpeg


def _albums(home: Home) -> dict[str, dict]:
    body = home.get("/api/v1/library/albums", params={"limit": 500}).json()
    assert_matches(body, "AlbumPage")
    return {a["title"]: a for a in body["items"]}


def test_library_needs_the_key(home: Home) -> None:
    r = home.client.get("/api/v1/library/home")
    assert r.status_code == 401
    assert r.headers["content-type"].startswith("application/problem+json")
    r = home.client.get("/api/v1/library/home", headers={"Authorization": "Bearer wrong"})
    assert r.status_code == 401


def test_scan_reads_every_good_file(home: Home) -> None:
    albums = _albums(home)
    assert set(albums) == {
        "Premam", "Rumours", "Aashiqui 2", "Roja", "OK Kanmani", "Kind of Blue", "Thalapathi",
    }  # fmt: skip
    assert albums["Premam"]["trackCount"] == 2
    assert albums["Premam"]["year"] == 2015


def test_quality_tiers_and_labels(home: Home) -> None:
    albums = _albums(home)
    assert albums["Rumours"]["tier"] == "hires"
    assert albums["Premam"]["tier"] == "lossless"
    assert albums["Aashiqui 2"]["tier"] == "lossy"
    rumours = home.get(f"/api/v1/library/albums/{albums['Rumours']['id']}").json()
    assert_matches(rumours, "Album")
    fmt = rumours["tracks"][0]["format"]
    assert fmt["label"] == "Hi-Res 24/96"
    assert fmt["bitDepth"] == 24 and fmt["sampleRate"] == 96000
    roja = home.get(f"/api/v1/library/albums/{albums['Roja']['id']}").json()
    assert roja["tracks"][0]["format"]["codec"] == "alac"
    assert roja["tracks"][0]["format"]["label"] == "Lossless 16/44.1"
    aashiqui = home.get(f"/api/v1/library/albums/{albums['Aashiqui 2']['id']}").json()
    assert aashiqui["tracks"][0]["format"]["label"] == "MP3 320"


def test_album_artist_and_credits(home: Home) -> None:
    albums = _albums(home)
    premam = home.get(f"/api/v1/library/albums/{albums['Premam']['id']}").json()
    assert premam["artistName"] == "Vijay Yesudas"
    assert [t["title"] for t in premam["tracks"]] == ["മലരേ (Malare)", "Aluva Puzha"]
    assert premam["tracks"][1]["artistName"] == "Vineeth Sreenivasan"
    assert albums["Aashiqui 2"]["artistName"] == "Mithoon, Jeet Gannguli"


def test_spellings_of_one_artist_merge(home: Home) -> None:
    body = home.get("/api/v1/library/artists", params={"limit": 500}).json()
    assert_matches(body, "ArtistPage")
    rahman = [a for a in body["items"] if "rahman" in a["name"].lower()]
    assert len(rahman) == 1, rahman
    assert rahman[0]["albumCount"] == 2
    artist = home.get(f"/api/v1/library/artists/{rahman[0]['id']}").json()
    assert_matches(artist, "Artist")
    assert {a["title"] for a in artist["albums"]} == {"Roja", "OK Kanmani"}
    assert len(artist["topTracks"]) == 2


def test_names_from_folders_when_untagged(home: Home) -> None:
    albums = _albums(home)
    thalapathi = home.get(f"/api/v1/library/albums/{albums['Thalapathi']['id']}").json()
    assert thalapathi["artistName"] == "Ilaiyaraaja"
    t = thalapathi["tracks"][0]
    assert t["title"] == "Sundari Kannal"
    assert t["trackNumber"] == 3
    assert t["hasLyrics"] is True
    assert "artworkId" in t  # cover.jpg beside the files


def test_problems_are_listed_not_hidden(home: Home) -> None:
    body = home.get("/api/v1/admin/library/imports").json()
    assert_matches(body, "LibraryStatus")
    problems = {i["path"]: i["problem"] for i in body["needsAttention"]}
    assert "damaged or not audio" in problems[os.path.join("Incoming", "broken.mp3")] or (
        "recognise" in problems[os.path.join("Incoming", "broken.mp3")]
    )
    dupes = {path: p for path, p in problems.items() if p.startswith("Same file as")}
    # The copy is the one set aside, whichever was read first.
    copy = os.path.join("Incoming", "Copy of Dreams.flac")
    original = os.path.join("Fleetwood Mac", "Rumours", "02 Dreams.flac")
    assert list(dupes) == [copy]
    assert dupes[copy] == f"Same file as {original}, so it was skipped"
    assert body["tracks"] == 8
    assert body["queued"] == 0
    assert body["folders"][0]["trackCount"] == 8


def test_search_any_script_and_word_starts(home: Home) -> None:
    r = home.get("/api/v1/library/search", params={"q": "mal"}).json()
    assert_matches(r, "SearchResults")
    assert [t["title"] for t in r["tracks"]][0] == "മലരേ (Malare)"
    r = home.get("/api/v1/library/search", params={"q": "മലരേ"}).json()
    assert r["tracks"][0]["title"] == "മലരേ (Malare)"
    r = home.get("/api/v1/library/search", params={"q": "तुम"}).json()
    assert r["tracks"][0]["title"] == "तुम ही हो (Tum Hi Ho)"
    r = home.get("/api/v1/library/search", params={"q": "a.r. rahman"}).json()
    assert r["artists"] and r["top"] == {"kind": "artist", "id": r["artists"][0]["id"]}
    r = home.get("/api/v1/library/search", params={"q": "ream"}).json()
    assert not r["tracks"], "matches start at word beginnings"
    r = home.get("/api/v1/library/search", params={"q": "fleetwood dreams"}).json()
    assert [t["title"] for t in r["tracks"]] == ["Dreams"]


def test_playlists_create_reorder_share_delete(home: Home) -> None:
    a, b, c = (home.track_id(t) for t in ("Dreams", "So What", "Kadhal Rojave"))
    r = home.post("/api/v1/library/playlists", json={"name": "Sunday mornings", "trackIds": [a, b]})
    assert r.status_code == 201
    pl = r.json()
    assert_matches(pl, "Playlist")
    assert pl["mine"] and not pl["shared"] and pl["trackCount"] == 2
    assert len(pl["artworkIds"]) >= 1

    r = home.put(f"/api/v1/library/playlists/{pl['id']}/items", json={"trackIds": [c, a, b, a]})
    body = r.json()
    assert [i["track"]["title"] for i in body["items"]] == [
        "Kadhal Rojave",
        "Dreams",
        "So What",
        "Dreams",
    ]

    r = home.patch(
        f"/api/v1/library/playlists/{pl['id']}", json={"name": "Sundays", "shared": True}
    )
    assert r.json()["name"] == "Sundays" and r.json()["shared"] is True

    listed = home.get("/api/v1/library/playlists").json()
    assert_matches(listed, "PlaylistList")
    assert [p["name"] for p in listed["items"]] == ["Sundays"]

    r = home.put(f"/api/v1/library/playlists/{pl['id']}/items", json={"trackIds": ["nope"]})
    assert r.status_code == 422

    assert home.delete(f"/api/v1/library/playlists/{pl['id']}").status_code == 204
    assert home.get(f"/api/v1/library/playlists/{pl['id']}").status_code == 404


def test_likes(home: Home) -> None:
    tid = home.track_id("Dreams")
    assert home.put(f"/api/v1/library/likes/{tid}").status_code == 204
    assert home.put(f"/api/v1/library/likes/{tid}").status_code == 204  # idempotent
    liked = home.get("/api/v1/library/tracks", params={"liked": True}).json()
    assert_matches(liked, "TrackPage")
    assert [t["title"] for t in liked["items"]] == ["Dreams"]
    assert liked["items"][0]["liked"] is True
    assert home.delete(f"/api/v1/library/likes/{tid}").status_code == 204
    assert home.get("/api/v1/library/tracks", params={"liked": True}).json()["total"] == 0
    assert home.put("/api/v1/library/likes/missing").status_code == 404


def test_home_shelves(home: Home) -> None:
    body = home.get("/api/v1/library/home").json()
    assert_matches(body, "Home")
    assert body["libraryEmpty"] is False
    assert body["jumpBackIn"] == []
    assert len(body["newAtHome"]) == 7
    tid = home.track_id("Dreams")
    album_id = home.get("/api/v1/library/tracks", params={"limit": 500}).json()
    r = home.post(f"/api/v1/media/tracks/{tid}/stream", json={"quality": "lossless"})
    assert r.status_code == 200
    body = home.get("/api/v1/library/home").json()
    assert body["jumpBackIn"][0]["kind"] == "album"
    assert body["jumpBackIn"][0]["title"] == "Rumours"
    del album_id


def test_paging_and_sorting(home: Home) -> None:
    page = home.get("/api/v1/library/tracks", params={"limit": 3, "offset": 0}).json()
    assert page["total"] == 8 and len(page["items"]) == 3
    nxt = home.get("/api/v1/library/tracks", params={"limit": 3, "offset": 3}).json()
    assert not {t["id"] for t in page["items"]} & {t["id"] for t in nxt["items"]}
    by_title = home.get("/api/v1/library/albums", params={"sort": "title"}).json()["items"]
    titles = [a["title"] for a in by_title]
    assert titles == sorted(titles, key=str.casefold)


def test_rescan_picks_up_new_and_removed_files(home: Home) -> None:
    os.remove(home.paths["sowhat"])
    r = home.post("/api/v1/admin/library/scan")
    assert r.status_code == 200
    assert_matches(r.json(), "LibraryStatus")
    home.wait()
    assert "Kind of Blue" not in _albums(home)
    # A changed file is read again.
    target = home.paths["premam2"]
    from mutagen.flac import FLAC

    f = FLAC(target)
    f["title"] = "Aluva Puzha (Reprise)"
    f.save()
    old = time.time() - 60
    os.utime(target, (old, old))
    home.post("/api/v1/admin/library/scan")
    home.wait()
    assert home.track_id("Aluva Puzha (Reprise)")


def test_unknown_things_are_404(home: Home) -> None:
    assert home.get("/api/v1/library/albums/nope").status_code == 404
    assert home.get("/api/v1/library/artists/nope").status_code == 404
    assert home.get("/api/v1/library/playlists/nope").status_code == 404


@pytest.mark.parametrize("q", ["", " "])
def test_empty_search(home: Home, q: str) -> None:
    r = home.get("/api/v1/library/search", params={"q": q})
    assert r.status_code in (200, 422)
