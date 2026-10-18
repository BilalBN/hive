"""Database tables. M0 has only server metadata; each milestone adds its own."""

from __future__ import annotations

from datetime import UTC, datetime

from sqlalchemy import DateTime, String
from sqlalchemy.orm import Mapped, mapped_column

from hive.db import Base


def utcnow() -> datetime:
    return datetime.now(UTC)


class ServerMeta(Base):
    """Key/value facts about this installation (install id, first start)."""

    __tablename__ = "server_meta"

    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    value: Mapped[str] = mapped_column(String(1024))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
