"""M3: keeping every song's fingerprints up to date, in the background.

New and changed songs are fingerprinted soon after they're read; songs that
left the library are dropped from the index. Rebuild starts over. Nothing
here touches the network.
"""

from __future__ import annotations

import logging
import threading
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import numpy as np
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from hive.db import Database
from hive.library import fingerprint as F
from hive.models import Track

log = logging.getLogger("hive.listen")

IDLE_SECONDS = 20  # how often an idle worker looks for new songs


class Recognition:
    def __init__(self, db: Database, data_dir: Path, ffmpeg: Path | None) -> None:
        self.db = db
        self.ffmpeg = ffmpeg
        self.index = F.FingerprintIndex(data_dir / "fingerprints.db")
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self.working_on: str | None = None
        self.waiting = 0
        self.failed: dict[str, str] = {}  # track id → why, until the file changes
        self.rebuilt_at: datetime | None = None

    # ---------------------------------------------------------------- the worker
    def start(self) -> None:
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._run, name="hive-fingerprints", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()
        if self._thread is not None:
            self._thread.join(timeout=10)

    def wake(self) -> None:
        self._wake.set()

    def rebuild(self) -> None:
        self.index.clear()
        self.failed.clear()
        self.rebuilt_at = datetime.now(UTC)
        log.info("fingerprints: rebuilding for every song")
        self.wake()

    def _todo(self) -> list[tuple[str, str, str, int]]:
        """Songs to fingerprint (id, path, sha256, duration), and drop the gone."""
        with Session(self.db.engine) as s:
            rows = s.execute(select(Track.id, Track.path, Track.sha256, Track.duration_ms)).all()
        known = self.index.known()
        present = {r[0] for r in rows}
        gone = [tid for tid in known if tid not in present]
        if gone:
            self.index.remove(gone)
        return [
            (tid, path, sha, dur)
            for tid, path, sha, dur in rows
            if known.get(tid) != sha and self.failed.get(tid) != sha
        ]

    def _run(self) -> None:
        while not self._stop.is_set():
            if self.ffmpeg is None:
                self._wake.wait(IDLE_SECONDS * 6)
                self._wake.clear()
                continue
            try:
                todo = self._todo()
            except Exception:  # noqa: BLE001 - keep the worker alive
                log.exception("fingerprints: couldn't list songs")
                todo = []
            self.waiting = len(todo)
            if not todo:
                self._wake.wait(IDLE_SECONDS)
                self._wake.clear()
                continue
            started, done = time.monotonic(), 0
            for tid, path, sha, dur in todo:
                if self._stop.is_set():
                    return
                self.working_on = tid
                self.fingerprint_one(tid, Path(path), sha, dur)
                done += 1
                self.waiting = len(todo) - done
                if done % 100 == 0:
                    log.info("fingerprints: %d of %d songs", done, len(todo))
            self.working_on = None
            log.info("fingerprints: %d songs in %.0f s", done, time.monotonic() - started)

    def run_until_idle(self) -> int:
        """Fingerprint everything waiting, here and now (tests, and the CLI)."""
        done = 0
        for tid, path, sha, dur in self._todo():
            done += self.fingerprint_one(tid, Path(path), sha, dur)
        self.waiting = 0
        return done

    def fingerprint_one(self, track_id: str, path: Path, sha: str, duration_ms: int) -> bool:
        try:
            samples = F.decode(self.ffmpeg, path, seconds=F.MAX_SONG_S)
            hashes, starts = F.fingerprint(samples)
            if len(hashes) == 0:
                raise ValueError("no sound to fingerprint (silent or very short)")
            self.index.add(track_id, sha, hashes, starts)
            self.failed.pop(track_id, None)
            return True
        except Exception as e:  # noqa: BLE001 - one bad file mustn't stop the rest
            self.failed[track_id] = sha
            log.warning("fingerprints: skipped a song: %s", e)
            return False

    # ---------------------------------------------------------------- answers
    def status(self) -> dict[str, Any]:
        with Session(self.db.engine) as s:
            total = int(s.scalar(select(func.count()).select_from(Track)) or 0)
        songs, landmarks = self.index.stats()
        body: dict[str, Any] = {
            "tracks": total,
            "fingerprinted": min(songs, total),
            "waiting": self.waiting,
            "working": self.working_on is not None,
            "failed": len(self.failed),
            "landmarks": landmarks,
            "ffmpeg": self.ffmpeg is not None,
        }
        if self.rebuilt_at:
            body["rebuiltAt"] = self.rebuilt_at.isoformat().replace("+00:00", "Z")
        return body

    def match_landmarks(self, hashes: list[int], starts: list[int]) -> F.Match | None:
        """M6: landmarks made on the device; no sound reaches home."""
        return self.index.match_landmarks(np.asarray(hashes), np.asarray(starts))

    def match(self, clip: bytes) -> tuple[F.Match | None, float]:
        """The song a recording is of, if it's at home, and the clip's length."""
        if self.ffmpeg is None:
            raise RuntimeError("FFmpeg isn't installed on the home PC, so Listen can't hear clips.")
        samples = F.decode(self.ffmpeg, clip, seconds=30)
        return self.index.match(samples), len(samples) / F.SR
