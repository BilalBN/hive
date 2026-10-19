"""Streaming at each quality, range requests, tickets, artwork and lyrics."""

from __future__ import annotations

import io
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest
from PIL import Image

from hive.auth import sign_ticket

from .conftest import Home, assert_matches, away, needs_ffmpeg

pytestmark = needs_ffmpeg


def _ticket(home: Home, title: str, **body) -> dict:
    tid = home.track_id(title)
    r = home.post(f"/api/v1/media/tracks/{tid}/stream", json=body)
    assert r.status_code == 200, r.text
    data = r.json()
    assert_matches(data, "StreamTicket")
    return data


def _probe(data: bytes) -> dict:
    probe = shutil.which("ffprobe")
    if probe is None:
        pytest.skip("ffprobe not installed")
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / "stream"
        f.write_bytes(data)
        r = subprocess.run(
            [probe, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(f)],
            capture_output=True,
            check=True,
        )
    return json.loads(r.stdout)


def test_lossless_sends_the_original_untouched(home: Home) -> None:
    t = _ticket(home, "Dreams", quality="lossless")
    assert t["transcoded"] is False
    assert t["mimeType"] == "audio/flac"
    assert t["format"]["label"] == "Hi-Res 24/96"
    assert "source" not in t
    assert t["loudness"]["integratedLufs"] < 0
    r = home.client.get(t["url"])  # no auth header: the ticket is enough
    assert r.status_code == 200
    assert r.content == home.paths["dreams"].read_bytes()


def test_range_requests_for_seeking(home: Home) -> None:
    t = _ticket(home, "Dreams", quality="lossless")
    size = home.paths["dreams"].stat().st_size
    r = home.client.get(t["url"], headers={"Range": "bytes=100-199"})
    assert r.status_code == 206
    assert r.headers["content-range"] == f"bytes 100-199/{size}"
    assert r.content == home.paths["dreams"].read_bytes()[100:200]
    assert r.headers["accept-ranges"] == "bytes"
    r = home.client.get(t["url"], headers={"Range": f"bytes={size + 10}-"})
    assert r.status_code == 416


def test_high_is_opus_256_in_ogg_and_cached(home: Home) -> None:
    t = _ticket(home, "Dreams", quality="high")
    assert t["transcoded"] is True
    assert t["mimeType"] == "audio/ogg"
    assert t["format"]["codec"] == "opus" and t["format"]["bitrateKbps"] == 256
    assert t["format"]["label"] == "Opus 256"
    assert t["source"]["label"] == "Hi-Res 24/96"
    data = home.client.get(t["url"]).content
    info = _probe(data)
    assert info["streams"][0]["codec_name"] == "opus"
    assert info["format"]["format_name"] == "ogg"
    # The second ask reuses the cached file.
    cache = home.client.app.state.library.transcoder.dir
    before = {p: p.stat().st_mtime for p in cache.rglob("*.ogg")}
    _ticket(home, "Dreams", quality="high")
    assert {p: p.stat().st_mtime for p in cache.rglob("*.ogg")} == before


def test_apple_players_get_aac_in_mp4(home: Home) -> None:
    t = _ticket(home, "Dreams", quality="dataSaver", player="apple")
    assert t["mimeType"] == "audio/mp4"
    assert t["format"]["codec"] == "aac" and t["format"]["bitrateKbps"] == 96
    assert t["format"]["label"] == "AAC 96"
    info = _probe(home.client.get(t["url"]).content)
    assert info["streams"][0]["codec_name"] == "aac"
    assert "mp4" in info["format"]["format_name"]


def test_alac_becomes_flac_for_non_apple_players(home: Home) -> None:
    t = _ticket(home, "Kadhal Rojave", quality="lossless", player="other")
    assert t["transcoded"] is True and t["mimeType"] == "audio/flac"
    assert t["format"]["lossless"] is True and t["format"]["codec"] == "flac"
    info = _probe(home.client.get(t["url"]).content)
    assert info["streams"][0]["codec_name"] == "flac"
    t = _ticket(home, "Kadhal Rojave", quality="lossless", player="apple")
    assert t["transcoded"] is False and t["format"]["codec"] == "alac"


def test_lossy_originals_are_sent_as_they_are_unless_too_big(home: Home) -> None:
    t = _ticket(home, "तुम ही हो (Tum Hi Ho)", quality="lossless")
    assert t["transcoded"] is False and t["mimeType"] == "audio/mpeg"
    t = _ticket(home, "तुम ही हो (Tum Hi Ho)", quality="dataSaver")
    assert t["transcoded"] is True and t["format"]["bitrateKbps"] == 96
    t = _ticket(home, "So What", quality="high")
    assert t["transcoded"] is False and t["mimeType"] == "audio/ogg"
    # Apple's player can't open Ogg, so an Opus original becomes AAC there.
    t = _ticket(home, "So What", quality="lossless", player="apple")
    assert t["transcoded"] is True and t["mimeType"] == "audio/mp4"
    info = _probe(home.client.get(t["url"]).content)
    assert info["streams"][0]["codec_name"] == "aac"


def test_tickets_expire_and_cannot_be_forged(home: Home) -> None:
    t = _ticket(home, "Dreams", quality="lossless")
    tampered = t["url"][:-3] + ("AAA" if not t["url"].endswith("AAA") else "BBB")
    assert home.client.get(tampered).status_code == 403
    secret = home.client.app.state.ticket_secret
    tid = home.track_id("Dreams")
    expired, _ = sign_ticket(secret, {"t": tid, "v": "orig", "u": "dev"}, -10)
    assert home.client.get(f"/api/v1/media/stream/{expired}").status_code == 403
    assert home.client.get("/api/v1/media/stream/garbage").status_code == 403


def test_prefetch_doesnt_count_as_played(home: Home) -> None:
    _ticket(home, "So What", quality="lossless", purpose="prefetch")
    assert home.get("/api/v1/library/home").json()["jumpBackIn"] == []
    _ticket(home, "So What", quality="lossless", context={"kind": "liked", "id": "liked"})
    tiles = home.get("/api/v1/library/home").json()["jumpBackIn"]
    assert tiles[0]["kind"] == "liked" and tiles[0]["title"] == "Liked songs"


def test_artwork_resized_and_cached(home: Home) -> None:
    album = next(
        a for a in home.get("/api/v1/library/albums").json()["items"] if a["title"] == "Premam"
    )
    r = home.get(f"/api/v1/media/artwork/{album['artworkId']}", params={"size": 300})
    assert r.status_code == 200
    assert r.headers["content-type"] == "image/jpeg"
    assert "immutable" in r.headers["cache-control"]
    with Image.open(io.BytesIO(r.content)) as im:
        assert im.size == (300, 300)
    # Never enlarged.
    r = home.get(f"/api/v1/media/artwork/{album['artworkId']}", params={"size": 1200})
    with Image.open(io.BytesIO(r.content)) as im:
        assert im.size == (800, 800)
    assert home.get("/api/v1/media/artwork/nope").status_code == 404
    assert away(home.client).get(f"/api/v1/media/artwork/{album['artworkId']}").status_code == 401


def test_lyrics_synced_and_plain(home: Home) -> None:
    body = home.get(f"/api/v1/media/tracks/{home.track_id('तुम ही हो (Tum Hi Ho)')}/lyrics").json()
    assert_matches(body, "Lyrics")
    assert body["kind"] == "synced"
    assert body["lines"][0] == {"timeMs": 500, "text": "Hum tere bin ab reh nahi sakte"}
    body = home.get(f"/api/v1/media/tracks/{home.track_id('Sundari Kannal')}/lyrics").json()
    assert body["kind"] == "plain"
    assert body["lines"][0]["text"] == "Sundari kannal oru sedhi"
    body = home.get(f"/api/v1/media/tracks/{home.track_id('Dreams')}/lyrics").json()
    assert body == {"kind": "none", "lines": []}


def test_missing_ffmpeg_says_so(home: Home) -> None:
    home.client.app.state.library.transcoder.ffmpeg = None
    tid = home.track_id("Mental Manadhil")
    r = home.post(f"/api/v1/media/tracks/{tid}/stream", json={"quality": "dataSaver"})
    assert r.status_code == 503
    assert "FFmpeg" in r.json()["detail"]
    # Lossless still works without it.
    r = home.post(f"/api/v1/media/tracks/{tid}/stream", json={"quality": "lossless"})
    assert r.status_code == 200
