"""M2: people, invites, email codes, access requests, devices, admin sessions,
audit log; tidy song titles.

Revision ID: 0005
Revises: 0004
Create Date: 2026-10-19
"""

import sqlalchemy as sa
from alembic import op

revision = "0005"
down_revision = "0004"
branch_labels = None
depends_on = None

TZ = sa.DateTime(timezone=True)


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.String(32), primary_key=True),
        sa.Column("email", sa.String(254), nullable=False, unique=True),
        sa.Column("name", sa.String(80), nullable=False),
        sa.Column("role", sa.String(8), nullable=False),
        sa.Column("status", sa.String(12), nullable=False),
        sa.Column("device_limit", sa.Integer(), nullable=True),
        sa.Column("simple_mode", sa.Boolean(), nullable=False),
        sa.Column("note", sa.String(200), nullable=True),
        sa.Column("totp_secret", sa.String(64), nullable=True),
        sa.Column("totp_pending", sa.String(64), nullable=True),
        sa.Column("totp_last_step", sa.Integer(), nullable=True),
        sa.Column("created_at", TZ, nullable=False),
        sa.Column("last_active_at", TZ, nullable=True),
    )
    op.create_table(
        "invites",
        sa.Column("id", sa.String(32), primary_key=True),
        sa.Column("code_hash", sa.String(64), nullable=False, unique=True),
        sa.Column("email", sa.String(254), nullable=True),
        sa.Column("name", sa.String(80), nullable=True),
        sa.Column("role", sa.String(8), nullable=False),
        sa.Column("note", sa.String(200), nullable=True),
        sa.Column("created_by", sa.String(32), nullable=True),
        sa.Column("created_at", TZ, nullable=False),
        sa.Column("expires_at", TZ, nullable=False),
        sa.Column("used_at", TZ, nullable=True),
        sa.Column("used_by", sa.String(32), nullable=True),
        sa.Column("revoked_at", TZ, nullable=True),
    )
    op.create_table(
        "email_codes",
        sa.Column("id", sa.String(32), primary_key=True),
        sa.Column("email", sa.String(254), nullable=False),
        sa.Column("purpose", sa.String(8), nullable=False),
        sa.Column("code_hash", sa.String(64), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("invite_id", sa.String(32), nullable=True),
        sa.Column("device_name", sa.String(80), nullable=True),
        sa.Column("platform", sa.String(12), nullable=True),
        sa.Column("created_at", TZ, nullable=False),
        sa.Column("expires_at", TZ, nullable=False),
        sa.Column("used_at", TZ, nullable=True),
    )
    op.create_index("ix_email_codes_email", "email_codes", ["email", "created_at"])
    op.create_table(
        "access_requests",
        sa.Column("id", sa.String(32), primary_key=True),
        sa.Column("token_hash", sa.String(64), nullable=False),
        sa.Column("email", sa.String(254), nullable=False),
        sa.Column("user_id", sa.String(32), nullable=True),
        sa.Column("invite_id", sa.String(32), nullable=True),
        sa.Column("device_name", sa.String(80), nullable=False),
        sa.Column("platform", sa.String(12), nullable=False),
        sa.Column("status", sa.String(10), nullable=False),
        sa.Column("existing_person", sa.Boolean(), nullable=False),
        sa.Column("note", sa.String(200), nullable=True),
        sa.Column("created_at", TZ, nullable=False),
        sa.Column("decided_at", TZ, nullable=True),
        sa.Column("decided_by", sa.String(32), nullable=True),
        sa.Column("device_id", sa.String(32), nullable=True),
        sa.Column("expires_at", TZ, nullable=False),
    )
    op.create_index("ix_access_requests_status", "access_requests", ["status", "created_at"])
    op.create_table(
        "devices",
        sa.Column("id", sa.String(32), primary_key=True),
        sa.Column(
            "user_id", sa.String(32), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("name", sa.String(80), nullable=False),
        sa.Column("platform", sa.String(12), nullable=False),
        sa.Column("app_version", sa.String(32), nullable=True),
        sa.Column("public_key", sa.String(64), nullable=False),
        sa.Column("status", sa.String(10), nullable=False),
        sa.Column("refresh_hash", sa.String(64), nullable=True),
        sa.Column("refresh_expires_at", TZ, nullable=True),
        sa.Column("challenge", sa.String(64), nullable=True),
        sa.Column("challenge_expires_at", TZ, nullable=True),
        sa.Column("created_at", TZ, nullable=False),
        sa.Column("last_seen_at", TZ, nullable=True),
        sa.Column("revoked_at", TZ, nullable=True),
        sa.Column("revoked_by", sa.String(8), nullable=True),
    )
    op.create_index("ix_devices_user", "devices", ["user_id", "status"])
    op.create_table(
        "admin_sessions",
        sa.Column("id", sa.String(64), primary_key=True),
        sa.Column(
            "user_id", sa.String(32), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False
        ),
        sa.Column("created_at", TZ, nullable=False),
        sa.Column("expires_at", TZ, nullable=False),
    )
    op.create_table(
        "audit_log",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("at", TZ, nullable=False),
        sa.Column("actor_id", sa.String(32), nullable=True),
        sa.Column("actor", sa.String(80), nullable=False),
        sa.Column("action", sa.String(48), nullable=False),
        sa.Column("target_id", sa.String(32), nullable=True),
        sa.Column("text", sa.Text(), nullable=False),
    )
    op.create_index("ix_audit_at", "audit_log", ["at"])
    op.create_index("ix_audit_target", "audit_log", ["target_id"])
    with op.batch_alter_table("tracks") as b:
        b.add_column(sa.Column("file_title", sa.String(512), nullable=True))
        b.add_column(sa.Column("title_override", sa.String(512), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("tracks") as b:
        b.drop_column("title_override")
        b.drop_column("file_title")
    for table in (
        "audit_log",
        "admin_sessions",
        "devices",
        "access_requests",
        "email_codes",
        "invites",
        "users",
    ):
        op.drop_table(table)
