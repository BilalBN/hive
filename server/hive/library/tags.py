"""Reading what's inside an audio file: format, tags, cover art and lyrics.

Uses mutagen, which reads ID3 (MP3, WAV, AIFF), FLAC, MP4/M4A and Ogg tags.
When tags are missing, names come from the folder and file names instead
(``Artist/Album/03 Title.flac``), so nothing is hidden for lack of tags.
"""

from __future__ import annotations

import base64
import contextlib
import re
from dataclasses import dataclass, field
from pathlib import Path

import mutagen
from mutagen.aiff import AIFF
from mutagen.flac import FLAC, Picture
from mutagen.id3 import ID3
from mutagen.mp3 import MP3
from mutagen.mp4 import MP4
from mutagen.oggopus import OggOpus
from mutagen.oggvorbis import OggVorbis
from mutagen.wave import WAVE

AUDIO_EXTENSIONS = {
    ".flac", ".mp3", ".m4a", ".mp4", ".aac", ".ogg", ".oga", ".opus", ".wav", ".aif", ".aiff",
}  # fmt: skip
IMAGE_NAMES = ("cover", "folder", "front", "album", "artwork")
IMAGE_EXTENSIONS = (".jpg", ".jpeg", ".png", ".webp")

_TRACK_PREFIX = re.compile(r"^\s*(?:(\d{1,2})[-.](?=\d))?(\d{1,3})\s*[-._)]?\s+")


class UnreadableFile(Exception):
    """The file isn't audio Hive can read. The message is shown in Hive Admin."""


@dataclass
class FileInfo:
    codec: str
    lossless: bool
    sample_rate: int
    channels: int
    duration_ms: int
    bit_depth: int | None = None
    bitrate_kbps: int | None = None
    title: str | None = None
    artist: str | None = None
    album: str | None = None
    album_artist: str | None = None
    track_no: int | None = None
    disc_no: int | None = None
    year: int | None = None
    genre: str | None = None
    compilation: bool = False
    composer: str | None = None
    lyricist: str | None = None
    language: str | None = None
    mb_album_id: str | None = None
    mb_release_group_id: str | None = None
    mb_recording_id: str | None = None
    picture: bytes | None = None
    picture_from_folder: bool = False
    lyrics: str | None = None
    extra: dict[str, str] = field(default_factory=dict)


def is_audio(path: Path) -> bool:
    return path.suffix.lower() in AUDIO_EXTENSIONS and not path.name.startswith("._")


def _first(value: object) -> str | None:
    if value is None:
        return None
    if isinstance(value, list | tuple):
        value = value[0] if value else None
        if value is None:
            return None
    text = str(value).strip().strip("\x00")
    return text or None


def _number(value: str | None) -> int | None:
    """'3', '3/12', '03' → 3."""
    if not value:
        return None
    m = re.match(r"\s*(\d+)", value)
    return int(m.group(1)) if m else None


def _year(value: str | None) -> int | None:
    if not value:
        return None
    m = re.search(r"(1[89]\d\d|20\d\d)", value)
    return int(m.group(1)) if m else None


def _codec_of(audio: mutagen.FileType) -> tuple[str, bool]:
    if isinstance(audio, FLAC):
        return "flac", True
    if isinstance(audio, MP3):
        return "mp3", False
    if isinstance(audio, MP4):
        codec = getattr(audio.info, "codec", "") or ""
        if codec.startswith("alac"):
            return "alac", True
        return "aac", False
    if isinstance(audio, OggOpus):
        return "opus", False
    if isinstance(audio, OggVorbis):
        return "vorbis", False
    if isinstance(audio, WAVE):
        return "wav", True
    if isinstance(audio, AIFF):
        return "aiff", True
    name = type(audio).__name__.lower()
    if "aac" in name:
        return "aac", False
    raise UnreadableFile(f"Hive can't play {type(audio).__name__} files")


def _tags_generic(audio: mutagen.FileType, info: FileInfo) -> None:
    """Vorbis comments (FLAC, Ogg) and the easy MP4 atoms."""
    tags = audio.tags
    if tags is None:
        return
    if isinstance(audio, MP4):
        g = lambda k: _first(tags.get(k))  # noqa: E731
        info.title = g("\xa9nam")
        info.artist = g("\xa9ART")
        info.album = g("\xa9alb")
        info.album_artist = g("aART")
        info.genre = g("\xa9gen")
        info.year = _year(g("\xa9day"))
        info.lyrics = g("\xa9lyr")
        trkn = tags.get("trkn")
        if trkn:
            info.track_no = trkn[0][0] or None
        disk = tags.get("disk")
        if disk:
            info.disc_no = disk[0][0] or None
        info.compilation = bool(tags.get("cpil"))
        info.composer = g("\xa9wrt")

        def free(name: str) -> str | None:
            v = tags.get(f"----:com.apple.iTunes:{name}")
            if not v:
                return None
            raw = v[0]
            text = raw if isinstance(raw, str) else bytes(raw).decode("utf-8", "replace")
            return _first(text)

        info.lyricist = free("LYRICIST")
        info.language = free("LANGUAGE")
        info.mb_album_id = free("MusicBrainz Album Id")
        info.mb_release_group_id = free("MusicBrainz Release Group Id")
        info.mb_recording_id = free("MusicBrainz Track Id")
        covr = tags.get("covr")
        if covr:
            info.picture = bytes(covr[0])
        return
    g = lambda k: _first(tags.get(k))  # noqa: E731
    info.title = g("title")
    info.artist = g("artist")
    info.album = g("album")
    info.album_artist = g("albumartist") or g("album artist") or g("album_artist")
    info.genre = g("genre")
    info.year = _year(g("date") or g("year") or g("originaldate"))
    info.track_no = _number(g("tracknumber"))
    info.disc_no = _number(g("discnumber"))
    info.compilation = g("compilation") in ("1", "true", "True")
    info.lyrics = g("lyrics") or g("unsyncedlyrics")
    info.composer = g("composer")
    info.lyricist = g("lyricist") or g("writer")
    info.language = g("language")
    info.mb_album_id = g("musicbrainz_albumid")
    info.mb_release_group_id = g("musicbrainz_releasegroupid")
    info.mb_recording_id = g("musicbrainz_trackid")
    if isinstance(audio, FLAC) and audio.pictures:
        front = [p for p in audio.pictures if p.type == 3]
        info.picture = (front or audio.pictures)[0].data
    elif "metadata_block_picture" in tags:
        try:
            pic = Picture(base64.b64decode(tags["metadata_block_picture"][0]))
            info.picture = pic.data
        except Exception:  # noqa: BLE001 - a broken picture shouldn't hide the song
            pass


def _tags_id3(tags: ID3, info: FileInfo) -> None:
    def text(frame: str) -> str | None:
        f = tags.get(frame)
        return _first(f.text) if f is not None and hasattr(f, "text") else None

    info.title = text("TIT2")
    info.artist = text("TPE1")
    info.album = text("TALB")
    info.album_artist = text("TPE2")
    info.genre = text("TCON")
    info.year = _year(text("TDRC") or text("TYER") or text("TDOR"))
    info.track_no = _number(text("TRCK"))
    info.disc_no = _number(text("TPOS"))
    info.compilation = text("TCMP") == "1"
    info.composer = text("TCOM")
    info.lyricist = text("TEXT")
    info.language = text("TLAN")

    def txxx(desc: str) -> str | None:
        for f in tags.getall("TXXX"):
            if getattr(f, "desc", "").lower() == desc.lower():
                return _first(f.text)
        return None

    info.mb_album_id = txxx("MusicBrainz Album Id")
    info.mb_release_group_id = txxx("MusicBrainz Release Group Id")
    for f in tags.getall("UFID"):
        if getattr(f, "owner", "") == "http://musicbrainz.org":
            with contextlib.suppress(Exception):
                info.mb_recording_id = f.data.decode("ascii")
    pictures = tags.getall("APIC")
    if pictures:
        front = [p for p in pictures if p.type == 3]
        info.picture = (front or pictures)[0].data
    lyrics = tags.getall("USLT")
    if lyrics:
        info.lyrics = _first(lyrics[0].text)
    synced = tags.getall("SYLT")
    if synced and not info.lyrics:
        # SYLT holds (text, time-in-ms) pairs; turn them into LRC.
        lines = []
        for text_, ms in synced[0].text:
            lines.append(f"[{ms // 60000:02d}:{(ms % 60000) / 1000:05.2f}]{text_.strip()}")
        info.lyrics = "\n".join(lines) or None


def read_file(path: Path, root: Path | None = None) -> FileInfo:
    try:
        audio = mutagen.File(path)
    except Exception as e:  # noqa: BLE001 - mutagen raises many kinds
        raise UnreadableFile(f"The file is damaged or not audio ({type(e).__name__})") from e
    if audio is None or audio.info is None:
        raise UnreadableFile("Not an audio file Hive recognises")

    codec, lossless = _codec_of(audio)
    ai = audio.info
    length = float(getattr(ai, "length", 0) or 0)
    if length <= 0:
        raise UnreadableFile("The file has no playable audio (length is zero)")
    sample_rate = int(getattr(ai, "sample_rate", 0) or 0)
    if codec == "opus":
        sample_rate = 48000  # Opus always decodes at 48 kHz
    bit_depth = getattr(ai, "bits_per_sample", None) or getattr(ai, "bits_per_raw_sample", None)
    bitrate = getattr(ai, "bitrate", None)
    info = FileInfo(
        codec=codec,
        lossless=lossless,
        sample_rate=sample_rate or 44100,
        channels=int(getattr(ai, "channels", 2) or 2),
        duration_ms=round(length * 1000),
        bit_depth=int(bit_depth) if lossless and bit_depth else None,
        bitrate_kbps=round(bitrate / 1000) if bitrate else None,
    )
    if isinstance(audio.tags, ID3):
        _tags_id3(audio.tags, info)
    else:
        _tags_generic(audio, info)
    _fill_from_names(path, info, root)
    if info.picture is None:
        info.picture = folder_picture(path.parent)
        info.picture_from_folder = info.picture is not None
    lrc = path.with_suffix(".lrc")
    if lrc.is_file():
        with contextlib.suppress(OSError):
            info.lyrics = lrc.read_text(encoding="utf-8-sig", errors="replace")
    return info


def _fill_from_names(path: Path, info: FileInfo, root: Path | None) -> None:
    """Fall back to Artist/Album/NN Title when tags are missing."""
    album_dir = path.parent if root is None or path.parent != root else None
    artist_dir = (
        album_dir.parent
        if album_dir is not None and (root is None or album_dir.parent != root)
        else None
    )
    if not info.title:
        stem = path.stem
        m = _TRACK_PREFIX.match(stem)
        if m:
            if info.track_no is None:
                info.track_no = int(m.group(2))
            if info.disc_no is None and m.group(1):
                info.disc_no = int(m.group(1))
            stem = stem[m.end() :]
        info.title = stem.replace("_", " ").strip() or path.stem
    if not info.album:
        info.album = (album_dir.name if album_dir is not None else "") or "Unknown album"
    if not info.artist:
        info.artist = info.album_artist or (
            (artist_dir.name if artist_dir is not None else "") or "Unknown artist"
        )


def folder_picture(folder: Path) -> bytes | None:
    """cover.jpg, folder.jpg and friends next to the music."""
    try:
        candidates = [p for p in folder.iterdir() if p.suffix.lower() in IMAGE_EXTENSIONS]
    except OSError:
        return None
    candidates.sort(key=lambda p: p.name.lower())
    for name in IMAGE_NAMES:
        for p in candidates:
            if p.stem.lower() == name:
                return _read_small(p)
    return _read_small(candidates[0]) if candidates else None


def _read_small(p: Path) -> bytes | None:
    try:
        if p.stat().st_size > 30 * 1024 * 1024:
            return None
        return p.read_bytes()
    except OSError:
        return None
