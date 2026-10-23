"""M4: continuity. What one device plays is offered on the person's others."""

from __future__ import annotations

import pytest

from .conftest import assert_matches, needs_ffmpeg
from .test_people import invite, join, set_up_admin

pytestmark = needs_ffmpeg


@pytest.fixture
def tracks(home) -> list[dict]:
    auth = {"Authorization": f"Bearer {home.key}"}
    return home.client.get("/api/v1/library/tracks", headers=auth, params={"limit": 10}).json()[
        "items"
    ]


def test_the_phone_offers_what_the_mac_was_playing(home, tracks) -> None:
    c = home.client
    mac = {"installId": "mac-install-1", "deviceName": "Bilal's MacBook"}
    ids = [t["id"] for t in tracks[:3]]
    r = c.put(
        "/api/v1/sync/session",
        json={
            **mac,
            "trackId": ids[1],
            "positionMs": 102000,
            "playing": False,
            "queue": ids,
            "index": 1,
            "source": {"kind": "album", "id": tracks[0]["albumId"], "name": "Premam"},
        },
        headers=home.auth,
    )
    assert r.status_code == 200, r.text
    assert_matches(r.json(), "PlaySessionState")

    got = c.get("/api/v1/sync/session", headers=home.auth).json()["session"]
    assert got["deviceName"] == "Bilal's MacBook" and got["track"]["id"] == ids[1]
    assert got["positionMs"] == 102000 and got["index"] == 1 and len(got["queue"]) == 3
    assert got["offer"] is True and got["source"]["name"] == "Premam"

    # Stopping keeps it to carry on from, as not playing.
    c.put("/api/v1/sync/session", json={**mac}, headers=home.auth)
    assert c.get("/api/v1/sync/session", headers=home.auth).json()["session"]["playing"] is False


def test_still_playing_counts_on_and_others_dont_see_it(home, tracks, monkeypatch) -> None:
    c = home.client
    c.put(
        "/api/v1/sync/session",
        json={
            "installId": "phone-install",
            "deviceName": "Pixel 8",
            "trackId": tracks[0]["id"],
            "positionMs": 10000,
            "playing": True,
            "queue": [tracks[0]["id"]],
            "index": 0,
        },
        headers=home.auth,
    )
    from datetime import UTC, datetime, timedelta

    import hive.library.sync_api as sync

    later = datetime.now(UTC) + timedelta(seconds=5)
    monkeypatch.setattr(
        sync,
        "datetime",
        type(
            "D",
            (),
            {"now": staticmethod(lambda tz=None: later), "fromisoformat": datetime.fromisoformat},
        ),
    )
    got = c.get("/api/v1/sync/session", headers=home.auth).json()["session"]
    # Five seconds on, never past the end of the song.
    assert got["positionMs"] == min(15000, tracks[0]["durationMs"])
    assert got["positionMs"] > min(10000, tracks[0]["durationMs"] - 1)

    # Someone else in the family has their own (empty) session.
    set_up_admin(c)
    amma = join(c, "amma@example.com", invite(c, "amma@example.com"))
    assert amma.client.get("/api/v1/sync/session", headers=amma.auth).json() == {}


def test_other_devices_hear_changes_over_the_websocket(home, tracks) -> None:
    c = home.client
    with c.websocket_connect("/api/v1/sync/events?install=phone-install", headers=home.auth) as ws:
        c.put(
            "/api/v1/sync/session",
            json={
                "installId": "mac-install-1",
                "deviceName": "Bilal's MacBook",
                "trackId": tracks[0]["id"],
                "positionMs": 0,
                "playing": True,
                "queue": [tracks[0]["id"]],
                "index": 0,
            },
            headers=home.auth,
        )
        message = ws.receive_json()
        assert message["type"] == "session"
        assert message["session"]["deviceName"] == "Bilal's MacBook"


def test_signed_in_only(home) -> None:
    from starlette.testclient import TestClient
    from starlette.websockets import WebSocketDisconnect

    away = TestClient(home.client.app, client=("100.64.0.9", 50000))
    assert away.get("/api/v1/sync/session").status_code == 401
    with pytest.raises(WebSocketDisconnect), away.websocket_connect("/api/v1/sync/events") as ws:
        ws.receive_json()
