"""Database tables.

M0: server metadata. M1: the library (artists, albums, tracks), the import
queue, playlists, likes and what each person played recently. M2: people,
invites, email codes, access requests, devices, admin sessions, audit log.
Before the first admin exists every request acts as one person, ``dev``.
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

    # M1.5: what Hive knows about the album beyond the tags.
    language: Mapped[str | None] = mapped_column(String(8), index=True)
    # Where each detail came from: {"language": "script", "artwork": "lookup", …}
    sources: Mapped[str] = mapped_column(Text, default="{}")
    # Fields set in Hive Admin, kept through rescans and lookups: {"year": 2015, …}
    overrides: Mapped[str] = mapped_column(Text, default="{}")
    kind: Mapped[str | None] = mapped_column(String(16))
    film_title: Mapped[str | None] = mapped_column(String(512))
    film_year: Mapped[int | None] = mapped_column(Integer)
    film_wikidata: Mapped[str | None] = mapped_column(String(32))
    mbid_release: Mapped[str | None] = mapped_column(String(36), index=True)
    mbid_release_group: Mapped[str | None] = mapped_column(String(36))
    # off | waiting | working | found | review | notFound | failed | edited
    lookup_state: Mapped[str] = mapped_column(String(16), default="waiting", index=True)
    lookup_note: Mapped[str | None] = mapped_column(Text)
    lookup_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # A match waiting for review, as the FoundAlbum JSON plus what to apply.
    lookup_candidate: Mapped[str | None] = mapped_column(Text)
    # The folder its songs are in (absolute), for grouping songs without tags.
    folder_path: Mapped[str | None] = mapped_column(String(2048), index=True)


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
    language: Mapped[str | None] = mapped_column(String(8))
    composer: Mapped[str | None] = mapped_column(String(512))
    lyricist: Mapped[str | None] = mapped_column(String(512))
    mbid_recording: Mapped[str | None] = mapped_column(String(36))
    # Lyrics kept by Hive rather than the file: typed in Hive Admin ("admin")
    # or found online ("online"). Admin lyrics win over the file's own.
    lyrics: Mapped[str | None] = mapped_column(Text)
    lyrics_source: Mapped[str | None] = mapped_column(String(8))
    lyrics_checked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), index=True)
    # False when the file has no album tag and Hive used its folder's name.
    album_tagged: Mapped[bool] = mapped_column(Boolean, default=True)
    # A song-by-song lookup's result (JSON: title, artist, album, albumArtist,
    # year, release, releaseGroup, recording), used over the file's tags.
    lookup: Mapped[str | None] = mapped_column(Text)
    # waiting | found | notFound, or None when the album is looked up whole.
    lookup_state: Mapped[str | None] = mapped_column(String(16))
    # M2 Tidy song names: the title as the file (or lookup) gives it, and the
    # clean one the admin chose to show instead. The file never changes.
    file_title: Mapped[str | None] = mapped_column(String(512))
    title_override: Mapped[str | None] = mapped_column(String(512))
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


class Credit(Base):
    """Who did what: a singer or lyricist of a song; a music director, actor or
    director of an album's film. People are Artist rows, so each has a page."""

    __tablename__ = "credits"
    __table_args__ = (
        Index("ix_credits_artist", "artist_id", "role"),
        Index("ix_credits_album", "album_id"),
        Index("ix_credits_track", "track_id"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    album_id: Mapped[str | None] = mapped_column(ForeignKey("albums.id", ondelete="CASCADE"))
    track_id: Mapped[str | None] = mapped_column(ForeignKey("tracks.id", ondelete="CASCADE"))
    artist_id: Mapped[str] = mapped_column(ForeignKey("artists.id", ondelete="CASCADE"))
    # singer | composer | lyricist | musicDirector | actor | director
    role: Mapped[str] = mapped_column(String(16))
    position: Mapped[int] = mapped_column(Integer, default=0)
    # tags | lookup | admin
    source: Mapped[str] = mapped_column(String(8), default="tags")


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


# ------------------------------------------------------------------ people (M2)


class User(Base):
    """A person in the family: proved their email once, approved once."""

    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    email: Mapped[str] = mapped_column(String(254), unique=True)  # lower case
    name: Mapped[str] = mapped_column(String(80))
    # admin | member
    role: Mapped[str] = mapped_column(String(8), default="member")
    # active | suspended
    status: Mapped[str] = mapped_column(String(12), default="active")
    device_limit: Mapped[int | None] = mapped_column(Integer)  # None: the home's default
    simple_mode: Mapped[bool] = mapped_column(Boolean, default=False)
    note: Mapped[str | None] = mapped_column(String(200))
    # An authenticator app (RFC 6238), for admins signing in away from home.
    totp_secret: Mapped[str | None] = mapped_column(String(64))
    totp_pending: Mapped[str | None] = mapped_column(String(64))
    totp_last_step: Mapped[int | None] = mapped_column(Integer)  # no code used twice
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    last_active_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Invite(Base):
    """An invite: a code (stored only as a hash), optionally for one address."""

    __tablename__ = "invites"

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    code_hash: Mapped[str] = mapped_column(String(64), unique=True)
    email: Mapped[str | None] = mapped_column(String(254))
    name: Mapped[str | None] = mapped_column(String(80))
    role: Mapped[str] = mapped_column(String(8), default="member")
    note: Mapped[str | None] = mapped_column(String(200))
    created_by: Mapped[str | None] = mapped_column(String(32))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    used_by: Mapped[str | None] = mapped_column(String(32))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class EmailCode(Base):
    """A 6-digit code sent to an address: 10 minutes, 5 tries, kept as a hash."""

    __tablename__ = "email_codes"
    __table_args__ = (Index("ix_email_codes_email", "email", "created_at"),)

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    email: Mapped[str] = mapped_column(String(254))
    # join | admin
    purpose: Mapped[str] = mapped_column(String(8))
    code_hash: Mapped[str] = mapped_column(String(64))
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    invite_id: Mapped[str | None] = mapped_column(String(32))
    device_name: Mapped[str | None] = mapped_column(String(80))
    platform: Mapped[str | None] = mapped_column(String(12))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class AccessRequest(Base):
    """Someone proved their email and is waiting (or was approved, or declined)."""

    __tablename__ = "access_requests"
    __table_args__ = (Index("ix_access_requests_status", "status", "created_at"),)

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    token_hash: Mapped[str] = mapped_column(String(64))
    email: Mapped[str] = mapped_column(String(254))
    user_id: Mapped[str | None] = mapped_column(String(32))  # set once approved
    invite_id: Mapped[str | None] = mapped_column(String(32))
    device_name: Mapped[str] = mapped_column(String(80))
    platform: Mapped[str] = mapped_column(String(12))
    # pending | approved | declined
    status: Mapped[str] = mapped_column(String(10), default="pending")
    existing_person: Mapped[bool] = mapped_column(Boolean, default=False)
    note: Mapped[str | None] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    decided_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    decided_by: Mapped[str | None] = mapped_column(String(32))
    device_id: Mapped[str | None] = mapped_column(String(32))  # the device it became
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class Device(Base):
    """One app install: its public key, and the refresh token it holds now."""

    __tablename__ = "devices"
    __table_args__ = (Index("ix_devices_user", "user_id", "status"),)

    id: Mapped[str] = mapped_column(String(32), primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    name: Mapped[str] = mapped_column(String(80))
    platform: Mapped[str] = mapped_column(String(12))
    app_version: Mapped[str | None] = mapped_column(String(32))
    public_key: Mapped[str] = mapped_column(String(64))  # Ed25519, base64url
    # active | revoked
    status: Mapped[str] = mapped_column(String(10), default="active")
    refresh_hash: Mapped[str | None] = mapped_column(String(64))
    refresh_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    challenge: Mapped[str | None] = mapped_column(String(64))
    challenge_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # self (removed by its owner, counts as a swap) | admin | reset
    revoked_by: Mapped[str | None] = mapped_column(String(8))


class AdminSession(Base):
    """A signed-in Hive Admin browser away from the home computer."""

    __tablename__ = "admin_sessions"

    id: Mapped[str] = mapped_column(String(64), primary_key=True)  # hash of the cookie
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class AuditEntry(Base):
    """Append-only: who did what and when (never what anyone listened to)."""

    __tablename__ = "audit_log"
    __table_args__ = (Index("ix_audit_at", "at"), Index("ix_audit_target", "target_id"))

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    actor_id: Mapped[str | None] = mapped_column(String(32))
    actor: Mapped[str] = mapped_column(String(80))
    action: Mapped[str] = mapped_column(String(48))
    target_id: Mapped[str | None] = mapped_column(String(32))
    text: Mapped[str] = mapped_column(Text)
