"""Song recognition for Listen: audio landmarks, built into Hive.

Each song's sound is turned into thousands of small "landmarks": pairs of
loud points in its spectrogram (a frequency at a moment, another frequency a
little later). A landmark is kept as a number made of the two frequencies and
the time between them, with where in the song it happened. A clip recorded in
a room has many of the same landmarks, at the same spacing, even with talk,
echo and a cheap microphone; the song whose landmarks line up most, at one
consistent offset, is the match, and the offset says how far into it the
clip was.

Fingerprints live in their own database file next to Hive's (they can always
be rebuilt from the music). Nothing here leaves home, and a clip is kept only
for the moment it takes to read it.
"""

from __future__ import annotations

import logging
import sqlite3
import subprocess
import tempfile
import threading
import time
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view

log = logging.getLogger("hive.listen")

SR = 11025  # samples per second, after mixing to mono
N_FFT = 512  # ~46 ms windows
HOP = 256  # ~23 ms between frames
FRAME_S = HOP / SR
MIN_BIN = 4  # below ~86 Hz is rumble, not tune

# Finding peaks: each peak raises a threshold around itself (a bell over
# SPREAD_BINS bins) that then decays every frame, so a loud note masks its own
# echo and its neighbours, and what's left are the moments notes start.
HP_POLE = 0.98  # takes each band's steady level out first
SPREAD_BINS = 3.0
DECAY = 0.985
PEAKS_PER_FRAME = 6

# Landmarks: a peak and one of the next FAN_OUT peaks after it, at most
# PAIR_MAX frames later and MAX_DF bins away. Frequencies in pairs of bins, so
# a slightly-off speed or microphone still gives the same number.
FAN_OUT = 6
PAIR_MIN, PAIR_MAX = 1, 63
MAX_DF = 63
FREQ_SHIFT = 1

MAX_SONG_S = 15 * 60  # longer files (DJ mixes) are fingerprinted for their first 15 minutes

# A match needs this many landmarks agreeing on one offset, and well ahead of
# the next best song. Measured on 8-second room recordings with echo and
# talking (tests/test_listen.py): right 9 times in 10 down to 0 dB, and no
# false matches on songs that aren't at home.
MIN_ALIGNED = 6
MIN_LEAD = 1.5


def decode(ffmpeg: Path, source: Path | bytes, seconds: float | None = None) -> np.ndarray:
    """Mono float samples at SR, from a file or a recording's bytes.

    A recording is handed to FFmpeg as a private temporary file (phones write
    M4A with its index at the end, which FFmpeg can't read from a pipe) and
    deleted as soon as it's read."""
    if isinstance(source, bytes):
        with tempfile.TemporaryDirectory(prefix="hive-clip-") as d:
            clip = Path(d) / "clip"
            clip.write_bytes(source)
            return decode(ffmpeg, clip, seconds)
    cmd = [str(ffmpeg), "-hide_banner", "-nostats", "-loglevel", "error", "-nostdin"]
    cmd += ["-i", str(source)]
    if seconds:
        cmd += ["-t", str(seconds)]
    cmd += ["-vn", "-ac", "1", "-ar", str(SR), "-f", "s16le", "pipe:1"]
    r = subprocess.run(cmd, capture_output=True, timeout=180, check=False)
    if r.returncode != 0 and not r.stdout:
        raise ValueError(r.stderr.decode(errors="replace").strip()[-300:] or "can't read the audio")
    return np.frombuffer(r.stdout, dtype="<i2").astype(np.float32) / 32768.0


def onset_spectrogram(samples: np.ndarray) -> np.ndarray:
    """Log loudness with each band's steady part taken out, so what stands
    out is where notes start (echo and hum fade below the threshold)."""
    if len(samples) < N_FFT:
        return np.zeros((0, N_FFT // 2 + 1), dtype=np.float32)
    frames = sliding_window_view(samples, N_FFT)[::HOP]
    window = np.hanning(N_FFT).astype(np.float32)
    mag = np.abs(np.fft.rfft(frames * window, axis=1))
    s = np.log(np.maximum(mag, mag.max() / 1e6 + 1e-12))
    s = s - s.mean()
    # High-pass along time: y[n] = x[n] - x[n-1] + POLE * y[n-1].
    out = np.empty_like(s)
    prev_x = s[0]
    prev_y = np.zeros(s.shape[1], dtype=s.dtype)
    for i in range(len(s)):
        y = s[i] - prev_x + HP_POLE * prev_y
        out[i] = y
        prev_x, prev_y = s[i], y
    return out.astype(np.float32)


def onset_peaks(spec: np.ndarray) -> np.ndarray:
    """Peaks above a threshold that each peak raises around itself and that
    then decays: a loud note masks its own echo and its neighbours."""
    n_frames, n_bins = spec.shape
    if n_frames == 0:
        return np.zeros((0, 2), dtype=np.int32)
    bins = np.arange(n_bins)
    spread = np.exp(-0.5 * ((bins[:, None] - bins[None, :]) / SPREAD_BINS) ** 2)
    thresh = (spread * spec[: min(10, n_frames)].max(axis=0)[None, :]).max(axis=1)
    out_t, out_f = [], []
    for t in range(n_frames):
        col = spec[t]
        diff = np.maximum(0, col - thresh)
        cand = np.nonzero((diff[1:-1] > diff[:-2]) & (diff[1:-1] >= diff[2:]))[0] + 1
        cand = cand[cand >= MIN_BIN]
        if len(cand):
            taken = 0
            for b in cand[np.argsort(-col[cand])]:
                if col[b] > thresh[b]:
                    out_t.append(t)
                    out_f.append(b)
                    thresh = np.maximum(thresh, col[b] * spread[b])
                    taken += 1
                    if taken >= PEAKS_PER_FRAME:
                        break
        thresh = thresh * DECAY
    return (
        np.stack([np.array(out_t, dtype=np.int32), np.array(out_f, dtype=np.int32)], axis=1)
        if out_t
        else np.zeros((0, 2), dtype=np.int32)
    )


def landmarks(pk: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Landmark numbers and the frame each starts at."""
    if len(pk) < 2:
        return np.zeros(0, dtype=np.int64), np.zeros(0, dtype=np.int32)
    hashes, starts = [], []
    t, f = pk[:, 0], pk[:, 1]
    # Each point pairs with the next FAN_OUT points close enough after it.
    for k in range(1, FAN_OUT + 1):
        if k >= len(pk):
            break
        dt = t[k:] - t[:-k]
        df = f[k:].astype(np.int64) - f[:-k].astype(np.int64)
        ok = (dt >= PAIR_MIN) & (dt <= PAIR_MAX) & (np.abs(df) <= MAX_DF)
        if not ok.any():
            continue
        f1 = f[:-k][ok].astype(np.int64) >> FREQ_SHIFT
        f2 = f[k:][ok].astype(np.int64) >> FREQ_SHIFT
        hashes.append((f1 << 16) | (f2 << 6) | dt[ok].astype(np.int64))
        starts.append(t[:-k][ok])
    if not hashes:
        return np.zeros(0, dtype=np.int64), np.zeros(0, dtype=np.int32)
    return np.concatenate(hashes), np.concatenate(starts)


def fingerprint(samples: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Landmark numbers and the frame each starts at."""
    return landmarks(onset_peaks(onset_spectrogram(samples)))


@dataclass(frozen=True)
class Match:
    track_id: str
    position_s: float  # where in the song the clip started
    aligned: int  # landmarks that agree
    confidence: float  # 0..1


class FingerprintIndex:
    """Landmarks of every song, in data/fingerprints.db."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.lock = threading.Lock()
        with self._connect() as db:
            db.executescript(
                """
                CREATE TABLE IF NOT EXISTS songs (
                  num INTEGER PRIMARY KEY,
                  track_id TEXT UNIQUE NOT NULL,
                  sha256 TEXT NOT NULL,
                  landmarks INTEGER NOT NULL,
                  done_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS marks (
                  hash INTEGER NOT NULL,
                  num INTEGER NOT NULL,
                  t INTEGER NOT NULL,
                  PRIMARY KEY (hash, num, t)
                ) WITHOUT ROWID;
                """
            )

    def _connect(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.path, timeout=30, check_same_thread=False)
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA synchronous=NORMAL")
        return db

    def known(self) -> dict[str, str]:
        """track id → the sha256 of the file it was made from."""
        with self._connect() as db:
            return dict(db.execute("SELECT track_id, sha256 FROM songs"))

    def stats(self) -> tuple[int, int]:
        with self._connect() as db:
            row = db.execute("SELECT count(*), coalesce(sum(landmarks), 0) FROM songs").fetchone()
            return int(row[0]), int(row[1])

    def add(self, track_id: str, sha256: str, hashes: np.ndarray, starts: np.ndarray) -> None:
        with self.lock, self._connect() as db:
            self._remove(db, track_id)
            cur = db.execute(
                "INSERT INTO songs (track_id, sha256, landmarks, done_at) VALUES (?, ?, ?, ?)",
                (track_id, sha256, int(len(hashes)), time.time()),
            )
            num = cur.lastrowid
            db.executemany(
                "INSERT OR IGNORE INTO marks (hash, num, t) VALUES (?, ?, ?)",
                ((int(h), num, int(s)) for h, s in zip(hashes, starts, strict=True)),
            )

    def _remove(self, db: sqlite3.Connection, track_id: str) -> None:
        row = db.execute("SELECT num FROM songs WHERE track_id = ?", (track_id,)).fetchone()
        if row:
            db.execute("DELETE FROM marks WHERE num = ?", (row[0],))
            db.execute("DELETE FROM songs WHERE num = ?", (row[0],))

    def remove(self, track_ids: Iterable[str]) -> None:
        with self.lock, self._connect() as db:
            for tid in track_ids:
                self._remove(db, tid)

    def clear(self) -> None:
        with self.lock, self._connect() as db:
            db.execute("DELETE FROM marks")
            db.execute("DELETE FROM songs")

    def match(self, samples: np.ndarray) -> Match | None:
        hashes, starts = fingerprint(samples)
        if len(hashes) < MIN_ALIGNED:
            return None
        rows: list[tuple[int, int, int]] = []
        unique = np.unique(hashes)
        with self._connect() as db:
            for i in range(0, len(unique), 500):
                chunk = [int(h) for h in unique[i : i + 500]]
                marks = ",".join("?" * len(chunk))
                rows += db.execute(
                    f"SELECT hash, num, t FROM marks WHERE hash IN ({marks})",  # noqa: S608
                    chunk,
                ).fetchall()
            names = dict(db.execute("SELECT num, track_id FROM songs"))
        if not rows:
            return None
        found = np.array(rows, dtype=np.int64)
        # For each landmark found at home, every place it occurs in the clip.
        order = np.argsort(hashes, kind="stable")
        sh, ss = hashes[order], starts[order]
        lo = np.searchsorted(sh, found[:, 0], side="left")
        hi = np.searchsorted(sh, found[:, 0], side="right")
        reps = hi - lo
        idx = np.repeat(np.arange(len(found)), reps)
        within = np.arange(len(idx)) - np.repeat(np.cumsum(reps) - reps, reps)
        clip_t = ss[lo[idx] + within]
        num = found[idx, 1]
        offset = found[idx, 2] - clip_t
        # Votes per (song, offset); the offsets either side count too (timing jitter).
        key = num * 200_000 + (offset + 100_000)
        keys, counts = np.unique(key, return_counts=True)
        near = counts.copy()
        for step in (-1, 1):
            j = np.searchsorted(keys, keys + step)
            hit = (j < len(keys)) & (keys[np.minimum(j, len(keys) - 1)] == keys + step)
            near[hit] += counts[j[hit]]
        nums = keys // 200_000
        offs = keys % 200_000 - 100_000
        # Each song's best offset, then the best song and the runner-up.
        order = np.lexsort((-near, nums))
        first = np.ones(len(order), dtype=bool)
        first[1:] = nums[order][1:] != nums[order][:-1]
        best = order[first]
        ranked = best[np.argsort(-near[best])]
        aligned, off, num_best = int(near[ranked[0]]), int(offs[ranked[0]]), int(nums[ranked[0]])
        runner_up = int(near[ranked[1]]) if len(ranked) > 1 else 0
        if aligned < MIN_ALIGNED or aligned < MIN_LEAD * max(runner_up, 1):
            return None
        track_id = names.get(num_best)
        if track_id is None:
            return None
        sure = min(1.0, aligned / 30)
        lead = min(1.0, (aligned - runner_up) / aligned * 1.5)
        confidence = sure * lead
        return Match(track_id, max(0.0, off * FRAME_S), aligned, round(confidence, 2))
