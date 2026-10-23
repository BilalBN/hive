"""M4: backups of everything Hive knows, on a schedule or now, and restoring
one at the next start without letting signed-out devices back in."""

from __future__ import annotations

import zipfile
from datetime import datetime

from fastapi.testclient import TestClient

from hive.app import create_app
from hive.config import Settings

from .conftest import HOME_COMPUTER, assert_matches
from .test_people import invite, join, set_up_admin


def started(settings: Settings) -> TestClient:
    c = TestClient(create_app(settings), client=HOME_COMPUTER)
    c.__enter__()
    c.app.state.people.resend_seconds = 0
    c.app.state.people.codes_per_hour = 50
    return c


def test_back_up_now_and_list(settings: Settings) -> None:
    c = started(settings)
    try:
        set_up_admin(c)
        art = settings.artwork_dir / "ab" / "cover.jpg"
        art.parent.mkdir(parents=True, exist_ok=True)
        art.write_bytes(b"\xff\xd8 a cover")
        status = c.get("/api/v1/admin/backups").json()
        assert_matches(status, "BackupStatus")
        assert status["items"] == [] and status["enabled"] is True and status["time"] == "03:00"
        assert status["folder"] == str(settings.data_dir / "backups")

        made = c.post("/api/v1/admin/backups")
        assert made.status_code == 200, made.text
        assert_matches(made.json(), "Backup")
        assert made.json()["kind"] == "manual" and made.json()["people"] == 1
        with zipfile.ZipFile(settings.data_dir / "backups" / made.json()["id"]) as z:
            assert {"manifest.json", "server.db", "artwork/ab/cover.jpg"} <= set(z.namelist())
        status = c.get("/api/v1/admin/backups").json()
        assert [i["id"] for i in status["items"]] == [
            made.json()["id"]
        ] and "lastError" not in status
        actions = [e["action"] for e in c.get("/api/v1/admin/audit").json()["items"]]
        assert "backup.run" in actions
    finally:
        c.__exit__(None, None, None)


def test_settings_keep_and_a_folder_that_cannot_be_written(settings: Settings, tmp_path) -> None:
    c = started(settings)
    try:
        drive = tmp_path / "BackupDrive" / "Hive"
        r = c.put(
            "/api/v1/admin/backups/settings",
            json={"folder": str(drive), "keep": 2, "time": "02:30"},
        )
        assert r.status_code == 200, r.text
        assert r.json()["folder"] == str(drive) and r.json()["keep"] == 2
        for _ in range(3):
            assert c.post("/api/v1/admin/backups").status_code == 200
        assert len(list(drive.glob("hive-backup-*.zip"))) == 2

        blocked = tmp_path / "file"
        blocked.write_text("not a folder")
        r = c.put("/api/v1/admin/backups/settings", json={"folder": str(blocked / "x")})
        assert r.status_code == 422 and "can't write" in r.json()["detail"]
        assert (
            c.put("/api/v1/admin/backups/settings", json={"folder": "relative/path"}).status_code
            == 422
        )
        assert c.put("/api/v1/admin/backups/settings", json={"time": "25:00"}).status_code == 422
    finally:
        c.__exit__(None, None, None)


def test_daily_backup_is_due_once_after_its_time(settings: Settings) -> None:
    c = started(settings)
    try:
        b = c.app.state.backups
        tz = datetime.now().astimezone().tzinfo
        assert not b.due(datetime(2026, 10, 22, 2, 59, tzinfo=tz))
        assert b.due(datetime(2026, 10, 22, 3, 1, tzinfo=tz))
        b.home.set("backup_scheduled_on", "2026-10-22")
        assert not b.due(datetime(2026, 10, 22, 9, 0, tzinfo=tz))
        assert b.due(datetime(2026, 10, 23, 3, 0, tzinfo=tz))
        b.configure(enabled=False)
        assert not b.due(datetime(2026, 10, 23, 3, 0, tzinfo=tz))
    finally:
        c.__exit__(None, None, None)


def test_restore_at_the_next_start_keeps_later_sign_outs(settings: Settings) -> None:
    c = started(settings)
    try:
        set_up_admin(c)
        phone = join(c, "amma@example.com", invite(c, "amma@example.com"))
        device_id = phone.session["deviceId"]
        c.patch("/api/v1/admin/settings", json={"homeName": "Before"})
        backup = c.post("/api/v1/admin/backups").json()

        # After the backup: renamed, and Amma's phone signed out.
        c.patch("/api/v1/admin/settings", json={"homeName": "After"})
        assert c.post(f"/api/v1/admin/devices/{device_id}/revoke").status_code == 200

        staged = c.post(f"/api/v1/admin/backups/{backup['id']}/restore")
        assert staged.status_code == 200, staged.text
        assert_matches(staged.json(), "BackupStatus")
        assert staged.json()["pendingRestore"]["id"] == backup["id"]
        kinds = [i["kind"] for i in staged.json()["items"]]
        assert "before-restore" in kinds  # today's state, kept first

        # Cancel, then choose it again.
        assert "pendingRestore" not in c.delete("/api/v1/admin/backups/restore").json()
        c.post(f"/api/v1/admin/backups/{backup['id']}/restore")
    finally:
        c.__exit__(None, None, None)

    c = started(settings)  # Hive restarts
    try:
        assert c.get("/api/v1/admin/settings").json()["homeName"] == "Before"
        status = c.get("/api/v1/admin/backups").json()
        assert status["restored"]["id"] == backup["id"] and "pendingRestore" not in status
        # Signed out after the backup: stays signed out.
        devices = c.get("/api/v1/admin/devices").json()["items"]
        assert next(d for d in devices if d["id"] == device_id)["status"] != "active"
        r = phone.client.get("/api/v1/library/home", headers=phone.auth)
        assert r.status_code == 401
        actions = [e["action"] for e in c.get("/api/v1/admin/audit").json()["items"]]
        assert "backup.restored" in actions
    finally:
        c.__exit__(None, None, None)


def test_restore_refuses_what_isnt_a_backup(settings: Settings) -> None:
    c = started(settings)
    try:
        folder = settings.data_dir / "backups"
        folder.mkdir(parents=True)
        (folder / "hive-backup-bad.zip").write_bytes(b"not a zip")
        r = c.post("/api/v1/admin/backups/hive-backup-bad.zip/restore")
        assert r.status_code == 422 and "damaged" in r.json()["detail"]
        assert c.post("/api/v1/admin/backups/..%2Fserver.db/restore").status_code == 404
        assert c.delete("/api/v1/admin/backups/hive-backup-nope.zip").status_code == 404
    finally:
        c.__exit__(None, None, None)


def test_signed_in_admin_only(settings: Settings) -> None:
    c = started(settings)
    try:
        other = TestClient(c.app, client=("100.64.0.9", 50000))
        assert other.get("/api/v1/admin/backups").status_code == 401
        assert other.post("/api/v1/admin/backups").status_code == 401
    finally:
        c.__exit__(None, None, None)


def test_backup_from_the_command_line_before_an_update(settings: Settings, capsys) -> None:
    """The installer runs `hive backup --kind before-update` with Hive stopped."""
    from hive.__main__ import backup

    assert backup(settings, "before-update") == 0  # a new install: nothing yet
    assert "nothing to back up" in capsys.readouterr().out
    c = started(settings)
    set_up_admin(c)
    c.__exit__(None, None, None)
    assert backup(settings, "before-update") == 0
    made = list((settings.data_dir / "backups").glob("hive-backup-*-before-update.zip"))
    assert len(made) == 1
    with zipfile.ZipFile(made[0]) as z:
        assert "server.db" in z.namelist()
