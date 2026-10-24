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
import json
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
from hive.library import catalog as C
from hive.library import languages as L
from hive.library import text as T
from hive.library.artwork import ArtworkStore
from hive.library.audio import Loudness, Transcoder, find_ffmpeg, measure_loudness
from hive.library.lookup import songs as SG
from hive.library.tags import FileInfo, UnreadableFile, is_audio, read_file
from hive.models import Album, Artist, ImportItem, ServerMeta, Track

log = logging.getLogger("hive.scanner")

# Bump when files should be read again after an upgrade.
LIBRARY_VERSION = 3
SETTLE_SECONDS = 2.0  # a file must be unchanged this long before it's read
VARIOUS = C.VARIOUS


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
        # Run once the queue empties after a scan or after files were read
        # (M6: music videos are matched to their songs then).
        self.idle_hooks: list = []
        self._idle_pending = False
        self._idle_lock = threading.Lock()
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
        self._upgrade_library()
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

    def _upgrade_library(self) -> None:
        """When this version reads more from files than the last one did (M1.5:
        composers, lyricists, language, folder grouping), read every file again."""
        with Session(self.db.engine) as s:
            # Hive 0.1 listed exact copies with the problems.
            s.execute(
                update(ImportItem)
                .where(ImportItem.status == "failed", ImportItem.problem.like("Same file as %"))
                .values(status="duplicate")
            )
            s.commit()
            meta = s.get(ServerMeta, "library_version")
            if meta is not None and meta.value.isdigit() and int(meta.value) >= LIBRARY_VERSION:
                return
            n = s.execute(update(Track).values(mtime=-1.0)).rowcount
            s.merge(ServerMeta(key="library_version", value=str(LIBRARY_VERSION)))
            s.commit()
        if n:
            log.info("reading %d songs again for this version of Hive", n)

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
                and item.status in ("failed", "duplicate", "ignored")
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
            gone = s.execute(delete(Track).where(Track.path == key)).rowcount
            _prune(s)
            s.commit()
        if gone:
            self._requeue_copies()

    def _requeue_copies(self) -> None:
        """A song's file went away: a copy of it, skipped until now, takes its
        place (read again, the first copy becomes the song)."""
        with Session(self.db.engine) as s:
            copies = s.scalars(
                select(ImportItem.path).where(ImportItem.status == "duplicate")
            ).all()
        for p in copies:
            if Path(p).exists():
                self.enqueue(Path(p), force=True)

    # ------------------------------------------------------- needs attention
    def ignore(self, item_id: int) -> bool:
        """Leave a problem file alone; it comes back if the file changes."""
        with self._write_lock, Session(self.db.engine) as s:
            item = s.get(ImportItem, item_id)
            if item is None or item.status not in ("failed", "duplicate"):
                return False
            item.status = "ignored"
            s.commit()
        return True

    def delete_copy(self, item_id: int) -> str | None:
        """Delete an exact copy of a song that's in the library. The bytes are
        compared again first, so nothing is lost. The copy's path, or None."""
        with Session(self.db.engine) as s:
            item = s.get(ImportItem, item_id)
            if item is None or item.status != "duplicate":
                return None
            path, folder = Path(item.path), Path(item.folder)
        if not path.is_file():
            return None
        digest = sha256_of(path)
        with Session(self.db.engine) as s:
            twins = s.scalars(
                select(Track.path).where(Track.sha256 == digest, Track.path != str(path))
            ).all()
        # The song in the library must still be on disk with the same bytes.
        if not any(Path(t).is_file() and sha256_of(Path(t)) == digest for t in twins):
            return None
        rel = _relative(path, self.folders)
        path.unlink()
        self.forget(path)
        _remove_empty_folders(path.parent, folder)
        log.info("deleted a copy of a song in the library")
        return rel

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
                self._requeue_copies()
            log.info("scan finished: %d files to read", queued)
        finally:
            self.scanning = False
            self.last_scan_at = _now()
            self._idle_pending = True
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
                self._run_idle_hooks()
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
                self._idle_pending = True

    def _run_idle_hooks(self) -> None:
        if not self._idle_pending or self.busy or self.scanning:
            return
        with self._idle_lock:
            if not self._idle_pending:
                return
            self._idle_pending = False
            for hook in self.idle_hooks:
                try:
                    hook()
                except Exception:  # noqa: BLE001 - a hook must not stop the worker
                    log.exception("after reading the library")

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

        def copy_of(s: Session) -> tuple[str | None, Track | None]:
            """(skip reason, twin to take over) for an exact copy already in the library."""
            twin = s.scalar(select(Track).where(Track.sha256 == digest, Track.path != str(path)))
            if twin is None or not Path(twin.path).exists():
                return None, None
            if st.st_mtime >= twin.mtime:
                rel = _relative(Path(twin.path), self.folders)
                return f"Same file as {rel}, so it was skipped", None
            # This one is older, so it's the original and the other the copy:
            # the song keeps its id (likes, playlists) and moves to this file.
            return None, twin

        def skip(reason: str) -> None:
            # Only exact copies reach here: they're listed apart from problems.
            self._finish(item.id, "duplicate", reason, size=st.st_size, mtime=st.st_mtime)

        # A first look before the slow work (loudness), so copies cost nothing.
        with Session(self.db.engine) as s:
            reason, _ = copy_of(s)
        if reason:
            skip(reason)
            return

        loudness = None
        with Session(self.db.engine) as s:
            # Same bytes as last time (a re-read for a newer Hive): the
            # loudness is the same too, and measuring is the slow part.
            known = s.execute(
                select(Track.lufs, Track.true_peak).where(
                    Track.path == str(path), Track.sha256 == digest, Track.lufs.is_not(None)
                )
            ).first()
        if known is not None:
            loudness = Loudness(integrated_lufs=known[0], true_peak_dbtp=known[1])
        elif self.ffmpeg is not None:
            loudness = measure_loudness(self.ffmpeg, path, info.duration_ms / 1000)
        artwork_id = self.artwork.save(info.picture) if info.picture else None

        with self._write_lock, Session(self.db.engine) as s:
            # Decide again under the lock: another worker may have added the
            # original or the copy while this one measured loudness.
            reason, twin = copy_of(s)
            if reason is None:
                self._store(s, item.id, path, root, st, digest, info, loudness, artwork_id, twin)
        if reason:
            skip(reason)

    def _store(
        self,
        s: Session,
        item_id: int,
        path: Path,
        root: Path,
        st,
        digest: str,
        info,
        loudness,
        artwork_id,
        twin,
    ) -> None:
        """Add or update the song and mark its import done, in one transaction
        (so a worker handling the copy can't overwrite the outcome). When
        [twin] was a copy, the song keeps its id (likes, playlists) and moves
        to this file."""
        if twin is not None:
            # Read before the update: the session refreshes twin.path with it.
            copy_path = twin.path
            s.execute(update(Track).where(Track.id == twin.id).values(path=str(path)))
            rel = _relative(path, self.folders)
            s.execute(
                update(ImportItem)
                .where(ImportItem.path == copy_path)
                .values(
                    status="duplicate",
                    problem=f"Same file as {rel}, so it was skipped",
                    track_id=None,
                    updated_at=_now(),
                )
            )
        track_id = _upsert(s, path, root, st, digest, info, loudness, artwork_id)
        s.execute(
            update(ImportItem)
            .where(ImportItem.id == item_id)
            .values(
                status="done",
                problem=None,
                track_id=track_id,
                size=st.st_size,
                mtime=st.st_mtime,
                updated_at=_now(),
            )
        )
        s.commit()


# Files an OS leaves in a folder; a folder holding only these counts as empty.
_LITTER = {".DS_Store", "Thumbs.db", "desktop.ini"}


def _remove_empty_folders(folder: Path, root: Path) -> None:
    """Remove [folder] and its parents up to (not including) the music folder,
    while they hold nothing but OS litter."""
    while folder != root and root in folder.parents:
        try:
            entries = list(folder.iterdir())
            if any(e.name not in _LITTER or e.is_dir() for e in entries):
                return
            for e in entries:
                e.unlink()
            folder.rmdir()
        except OSError:
            return
        folder = folder.parent


def _relative(path: Path, folders: list[Path]) -> str:
    for f in folders:
        try:
            return str(path.relative_to(f))
        except ValueError:
            continue
    return path.name


def _artist(s: Session, name: str) -> Artist:
    return C.artist_row(s, name)


def _apply_song_lookup(info: FileInfo, found: dict) -> None:
    """A song with no album tag that was looked up on its own: what was found
    (its real title, singer and album) stands in for the file names."""
    info.title = found.get("title") or info.title
    info.artist = found.get("artist") or info.artist
    info.album = found.get("album") or info.album
    info.album_artist = found.get("albumArtist") or info.album_artist
    info.year = info.year or found.get("year")
    info.mb_recording_id = info.mb_recording_id or found.get("recording")
    info.mb_album_id = info.mb_album_id or found.get("release")
    info.mb_release_group_id = info.mb_release_group_id or found.get("releaseGroup")


def _upsert(s, path, root, st, digest, info: FileInfo, loudness, artwork_id) -> str:
    track = s.scalar(select(Track).where(Track.path == str(path)))
    if track is not None and track.lookup and (info.album_from_folder or SG.junk_album(info.album)):
        _apply_song_lookup(info, json.loads(track.lookup))
    credit = info.artist or "Unknown artist"
    album_title = info.album or "Unknown album"
    title_key = T.name_key(album_title)
    folder = str(path.parent)

    album: Album | None = None
    if info.album_artist:
        album_artist = info.album_artist
    elif info.compilation:
        album_artist = VARIOUS
    else:
        album_artist = T.primary_artist(credit)
        # Songs of one album in one folder, each with its own singer and no
        # album-artist tag (most film soundtracks): keep them together.
        album = C.find_folder_album(s, title_key, folder)
        if album is not None and album.artist_key != T.name_key(album_artist):
            album_artist = album.artist_name
    artist_key = T.name_key(album_artist)
    track_artist_row = _artist(s, T.primary_artist(credit))

    if album is None:
        album = s.scalar(
            select(Album).where(Album.artist_key == artist_key, Album.title_key == title_key)
        )
    if album is None:
        album_artist_row = _artist(s, album_artist)
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
            folder_path=folder,
            sources="{}",
            overrides="{}",
            lookup_state="waiting",
        )
        s.add(album)
        s.flush()
        if artwork_id:
            C.set_source(album, "artwork", "folder" if info.picture_from_folder else "tags")
    else:
        album.year = album.year or info.year
        album.genre = album.genre or info.genre
        album.folder_path = album.folder_path or folder
        if artwork_id and not album.artwork_id:
            album.artwork_id = artwork_id
            C.set_source(album, "artwork", "folder" if info.picture_from_folder else "tags")

    if track is None:
        track = Track(id=new_id(), path=str(path))
        s.add(track)
    new_title = info.title or path.stem
    before = (track.file_title or track.title, track.artist_name)
    if track.title is not None and before != (new_title, credit):
        track.lyrics_checked_at = None  # a new name may find lyrics online
    track.file_title = new_title
    # A tidy name chosen in Hive Admin is shown instead; the file is untouched.
    track.title = track.title_override or new_title
    track.album_id = album.id
    track.artist_id = track_artist_row.id
    track.artist_name = credit
    track.track_no = info.track_no
    track.disc_no = info.disc_no
    track.duration_ms = info.duration_ms
    track.genre = info.genre
    track.year = info.year
    track.artwork_id = artwork_id or album.artwork_id
    # Lyrics Hive keeps itself (typed in Hive Admin, or found online) count too.
    track.has_lyrics = bool(info.lyrics and info.lyrics.strip()) or bool(track.lyrics)
    track.album_tagged = not info.album_from_folder
    track.lufs = loudness.integrated_lufs if loudness else None
    track.true_peak = loudness.true_peak_dbtp if loudness else None
    track.language = L.from_tag(info.language)
    track.composer = info.composer
    track.lyricist = info.lyricist
    apply_track_overrides(s, track)
    track.mbid_recording = info.mb_recording_id
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
    C.set_track_credits(s, track, credit)
    if info.mb_album_id and not album.mbid_release:
        album.mbid_release = info.mb_album_id
        album.mbid_release_group = info.mb_release_group_id
    # One soundtrack, several singers, one composer: the composer is the album
    # artist (the music director), as film albums are usually credited.
    siblings = s.scalars(select(Track).where(Track.album_id == album.id)).all()
    if info.album_artist or info.compilation:
        C.set_source(album, "artistName", "albumArtistTag")
    elif len(siblings) > 1 and C.sources(album).get("artistName") != "albumArtistTag":
        singers = {T.name_key(T.primary_artist(t.artist_name)) for t in siblings}
        if len(singers) > 1 and "artistName" not in C.overrides(album):
            composer = C.common_value([t.composer for t in siblings])
            new_artist = composer or VARIOUS
            if album.artist_name != new_artist:
                album.artist_name = new_artist
                album.artist_id = _artist(s, new_artist).id
                C.set_source(album, "artistName", "tags" if composer else "folder")
    C.refresh_language(s, album)
    C.apply_overrides(album)
    C.refresh_search(s, album)
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
    C.prune(s)


# The fields Hive Admin can correct on a song, and the Track attribute each sets.
TRACK_FIELDS = {
    "title": "title",
    "artistName": "artist_name",
    "trackNumber": "track_no",
    "discNumber": "disc_no",
    "composer": "composer",
    "lyricist": "lyricist",
}


def track_overrides(track: Track) -> dict:
    import json

    try:
        return json.loads(track.overrides or "{}")
    except ValueError:
        return {}


def apply_track_overrides(s: Session, track: Track) -> None:
    """Corrections made in Hive Admin win over the file's tags."""
    edits = track_overrides(track)
    for field, attr in TRACK_FIELDS.items():
        if field in edits:
            setattr(track, attr, edits[field])
    if "artistName" in edits and edits["artistName"]:
        track.artist_id = _artist(s, edits["artistName"]).id
