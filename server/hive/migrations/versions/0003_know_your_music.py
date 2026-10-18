"""M1.5: album language, film, sources and lookup state; song credits.

Revision ID: 0003
Revises: 0002
Create Date: 2026-10-18
"""

import sqlalchemy as sa
from alembic import op

revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None

ALBUM_COLUMNS = [
    sa.Column("language", sa.String(length=8), nullable=True),
    sa.Column("sources", sa.Text(), nullable=False, server_default="{}"),
    sa.Column("overrides", sa.Text(), nullable=False, server_default="{}"),
    sa.Column("kind", sa.String(length=16), nullable=True),
    sa.Column("film_title", sa.String(length=512), nullable=True),
    sa.Column("film_year", sa.Integer(), nullable=True),
    sa.Column("film_wikidata", sa.String(length=32), nullable=True),
    sa.Column("mbid_release", sa.String(length=36), nullable=True),
    sa.Column("mbid_release_group", sa.String(length=36), nullable=True),
    sa.Column("lookup_state", sa.String(length=16), nullable=False, server_default="waiting"),
    sa.Column("lookup_note", sa.Text(), nullable=True),
    sa.Column("lookup_at", sa.DateTime(timezone=True), nullable=True),
    sa.Column("lookup_candidate", sa.Text(), nullable=True),
    sa.Column("folder_path", sa.String(length=2048), nullable=True),
]
TRACK_COLUMNS = [
    sa.Column("language", sa.String(length=8), nullable=True),
    sa.Column("composer", sa.String(length=512), nullable=True),
    sa.Column("lyricist", sa.String(length=512), nullable=True),
    sa.Column("mbid_recording", sa.String(length=36), nullable=True),
]


def upgrade() -> None:
    with op.batch_alter_table("albums") as b:
        for c in ALBUM_COLUMNS:
            b.add_column(c)
        b.create_index("ix_albums_language", ["language"])
        b.create_index("ix_albums_mbid_release", ["mbid_release"])
        b.create_index("ix_albums_lookup_state", ["lookup_state"])
        b.create_index("ix_albums_folder_path", ["folder_path"])
    with op.batch_alter_table("tracks") as b:
        for c in TRACK_COLUMNS:
            b.add_column(c)
    op.create_table(
        "credits",
        sa.Column("id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("album_id", sa.String(length=32), nullable=True),
        sa.Column("track_id", sa.String(length=32), nullable=True),
        sa.Column("artist_id", sa.String(length=32), nullable=False),
        sa.Column("role", sa.String(length=16), nullable=False),
        sa.Column("position", sa.Integer(), nullable=False),
        sa.Column("source", sa.String(length=8), nullable=False),
        sa.ForeignKeyConstraint(["album_id"], ["albums.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["track_id"], ["tracks.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["artist_id"], ["artists.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    with op.batch_alter_table("credits") as b:
        b.create_index("ix_credits_artist", ["artist_id", "role"])
        b.create_index("ix_credits_album", ["album_id"])
        b.create_index("ix_credits_track", ["track_id"])


def downgrade() -> None:
    op.drop_table("credits")
    with op.batch_alter_table("tracks") as b:
        for c in TRACK_COLUMNS:
            b.drop_column(c.name)
    with op.batch_alter_table("albums") as b:
        for name in (
            "ix_albums_language",
            "ix_albums_mbid_release",
            "ix_albums_lookup_state",
            "ix_albums_folder_path",
        ):
            b.drop_index(name)
        for c in ALBUM_COLUMNS:
            b.drop_column(c.name)
