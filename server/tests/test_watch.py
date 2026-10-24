"""M4: System health, Logs, alerts to the admins, and the minimum app version."""

from __future__ import annotations

import logging
from collections import namedtuple

from fastapi.testclient import TestClient

from .conftest import assert_matches
from .test_people import invite, join, set_up_admin


def test_system_health_and_alerts(server: TestClient, monkeypatch) -> None:
    set_up_admin(server)
    report = server.get("/api/v1/admin/system")
    assert report.status_code == 200, report.text
    assert_matches(report.json(), "SystemHealth")
    assert report.json()["disks"] and report.json()["packaged"] is False

    # A nearly full drive: on System health, on the Overview, and one email a day.
    Usage = namedtuple("Usage", "total used free")
    monkeypatch.setattr(
        "hive.watch.shutil.disk_usage", lambda p: Usage(500 * 1024**3, 0, 100 * 1024**2)
    )
    problems = server.get("/api/v1/admin/system").json()["problems"]
    assert any(p["key"].startswith("disk-full") for p in problems)
    alerts = server.get("/api/v1/admin/overview").json()["alerts"]
    assert any("nearly full" in a["text"] for a in alerts)
    notes = []
    monkeypatch.setattr(
        server.app.state.people, "_notify_admins", lambda note=None, kind=None: notes.append(note)
    )
    watch = server.app.state.watch
    assert watch.check() and len(notes) == 1
    assert "nearly full" in notes[0][1] and "Hive Admin" in notes[0][1]
    assert watch.check() == []  # not again today


def test_logs_with_filters(server: TestClient, caplog) -> None:
    caplog.set_level(logging.INFO)  # as the server sets it up
    set_up_admin(server)
    logging.getLogger("hive.scan").warning("a folder couldn't be read")
    logging.getLogger("hive.stream").info("stream started")
    page = server.get("/api/v1/admin/logs", params={"level": "WARNING"})
    assert page.status_code == 200
    assert_matches(page.json(), "LogPage")
    texts = [line["text"] for line in page.json()["items"]]
    assert "a folder couldn't be read" in texts and "stream started" not in texts
    found = server.get("/api/v1/admin/logs", params={"q": "stream started"}).json()["items"]
    assert found[0]["area"] == "stream"
    assert "scan" in server.get("/api/v1/admin/logs").json()["areas"]
    assert server.get("/api/v1/admin/logs/file").status_code == 200


def test_minimum_app_version(server: TestClient) -> None:
    set_up_admin(server)
    join(server, "amma@example.com", invite(server, "amma@example.com"))  # app 0.2.0
    r = server.patch("/api/v1/admin/settings", json={"minAppVersion": "0.3.0"})
    assert r.status_code == 200 and r.json()["minAppVersion"] == "0.3.0"
    assert server.get("/api/v1/health").json()["minAppVersion"] == "0.3.0"
    health = server.get("/api/v1/admin/system").json()
    assert health["devicesOnOldApps"] == 1
    assert any(p["key"] == "old-apps" for p in health["problems"])
    assert server.patch("/api/v1/admin/settings", json={"minAppVersion": "soon"}).status_code == 422


def test_admins_only(server: TestClient) -> None:
    other = TestClient(server.app, client=("100.64.0.9", 50000))
    for path in ("/api/v1/admin/system", "/api/v1/admin/logs", "/api/v1/admin/logs/file"):
        assert other.get(path).status_code == 401
