"""M4: backups of everything Hive knows, and restoring one.

A backup is one zip file: the database (people, devices, likes, playlists,
history, settings, what Hive found out about each album), the cover art
Hive keeps, the server's settings file for reference, and a manifest. The
music itself isn't in it: it lives in the music folders, and backing those
up is a job for the drive they're on. Song fingerprints aren't either:
they're rebuilt from the music.

Restoring is staged and finished at the next start, before anything opens
the database. Anyone signed out or paused after the backup was made stays
signed out or paused: the database being replaced is read for that first.
"""

from __future__ import annotations

import json
import logging
import re
import shutil
import sqlite3
import tempfile
import threading
import zipfile
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from hive import __version__
from hive.config import Settings
from hive.people.settings import HomeSettings

log = logging.getLogger("hive.backups")

FORMAT = 1
PREFIX = "hive-backup-"
PENDING = "restore.pending"
KINDS = ("manual", "scheduled", "before-restore", "before-update")


class BackupProblem(Exception):
    """Something the admin can act on, in plain words."""


def _iso(t: datetime) -> str:
    return t.astimezone(UTC).isoformat().replace("+00:00", "Z")


def _copy_database(source: Path, target: Path) -> None:
    """A consistent copy of a live SQLite database (WAL included)."""
    src = sqlite3.connect(source)
    dst = sqlite3.connect(target)
    try:
        src.backup(dst)
    finally:
        dst.close()
        src.close()


def _count(db: Path, table: str) -> int:
    con = sqlite3.connect(db)
    try:
        return int(con.execute(f"SELECT count(*) FROM {table}").fetchone()[0])  # noqa: S608
    except sqlite3.Error:
        return 0
    finally:
        con.close()


def read_manifest(path: Path) -> dict[str, Any]:
    try:
        with zipfile.ZipFile(path) as z:
            names = set(z.namelist())
            if "manifest.json" not in names or "server.db" not in names:
                raise BackupProblem("That file isn't a Hive backup.")
            manifest = json.loads(z.read("manifest.json"))
    except (zipfile.BadZipFile, OSError, ValueError) as e:
        raise BackupProblem("That backup can't be read; it may be damaged.") from e
    if int(manifest.get("format", 0)) > FORMAT:
        raise BackupProblem("That backup was made by a newer Hive. Update Hive first.")
    return manifest


class Backups:
    """Makes backups (now, or daily on a schedule), lists and prunes them,
    and stages a restore for the next start."""

    def __init__(self, settings: Settings, home: HomeSettings) -> None:
        self.settings = settings
        self.home = home
        self.lock = threading.Lock()
        self.running = False
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    # ------------------------------------------------------------ settings
    @property
    def folder(self) -> Path:
        saved = self.home.get("backup_folder")
        return Path(saved) if saved else self.settings.data_dir / "backups"

    @property
    def enabled(self) -> bool:
        return self.home.get("backup_enabled") != "0"

    @property
    def time(self) -> str:
        return self.home.get("backup_time") or "03:00"

    @property
    def keep(self) -> int:
        return int(self.home.get("backup_keep") or 14)

    def configure(
        self,
        *,
        folder: str | None = None,
        enabled: bool | None = None,
        time: str | None = None,
        keep: int | None = None,
    ) -> None:
        if folder is not None:
            path = Path(folder.strip()).expanduser()
            if not path.is_absolute():
                raise BackupProblem("Give the full path of the backup folder.")
            try:
                path.mkdir(parents=True, exist_ok=True)
                probe = path / ".hive-write-test"
                probe.write_text("ok")
                probe.unlink()
            except OSError as e:
                raise BackupProblem(
                    f"Hive can't write to {path}. Is the drive connected? ({e.strerror})"
                ) from e
            default = self.settings.data_dir / "backups"
            self.home.set("backup_folder", None if path == default else str(path))
        if enabled is not None:
            self.home.set("backup_enabled", "1" if enabled else "0")
        if time is not None:
            self.home.set("backup_time", time)
        if keep is not None:
            self.home.set("backup_keep", str(keep))

    # ------------------------------------------------------------ backups
    def items(self) -> list[dict[str, Any]]:
        if not self.folder.exists():
            return []
        out = []
        for f in sorted(self.folder.glob(f"{PREFIX}*.zip"), reverse=True):
            try:
                m = read_manifest(f)
            except BackupProblem:
                continue
            out.append(
                {
                    "id": f.name,
                    "at": m["createdAt"],
                    "sizeBytes": f.stat().st_size,
                    "kind": m.get("kind", "manual"),
                    "serverVersion": m.get("serverVersion", ""),
                    "people": m.get("people", 0),
                    "tracks": m.get("tracks", 0),
                    "musicFolders": m.get("musicFolders", []),
                }
            )
        return out

    def path_of(self, backup_id: str) -> Path:
        name = Path(backup_id).name
        path = self.folder / name
        if name != backup_id or not name.startswith(PREFIX) or not path.is_file():
            raise FileNotFoundError(backup_id)
        return path

    def run(self, kind: str = "manual") -> dict[str, Any]:
        with self.lock:
            self.running = True
            try:
                item = self._run(kind)
                self.home.set("backup_last_at", item["at"])
                self.home.set("backup_last_error", None)
                return item
            except Exception as e:
                self.home.set("backup_last_at", _iso(datetime.now(UTC)))
                self.home.set(
                    "backup_last_error",
                    str(e) if isinstance(e, BackupProblem) else f"The backup failed: {e}",
                )
                raise
            finally:
                self.running = False

    def _run(self, kind: str) -> dict[str, Any]:
        s = self.settings
        now = datetime.now(UTC)
        folder = self.folder
        try:
            folder.mkdir(parents=True, exist_ok=True)
        except OSError as e:
            raise BackupProblem(
                f"Hive can't reach the backup folder {folder}. Is the drive connected?"
            ) from e
        stamp = f"{now.strftime('%Y%m%d-%H%M%S')}{now.microsecond // 1000:03d}"
        name = f"{PREFIX}{stamp}-{kind}.zip"
        part = folder / f"{name}.part"
        with tempfile.TemporaryDirectory(prefix="hive-backup-") as tmp:
            db = Path(tmp) / "server.db"
            _copy_database(s.database_path, db)
            manifest = {
                "format": FORMAT,
                "kind": kind,
                "createdAt": _iso(now),
                "serverVersion": __version__,
                "homeName": self.home.home_name,
                "people": _count(db, "users"),
                "tracks": _count(db, "tracks"),
                "musicFolders": [str(p) for p in s.music_folders],
            }
            try:
                with zipfile.ZipFile(part, "w", zipfile.ZIP_DEFLATED) as z:
                    z.writestr("manifest.json", json.dumps(manifest, indent=2))
                    z.write(db, "server.db")
                    config = s.data_dir / "hive.toml"
                    if config.is_file():
                        z.write(config, "hive.toml")
                    if s.artwork_dir.is_dir():
                        for f in sorted(s.artwork_dir.rglob("*")):
                            if f.is_file():
                                # Covers are already compressed.
                                z.write(
                                    f,
                                    f"artwork/{f.relative_to(s.artwork_dir).as_posix()}",
                                    compress_type=zipfile.ZIP_STORED,
                                )
                part.rename(folder / name)
            except OSError as e:
                part.unlink(missing_ok=True)
                raise BackupProblem(f"Hive couldn't write the backup to {folder}: {e}") from e
        self._prune()
        log.info("backup made (%s)", kind)
        return next(i for i in self.items() if i["id"] == name)

    def _prune(self) -> None:
        """Keep the newest [keep] scheduled and manual backups; safety copies
        made before a restore or update are kept for 30 days."""
        everyday = [i for i in self.items() if i["kind"] in ("manual", "scheduled")]
        for old in everyday[self.keep :]:
            (self.folder / old["id"]).unlink(missing_ok=True)
        month_ago = _iso(datetime.now(UTC) - timedelta(days=30))
        for old in self.items():
            if old["kind"] not in ("manual", "scheduled") and old["at"] < month_ago:
                (self.folder / old["id"]).unlink(missing_ok=True)

    def delete(self, backup_id: str) -> None:
        self.path_of(backup_id).unlink()

    # ------------------------------------------------------------ restore
    @property
    def pending_file(self) -> Path:
        return self.settings.data_dir / PENDING

    def pending(self) -> dict[str, Any] | None:
        try:
            return json.loads(self.pending_file.read_text())
        except (OSError, ValueError):
            return None

    def stage_restore(
        self, backup_id: str, folders: dict[str, str] | None = None
    ) -> dict[str, Any]:
        """[folders]: where each of the backup's music folders is now (moving
        to another computer); songs keep their likes, plays and playlists."""
        path = self.path_of(backup_id)
        manifest = read_manifest(path)
        for new in (folders or {}).values():
            if not Path(new).is_absolute():
                raise BackupProblem("Give the full path of each music folder.")
        # Today's state is kept first, so the restore can be undone.
        safety = self.run("before-restore")
        staged = {
            "id": backup_id,
            "path": str(path),
            "backupAt": manifest["createdAt"],
            "stagedAt": _iso(datetime.now(UTC)),
            "safety": safety["id"],
            "folders": folders or {},
        }
        self.pending_file.write_text(json.dumps(staged))
        return staged

    def cancel_restore(self) -> None:
        self.pending_file.unlink(missing_ok=True)

    # ------------------------------------------------------------ schedule
    def start(self) -> None:
        self._thread = threading.Thread(target=self._loop, name="hive-backups", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=5)

    def due(self, now: datetime | None = None) -> bool:
        """The daily backup hasn't run today and its time has come (local time)."""
        if not self.enabled:
            return False
        now = (now or datetime.now()).astimezone()
        hour, minute = (int(x) for x in self.time.split(":"))
        if (now.hour, now.minute) < (hour, minute):
            return False
        return self.home.get("backup_scheduled_on") != now.date().isoformat()

    def _loop(self) -> None:
        while not self._stop.wait(60):
            try:
                if self.due():
                    self.home.set(
                        "backup_scheduled_on", datetime.now().astimezone().date().isoformat()
                    )
                    self.run("scheduled")
            except Exception:
                log.exception("scheduled backup failed")


def finish_pending_restore(settings: Settings) -> str | None:
    """At start-up, before the database opens: put a staged backup in place.
    Returns the backup's name when one was restored."""
    pending_file = settings.data_dir / PENDING
    if not pending_file.exists():
        return None
    staged = json.loads(pending_file.read_text())
    source = Path(staged["path"])
    pending_file.unlink()
    try:
        read_manifest(source)
    except BackupProblem:
        log.error("the backup to restore is missing or damaged; nothing was changed")
        return None
    data = settings.data_dir
    current = settings.database_path
    later = data / f"before-restore-{datetime.now(UTC).strftime('%Y%m%d-%H%M%S')}.db"
    if current.exists():
        _copy_database(current, later)
    with zipfile.ZipFile(source) as z:
        for suffix in ("", "-wal", "-shm"):
            Path(f"{current}{suffix}").unlink(missing_ok=True)
        with z.open("server.db") as src, current.open("wb") as dst:
            shutil.copyfileobj(src, dst)
        art = settings.artwork_dir
        if art.exists():
            shutil.rmtree(art)
        for name in z.namelist():
            if name.startswith("artwork/") and not name.endswith("/"):
                target = art / name.removeprefix("artwork/")
                target.parent.mkdir(parents=True, exist_ok=True)
                with z.open(name) as src, target.open("wb") as dst:
                    shutil.copyfileobj(src, dst)
    if later.exists():
        reapply_signouts(later, current)
        keep_this_computer(later, current)
        later.unlink()
    if staged.get("folders"):
        moved = move_music_folders(current, staged["folders"])
        log.info("music folders moved for %d songs", moved)
    log.info("backup restored (%s)", source.name)
    return source.name


def reapply_signouts(later: Path, restored: Path) -> int:
    """Devices signed out, people paused, and invites cancelled or used in
    the database being replaced stay that way in the restored one.
    Returns how many were re-applied."""
    con = sqlite3.connect(restored)
    try:
        return _reapply(con, later)
    except sqlite3.OperationalError:
        # A backup from before devices and invites existed (M1): nothing to keep.
        return 0
    finally:
        con.close()


def _reapply(con: sqlite3.Connection, later: Path) -> int:
    con.execute("ATTACH DATABASE ? AS later", (str(later),))
    n = 0
    n += con.execute(
        """UPDATE devices SET status = 'revoked', refresh_hash = NULL,
               revoked_at = (SELECT l.revoked_at FROM later.devices l WHERE l.id = devices.id),
               revoked_by = (SELECT l.revoked_by FROM later.devices l WHERE l.id = devices.id)
           WHERE status = 'active'
             AND id IN (SELECT id FROM later.devices WHERE status = 'revoked')"""
    ).rowcount
    n += con.execute(
        """UPDATE users SET status = 'suspended'
           WHERE status = 'active'
             AND id IN (SELECT id FROM later.users WHERE status = 'suspended')"""
    ).rowcount
    n += con.execute(
        """UPDATE invites SET
               revoked_at = (SELECT l.revoked_at FROM later.invites l WHERE l.id = invites.id),
               used_at = COALESCE(used_at,
                   (SELECT l.used_at FROM later.invites l WHERE l.id = invites.id))
           WHERE revoked_at IS NULL AND used_at IS NULL
             AND id IN (SELECT id FROM later.invites
                        WHERE revoked_at IS NOT NULL OR used_at IS NOT NULL)"""
    ).rowcount
    con.commit()
    con.execute("DETACH DATABASE later")
    return n


# Settings about this computer rather than the family: restoring a backup
# made on another computer keeps this computer's own.
THIS_COMPUTER = ("address", "private_network_link", "backup_folder", "backup_scheduled_on")


def keep_this_computer(later: Path, restored: Path) -> None:
    con = sqlite3.connect(restored)
    try:
        con.execute("ATTACH DATABASE ? AS later", (str(later),))
        marks = ",".join("?" * len(THIS_COMPUTER))
        con.execute(f"DELETE FROM server_meta WHERE key IN ({marks})", THIS_COMPUTER)  # noqa: S608
        con.execute(
            f"INSERT INTO server_meta (key, value, updated_at) SELECT key, value, updated_at "  # noqa: S608
            f"FROM later.server_meta "
            f"WHERE key IN ({marks})",
            THIS_COMPUTER,
        )
        con.commit()
        con.execute("DETACH DATABASE later")
    except sqlite3.OperationalError:
        pass  # a very old backup without these settings
    finally:
        con.close()


def _moved(path: str, old: str, new: str) -> str | None:
    """[path] under [old], as it is under [new] on this computer (separators
    converted, so a Mac path becomes a Windows one)."""
    old_s = old.rstrip("/\\")
    if path != old_s and not (path.startswith(old_s) and path[len(old_s)] in "/\\"):
        return None
    rest = [p for p in re.split(r"[/\\]", path[len(old_s) :]) if p]
    return str(Path(new, *rest))


def move_music_folders(db: Path, folders: dict[str, str]) -> int:
    """Point songs, albums and the import list at the folders' new places.
    Song ids stay the same, so likes, playlists and history stay with them.
    Returns how many songs were moved."""
    con = sqlite3.connect(db)
    moved = 0
    try:
        for old, new in folders.items():
            for table in ("tracks", "import_items"):
                rows = con.execute(f"SELECT rowid, path FROM {table}").fetchall()  # noqa: S608
                for rowid, path in rows:
                    target = _moved(path, old, new)
                    if target is None:
                        continue
                    try:
                        con.execute(
                            f"UPDATE {table} SET path = ?, folder = ? WHERE rowid = ?",  # noqa: S608
                            (target, str(Path(new)), rowid),
                        )
                    except sqlite3.IntegrityError:
                        continue  # already there under its new path
                    if table == "tracks":
                        moved += 1
            for rowid, path in con.execute(
                "SELECT rowid, folder_path FROM albums WHERE folder_path IS NOT NULL"
            ).fetchall():
                target = _moved(path, old, new)
                if target is not None:
                    con.execute(
                        "UPDATE albums SET folder_path = ? WHERE rowid = ?", (target, rowid)
                    )
        con.commit()
        return moved
    finally:
        con.close()
