"""M4: correcting a song's details in Hive Admin, and the same song found in
two different files."""

from __future__ import annotations

import os
import subprocess
import time

from .conftest import FFMPEG, Home, assert_matches, needs_ffmpeg


def _track(home: Home, title: str) -> dict:
    body = home.get("/api/v1/library/tracks", params={"limit": 500}).json()
    return next(t for t in body["items"] if t["title"] == title)


@needs_ffmpeg
def test_correct_a_song_and_it_survives_a_rescan(home: Home) -> None:
    t = _track(home, "Dreams")
    r = home.patch(
        f"/api/v1/admin/library/tracks/{t['id']}",
        json={
            "title": "Dreams (2004 Remaster)",
            "artistName": "Fleetwood Mac & Friends",
            "trackNumber": 7,
        },
    )
    assert r.status_code == 200, r.text
    album = r.json()
    assert_matches(album, "AdminAlbum")
    assert sorted(album["editedTracks"][t["id"]]) == ["artistName", "title", "trackNumber"]
    edited = _track(home, "Dreams (2004 Remaster)")
    assert edited["artistName"] == "Fleetwood Mac & Friends" and edited["trackNumber"] == 7

    # The file is read again (it changed on disk); the corrections stay.
    old = time.time() - 60
    os.utime(home.paths["dreams"], (old, old))
    home.client.app.state.library.enqueue(home.paths["dreams"], force=True)
    home.wait()
    assert _track(home, "Dreams (2004 Remaster)")["trackNumber"] == 7

    # Null puts back what the file says.
    r = home.patch(
        f"/api/v1/admin/library/tracks/{t['id']}",
        json={"title": None, "artistName": None, "trackNumber": None},
    )
    assert r.status_code == 200 and t["id"] not in r.json().get("editedTracks", {})
    home.wait()
    back = _track(home, "Dreams")
    assert back["artistName"] == "Fleetwood Mac" and back["trackNumber"] == 2

    assert home.patch("/api/v1/admin/library/tracks/nope", json={"title": "x"}).status_code == 404
    assert (
        home.patch(f"/api/v1/admin/library/tracks/{t['id']}", json={"title": ""}).status_code == 422
    )
    assert (
        home.patch(f"/api/v1/admin/library/tracks/{t['id']}", json={"colour": "red"}).status_code
        == 422
    )
    actions = [e["action"] for e in home.get("/api/v1/admin/audit").json()["items"]]
    assert "track.edit" in actions


def _second_copy(home: Home) -> str:
    """Dreams again, as an MP3 on a compilation."""
    out = home.music / "Compilations" / "Best of 77" / "05 Dreams.mp3"
    out.parent.mkdir(parents=True)
    subprocess.run(
        [FFMPEG, "-y", "-loglevel", "error", "-i", str(home.paths["dreams"]), "-c:a", "libmp3lame",
         "-b:a", "192k", "-ar", "44100", "-metadata", "album=Best of 77",
         "-metadata", "track=5", str(out)],
        check=True,
    )  # fmt: skip
    old = time.time() - 600
    os.utime(out, (old, old))
    home.client.app.state.library.enqueue(out)
    home.wait()
    return str(out)


@needs_ffmpeg
def test_same_song_twice_keep_the_better_copy(home: Home) -> None:
    flac = _track(home, "Dreams")["id"]
    assert home.get("/api/v1/admin/library/same-songs").json() == {"items": []}
    mp3_path = _second_copy(home)
    body = home.get("/api/v1/admin/library/same-songs").json()
    assert_matches(body, "SameSongs")
    [group] = body["items"]
    best, other = group["copies"]
    assert best["trackId"] == flac and best["best"] and best["lossless"]
    assert other["format"].startswith("MP3") and not other["best"]
    assert other["albumTitle"] == "Best of 77" and other["file"].endswith("05 Dreams.mp3")

    # People liked and listed the MP3; that moves to the FLAC.
    mp3 = other["trackId"]
    assert home.put(f"/api/v1/library/likes/{mp3}").status_code == 204
    pl = home.post(
        "/api/v1/library/playlists", json={"name": "Seventies", "trackIds": [mp3]}
    ).json()

    assert (
        home.post(
            "/api/v1/admin/library/same-songs/resolve", json={"keep": flac, "remove": [flac]}
        ).status_code
        == 422
    )
    r = home.post("/api/v1/admin/library/same-songs/resolve", json={"keep": flac, "remove": [mp3]})
    assert r.status_code == 200, r.text
    assert_matches(r.json(), "SameSongResult")
    assert r.json() == {"moved": {"likes": 1, "plays": 0, "playlistEntries": 1}, "deleted": 1}
    assert not os.path.exists(mp3_path)
    home.wait()
    items = home.get(f"/api/v1/library/playlists/{pl['id']}").json()["items"]
    assert [i["track"]["id"] for i in items] == [flac]
    liked = home.get("/api/v1/library/tracks", params={"limit": 500}).json()["items"]
    assert [t["id"] for t in liked if t["title"] == "Dreams"] == [flac]
    assert home.get("/api/v1/admin/library/same-songs").json() == {"items": []}
    actions = [e["action"] for e in home.get("/api/v1/admin/audit").json()["items"]]
    assert "library.same_song" in actions


@needs_ffmpeg
def test_same_song_twice_keep_both(home: Home) -> None:
    _second_copy(home)
    [group] = home.get("/api/v1/admin/library/same-songs").json()["items"]
    r = home.post("/api/v1/admin/library/same-songs/keep-both", json={"key": group["key"]})
    assert r.status_code == 200 and r.json() == {"items": []}
    assert home.get("/api/v1/admin/library/same-songs").json() == {"items": []}
