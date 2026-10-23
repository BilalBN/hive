"""M4: how the server is doing. Recent log lines for Hive Admin → Logs, the
System health page (disks, backups, devices on old apps), and an email to
the admins when something needs them: at most once a day per problem, and
never with personal details in it."""

from __future__ import annotations

import collections
import logging
import platform
import shutil
import sys
import threading
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from hive import __version__
from hive.models import Device

log = logging.getLogger("hive.watch")

LOW_FRACTION = 0.10  # under 10 % free…
LOW_BYTES = 5 * 1024**3  # …or under 5 GB: running low
FULL_BYTES = 512 * 1024**2  # under 512 MB: nearly full
BACKUP_STALE = timedelta(days=3)
ALERT_EVERY = timedelta(hours=24)


# ------------------------------------------------------------------ log lines


class RecentLines(logging.Handler):
    """The last few thousand log lines, kept in memory for Hive Admin."""

    def __init__(self, keep: int = 3000) -> None:
        super().__init__(level=logging.DEBUG)
        self.lines: collections.deque[dict[str, Any]] = collections.deque(maxlen=keep)
        self.counter = 0

    def emit(self, record: logging.LogRecord) -> None:
        try:
            area = getattr(record, "area", None) or (
                record.name.split(".", 2)[1]
                if record.name.startswith("hive.")
                else record.name.split(".")[0]
            )
            text = record.getMessage()
            if record.exc_info and record.levelno >= logging.ERROR:
                text += "\n" + logging.Formatter().formatException(record.exc_info).splitlines()[-1]
            self.counter += 1
            self.lines.append(
                {
                    "id": self.counter,
                    "at": datetime.fromtimestamp(record.created, UTC)
                    .isoformat()
                    .replace("+00:00", "Z"),
                    "level": record.levelname if record.levelname in LEVELS else "INFO",
                    "area": area[:24],
                    "text": text[:2000],
                    "_t": record.created,
                }
            )
        except Exception:  # noqa: BLE001 — logging must never fail the server
            pass

    def query(
        self, level: str = "INFO", q: str = "", area: str | None = None, limit: int = 300
    ) -> list[dict[str, Any]]:
        floor = LEVELS.index(level) if level in LEVELS else 1
        q = q.lower()
        out = []
        for line in reversed(self.lines):
            if LEVELS.index(line["level"]) < floor:
                continue
            if area and line["area"] != area:
                continue
            if q and q not in line["text"].lower() and q not in line["area"]:
                continue
            out.append({k: v for k, v in line.items() if k != "_t"})
            if len(out) >= limit:
                break
        return out

    def count_since(self, level: str, since: float) -> int:
        return sum(1 for line in self.lines if line["level"] == level and line["_t"] >= since)

    def areas(self) -> list[str]:
        return sorted({line["area"] for line in self.lines})


LEVELS = ["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"]
recent = RecentLines()


def keep_recent_lines() -> None:
    """Attach the in-memory copy to the root logger (once)."""
    root = logging.getLogger()
    if recent not in root.handlers:
        root.addHandler(recent)


# ------------------------------------------------------------------ health


def _disk(label: str, path: Path) -> dict[str, Any] | None:
    probe = path
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    try:
        usage = shutil.disk_usage(probe)
    except OSError:
        return None
    level = "ok"
    if usage.free < FULL_BYTES:
        level = "full"
    elif usage.free < LOW_BYTES or usage.free < usage.total * LOW_FRACTION:
        level = "low"
    return {
        "label": label,
        "path": str(path),
        "freeBytes": usage.free,
        "totalBytes": usage.total,
        "level": level,
    }


def _older(version: str | None, minimum: str) -> bool:
    def parts(v: str) -> tuple[int, ...]:
        try:
            return tuple(int(p) for p in v.split("+")[0].split(".")[:3])
        except ValueError:
            return (0,)

    return version is not None and parts(version) < parts(minimum)


def min_app_version(app) -> str:
    return app.state.people.home.get("min_app_version") or app.state.settings.min_app_version


def report(app) -> dict[str, Any]:
    """Everything System health shows, and the problems worth an alert."""
    settings = app.state.settings
    backups = app.state.backups
    disks = []
    seen: set[int] = set()
    places = [("Hive's data", settings.data_dir)]
    places += [(f"Music: {p.name or p}", p) for p in settings.music_folders]
    places.append(("Backups", backups.folder))
    for label, path in places:
        d = _disk(label, path)
        if d is None:
            continue
        # One line per drive (several folders are often on the same one).
        key = hash((d["totalBytes"], d["freeBytes"] // (1024**2)))
        if key in seen:
            continue
        seen.add(key)
        disks.append(d)

    minimum = min_app_version(app)
    with Session(app.state.db.engine) as s:
        versions = list(s.scalars(select(Device.app_version).where(Device.status == "active")))
    old_apps = sum(1 for v in versions if _older(v, minimum))

    day_ago = time.time() - 86400
    started = app.state.started_at
    last_backup = backups.home.get("backup_last_at")
    body: dict[str, Any] = {
        "serverVersion": __version__,
        "startedAt": started.isoformat().replace("+00:00", "Z"),
        "uptimeSeconds": int((datetime.now(UTC) - started).total_seconds()),
        "system": f"{platform.system()} {platform.release()}",
        "python": platform.python_version(),
        "packaged": bool(getattr(sys, "frozen", False)),
        "dataFolder": str(settings.data_dir),
        "databaseBytes": settings.database_path.stat().st_size
        if settings.database_path.exists()
        else 0,
        "disks": disks,
        "minAppVersion": minimum,
        "devices": len(versions),
        "devicesOnOldApps": old_apps,
        "errorsToday": recent.count_since("ERROR", day_ago)
        + recent.count_since("CRITICAL", day_ago),
        "warningsToday": recent.count_since("WARNING", day_ago),
        "ffmpeg": app.state.library.ffmpeg is not None,
    }
    if last_backup:
        body["lastBackupAt"] = last_backup
    body["problems"] = problems(app, body)
    return body


def problems(app, body: dict[str, Any]) -> list[dict[str, str]]:
    """Plain words for what needs the admin, each with a stable key."""
    out = []
    for d in body["disks"]:
        free = d["freeBytes"] / 1024**3
        if d["level"] == "full":
            out.append(
                {
                    "key": f"disk-full:{d['label']}",
                    "level": "problem",
                    "text": f"The drive for {d['label']} is nearly full ({free:.1f} GB free). "
                    "Hive may stop saving changes; free up some space.",
                }
            )
        elif d["level"] == "low":
            out.append(
                {
                    "key": f"disk-low:{d['label']}",
                    "level": "warning",
                    "text": f"The drive for {d['label']} is running low ({free:.1f} GB free).",
                }
            )
    backups = app.state.backups
    error = backups.home.get("backup_last_error")
    if error:
        out.append(
            {
                "key": "backup-failed",
                "level": "problem",
                "text": f"The last backup didn't work: {error}",
            }
        )
    elif backups.enabled:
        last = body.get("lastBackupAt")
        stale = (
            last is None
            or datetime.fromisoformat(last.replace("Z", "+00:00"))
            < datetime.now(UTC) - BACKUP_STALE
        )
        uptime_ok = body["uptimeSeconds"] > 2 * 86400  # give a new home a couple of days
        if stale and (last is not None or uptime_ok):
            out.append(
                {
                    "key": "backup-stale",
                    "level": "warning",
                    "text": "There hasn't been a backup for more than 3 days. "
                    "Hive Admin → Backups.",
                }
            )
    if not body["ffmpeg"]:
        out.append(
            {
                "key": "ffmpeg",
                "level": "problem",
                "text": "FFmpeg isn't installed, so some songs can't be read or played "
                "at lower quality.",
            }
        )
    if body["devicesOnOldApps"]:
        n = body["devicesOnOldApps"]
        out.append(
            {
                "key": "old-apps",
                "level": "info",
                "text": f"{n} {'device is' if n == 1 else 'devices are'} on an app older than "
                f"{body['minAppVersion']} and will be asked to update.",
            }
        )
    return out


class Watch:
    """Every half hour: anything that needs the admins gets one email a day."""

    def __init__(self, app) -> None:
        self.app = app
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        self._thread = threading.Thread(target=self._loop, name="hive-watch", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=5)

    def _loop(self) -> None:
        while not self._stop.wait(1800):
            try:
                self.check()
            except Exception:
                log.exception("health check failed")

    def check(self) -> list[str]:
        """Email the admins about new problems; returns the keys emailed."""
        from hive.people import mail

        home = self.app.state.people.home
        now = datetime.now(UTC)
        sent = []
        for p in report(self.app)["problems"]:
            if p["level"] == "info":
                continue
            key = f"alerted:{p['key']}"
            last = home.get(key)
            if last and datetime.fromisoformat(last) > now - ALERT_EVERY:
                continue
            self.app.state.people._notify_admins(mail.health_note(home.home_name, p["text"]))
            home.set(key, now.isoformat())
            sent.append(p["key"])
        if sent:
            log.warning("told the admins about: %s", ", ".join(sent))
        return sent
