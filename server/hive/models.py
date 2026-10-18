"""Database tables.

M0: server metadata. M1: the library (artists, albums, tracks), the import
queue, playlists, likes and what each person played recently. People and
devices arrive in M2; until then every request acts as one person, ``dev``.
"""

from __future__ import annotations

from datetime import UTC, datetime

from sqlalchemy import (
    Boolean,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column

from hive.db import Base


def utcnow() -> datetime:
    return datetime.now(UTC)


class ServerMeta(Base):
    """Key/value facts about this installation (install id, first start, secrets)."""

    __tablename__ = "server_meta"

    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    value: Mapped[str] = mapped_column(String(1024))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


# ------------------------------------------------------------------ library


class Artist(Base):
    __tablename__ = "artists"

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    name: Mapped[str] = mapped_column(String(512))
    # Spelling-insensitive key: "A.R. Rahman" and "AR Rahman" share one.
    name_key: Mapped[str] = mapped_column(String(512), unique=True)
    search_text: Mapped[str] = mapped_column(Text, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Album(Base):
    __tablename__ = "albums"
    __table_args__ = (UniqueConstraint("artist_key", "title_key", name="uq_album_identity"),)

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    title: Mapped[str] = mapped_column(String(512))
    title_key: Mapped[str] = mapped_column(String(512))
    artist_id: Mapped[str | None] = mapped_column(ForeignKey("artists.id", ondelete="SET NULL"))
    artist_name: Mapped[str] = mapped_column(String(512))
    artist_key: Mapped[str] = mapped_column(String(512))
    year: Mapped[int | None] = mapped_column(Integer)
    genre: Mapped[str | None] = mapped_column(String(128))
    artwork_id: Mapped[str | None] = mapped_column(String(64))
    album_lufs: Mapped[float | None] = mapped_column(Float)
    search_text: Mapped[str] = mapped_column(Text, default="")
    added_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Track(Base):
    """One song and its original file. Transcodes are cached files, not rows."""

    __tablename__ = "tracks"
    __table_args__ = (
        Index("ix_tracks_album", "album_id", "disc_no", "track_no"),
        Index("ix_tracks_artist", "artist_id"),
    )

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    title: Mapped[str] = mapped_column(String(512))
    album_id: Mapped[str] = mapped_column(ForeignKey("albums.id", ondelete="CASCADE"))
    artist_id: Mapped[str | None] = mapped_column(ForeignKey("artists.id", ondelete="SET NULL"))
    artist_name: Mapped[str] = mapped_column(String(512))
    track_no: Mapped[int | None] = mapped_column(Integer)
    disc_no: Mapped[int | None] = mapped_column(Integer)
    duration_ms: Mapped[int] = mapped_column(Integer, default=0)
    genre: Mapped[str | None] = mapped_column(String(128))
    year: Mapped[int | None] = mapped_column(Integer)
    artwork_id: Mapped[str | None] = mapped_column(String(64))
    has_lyrics: Mapped[bool] = mapped_column(Boolean, default=False)
    lufs: Mapped[float | None] = mapped_column(Float)
    true_peak: Mapped[float | None] = mapped_column(Float)
    search_text: Mapped[str] = mapped_column(Text, default="")
    added_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)

    # The original file, stored byte for byte.
    path: Mapped[str] = mapped_column(String(2048), unique=True)
    folder: Mapped[str] = mapped_column(String(2048))
    size: Mapped[int] = mapped_column(Integer)
    mtime: Mapped[float] = mapped_column(Float)
    sha256: Mapped[str] = mapped_column(String(64), index=True)
    codec: Mapped[str] = mapped_column(String(16))
    lossless: Mapped[bool] = mapped_column(Boolean)
    sample_rate: Mapped[int] = mapped_column(Integer)
    bit_depth: Mapped[int | None] = mapped_column(Integer)
    bitrate_kbps: Mapped[int | None] = mapped_column(Integer)
    channels: Mapped[int] = mapped_column(Integer, default=2)


class ImportItem(Base):
    """A file the scanner has seen: the work queue and the "needs attention" list."""

    __tablename__ = "import_items"
    __table_args__ = (Index("ix_import_status", "status", "id"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    path: Mapped[str] = mapped_column(String(2048), unique=True)
    folder: Mapped[str] = mapped_column(String(2048))
    # queued → working → done | failed
    status: Mapped[str] = mapped_column(String(16), default="queued")
    problem: Mapped[str | None] = mapped_column(Text)
    track_id: Mapped[str | None] = mapped_column(String(32))
    size: Mapped[int | None] = mapped_column(Integer)
    mtime: Mapped[float | None] = mapped_column(Float)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow
    )


# ------------------------------------------------------------- per person


class Playlist(Base):
    __tablename__ = "playlists"

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    name: Mapped[str] = mapped_column(String(256))
    owner_id: Mapped[str] = mapped_column(String(64), index=True)
    shared: Mapped[bool] = mapped_column(Boolean, default=False)
    search_text: Mapped[str] = mapped_column(Text, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class PlaylistItem(Base):
    __tablename__ = "playlist_items"
    __table_args__ = (Index("ix_playlist_items_order", "playlist_id", "position"),)

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    playlist_id: Mapped[str] = mapped_column(ForeignKey("playlists.id", ondelete="CASCADE"))
    track_id: Mapped[str] = mapped_column(ForeignKey("tracks.id", ondelete="CASCADE"))
    position: Mapped[int] = mapped_column(Integer)
    added_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Like(Base):
    __tablename__ = "likes"

    user_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    track_id: Mapped[str] = mapped_column(
        ForeignKey("tracks.id", ondelete="CASCADE"), primary_key=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class PlayCount(Base):
    """How often each person played each song. Private to that person; the
    admin never sees it."""

    __tablename__ = "play_counts"

    user_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    track_id: Mapped[str] = mapped_column(
        ForeignKey("tracks.id", ondelete="CASCADE"), primary_key=True
    )
    count: Mapped[int] = mapped_column(Integer, default=0)
    last_played_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class RecentContext(Base):
    """Albums, playlists and artists a person played from, for "Jump back in"."""

    __tablename__ = "recent_contexts"

    user_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    kind: Mapped[str] = mapped_column(String(16), primary_key=True)
    ref_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    last_played_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
