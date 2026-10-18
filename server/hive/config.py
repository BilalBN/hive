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

    # Folders Hive reads music from (never writes, except uploads). Files
    # dropped into them are picked up automatically.
    music_folders: list[Path] = Field(default_factory=lambda: [Path.home() / "Music" / "Hive"])
    # Where browser uploads land; defaults to "Uploads" inside the first music folder.
    upload_folder: Path | None = None
    upload_max_bytes: int = 4 * 1024**3
    # Watch the music folders for changes (off in tests).
    watch_folders: bool = True
    scan_workers: int = 2
    # FFmpeg makes the High and Data saver streams and measures loudness.
    # Found on PATH or in the usual Homebrew and Windows places when not set.
    ffmpeg: Path | None = None

    # Look up album details, covers and films online (MusicBrainz, Cover Art
    # Archive, Wikidata). Hive Admin can switch it; this is the starting value.
    lookup_online: bool = True
    # Optional AcoustID application key, to recognise songs by their sound.
    acoustid_key: str | None = None
    # Run the lookup in the background (tests drive it themselves).
    lookup_worker: bool = True

    admin_dist: Path = Field(default_factory=lambda: REPO_ROOT / "admin" / "dist")
    log_level: str = "INFO"
    min_app_version: str = "0.1.0"

    @field_validator("log_level")
    @classmethod
    def _upper(cls, v: str) -> str:
        return v.upper()

    @field_validator("music_folders", mode="after")
    @classmethod
    def _expand_folders(cls, v: list[Path]) -> list[Path]:
        return [p.expanduser().absolute() for p in v]

    @field_validator("upload_folder", "ffmpeg", "data_dir", mode="after")
    @classmethod
    def _expand(cls, v: Path | None) -> Path | None:
        return v.expanduser().absolute() if v is not None else None

    @property
    def uploads_path(self) -> Path:
        if self.upload_folder is not None:
            return self.upload_folder
        if self.music_folders:
            return self.music_folders[0] / "Uploads"
        return self.data_dir / "uploads"

    @property
    def cache_dir(self) -> Path:
        return self.data_dir / "cache"

    @property
    def artwork_dir(self) -> Path:
        return self.data_dir / "artwork"

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
