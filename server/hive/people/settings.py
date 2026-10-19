"""Settings the admin changes in Hive Admin, kept in the database
(server_meta) so they survive restarts and travel with backups."""

from __future__ import annotations

from dataclasses import dataclass

from sqlalchemy.orm import Session

from hive.db import Database
from hive.models import ServerMeta

DEFAULTS = {
    "devices_per_person": "4",
    "swaps_per_month": "2",
    "email_port": "587",
    "email_security": "starttls",
}


class HomeSettings:
    def __init__(self, db: Database, home_name: str) -> None:
        self.db = db
        self.default_home_name = home_name

    def get(self, key: str) -> str | None:
        with Session(self.db.engine) as s:
            row = s.get(ServerMeta, key)
            return row.value if row else DEFAULTS.get(key)

    def set(self, key: str, value: str | None) -> None:
        with Session(self.db.engine) as s:
            row = s.get(ServerMeta, key)
            if value is None or value == "":
                if row is not None:
                    s.delete(row)
            elif row is None:
                s.add(ServerMeta(key=key, value=value))
            else:
                row.value = value
            s.commit()

    # ------------------------------------------------------------ typed
    @property
    def home_name(self) -> str:
        return self.get("home_name") or self.default_home_name

    @property
    def devices_per_person(self) -> int:
        return int(self.get("devices_per_person") or 4)

    @property
    def swaps_per_month(self) -> int:
        return int(self.get("swaps_per_month") or 2)

    @property
    def email(self) -> EmailSettings:
        return EmailSettings(
            host=self.get("email_host") or "",
            port=int(self.get("email_port") or 587),
            security=self.get("email_security") or "starttls",
            username=self.get("email_username") or "",
            password=self.get("email_password") or "",
            sender=self.get("email_from") or self.get("email_username") or "",
        )


@dataclass(frozen=True)
class EmailSettings:
    host: str
    port: int
    security: str  # starttls | ssl | none
    username: str
    password: str
    sender: str

    @property
    def ready(self) -> bool:
        return bool(self.host and self.sender)
