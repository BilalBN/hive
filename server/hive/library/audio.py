"""FFmpeg: loudness measurement and the cached Opus / FLAC streams.

Originals are never touched. Lossy streams (High = Opus 256 kbps, Data saver =
Opus 96 kbps; AAC at the same rates for Apple's player) and FLAC copies of
ALAC/AIFF for non-Apple players are made once in ``<data>/cache/streams`` and
reused.
"""

from __future__ import annotations

import logging
import os
import re
import shutil
import subprocess
import sys
import threading
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger("hive.audio")

_COMMON_FFMPEG = [
    "/opt/homebrew/bin/ffmpeg",  # Homebrew on Apple silicon
    "/usr/local/bin/ffmpeg",  # Homebrew on Intel Macs
    "/usr/bin/ffmpeg",
    r"C:\ffmpeg\bin\ffmpeg.exe",
    r"C:\Program Files\ffmpeg\bin\ffmpeg.exe",
]


def find_ffmpeg(configured: Path | None = None) -> Path | None:
    if configured is not None:
        return configured if configured.is_file() else None
    from hive.config import bundled_tool

    bundled = bundled_tool("ffmpeg")
    if bundled:
        return bundled
    on_path = shutil.which("ffmpeg")
    if on_path:
        return Path(on_path)
    for c in _COMMON_FFMPEG:
        if Path(c).is_file():
            return Path(c)
    return None


def _run(cmd: list[str], timeout: float) -> subprocess.CompletedProcess[str]:
    kwargs: dict = {}
    if sys.platform == "win32":
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW  # type: ignore[attr-defined]
    return subprocess.run(  # noqa: S603 - fixed argument list, no shell
        cmd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
        check=False,
        **kwargs,
    )


@dataclass
class Loudness:
    integrated_lufs: float
    true_peak_dbtp: float


_I = re.compile(r"I:\s+(-?[\d.]+|-inf)\s+LUFS")
_PEAK = re.compile(r"Peak:\s+(-?[\d.]+|-inf)\s+dBFS")


def measure_loudness(ffmpeg: Path, path: Path, duration_s: float) -> Loudness | None:
    """EBU R128 integrated loudness and true peak, or None if FFmpeg can't."""
    cmd = [
        str(ffmpeg), "-hide_banner", "-nostats", "-nostdin", "-i", str(path),
        "-map", "0:a:0", "-af", "ebur128=peak=true", "-f", "null", "-",
    ]  # fmt: skip
    try:
        r = _run(cmd, timeout=max(60.0, duration_s * 2))
    except (OSError, subprocess.TimeoutExpired) as e:
        log.warning("loudness failed for %s: %s", path.name, e)
        return None
    summary = r.stderr[r.stderr.rfind("Summary:") :] if "Summary:" in r.stderr else r.stderr
    i = _I.findall(summary)
    p = _PEAK.findall(summary)
    if not i or i[-1] == "-inf":
        return None
    peak = float(p[-1]) if p and p[-1] != "-inf" else -70.0
    return Loudness(integrated_lufs=float(i[-1]), true_peak_dbtp=peak)


# ------------------------------------------------------------- stream variants


@dataclass(frozen=True)
class Variant:
    """One way of sending a song."""

    key: str  # cache file name part
    codec: str
    container: str
    mime: str
    bitrate_kbps: int | None
    lossless: bool


OPUS_HIGH = Variant("opus256.ogg", "opus", "ogg", "audio/ogg", 256, False)
OPUS_SAVER = Variant("opus96.ogg", "opus", "ogg", "audio/ogg", 96, False)
# Apple's player (AVFoundation) doesn't stream Opus or Ogg reliably, so Apple
# devices get AAC in MP4 at the same bitrates.
AAC_HIGH = Variant("aac256.m4a", "aac", "mp4", "audio/mp4", 256, False)
AAC_SAVER = Variant("aac96.m4a", "aac", "mp4", "audio/mp4", 96, False)
FLAC_COPY = Variant("lossless.flac", "flac", "flac", "audio/flac", None, True)

ALL_VARIANTS = (OPUS_HIGH, OPUS_SAVER, AAC_HIGH, AAC_SAVER, FLAC_COPY)

ORIGINAL_MIME = {
    "flac": "audio/flac",
    "alac": "audio/mp4",
    "aac": "audio/mp4",
    "mp3": "audio/mpeg",
    "opus": "audio/ogg",
    "vorbis": "audio/ogg",
    "wav": "audio/wav",
    "aiff": "audio/aiff",
}


def original_mime(codec: str, path: Path) -> str:
    if codec == "aac" and path.suffix.lower() == ".aac":
        return "audio/aac"
    return ORIGINAL_MIME.get(codec, "application/octet-stream")


class TranscodeError(RuntimeError):
    def __init__(self, message: str, ffmpeg_output: str = "") -> None:
        super().__init__(message)
        self.ffmpeg_output = ffmpeg_output


class Transcoder:
    """Makes and caches stream variants; one FFmpeg run per variant, ever."""

    def __init__(self, ffmpeg: Path | None, cache_dir: Path) -> None:
        self.ffmpeg = ffmpeg
        self.dir = cache_dir / "streams"
        self._locks: dict[str, threading.Lock] = {}
        self._guard = threading.Lock()

    def path_for(self, sha256: str, variant: Variant) -> Path:
        return self.dir / sha256[:2] / f"{sha256}.{variant.key}"

    def _lock(self, key: str) -> threading.Lock:
        with self._guard:
            return self._locks.setdefault(key, threading.Lock())

    def ensure(self, source: Path, sha256: str, variant: Variant, duration_s: float) -> Path:
        """The cached file for this variant, made now if needed. Raises RuntimeError."""
        out = self.path_for(sha256, variant)
        if out.is_file() and out.stat().st_size > 0:
            return out
        if self.ffmpeg is None:
            raise RuntimeError("FFmpeg isn't installed on the home PC")
        with self._lock(out.name):
            if out.is_file() and out.stat().st_size > 0:
                return out
            out.parent.mkdir(parents=True, exist_ok=True)
            tmp = out.with_name(out.name + f".part{os.getpid()}")
            cmd = [str(self.ffmpeg), "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
                   "-i", str(source), "-map", "0:a:0", "-map_metadata", "-1", "-vn"]  # fmt: skip
            if variant.codec == "opus":
                cmd += ["-c:a", "libopus", "-b:a", f"{variant.bitrate_kbps}k", "-vbr", "on",
                        "-application", "audio", "-ar", "48000", "-f", "ogg"]  # fmt: skip
            elif variant.codec == "aac":
                # The index goes at the front so playback can start before the end arrives.
                cmd += ["-c:a", "aac", "-b:a", f"{variant.bitrate_kbps}k", "-ac", "2",
                        "-movflags", "+faststart", "-f", "mp4"]  # fmt: skip
            else:
                # FLAC copy of ALAC/AIFF/WAV: bit-identical audio, keeps the bit depth.
                cmd += ["-c:a", "flac", "-compression_level", "5", "-f", "flac"]
            cmd.append(str(tmp))
            try:
                r = _run(cmd, timeout=max(120.0, duration_s * 3))
            except subprocess.TimeoutExpired as e:
                tmp.unlink(missing_ok=True)
                raise RuntimeError("Making the stream took too long") from e
            if r.returncode != 0 or not tmp.is_file():
                tmp.unlink(missing_ok=True)
                reason = r.stderr.strip()[-500:]
                log.error("ffmpeg failed for %s: %s", source.name, reason)
                raise TranscodeError("FFmpeg couldn't convert this song", reason)
            os.replace(tmp, out)
            log.info("made %s for %s", variant.key, source.name)
            return out
