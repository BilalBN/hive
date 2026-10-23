"""M4: corrections to a song made in Hive Admin (title, artist, numbers,
composer, lyricist), kept apart from what the file says.

Revision ID: 0007
Revises: 0006
Create Date: 2026-10-23
"""

import sqlalchemy as sa
from alembic import op

revision = "0007"
down_revision = "0006"
branch_labels = None
depends_on = None


def upgrade() -> None:
    with op.batch_alter_table("tracks") as t:
        t.add_column(sa.Column("overrides", sa.Text(), nullable=False, server_default="{}"))


def downgrade() -> None:
    with op.batch_alter_table("tracks") as t:
        t.drop_column("overrides")
