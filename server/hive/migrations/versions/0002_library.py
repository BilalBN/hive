"""Library: artists, albums, tracks, import queue, playlists, likes, play counts.

Revision ID: 0002
Revises: 0001
Create Date: 2026-10-18
"""

import sqlalchemy as sa
from alembic import op

revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "artists",
        sa.Column("id", sa.String(length=32), nullable=False),
        sa.Column("name", sa.String(length=512), nullable=False),
        sa.Column("name_key", sa.String(length=512), nullable=False),
        sa.Column("search_text", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("name_key"),
    )
    op.create_table(
        "import_items",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("path", sa.String(length=2048), nullable=False),
        sa.Column("folder", sa.String(length=2048), nullable=False),
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("problem", sa.Text(), nullable=True),
        sa.Column("track_id", sa.String(length=32), nullable=True),
        sa.Column("size", sa.Integer(), nullable=True),
        sa.Column("mtime", sa.Float(), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("path"),
    )
    with op.batch_alter_table("import_items", schema=None) as batch_op:
        batch_op.create_index("ix_import_status", ["status", "id"], unique=False)

    op.create_table(
        "playlists",
        sa.Column("id", sa.String(length=32), nullable=False),
        sa.Column("name", sa.String(length=256), nullable=False),
        sa.Column("owner_id", sa.String(length=64), nullable=False),
        sa.Column("shared", sa.Boolean(), nullable=False),
        sa.Column("search_text", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("id"),
    )
    with op.batch_alter_table("playlists", schema=None) as batch_op:
        batch_op.create_index(batch_op.f("ix_playlists_owner_id"), ["owner_id"], unique=False)

    op.create_table(
        "recent_contexts",
        sa.Column("user_id", sa.String(length=64), nullable=False),
        sa.Column("kind", sa.String(length=16), nullable=False),
        sa.Column("ref_id", sa.String(length=64), nullable=False),
        sa.Column("last_played_at", sa.DateTime(timezone=True), nullable=False),
        sa.PrimaryKeyConstraint("user_id", "kind", "ref_id"),
    )
    op.create_table(
        "albums",
        sa.Column("id", sa.String(length=32), nullable=False),
        sa.Column("title", sa.String(length=512), nullable=False),
        sa.Column("title_key", sa.String(length=512), nullable=False),
        sa.Column("artist_id", sa.String(length=32), nullable=True),
        sa.Column("artist_name", sa.String(length=512), nullable=False),
        sa.Column("artist_key", sa.String(length=512), nullable=False),
        sa.Column("year", sa.Integer(), nullable=True),
        sa.Column("genre", sa.String(length=128), nullable=True),
        sa.Column("artwork_id", sa.String(length=64), nullable=True),
        sa.Column("album_lufs", sa.Float(), nullable=True),
        sa.Column("search_text", sa.Text(), nullable=False),
        sa.Column("added_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["artist_id"], ["artists.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("artist_key", "title_key", name="uq_album_identity"),
    )
    op.create_table(
        "tracks",
        sa.Column("id", sa.String(length=32), nullable=False),
        sa.Column("title", sa.String(length=512), nullable=False),
        sa.Column("album_id", sa.String(length=32), nullable=False),
        sa.Column("artist_id", sa.String(length=32), nullable=True),
        sa.Column("artist_name", sa.String(length=512), nullable=False),
        sa.Column("track_no", sa.Integer(), nullable=True),
        sa.Column("disc_no", sa.Integer(), nullable=True),
        sa.Column("duration_ms", sa.Integer(), nullable=False),
        sa.Column("genre", sa.String(length=128), nullable=True),
        sa.Column("year", sa.Integer(), nullable=True),
        sa.Column("artwork_id", sa.String(length=64), nullable=True),
        sa.Column("has_lyrics", sa.Boolean(), nullable=False),
        sa.Column("lufs", sa.Float(), nullable=True),
        sa.Column("true_peak", sa.Float(), nullable=True),
        sa.Column("search_text", sa.Text(), nullable=False),
        sa.Column("added_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("path", sa.String(length=2048), nullable=False),
        sa.Column("folder", sa.String(length=2048), nullable=False),
        sa.Column("size", sa.Integer(), nullable=False),
        sa.Column("mtime", sa.Float(), nullable=False),
        sa.Column("sha256", sa.String(length=64), nullable=False),
        sa.Column("codec", sa.String(length=16), nullable=False),
        sa.Column("lossless", sa.Boolean(), nullable=False),
        sa.Column("sample_rate", sa.Integer(), nullable=False),
        sa.Column("bit_depth", sa.Integer(), nullable=True),
        sa.Column("bitrate_kbps", sa.Integer(), nullable=True),
        sa.Column("channels", sa.Integer(), nullable=False),
        sa.ForeignKeyConstraint(["album_id"], ["albums.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["artist_id"], ["artists.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("path"),
    )
    with op.batch_alter_table("tracks", schema=None) as batch_op:
        batch_op.create_index("ix_tracks_album", ["album_id", "disc_no", "track_no"], unique=False)
        batch_op.create_index("ix_tracks_artist", ["artist_id"], unique=False)
        batch_op.create_index(batch_op.f("ix_tracks_sha256"), ["sha256"], unique=False)

    op.create_table(
        "likes",
        sa.Column("user_id", sa.String(length=64), nullable=False),
        sa.Column("track_id", sa.String(length=32), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["track_id"], ["tracks.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("user_id", "track_id"),
    )
    op.create_table(
        "play_counts",
        sa.Column("user_id", sa.String(length=64), nullable=False),
        sa.Column("track_id", sa.String(length=32), nullable=False),
        sa.Column("count", sa.Integer(), nullable=False),
        sa.Column("last_played_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["track_id"], ["tracks.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("user_id", "track_id"),
    )
    op.create_table(
        "playlist_items",
        sa.Column("id", sa.String(length=32), nullable=False),
        sa.Column("playlist_id", sa.String(length=32), nullable=False),
        sa.Column("track_id", sa.String(length=32), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.Column("added_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["playlist_id"], ["playlists.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["track_id"], ["tracks.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    with op.batch_alter_table("playlist_items", schema=None) as batch_op:
        batch_op.create_index("ix_playlist_items_order", ["playlist_id", "position"], unique=False)


def downgrade() -> None:
    with op.batch_alter_table("playlist_items", schema=None) as batch_op:
        batch_op.drop_index("ix_playlist_items_order")

    op.drop_table("playlist_items")
    op.drop_table("play_counts")
    op.drop_table("likes")
    with op.batch_alter_table("tracks", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_tracks_sha256"))
        batch_op.drop_index("ix_tracks_artist")
        batch_op.drop_index("ix_tracks_album")

    op.drop_table("tracks")
    op.drop_table("albums")
    op.drop_table("recent_contexts")
    with op.batch_alter_table("playlists", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_playlists_owner_id"))

    op.drop_table("playlists")
    with op.batch_alter_table("import_items", schema=None) as batch_op:
        batch_op.drop_index("ix_import_status")

    op.drop_table("import_items")
    op.drop_table("artists")
