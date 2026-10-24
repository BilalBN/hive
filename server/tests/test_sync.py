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


# ------------------------------------------------------------------ M6: remotes


def _drain_until(ws, kind: str) -> dict:
    while True:
        m = ws.receive_json()
        if m["type"] == kind:
            return m


def test_devices_and_a_phone_as_a_remote(home, tracks) -> None:
    c = home.client
    mac_url = "/api/v1/sync/events?install=mac-install-1&name=Bilal%27s%20MacBook"
    phone_url = "/api/v1/sync/events?install=phone-install&name=Bilal%27s%20Pixel"
    with (
        c.websocket_connect(mac_url, headers=home.auth) as mac,
        c.websocket_connect(phone_url, headers=home.auth) as phone,
    ):
        assert _drain_until(mac, "devices")  # the phone opened Hive
        devices = c.get("/api/v1/sync/devices", headers=home.auth).json()
        assert_matches(devices, "DeviceList")
        names = {d["installId"]: d["deviceName"] for d in devices["items"]}
        assert names == {"mac-install-1": "Bilal's MacBook", "phone-install": "Bilal's Pixel"}
        assert not any(d["playing"] for d in devices["items"])

        # The Mac plays; the phone hears it as a device change.
        ids = [t["id"] for t in tracks[:3]]
        c.put(
            "/api/v1/sync/session",
            json={
                "installId": "mac-install-1",
                "deviceName": "Bilal's MacBook",
                "trackId": ids[0],
                "positionMs": 1000,
                "playing": True,
                "queue": ids,
                "index": 0,
            },
            headers=home.auth,
        )
        device = _drain_until(phone, "device")["device"]
        assert device["installId"] == "mac-install-1" and device["playing"] is True
        assert device["track"]["id"] == ids[0]

        # The phone pauses the Mac, then moves playback to the Mac from its own queue.
        r = c.post(
            "/api/v1/sync/devices/mac-install-1/command",
            json={"action": "pause", "fromInstall": "phone-install"},
            headers=home.auth,
        )
        assert r.status_code == 200 and r.json() == {"sent": True}
        got = _drain_until(mac, "command")
        assert got["command"] == {"action": "pause"} and got["fromName"] == "Bilal's Pixel"

        c.post(
            "/api/v1/sync/devices/mac-install-1/command",
            json={
                "action": "load",
                "fromInstall": "phone-install",
                "queue": [ids[2], ids[1]],
                "index": 1,
                "positionMs": 5000,
            },
            headers=home.auth,
        )
        load = _drain_until(mac, "command")["command"]
        assert load["action"] == "load" and load["index"] == 1 and load["positionMs"] == 5000
        assert [t["id"] for t in load["queue"]] == [ids[2], ids[1]] and load["playing"] is True

        bad = c.post(
            "/api/v1/sync/devices/mac-install-1/command",
            json={"action": "seek", "fromInstall": "phone-install"},
            headers=home.auth,
        )
        assert bad.status_code == 422
        assert (
            c.post(
                "/api/v1/sync/devices/mac-install-1/command",
                json={"action": "dance", "fromInstall": "phone-install"},
                headers=home.auth,
            ).status_code
            == 422
        )
    # Closed: no longer listed, and commands say so.
    assert c.get("/api/v1/sync/devices", headers=home.auth).json() == {"items": []}
    r = c.post(
        "/api/v1/sync/devices/mac-install-1/command",
        json={"action": "play", "fromInstall": "phone-install"},
        headers=home.auth,
    )
    assert r.status_code == 409
