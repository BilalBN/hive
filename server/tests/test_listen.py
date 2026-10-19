"""M3: Listen recognises songs at home from a recording made across a room,
says where in the song it is, keeps a history, and lets people ask for songs
that aren't at home. Downloads stay playable offline for 30 days."""

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

import jsonschema
import pytest
from fastapi.testclient import TestClient

from hive.app import create_app
from hive.config import Settings
from hive.contract import load_contract

from .audio_fixtures import in_a_room, music_like, write_audio
from .conftest import HOME_COMPUTER, assert_matches, needs_ffmpeg

pytestmark = needs_ffmpeg

RATE = 44100
SONGS = 6


@pytest.fixture
def listening(settings: Settings, tmp_path: Path) -> Iterator[tuple[TestClient, dict, dict]]:
    """Six made-up songs at home, fingerprinted; returns the client, auth
    headers, and track id → samples."""
    music = settings.music_folders[0]
    samples = {}
    for i in range(SONGS):
        x = music_like(i, 30)
        write_audio(music / "Test Band" / "Made Up" / f"{i + 1:02d} Song {i + 1}.flac", x)
        samples[f"Song {i + 1}"] = x
    with TestClient(create_app(settings), client=HOME_COMPUTER) as c:
        assert c.app.state.library.wait_idle(60)
        auth = {"Authorization": f"Bearer {c.app.state.dev_key}"}
        assert c.app.state.recognition.run_until_idle() == SONGS
        items = c.get("/api/v1/library/tracks", headers=auth, params={"limit": 50}).json()["items"]
        by_id = {t["id"]: samples[t["title"]] for t in items}
        yield c, auth, by_id


def _clip(tmp_path: Path, samples, start: float, seed: int, snr: float) -> bytes:
    room = in_a_room(samples[int(start * RATE) : int((start + 8) * RATE)], seed, snr)
    return write_audio(
        tmp_path / f"clip{seed}.m4a", room, args=["-c:a", "aac", "-b:a", "64k"]
    ).read_bytes()


def test_recognises_a_song_heard_across_a_room(listening, tmp_path: Path) -> None:
    c, auth, songs = listening
    right = 0
    for n, (track_id, x) in enumerate(songs.items()):
        start = 4.0 + 3 * n
        r = c.post(
            "/api/v1/listen/match",
            content=_clip(tmp_path, x, start, n, snr=6),
            headers={**auth, "Content-Type": "audio/mp4"},
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert_matches(body, "ListenResult")
        if body["matched"] and body["track"]["id"] == track_id:
            # Where the song is now: the clip's start plus its 8 seconds.
            assert abs(body["positionMs"] / 1000 - (start + 8)) < 1.0
            right += 1
    assert right >= SONGS - 1  # room recordings: allow one miss in six


def test_a_song_not_at_home_is_not_matched(listening, tmp_path: Path) -> None:
    c, auth, _ = listening
    for seed in range(4):
        stranger = music_like(500 + seed, 10)
        r = c.post(
            "/api/v1/listen/match",
            content=_clip(tmp_path, stranger, 1, 100 + seed, snr=6),
            headers={**auth, "Content-Type": "audio/mp4"},
        )
        assert r.status_code == 200
        assert r.json()["matched"] is False


def test_history_and_asking_for_a_song(listening, tmp_path: Path) -> None:
    c, auth, songs = listening
    track_id, x = next(iter(songs.items()))
    found = c.post(
        "/api/v1/listen/match",
        content=_clip(tmp_path, x, 5, 7, snr=15),
        headers={**auth, "Content-Type": "audio/mp4"},
    ).json()
    missed = c.post(
        "/api/v1/listen/match",
        content=_clip(tmp_path, music_like(900, 10), 1, 8, snr=15),
        headers={**auth, "Content-Type": "audio/mp4"},
    ).json()
    assert found["matched"] and not missed["matched"]

    asked = c.post(
        "/api/v1/listen/requests",
        json={"source": "listen", "listenEventId": missed["id"], "note": "The song at the wedding"},
        headers=auth,
    )
    assert asked.status_code == 200, asked.text
    assert_matches(asked.json(), "SongRequest")
    assert asked.json()["status"] == "waiting" and "heardAt" in asked.json()

    history = c.get("/api/v1/listen/history", headers=auth).json()
    assert_matches(history, "ListenHistory")
    newest, older = history["items"][0], history["items"][1]
    assert newest["id"] == missed["id"] and newest["requested"] is True
    assert older["track"]["id"] == track_id

    # Hive Admin sees it, says it was added.
    listed = c.get("/api/v1/admin/song-requests").json()
    assert_matches(listed, "AdminSongRequests")
    req = listed["items"][0]
    assert req["note"] == "The song at the wedding" and req["personName"]
    done = c.patch(f"/api/v1/admin/song-requests/{req['id']}", json={"status": "added"})
    assert done.json()["status"] == "added" and "decidedAt" in done.json()

    status = c.get("/api/v1/admin/recognition").json()
    assert_matches(status, "RecognitionStatus")
    assert status["fingerprinted"] == status["tracks"] == SONGS
    assert status["matchesThisWeek"] == 1 and status["noMatchThisWeek"] == 1


def test_bad_recordings(listening) -> None:
    c, auth, _ = listening
    big = c.post("/api/v1/listen/match", content=b"0" * (3 * 1024 * 1024 + 1), headers=auth)
    assert big.status_code == 413
    junk = c.post("/api/v1/listen/match", content=b"not audio at all" * 200, headers=auth)
    assert junk.status_code == 422
    empty = c.post("/api/v1/listen/requests", json={"source": "search"}, headers=auth)
    assert empty.status_code == 422


def test_rebuild_starts_over(listening) -> None:
    c, _, _ = listening
    rec = c.app.state.recognition
    status = c.post("/api/v1/admin/recognition/rebuild").json()
    assert status["fingerprinted"] == 0
    assert rec.run_until_idle() == SONGS
    assert c.get("/api/v1/admin/recognition").json()["fingerprinted"] == SONGS


def test_downloads_play_offline_for_30_days(listening) -> None:
    c, auth, songs = listening
    track_id = next(iter(songs))
    r = c.post(
        f"/api/v1/media/tracks/{track_id}/download", json={"quality": "lossless"}, headers=auth
    )
    assert r.status_code == 200, r.text
    spec = load_contract()
    jsonschema.validate(
        r.json(), {"$ref": "#/components/schemas/DownloadTicket", "components": spec["components"]}
    )
    ticket = r.json()
    assert ticket["validUntil"] > ticket["expiresAt"]  # the file lasts, the link doesn't
    audio = c.get(ticket["url"])
    assert audio.status_code == 200 and len(audio.content) == ticket["sizeBytes"]

    check = c.post(
        "/api/v1/media/downloads/check", json={"trackIds": [track_id, "gone-song"]}, headers=auth
    ).json()
    assert_matches(check, "DownloadCheck")
    assert check["gone"] == ["gone-song"]
