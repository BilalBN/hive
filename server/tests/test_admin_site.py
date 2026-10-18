from __future__ import annotations

from fastapi.testclient import TestClient

from hive.app import create_app


def test_admin_not_built_message(client) -> None:
    r = client.get("/admin/")
    assert r.status_code == 503
    assert "isn't built yet" in r.text


def test_root_redirects_to_admin(client) -> None:
    r = client.get("/", follow_redirects=False)
    assert r.status_code in (302, 307)
    assert r.headers["location"] == "/admin/"


def test_admin_serves_build_and_client_routes(settings) -> None:
    dist = settings.admin_dist
    (dist / "assets").mkdir(parents=True)
    (dist / "index.html").write_text("<div id=root>hive admin</div>", encoding="utf-8")
    (dist / "assets" / "app.js").write_text("console.log(1)", encoding="utf-8")
    (settings.data_dir).mkdir(parents=True, exist_ok=True)
    (settings.data_dir / "secret.txt").write_text("nope", encoding="utf-8")

    with TestClient(create_app(settings)) as c:
        assert "hive admin" in c.get("/admin/").text
        assert c.get("/admin/assets/app.js").text == "console.log(1)"
        # A client-side route loads the app.
        assert "hive admin" in c.get("/admin/devices").text
        # A missing asset is a real 404, not the app.
        assert c.get("/admin/assets/missing.js").status_code == 404
        # Path traversal stays inside the build folder.
        r = c.get("/admin/..%2F..%2Fdata%2Fsecret.txt")
        assert r.status_code == 404 or "nope" not in r.text
