"""Lyrics set in Hive Admin or found online; songs looked up one by one.

Revision ID: 0004
Revises: 0003
Create Date: 2026-10-19
"""

import sqlalchemy as sa
from alembic import op

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None

TRACK_COLUMNS = [
    # Lyrics kept by Hive (not in the file): typed in Hive Admin or found online.
    sa.Column("lyrics", sa.Text(), nullable=True),
    sa.Column("lyrics_source", sa.String(length=8), nullable=True),
    sa.Column("lyrics_checked_at", sa.DateTime(timezone=True), nullable=True),
    # The file names its album (rather than Hive taking the folder's name).
    sa.Column("album_tagged", sa.Boolean(), nullable=False, server_default=sa.true()),
    # What a song-by-song lookup found (JSON), applied over the file's tags.
    sa.Column("lookup", sa.Text(), nullable=True),
    sa.Column("lookup_state", sa.String(length=16), nullable=True),
]


def upgrade() -> None:
    with op.batch_alter_table("tracks") as b:
        for c in TRACK_COLUMNS:
            b.add_column(c)
        b.create_index("ix_tracks_lyrics_checked_at", ["lyrics_checked_at"])


def downgrade() -> None:
    with op.batch_alter_table("tracks") as b:
        b.drop_index("ix_tracks_lyrics_checked_at")
        for c in TRACK_COLUMNS:
            b.drop_column(c.name)
