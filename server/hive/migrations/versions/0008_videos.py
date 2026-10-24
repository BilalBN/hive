"""M6: music videos found in the music folders, each matched to its song.

Revision ID: 0008
Revises: 0007
Create Date: 2026-10-24
"""

import sqlalchemy as sa
from alembic import op

revision = "0008"
down_revision = "0007"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "videos",
        sa.Column("id", sa.String(32), primary_key=True),
        sa.Column("path", sa.String(4096), nullable=False, unique=True),
        sa.Column("folder", sa.String(4096), nullable=False),
        sa.Column("size", sa.Integer(), nullable=False),
        sa.Column("mtime", sa.Float(), nullable=False),
        sa.Column("duration_ms", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("width", sa.Integer()),
        sa.Column("height", sa.Integer()),
        sa.Column("track_id", sa.String(32), sa.ForeignKey("tracks.id", ondelete="SET NULL")),
        sa.Column("added_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_videos_track_id", "videos", ["track_id"])


def downgrade() -> None:
    op.drop_index("ix_videos_track_id", "videos")
    op.drop_table("videos")
