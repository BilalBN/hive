from __future__ import annotations

import os
import shutil
import time
from collections.abc import Iterator
from pathlib import Path

import jsonschema
import pytest
from fastapi.testclient import TestClient

from hive.app import create_app
from hive.config import Settings
from hive.contract import load_contract

from .audio_fixtures import FFMPEG, build_library

needs_ffmpeg = pytest.mark.skipif(FFMPEG is None, reason="FFmpeg is not installed")


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(
        home_name="Test home",
        data_dir=tmp_path / "data",
        admin_dist=tmp_path / "admin-dist",
        min_app_version="0.1.0",
        music_folders=[tmp_path / "music"],
        watch_folders=False,
        scan_workers=2,
        lookup_online=False,
        lookup_worker=False,
    )


@pytest.fixture
def client(settings: Settings) -> Iterator[TestClient]:
    with TestClient(create_app(settings)) as c:
        yield c


@pytest.fixture(scope="session")
def built_library(tmp_path_factory: pytest.TempPathFactory) -> tuple[Path, dict[str, Path]]:
    if FFMPEG is None:
        pytest.skip("FFmpeg is not installed")
    root = tmp_path_factory.mktemp("library-src")
    return root, build_library(root)


class Home:
    """A running server with the test library scanned in."""

    def __init__(self, client: TestClient, paths: dict[str, Path], music: Path) -> None:
        self.client = client
        self.paths = paths
        self.music = music
        self.key = client.app.state.dev_key
        self.auth = {"Authorization": f"Bearer {self.key}"}

    def get(self, url: str, headers: dict | None = None, **kw):
        return self.client.get(url, headers={**self.auth, **(headers or {})}, **kw)

    def post(self, url: str, headers: dict | None = None, **kw):
        return self.client.post(url, headers={**self.auth, **(headers or {})}, **kw)

    def put(self, url: str, headers: dict | None = None, **kw):
        return self.client.put(url, headers={**self.auth, **(headers or {})}, **kw)

    def patch(self, url: str, headers: dict | None = None, **kw):
        return self.client.patch(url, headers={**self.auth, **(headers or {})}, **kw)

    def delete(self, url: str, headers: dict | None = None, **kw):
        return self.client.delete(url, headers={**self.auth, **(headers or {})}, **kw)

    def wait(self) -> None:
        assert self.client.app.state.library.wait_idle(60), "scan didn't finish"

    def track_id(self, title: str) -> str:
        body = self.get("/api/v1/library/tracks", params={"limit": 500}).json()
        for t in body["items"]:
            if t["title"] == title:
                return t["id"]
        raise KeyError(title)


@pytest.fixture
def home(settings: Settings, built_library) -> Iterator[Home]:
    src, paths = built_library
    music = settings.music_folders[0]
    shutil.copytree(src, music)
    # Pretend the files were copied a while ago, so they're read at once; the
    # duplicate is the newer copy.
    old = time.time() - 600
    for p in sorted(music.rglob("*")):
        if p.is_file():
            stamp = old + 60 if p.name.startswith("Copy of") else old
            os.utime(p, (stamp, stamp))
    mapped = {k: music / v.relative_to(src) for k, v in paths.items()}
    with TestClient(create_app(settings)) as c:
        h = Home(c, mapped, music)
        h.wait()
        yield h


# ------------------------------------------------------------ contract checks


def assert_matches(body, schema_name: str) -> None:
    """Validate against the contract schema, and reject keys it doesn't define."""
    spec = load_contract()
    schema = {"$ref": f"#/components/schemas/{schema_name}", "components": spec["components"]}
    jsonschema.validate(body, schema, format_checker=jsonschema.FormatChecker())
    _no_extra_keys(body, spec["components"]["schemas"][schema_name], spec, schema_name)


def _resolve(node, spec):
    while isinstance(node, dict) and "$ref" in node:
        node = spec["components"]["schemas"][node["$ref"].rsplit("/", 1)[-1]]
    return node


def _no_extra_keys(body, schema, spec, where: str) -> None:
    schema = _resolve(schema, spec)
    if isinstance(body, dict) and "properties" in schema:
        extra = set(body) - set(schema["properties"])
        assert not extra, f"{where}: keys not in the contract: {sorted(extra)}"
        for k, v in body.items():
            _no_extra_keys(v, schema["properties"][k], spec, f"{where}.{k}")
    elif isinstance(body, list) and "items" in schema:
        for i, v in enumerate(body):
            _no_extra_keys(v, schema["items"], spec, f"{where}[{i}]")
