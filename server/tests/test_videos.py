"""M6: music videos in the music folders, matched to their songs and
streamed to the apps."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from .conftest import FFMPEG, Home, assert_matches, needs_ffmpeg

pytestmark = needs_ffmpeg


def _video(path: Path, seconds: int = 2) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [FFMPEG, "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", f"testsrc=size=320x240:rate=10:duration={seconds}", "-c:v", "mpeg4", str(path)],
        check=True,
    )  # fmt: skip
    return path


def _summary(home: Home, title: str) -> dict:
    items = home.get("/api/v1/library/tracks", params={"limit": 500}).json()["items"]
    return next(t for t in items if t["title"] == title)


def test_videos_are_matched_to_their_songs_and_stream(home: Home) -> None:
    beside = _video(home.paths["dreams"].with_suffix(".mp4"))
    named = _video(home.music / "Videos" / "Vineeth Sreenivasan - Aluva Puzha (Official Video).mp4")
    _video(home.music / "Videos" / "Holiday clip.mp4")
    assert home.client.app.state.videos.sync() == 2

    dreams = _summary(home, "Dreams")
    assert_matches(dreams, "TrackSummary")
    assert dreams["videoId"]
    assert _summary(home, "Aluva Puzha")["videoId"]
    assert "videoId" not in _summary(home, "So What")

    r = home.post(f"/api/v1/media/tracks/{dreams['id']}/video")
    assert r.status_code == 200, r.text
    ticket = r.json()
    assert_matches(ticket, "VideoTicket")
    assert ticket["mimeType"] == "video/mp4" and ticket["width"] == 320 and ticket["height"] == 240
    assert 1500 <= ticket["durationMs"] <= 2500
    part = home.client.get(ticket["url"], headers={"Range": "bytes=0-99"})
    assert part.status_code == 206 and len(part.content) == 100
    assert home.client.get(ticket["url"]).content == beside.read_bytes()
    assert home.client.get("/api/v1/media/video/forged").status_code == 403
    assert (
        home.post(f"/api/v1/media/tracks/{_summary(home, 'So What')['id']}/video").status_code
        == 404
    )

    listed = home.get("/api/v1/admin/library/videos").json()
    assert_matches(listed, "AdminVideos")
    assert listed["matched"] == 2 and len(listed["items"]) == 3
    holiday = next(i for i in listed["items"] if i["file"].endswith("Holiday clip.mp4"))
    assert "trackId" not in holiday

    # A deleted video goes; a song left without one says so.
    os.remove(named)
    assert home.client.app.state.videos.sync() == 1
    assert "videoId" not in _summary(home, "Aluva Puzha")
