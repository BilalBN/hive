"""M6: music videos.

A video file in the music folders is matched to its song:

1. the same name in the same folder ("03 Malare.mp4" beside "03 Malare.flac"),
2. otherwise a name like "Artist - Title.mp4" (or just "Title.mp4") that
   matches one song in the library.

Videos that match nothing aren't shown in the apps (Hive Admin lists them).
Hive reads each video's length and size with FFmpeg; the file itself is
streamed as it is, never changed."""

from __future__ import annotations

import logging
import os
import re
import subprocess
import threading
from pathlib import Path

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from hive.library import text as T
from hive.library.scanner import new_id
from hive.models import Track, Video

log = logging.getLogger("hive.library")

VIDEO_EXTENSIONS = {".mp4", ".m4v", ".mov", ".mkv", ".webm"}
MIME = {
    ".mp4": "video/mp4",
    ".m4v": "video/mp4",
    ".mov": "video/quicktime",
    ".mkv": "video/x-matroska",
    ".webm": "video/webm",
}


def is_video(path: Path) -> bool:
    return path.suffix.lower() in VIDEO_EXTENSIONS and not path.name.startswith("._")


_DURATION = re.compile(r"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)")
_SIZE = re.compile(r"Video: .*?(\d{2,5})x(\d{2,5})")


def probe(ffmpeg: Path | None, path: Path) -> tuple[int, int | None, int | None]:
    """Length in ms, width and height, from FFmpeg's description of the file."""
    if ffmpeg is None:
        return 0, None, None
    try:
        r = subprocess.run(
            [str(ffmpeg), "-hide_banner", "-nostdin", "-i", str(path)],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return 0, None, None
    ms = 0
    if m := _DURATION.search(r.stderr):
        h, mi, se = m.groups()
        ms = int((int(h) * 3600 + int(mi) * 60 + float(se)) * 1000)
    if m := _SIZE.search(r.stderr):
        return ms, int(m.group(1)), int(m.group(2))
    return ms, None, None


def _name_key(name: str) -> str:
    title = re.sub(r"\s*[\(\[].*?[\)\]]", "", name)  # "(Official Video)" and the like
    title = re.sub(r"^\d+[\s.\-_]+", "", title)  # a leading track number
    return T.name_key(title)


class Videos:
    def __init__(self, db, library) -> None:
        self.db = db
        self.library = library
        self._lock = threading.Lock()

    def sync(self) -> int:
        """Find videos in the music folders, read new ones, match them to
        songs, and drop ones whose files are gone. Returns how many are matched."""
        with self._lock:
            return self._sync()

    def _sync(self) -> int:
        found: dict[str, tuple[Path, str]] = {}
        live_roots = []
        for folder in self.library.folders:
            if not folder.is_dir():
                continue
            live_roots.append(str(folder))
            for dirpath, dirnames, filenames in os.walk(folder):
                dirnames[:] = [d for d in dirnames if not d.startswith(".")]
                for name in filenames:
                    p = Path(dirpath) / name
                    if is_video(p):
                        found[str(p)] = (p, str(folder))
        with Session(self.db.engine) as s:
            known = {v.path: v for v in s.scalars(select(Video))}
            gone = [
                v.id for path, v in known.items() if v.folder in live_roots and path not in found
            ]
            if gone:
                s.execute(delete(Video).where(Video.id.in_(gone)))
            for path, (p, folder) in found.items():
                try:
                    st = p.stat()
                except OSError:
                    continue
                v = known.get(path)
                if v is None:
                    v = Video(id=new_id(), path=path, folder=folder, size=0, mtime=0)
                    s.add(v)
                if v.size != st.st_size or v.mtime != st.st_mtime:
                    v.duration_ms, v.width, v.height = probe(self.library.ffmpeg, p)
                    v.size, v.mtime = st.st_size, st.st_mtime
            s.flush()
            matched = self._link(s)
            s.commit()
        return matched

    def _link(self, s: Session) -> int:
        tracks = list(s.execute(select(Track.id, Track.path, Track.title, Track.artist_name)))
        by_file = {str(Path(p).with_suffix("")).lower(): tid for tid, p, _, _ in tracks}
        by_title: dict[str, list[str]] = {}
        by_artist_title: dict[str, list[str]] = {}
        for tid, _, title, artist in tracks:
            key = _name_key(title)
            by_title.setdefault(key, []).append(tid)
            by_artist_title.setdefault(f"{T.name_key(T.primary_artist(artist))}|{key}", []).append(
                tid
            )
        matched = 0
        for v in s.scalars(select(Video)):
            stem = Path(v.path).with_suffix("")
            tid = by_file.get(str(stem).lower())
            if tid is None:
                name = stem.name
                if " - " in name:
                    artist, title = name.split(" - ", 1)
                    hits = by_artist_title.get(f"{T.name_key(artist)}|{_name_key(title)}", [])
                else:
                    hits = by_title.get(_name_key(name), [])
                tid = hits[0] if len(hits) == 1 else None
            v.track_id = tid
            matched += tid is not None
        return matched
