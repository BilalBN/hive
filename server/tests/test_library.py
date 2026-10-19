"""Scanning a real (generated) library and reading it back through the API."""

from __future__ import annotations

import os
import time

import pytest

from .conftest import Home, assert_matches, away, needs_ffmpeg

pytestmark = needs_ffmpeg


def _albums(home: Home) -> dict[str, dict]:
    body = home.get("/api/v1/library/albums", params={"limit": 500}).json()
    assert_matches(body, "AlbumPage")
    return {a["title"]: a for a in body["items"]}


def test_library_needs_the_key(home: Home) -> None:
    other = away(home.client)  # not the home computer
    r = other.get("/api/v1/library/home")
    assert r.status_code == 401
    assert r.headers["content-type"].startswith("application/problem+json")
    r = other.get("/api/v1/library/home", headers={"Authorization": "Bearer wrong"})
    assert r.status_code == 401
    r = other.get("/api/v1/library/home", headers=home.auth)  # the development key
    assert r.status_code == 200


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
    # Exact copies aren't problems: they're listed on their own.
    assert not any(p.startswith("Same file as") for p in problems.values())
    dupes = {i["path"]: i["problem"] for i in body["duplicates"]}
    # The copy is the one set aside, whichever was read first.
    copy = os.path.join("Incoming", "Copy of Dreams.flac")
    original = os.path.join("Fleetwood Mac", "Rumours", "02 Dreams.flac")
    assert list(dupes) == [copy]
    assert dupes[copy] == f"Same file as {original}, so it was skipped"
    assert body["duplicates"][0]["status"] == "duplicate"
    assert body["tracks"] == 8
    assert body["queued"] == 0
    assert body["folders"][0]["trackCount"] == 8


def _status(home: Home) -> dict:
    body = home.get("/api/v1/admin/library/imports").json()
    assert_matches(body, "LibraryStatus")
    return body


def test_deleting_a_copy_keeps_the_song(home: Home) -> None:
    copy = home.paths["duplicate"]
    item = _status(home)["duplicates"][0]
    r = home.post(f"/api/v1/admin/library/imports/{item['id']}/delete-copy")
    assert r.status_code == 200
    assert_matches(r.json(), "LibraryStatus")
    assert not copy.exists()
    assert copy.parent.exists()  # broken.mp3 is still in Incoming
    body = _status(home)
    assert body["duplicates"] == [] and body["tracks"] == 8
    assert home.track_id("Dreams")


def test_delete_all_copies_and_empty_folders_go(home: Home) -> None:
    copy = home.paths["duplicate"]
    folder = copy.parent / "Again"
    folder.mkdir()
    second = folder / "Dreams again.flac"
    second.write_bytes(copy.read_bytes())
    (folder / ".DS_Store").write_bytes(b"\0")
    home.client.app.state.library.enqueue(second)
    home.wait()
    assert len(_status(home)["duplicates"]) == 2
    body = home.post("/api/v1/admin/library/imports/delete-copies").json()
    assert body["duplicates"] == [] and body["tracks"] == 8
    assert not folder.exists()  # held nothing else
    assert copy.parent.exists()


def test_a_copy_is_kept_when_the_original_changed(home: Home) -> None:
    item = _status(home)["duplicates"][0]
    original = home.paths["dreams"]
    with original.open("ab") as f:
        f.write(b"edited")
    r = home.post(f"/api/v1/admin/library/imports/{item['id']}/delete-copy")
    assert r.status_code == 409
    assert home.paths["duplicate"].exists()


def test_removing_the_original_brings_the_copy_in(home: Home) -> None:
    library = home.client.app.state.library
    original = home.paths["dreams"]
    original.unlink()
    library.forget(original)
    home.wait()
    body = _status(home)
    assert body["duplicates"] == [] and body["tracks"] == 8
    assert home.track_id("Dreams")


def test_ignoring_a_problem(home: Home) -> None:
    broken = next(i for i in _status(home)["needsAttention"] if "broken" in i["path"])
    r = home.post(f"/api/v1/admin/library/imports/{broken['id']}/ignore")
    assert r.status_code == 200
    assert not any("broken" in i["path"] for i in r.json()["needsAttention"])
    home.post("/api/v1/admin/library/scan")
    home.wait()
    assert not any("broken" in i["path"] for i in _status(home)["needsAttention"])
    assert home.post("/api/v1/admin/library/imports/99999/ignore").status_code == 404


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


# ------------------------------------------------------------------ M2


def test_suggestions_finish_what_is_typed(home: Home) -> None:
    body = home.get("/api/v1/library/suggest", params={"q": "dre"}).json()
    assert_matches(body, "Suggestions")
    assert body["items"][0] == {
        "kind": "song",
        "id": home.track_id("Dreams"),
        "text": "Dreams",
        "detail": "Fleetwood Mac",
    }
    # Typed in English, a Malayalam title is suggested by its spelling.
    texts = [
        i["text"] for i in home.get("/api/v1/library/suggest", params={"q": "mala"}).json()["items"]
    ]
    assert "മലരേ (Malare)" in texts
    kinds = {
        i["kind"]
        for i in home.get("/api/v1/library/suggest", params={"q": "fleet"}).json()["items"]
    }
    assert "artist" in kinds
    # A song isn't suggested just because its album matches.
    rumours = home.get("/api/v1/library/suggest", params={"q": "rumou"}).json()["items"]
    assert [i["kind"] for i in rumours] == ["album"]


def test_tidy_song_names(home: Home) -> None:
    # Download-site clutter in a title, as songs arrive from the internet.
    track_id = home.track_id("Dreams")
    with home.client.app.state.db.engine.begin() as conn:
        from sqlalchemy import update

        from hive.models import Track

        conn.execute(
            update(Track)
            .where(Track.id == track_id)
            .values(title="02_Dreams [www.Mp3MaD.Com]", file_title="02_Dreams [www.Mp3MaD.Com]")
        )
    body = home.get("/api/v1/admin/library/tidy").json()
    assert_matches(body, "TidyList")
    item = next(i for i in body["items"] if i["trackId"] == track_id)
    assert item == {
        "trackId": track_id,
        "albumId": item["albumId"],
        "albumTitle": "Rumours",
        "before": "02_Dreams [www.Mp3MaD.Com]",
        "after": "Dreams",
        "applied": False,
    }
    body = home.post("/api/v1/admin/library/tidy", json={"trackIds": [track_id]}).json()
    assert next(i for i in body["items"] if i["trackId"] == track_id)["applied"] is True
    assert home.track_id("Dreams") == track_id
    assert home.get("/api/v1/library/suggest", params={"q": "dreams"}).json()["items"]
    # A rescan keeps the tidy name; the file is never changed.
    home.client.app.state.library.enqueue(home.paths["dreams"], force=True)
    home.wait()
    assert home.track_id("Dreams") == track_id
    # Undo: back to what the file says (here the file's own tag is clean).
    body = home.post("/api/v1/admin/library/tidy/undo", json={"trackIds": [track_id]}).json()
    assert not any(i["trackId"] == track_id and i["applied"] for i in body["items"])
    assert home.track_id("Dreams") == track_id
