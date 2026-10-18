from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from hive.app import create_app
from hive.config import Settings


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(
        home_name="Test home",
        data_dir=tmp_path / "data",
        admin_dist=tmp_path / "admin-dist",
        min_app_version="0.1.0",
    )


@pytest.fixture
def client(settings: Settings) -> Iterator[TestClient]:
    with TestClient(create_app(settings)) as c:
        yield c
