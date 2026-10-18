from __future__ import annotations

import sqlite3
from datetime import UTC, datetime

from hive import __version__
from hive.__main__ import TAILSCALE_NET, resolve_hosts
from hive.config import Settings


def test_health(client) -> None:
    r = client.get("/api/v1/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["homeName"] == "Test home"
    assert body["serverVersion"] == __version__
    assert body["minAppVersion"] == "0.1.0"
    server_time = datetime.fromisoformat(body["serverTime"])
    assert abs((datetime.now(UTC) - server_time).total_seconds()) < 5


def test_database_created_and_migrated(client, settings) -> None:
    db = settings.database_path
    assert db.is_file()
    with sqlite3.connect(db) as conn:
        tables = {r[0] for r in conn.execute("select name from sqlite_master where type='table'")}
        mode = conn.execute("pragma journal_mode").fetchone()[0]
    assert "server_meta" in tables
    assert "alembic_version" in tables
    assert mode == "wal"


def test_restart_keeps_database(settings) -> None:
    from fastapi.testclient import TestClient

    from hive.app import create_app

    for _ in range(2):
        with TestClient(create_app(settings)) as c:
            assert c.get("/api/v1/health").status_code == 200


def test_settings_from_toml_and_env(tmp_path, monkeypatch) -> None:
    cfg = tmp_path / "hive.toml"
    cfg.write_text('home_name = "Toml home"\nport = 9000\n', encoding="utf-8")
    monkeypatch.setenv("HIVE_CONFIG", str(cfg))
    monkeypatch.setenv("HIVE_PORT", "9100")
    s = Settings()
    assert s.home_name == "Toml home"
    assert s.port == 9100  # environment wins over the file


def test_plain_host_is_used_as_is() -> None:
    assert resolve_hosts("127.0.0.1") == ["127.0.0.1"]


def test_tailscale_host_binds_localhost_and_tailnet(monkeypatch) -> None:
    import hive.__main__ as cli

    monkeypatch.setattr(cli, "tailscale_ipv4", lambda: "100.84.12.7")
    assert resolve_hosts("tailscale") == ["127.0.0.1", "100.84.12.7"]
    import ipaddress

    assert ipaddress.ip_address("100.84.12.7") in TAILSCALE_NET
