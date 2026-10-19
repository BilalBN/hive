"""M3: Listen history and song requests. (Fingerprints live in their own
file, data/fingerprints.db.)

Revision ID: 0006
Revises: 0005
Create Date: 2026-10-20
"""

import sqlalchemy as sa
from alembic import op

revision = "0006"
down_revision = "0005"
branch_labels = None
depends_on = None

TZ = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "listen_events",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("user_id", sa.String(32), nullable=False),
        sa.Column("at", TZ, nullable=False),
        sa.Column("source", sa.String(8), nullable=False),
        sa.Column(
            "track_id",
            sa.String(32),
            sa.ForeignKey("tracks.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("position_ms", sa.Integer(), nullable=True),
        sa.Column("confidence", sa.Float(), nullable=True),
        sa.Column("title", sa.String(512), nullable=True),
        sa.Column("artist", sa.String(512), nullable=True),
    )
    op.create_index("ix_listen_user_at", "listen_events", ["user_id", "at"])
    op.create_table(
        "song_requests",
        sa.Column("id", sa.String(32), primary_key=True),
        sa.Column("user_id", sa.String(32), nullable=False),
        sa.Column("at", TZ, nullable=False),
        sa.Column("source", sa.String(8), nullable=False),
        sa.Column("title", sa.String(512), nullable=True),
        sa.Column("artist", sa.String(512), nullable=True),
        sa.Column("note", sa.String(500), nullable=True),
        sa.Column("heard_at", TZ, nullable=True),
        sa.Column("listen_event_id", sa.Integer(), nullable=True),
        sa.Column("status", sa.String(10), nullable=False),
        sa.Column("decided_at", TZ, nullable=True),
        sa.Column("decided_by", sa.String(80), nullable=True),
    )
    op.create_index("ix_song_requests_status", "song_requests", ["status", "at"])


def downgrade() -> None:
    op.drop_table("song_requests")
    op.drop_table("listen_events")
