#!/usr/bin/env python3
"""Writes app/test/fixtures/landmarks.json: the landmarks home makes from a
made-up tune recorded the way Listen records (16 kHz, 16-bit mono WAV, read
with FFmpeg like a phone's clip). The app's own landmark maker
(app/lib/listen/landmarks.dart) is tested against it, so the two agree.

    server/.venv/bin/python tools/gen_landmark_fixture.py
"""

from __future__ import annotations

import io
import json
import math
import shutil
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "server"))

from hive.library import fingerprint as F  # noqa: E402

RATE = 16000  # what Listen records at
SONG_RATE = 44100  # home's copy of the song
SONG_SECONDS = 10
CLIP_FROM, CLIP_SECONDS = 2.0, 6  # the recording: 6 seconds from 2 s in
NOTES = [0, 4, 7, 12, 7, 4, 2, 5, 9, 12, 14, 9, 5, 2, 0, -3, 0, 7, 3, 10, 15, 10, 3, -2]


def tune(t: float) -> float:
    """The made-up song at time t (keep in step with the Dart test)."""
    note_len = 0.25
    k = int(t / note_len)
    f = 220.0 * 2 ** (NOTES[k % len(NOTES)] / 12)
    tn = t - k * note_len
    x = 0.0
    for h in (1, 2, 3):
        x += (0.5 / h) * math.sin(2 * math.pi * f * h * t)
    return x * 0.6 * math.exp(-3 * tn)


def _pcm(xs) -> bytes:
    out = bytearray()
    for x in xs:
        out += int(round(max(-1.0, min(1.0, x)) * 32767)).to_bytes(2, "little", signed=True)
    return bytes(out)


def song_pcm() -> bytes:
    return _pcm(tune(n / SONG_RATE) for n in range(SONG_RATE * SONG_SECONDS))


def clip_pcm() -> bytes:
    """The song across a room: quieter, an echo 60 ms later, and hiss (a
    simple generator both languages repeat exactly)."""
    seed = 12345
    xs = []
    for n in range(RATE * CLIP_SECONDS):
        t = CLIP_FROM + n / RATE
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        hiss = (seed / 0x7FFFFFFF - 0.5) * 0.2
        xs.append(0.5 * tune(t) + 0.25 * tune(t - 0.06) + hiss)
    return _pcm(xs)


def wav(pcm: bytes, rate: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return buf.getvalue()


def aligned(ref: dict[int, list[int]], hashes, starts) -> tuple[int, int]:
    """Home's vote: the best (song frame - clip frame) offset and how many
    landmarks agree on it, give or take a frame."""
    votes: dict[int, int] = {}
    for h, t in zip(hashes, starts, strict=True):
        for rt in ref.get(int(h), ()):
            votes[rt - int(t)] = votes.get(rt - int(t), 0) + 1
    best = max(votes, key=lambda o: votes[o] + votes.get(o - 1, 0) + votes.get(o + 1, 0))
    return best, votes[best] + votes.get(best - 1, 0) + votes.get(best + 1, 0)


def main() -> None:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        sys.exit("needs FFmpeg")
    song = F.decode(Path(ffmpeg), wav(song_pcm(), SONG_RATE))
    ref_h, ref_t = F.fingerprint(song)
    ref: dict[int, list[int]] = {}
    for h, t in zip(ref_h.tolist(), ref_t.tolist(), strict=True):
        ref.setdefault(h, []).append(t)
    clip = F.decode(Path(ffmpeg), wav(clip_pcm(), RATE))
    clip_h, clip_t = F.fingerprint(clip)
    offset, votes = aligned(ref, clip_h, clip_t)
    out = ROOT / "app" / "test" / "fixtures" / "landmarks.json"
    out.write_text(
        json.dumps(
            {
                "song": {"hashes": ref_h.tolist(), "starts": ref_t.tolist()},
                "home": {"offset": offset, "aligned": votes, "landmarks": len(clip_h)},
            }
        )
        + "\n"
    )
    print(f"{out.relative_to(ROOT)}: song {len(ref_h)} landmarks; home matches the clip at "
          f"frame {offset} with {votes} aligned")


if __name__ == "__main__":
    main()
