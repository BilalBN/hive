"""The scan pipeline: every music file goes through the same steps.

1. Seen (folder scan at start, the folder watcher, a finished upload, or
   "Scan now" in Hive Admin) → an import item is queued.
2. A worker waits until the file has stopped changing, hashes it to skip exact
   duplicates, reads its format, tags, cover and lyrics, and measures loudness.
3. Names are merged by spelling-insensitive keys ("AR Rahman" = "A.R. Rahman"),
   and the song is added to the library and to search.

Anything that fails stays in Hive Admin's "Needs attention" list with a plain
reason, instead of disappearing.
"""

from __future__ import annotations

import hashlib
import logging
import os
import secrets
import threading
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import delete, func, select, update
from sqlalchemy.orm import Session

from hive.config import Settings
from hive.db import Database
from hive.library import text as T
from hive.library.artwork import ArtworkStore
from hive.library.audio import Transcoder, find_ffmpeg, measure_loudness
from hive.library.tags import FileInfo, UnreadableFile, is_audio, read_file
from hive.models import Album, Artist, ImportItem, PlaylistItem, Track

log = logging.getLogger("hive.scanner")

SETTLE_SECONDS = 2.0  # a file must be unchanged this long before it's read
VARIOUS = "Various Artists"


@dataclass(frozen=True)
class Claimed:
    id: int
    path: str
    folder: str


def new_id() -> str:
    return secrets.token_hex(8)


def _now() -> datetime:
    return datetime.now(UTC)


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


class Library:
    """Owns the scan workers, the folder watcher, artwork and transcodes."""

    def __init__(self, settings: Settings, db: Database) -> None:
        self.settings = settings
        self.db = db
        self.ffmpeg = find_ffmpeg(settings.ffmpeg)
        self.artwork = ArtworkStore(settings.artwork_dir, settings.cache_dir)
        self.transcoder = Transcoder(self.ffmpeg, settings.cache_dir)
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._write_lock = threading.Lock()
        self._threads: list[threading.Thread] = []
        self._observer = None
        self._not_before: dict[int, float] = {}
        self._busy = 0
        self._busy_lock = threading.Lock()
        self.scanning = False
        self._scan_lock = threading.Lock()
        self.last_scan_at: datetime | None = None

    # ------------------------------------------------------------ lifecycle
    @property
    def folders(self) -> list[Path]:
        return list(self.settings.music_folders)

    def start(self) -> None:
        for folder in self.folders:
            try:
                folder.mkdir(parents=True, exist_ok=True)
            except OSError as e:
                log.warning("music folder %s isn't available: %s", folder, e)
        try:
            self.settings.uploads_path.mkdir(parents=True, exist_ok=True)
        except OSError as e:
            log.warning("upload folder %s isn't available: %s", self.settings.uploads_path, e)
        if self.ffmpeg is None:
            log.warning(
                "FFmpeg not found: High and Data saver streams and volume levelling are off "
                "until it is installed (macOS: brew install ffmpeg)"
            )
        # Items left "working" by a crash go back in the queue.
        with Session(self.db.engine) as s:
            s.execute(
                update(ImportItem).where(ImportItem.status == "working").values(status="queued")
            )
            s.commit()
        for i in range(max(1, self.settings.scan_workers)):
            t = threading.Thread(target=self._work, name=f"hive-scan-{i}", daemon=True)
            t.start()
            self._threads.append(t)
        self.scan_in_background()
        if self.settings.watch_folders:
            self._start_watcher()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()
        if self._observer is not None:
            self._observer.stop()
        for t in self._threads:
            t.join(timeout=5)

    def _start_watcher(self) -> None:
        try:
            from watchdog.observers import Observer

            from hive.library.watcher import FolderEvents
        except ImportError:  # pragma: no cover
            return
        observer = Observer()
        handler = FolderEvents(self)
        for folder in self.folders:
            if folder.is_dir():
                observer.schedule(handler, str(folder), recursive=True)
        observer.daemon = True
        observer.start()
        self._observer = observer

    # ------------------------------------------------------------ queueing
    def root_of(self, path: Path) -> Path | None:
        for folder in self.folders:
            try:
                path.relative_to(folder)
                return folder
            except ValueError:
                continue
        return None

    def enqueue(self, path: Path, *, force: bool = False) -> bool:
        """Queue a file if it's new or changed. Returns True if queued."""
        if not is_audio(path):
            return False
        root = self.root_of(path)
        if root is None:
            return False
        try:
            st = path.stat()
        except OSError:
            return False
        key = str(path)
        with self._write_lock, Session(self.db.engine) as s:
            if not force:
                track = s.scalar(select(Track).where(Track.path == key))
                if track is not None and track.size == st.st_size and track.mtime == st.st_mtime:
                    return False
            item = s.scalar(select(ImportItem).where(ImportItem.path == key))
            if item is None:
                s.add(ImportItem(path=key, folder=str(root), status="queued"))
            elif item.status == "working":
                return False
            elif (
                not force
                and item.status == "failed"
                and item.size == st.st_size
                and item.mtime == st.st_mtime
            ):
                return False  # still the same broken file
            else:
                item.status = "queued"
                item.problem = None
            s.commit()
        self._wake.set()
        return True

    def picture_added(self, folder: Path) -> None:
        """Cover art arrived after the songs: read the folder's songs again."""
        try:
            siblings = [p for p in folder.iterdir() if is_audio(p)]
        except OSError:
            return
        for p in siblings:
            self.enqueue(p, force=True)

    def forget(self, path: Path) -> None:
        """A file was deleted or moved away."""
        key = str(path)
        with self._write_lock, Session(self.db.engine) as s:
            s.execute(delete(ImportItem).where(ImportItem.path == key))
            s.execute(delete(Track).where(Track.path == key))
            _prune(s)
            s.commit()

    def scan_in_background(self) -> None:
        with self._scan_lock:
            if self.scanning:
                return
            self.scanning = True
        threading.Thread(target=self.scan, kwargs={"claimed": True}, daemon=True).start()

    def scan(self, claimed: bool = False) -> int:
        """Walk every music folder; queue new and changed files; drop vanished ones."""
        if not claimed:
            with self._scan_lock:
                if self.scanning:
                    return 0
                self.scanning = True
        queued = 0
        try:
            seen: set[str] = set()
            for folder in self.folders:
                if not folder.is_dir():
                    continue
                for dirpath, dirnames, filenames in os.walk(folder):
                    dirnames[:] = [d for d in dirnames if not d.startswith(".")]
                    for name in filenames:
                        p = Path(dirpath) / name
                        if not is_audio(p):
                            continue
                        seen.add(str(p))
                        if self.enqueue(p):
                            queued += 1
            live_roots = [str(f) for f in self.folders if f.is_dir()]
            with self._write_lock, Session(self.db.engine) as s:
                # Only drop songs from folders that are actually reachable now, so
                # an unplugged drive doesn't empty the library.
                gone = [
                    (tid, p)
                    for tid, p, folder in s.execute(select(Track.id, Track.path, Track.folder))
                    if folder in live_roots and p not in seen
                ]
                for tid, _p in gone:
                    s.execute(delete(Track).where(Track.id == tid))
                stale = [
                    iid
                    for iid, p, folder in s.execute(
                        select(ImportItem.id, ImportItem.path, ImportItem.folder)
                    )
                    if folder in live_roots and p not in seen
                ]
                if stale:
                    s.execute(delete(ImportItem).where(ImportItem.id.in_(stale)))
                if gone:
                    _prune(s)
                s.commit()
            if gone:
                log.info("removed %d songs whose files are gone", len(gone))
            log.info("scan finished: %d files to read", queued)
        finally:
            self.scanning = False
            self.last_scan_at = _now()
        return queued

    @property
    def busy(self) -> bool:
        return self._busy > 0

    def wait_idle(self, timeout: float = 30.0) -> bool:
        """For tests and the CLI: wait until nothing is queued or being read."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with Session(self.db.engine) as s:
                pending = s.scalar(
                    select(func.count())
                    .select_from(ImportItem)
                    .where(ImportItem.status.in_(("queued", "working")))
                )
            if not pending and not self.scanning and not self.busy:
                return True
            self._wake.set()
            time.sleep(0.05)
        return False

    # ------------------------------------------------------------ workers
    def _claim(self) -> Claimed | None:
        now = time.monotonic()
        with self._write_lock, Session(self.db.engine) as s:
            items = s.scalars(
                select(ImportItem)
                .where(ImportItem.status == "queued")
                .order_by(ImportItem.id)
                .limit(50)
            ).all()
            for item in items:
                if self._not_before.get(item.id, 0) > now:
                    continue
                claimed = Claimed(item.id, item.path, item.folder)
                item.status = "working"
                s.commit()
                return claimed
        return None

    def _work(self) -> None:
        while not self._stop.is_set():
            item = self._claim()
            if item is None:
                self._wake.wait(timeout=1.0)
                self._wake.clear()
                continue
            with self._busy_lock:
                self._busy += 1
            try:
                self._process(item)
            except Exception:  # noqa: BLE001 - one bad file must not stop the worker
                log.exception("unexpected error reading %s", item.path)
                self._finish(item.id, "failed", "Hive hit an unexpected error reading this file")
            finally:
                with self._busy_lock:
                    self._busy -= 1

    def _finish(self, item_id: int, status: str, problem: str | None = None, **values) -> None:
        with self._write_lock, Session(self.db.engine) as s:
            s.execute(
                update(ImportItem)
                .where(ImportItem.id == item_id)
                .values(status=status, problem=problem, updated_at=_now(), **values)
            )
            s.commit()

    def _process(self, item: Claimed) -> None:
        path = Path(item.path)
        root = Path(item.folder)
        try:
            st = path.stat()
        except OSError:
            self.forget(path)
            return
        # Wait for copies and uploads to finish writing.
        if time.time() - st.st_mtime < SETTLE_SECONDS:
            self._not_before[item.id] = time.monotonic() + SETTLE_SECONDS
            self._finish(item.id, "queued")
            return
        self._not_before.pop(item.id, None)

        try:
            info = read_file(path, root)
        except UnreadableFile as e:
            self._finish(item.id, "failed", str(e), size=st.st_size, mtime=st.st_mtime)
            return
        digest = sha256_of(path)
        if os.stat(path).st_size != st.st_size:
            self._finish(item.id, "queued")  # still being written
            return

        replaces: str | None = None
        twin_path = ""
        with Session(self.db.engine) as s:
            twin = s.scalar(select(Track).where(Track.sha256 == digest, Track.path != str(path)))
            if twin is not None and Path(twin.path).exists():
                if st.st_mtime >= twin.mtime:
                    rel = _relative(Path(twin.path), self.folders)
                    self._finish(
                        item.id,
                        "failed",
                        f"Same file as {rel}, so it was skipped",
                        size=st.st_size,
                        mtime=st.st_mtime,
                    )
                    return
                # This one is older, so it's the original and the other the copy:
                # the song keeps its id (likes, playlists) and moves to this file.
                replaces, twin_path = twin.id, twin.path

        loudness = None
        if self.ffmpeg is not None:
            loudness = measure_loudness(self.ffmpeg, path, info.duration_ms / 1000)
        artwork_id = self.artwork.save(info.picture) if info.picture else None

        with self._write_lock, Session(self.db.engine) as s:
            if replaces is not None:
                s.execute(update(Track).where(Track.id == replaces).values(path=str(path)))
                rel = _relative(path, self.folders)
                s.execute(
                    update(ImportItem)
                    .where(ImportItem.path == twin_path)
                    .values(
                        status="failed",
                        problem=f"Same file as {rel}, so it was skipped",
                        track_id=None,
                        updated_at=_now(),
                    )
                )
            track_id = _upsert(s, path, root, st, digest, info, loudness, artwork_id)
            s.commit()
        self._finish(item.id, "done", None, track_id=track_id, size=st.st_size, mtime=st.st_mtime)


def _relative(path: Path, folders: list[Path]) -> str:
    for f in folders:
        try:
            return str(path.relative_to(f))
        except ValueError:
            continue
    return path.name


def _artist(s: Session, name: str) -> Artist:
    key = T.name_key(name)
    a = s.scalar(select(Artist).where(Artist.name_key == key))
    if a is None:
        a = Artist(id=new_id(), name=name, name_key=key, search_text=T.search_text(name))
        s.add(a)
        s.flush()
    return a


def _upsert(s, path, root, st, digest, info: FileInfo, loudness, artwork_id) -> str:
    credit = info.artist or "Unknown artist"
    if info.album_artist:
        album_artist = info.album_artist
    elif info.compilation:
        album_artist = VARIOUS
    else:
        album_artist = T.primary_artist(credit)
    album_title = info.album or "Unknown album"
    artist_key = T.name_key(album_artist)
    title_key = T.name_key(album_title)

    album_artist_row = _artist(s, album_artist)
    track_artist_row = _artist(s, T.primary_artist(credit))

    album = s.scalar(
        select(Album).where(Album.artist_key == artist_key, Album.title_key == title_key)
    )
    if album is None:
        album = Album(
            id=new_id(),
            title=album_title,
            title_key=title_key,
            artist_id=album_artist_row.id,
            artist_name=album_artist,
            artist_key=artist_key,
            year=info.year,
            genre=info.genre,
            artwork_id=artwork_id,
            search_text=T.search_text(album_title, album_artist),
        )
        s.add(album)
        s.flush()
    else:
        album.year = album.year or info.year
        album.genre = album.genre or info.genre
        album.artwork_id = album.artwork_id or artwork_id

    track = s.scalar(select(Track).where(Track.path == str(path)))
    if track is None:
        track = Track(id=new_id(), path=str(path))
        s.add(track)
    track.title = info.title or path.stem
    track.album_id = album.id
    track.artist_id = track_artist_row.id
    track.artist_name = credit
    track.track_no = info.track_no
    track.disc_no = info.disc_no
    track.duration_ms = info.duration_ms
    track.genre = info.genre
    track.year = info.year
    track.artwork_id = artwork_id or album.artwork_id
    track.has_lyrics = bool(info.lyrics and info.lyrics.strip())
    track.lufs = loudness.integrated_lufs if loudness else None
    track.true_peak = loudness.true_peak_dbtp if loudness else None
    track.search_text = T.search_text(track.title, credit, album_title)
    track.folder = str(root)
    track.size = st.st_size
    track.mtime = st.st_mtime
    track.sha256 = digest
    track.codec = info.codec
    track.lossless = info.lossless
    track.sample_rate = info.sample_rate
    track.bit_depth = info.bit_depth
    track.bitrate_kbps = info.bitrate_kbps
    track.channels = info.channels
    s.flush()
    album.album_lufs = _album_lufs(s, album.id)
    _prune(s)
    return track.id


def _album_lufs(s: Session, album_id: str) -> float | None:
    """Duration-weighted energy average of the album's songs."""
    import math

    rows = s.execute(
        select(Track.lufs, Track.duration_ms).where(
            Track.album_id == album_id, Track.lufs.isnot(None)
        )
    ).all()
    total = sum(d for _, d in rows)
    if not rows or total <= 0:
        return None
    energy = sum(d * 10 ** (lufs / 10) for lufs, d in rows) / total
    return round(10 * math.log10(energy), 2)


def _prune(s: Session) -> None:
    """Drop albums with no songs and artists with nothing left."""
    s.execute(delete(Album).where(~Album.id.in_(select(Track.album_id).distinct())))
    s.execute(delete(PlaylistItem).where(~PlaylistItem.track_id.in_(select(Track.id))))
    s.execute(
        delete(Artist).where(
            ~Artist.id.in_(select(Album.artist_id).where(Album.artist_id.isnot(None))),
            ~Artist.id.in_(select(Track.artist_id).where(Track.artist_id.isnot(None))),
        )
    )
