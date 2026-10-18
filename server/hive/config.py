"""Server settings.

Settings come from, in order of priority:
1. environment variables prefixed ``HIVE_`` (for example ``HIVE_PORT=9000``);
2. the TOML file named by ``HIVE_CONFIG``, or ``<data_dir>/hive.toml``;
3. the defaults below.
"""

from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path

from pydantic import Field, field_validator
from pydantic_settings import (
    BaseSettings,
    PydanticBaseSettingsSource,
    SettingsConfigDict,
    TomlConfigSettingsSource,
)

REPO_ROOT = Path(__file__).resolve().parents[2]


def _default_data_dir() -> Path:
    env = os.environ.get("HIVE_DATA_DIR")
    if env:
        return Path(env)
    return REPO_ROOT / "data"


def _config_file() -> Path:
    env = os.environ.get("HIVE_CONFIG")
    if env:
        return Path(env)
    return _default_data_dir() / "hive.toml"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="HIVE_", extra="ignore")

    home_name: str = Field("Hive", description="What the family sees as the home.")
    admin_display_name: str = Field("Admin", description="Used in family-facing copy.")
    data_dir: Path = Field(default_factory=_default_data_dir)

    # Where to listen. "tailscale" binds to localhost plus this machine's
    # Tailscale address, and nothing else (no home Wi-Fi, no internet).
    host: str = "127.0.0.1"
    port: int = 8443
    tls_cert: Path | None = None
    tls_key: Path | None = None

    music_folders: list[Path] = Field(default_factory=list)
    admin_dist: Path = Field(default_factory=lambda: REPO_ROOT / "admin" / "dist")
    log_level: str = "INFO"
    min_app_version: str = "0.1.0"

    @field_validator("log_level")
    @classmethod
    def _upper(cls, v: str) -> str:
        return v.upper()

    @property
    def database_path(self) -> Path:
        return self.data_dir / "server.db"

    @property
    def database_url(self) -> str:
        return f"sqlite:///{self.database_path.as_posix()}"

    @property
    def log_dir(self) -> Path:
        return self.data_dir / "logs"

    @classmethod
    def settings_customise_sources(
        cls,
        settings_cls: type[BaseSettings],
        init_settings: PydanticBaseSettingsSource,
        env_settings: PydanticBaseSettingsSource,
        dotenv_settings: PydanticBaseSettingsSource,
        file_secret_settings: PydanticBaseSettingsSource,
    ) -> tuple[PydanticBaseSettingsSource, ...]:
        return (
            init_settings,
            env_settings,
            TomlConfigSettingsSource(settings_cls, toml_file=_config_file()),
        )


@lru_cache
def get_settings() -> Settings:
    return Settings()
