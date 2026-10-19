"""A small real music library, made with FFmpeg and tagged with mutagen.

Nothing binary is committed: every file is generated once per test session.
Each song is a few seconds of a different tone, so every file hashes
differently, and the tags cover the cases the scanner must handle: Malayalam
and Hindi titles, hi-res FLAC, MP3 with lyrics, ALAC, Opus, two spellings of
one artist, a file with no tags, a damaged file and an exact duplicate.
"""

from __future__ import annotations

import io
import shutil
import subprocess
from pathlib import Path

from mutagen.flac import FLAC, Picture
from mutagen.id3 import APIC, ID3, TALB, TIT2, TPE1, TPE2, TRCK, USLT
from mutagen.mp4 import MP4, MP4Cover
from mutagen.oggopus import OggOpus
from PIL import Image

FFMPEG = shutil.which("ffmpeg")


def _tone(out: Path, freq: int, seconds: float, args: list[str]) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi",
        "-i", f"sine=frequency={freq}:duration={seconds}:sample_rate=44100",
        "-ac", "2", *args, str(out),
    ]  # fmt: skip
    subprocess.run(cmd, check=True)


def cover_png(color: tuple[int, int, int]) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (800, 800), color).save(buf, "PNG")
    return buf.getvalue()


def _flac_tags(path: Path, picture: bytes | None = None, **tags: str) -> None:
    f = FLAC(path)
    for k, v in tags.items():
        f[k] = v
    if picture:
        pic = Picture()
        pic.type = 3
        pic.mime = "image/png"
        pic.data = picture
        f.add_picture(pic)
    f.save()


SYNCED_LRC = (
    "[ar:Arijit Singh]\n"
    "[00:00.50]Hum tere bin ab reh nahi sakte\n"
    "[00:01.75]Tere bina kya wajood mera\n"
)


def build_library(root: Path) -> dict[str, Path]:
    """Write the test library under root; returns notable paths by name."""
    assert FFMPEG, "FFmpeg is needed for the library tests"
    p: dict[str, Path] = {}

    # Malayalam title, 16/44.1 FLAC, embedded cover.
    p["malare"] = root / "Vijay Yesudas" / "Premam" / "01 Malare.flac"
    _tone(p["malare"], 440, 3, ["-c:a", "flac", "-sample_fmt", "s16"])
    _flac_tags(p["malare"], cover_png((200, 120, 40)), title="മലരേ (Malare)",
               artist="Vijay Yesudas", album="Premam", tracknumber="1", date="2015")  # fmt: skip
    p["premam2"] = root / "Vijay Yesudas" / "Premam" / "02 Aluva Puzha.flac"
    _tone(p["premam2"], 466, 2, ["-c:a", "flac", "-sample_fmt", "s16"])
    _flac_tags(p["premam2"], title="Aluva Puzha", artist="Vineeth Sreenivasan",
               albumartist="Vijay Yesudas", album="Premam", tracknumber="2",
               date="2015")  # fmt: skip

    # Hi-res 24/96 FLAC.
    p["dreams"] = root / "Fleetwood Mac" / "Rumours" / "02 Dreams.flac"
    _tone(p["dreams"], 523, 3, ["-c:a", "flac", "-sample_fmt", "s32", "-ar", "96000",
                               "-bits_per_raw_sample", "24"])  # fmt: skip
    _flac_tags(p["dreams"], cover_png((40, 80, 160)), title="Dreams", artist="Fleetwood Mac",
               album="Rumours", tracknumber="2", date="1977")  # fmt: skip

    # Hindi MP3 320 with lyrics in the tags.
    p["tumhiho"] = root / "Aashiqui 2" / "Tum Hi Ho.mp3"
    _tone(p["tumhiho"], 587, 3, ["-c:a", "libmp3lame", "-b:a", "320k"])
    id3 = ID3()
    id3.add(TIT2(encoding=3, text="तुम ही हो (Tum Hi Ho)"))
    id3.add(TPE1(encoding=3, text="Arijit Singh"))
    id3.add(TPE2(encoding=3, text="Mithoon, Jeet Gannguli"))
    id3.add(TALB(encoding=3, text="Aashiqui 2"))
    id3.add(TRCK(encoding=3, text="3/10"))
    id3.add(USLT(encoding=3, lang="hin", desc="", text=SYNCED_LRC))
    id3.add(APIC(encoding=3, mime="image/png", type=3, desc="", data=cover_png((150, 30, 60))))
    id3.save(p["tumhiho"])

    # ALAC by "A. R. Rahman" and FLAC by "AR Rahman": one artist.
    p["roja"] = root / "A. R. Rahman" / "Roja" / "01 Kadhal Rojave.m4a"
    _tone(p["roja"], 659, 2, ["-c:a", "alac", "-sample_fmt", "s16p"])
    m = MP4(p["roja"])
    m["\xa9nam"] = "Kadhal Rojave"
    m["\xa9ART"] = "A. R. Rahman"
    m["\xa9alb"] = "Roja"
    m["\xa9day"] = "1992"
    m["trkn"] = [(1, 6)]
    m["covr"] = [MP4Cover(cover_png((20, 140, 90)), imageformat=MP4Cover.FORMAT_PNG)]
    m.save()
    p["okkanmani"] = root / "AR Rahman" / "OK Kanmani" / "01 Mental Manadhil.flac"
    _tone(p["okkanmani"], 698, 2, ["-c:a", "flac", "-sample_fmt", "s16"])
    _flac_tags(p["okkanmani"], title="Mental Manadhil", artist="AR Rahman", album="OK Kanmani",
               tracknumber="1", date="2015")  # fmt: skip

    # Opus original.
    p["sowhat"] = root / "Miles Davis" / "Kind of Blue" / "01 So What.opus"
    _tone(p["sowhat"], 784, 3, ["-c:a", "libopus", "-b:a", "160k"])
    o = OggOpus(p["sowhat"])
    o["title"] = "So What"
    o["artist"] = "Miles Davis"
    o["album"] = "Kind of Blue"
    o["tracknumber"] = "1"
    o.save()

    # No tags at all, names from folders; a .lrc file and a cover.jpg beside it.
    p["untagged"] = root / "Ilaiyaraaja" / "Thalapathi" / "03 Sundari Kannal.flac"
    _tone(p["untagged"], 880, 2, ["-c:a", "flac"])
    p["untagged"].with_suffix(".lrc").write_text("Sundari kannal oru sedhi\nSollaayo\n", "utf-8")
    Image.new("RGB", (300, 300), (90, 90, 200)).save(p["untagged"].parent / "cover.jpg", "JPEG")

    # Damaged file and an exact duplicate in another folder.
    p["broken"] = root / "Incoming" / "broken.mp3"
    p["broken"].parent.mkdir(parents=True, exist_ok=True)
    p["broken"].write_bytes(b"this is not audio" * 100)
    p["duplicate"] = root / "Incoming" / "Copy of Dreams.flac"
    shutil.copyfile(p["dreams"], p["duplicate"])
    return p


# ------------------------------------------------------------ M3: Listen


def music_like(seed: int, seconds: float = 30.0, rate: int = 44100):
    """A made-up tune: chords with overtones, a bass line and a drum hit on
    each note, at a tempo of its own. Different seeds sound different."""
    import numpy as np

    r = np.random.default_rng(seed)
    out = np.zeros(int(seconds * rate), np.float32)
    beat = 60 / r.uniform(80, 140)
    scale = 220 * 2 ** (np.array([0, 2, 3, 5, 7, 8, 10, 12, 14, 15]) / 12)
    t = 0.0
    while t < seconds - 1:
        dur = beat * r.choice([0.5, 1, 1, 2])
        n, i = int(dur * rate), int(t * rate)
        tt = np.arange(n) / rate
        env = np.exp(-tt * r.uniform(1, 4))
        room = len(out) - i
        for f in r.choice(scale, size=r.integers(1, 4)) * r.choice([1, 2]):
            for h, a in [(1, 1), (2, 0.5), (3, 0.25), (4, 0.12)]:
                out[i : i + n] += (a * np.sin(2 * np.pi * f * h * tt) * env * 0.15)[:room]
        out[i : i + n] += (0.2 * np.sin(2 * np.pi * r.choice(scale) / 4 * tt) * env)[:room]
        k = min(int(0.05 * rate), room)
        out[i : i + k] += r.normal(0, 0.3, k) * np.exp(-np.arange(k) / 300)
        t += dur
    return out / np.max(np.abs(out)) * 0.8


def in_a_room(samples, seed: int, snr_db: float, rate: int = 44100):
    """As a phone hears it across a room: echo, talking-like noise, quieter."""
    import numpy as np

    r = np.random.default_rng(seed)
    n = int(0.25 * rate)
    echo = r.normal(0, 1, n) * np.exp(-np.arange(n) / (0.06 * rate))
    echo[0] = 1
    y = np.convolve(samples, echo)[: len(samples)]
    y /= np.max(np.abs(y))
    noise = np.convolve(r.normal(0, 1, len(y)), np.ones(8) / 8, "same")
    noise *= 0.5 + 0.5 * np.abs(np.sin(np.arange(len(y)) / rate * 2 * np.pi * 3))
    noise *= np.sqrt(np.mean(y**2) / (np.mean(noise**2) * 10 ** (snr_db / 10)))
    return (y + noise) * r.uniform(0.2, 0.9)


def write_audio(path: Path, samples, rate: int = 44100, args: list[str] | None = None) -> Path:
    """Samples to a file FFmpeg makes from its extension (.flac, .m4a, .wav…)."""
    import numpy as np

    pcm = (np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes()
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [FFMPEG, "-y", "-loglevel", "error", "-f", "s16le", "-ar", str(rate), "-ac", "1",
         "-i", "pipe:0", *(args or []), str(path)],
        input=pcm,
        check=True,
    )  # fmt: skip
    return path
