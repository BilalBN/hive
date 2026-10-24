"""M5: Shazam for songs that aren't at home: off until the admin turns it on,
Android tokens from the ShazamKit key kept at home, and what Shazam named
kept in the person's history."""

from __future__ import annotations

import base64
import json

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature
from fastapi.testclient import TestClient

from hive.library.shazam_api import developer_token

from .conftest import assert_matches


@pytest.fixture
def key() -> tuple[str, ec.EllipticCurvePublicKey]:
    k = ec.generate_private_key(ec.SECP256R1())
    pem = k.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode()
    return pem, k.public_key()


def _unb64(part: str) -> bytes:
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


def test_developer_token_is_a_valid_es256_jwt(key) -> None:
    pem, public = key
    token, exp = developer_token("TEAMID1234", "KEYID56789", pem, now=1_800_000_000)
    header, payload, sig = token.split(".")
    assert json.loads(_unb64(header)) == {"alg": "ES256", "kid": "KEYID56789", "typ": "JWT"}
    assert json.loads(_unb64(payload)) == {"iss": "TEAMID1234", "iat": 1_800_000_000, "exp": exp}
    raw = _unb64(sig)
    assert len(raw) == 64
    der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
    public.verify(der, f"{header}.{payload}".encode(), ec.ECDSA(hashes.SHA256()))


def test_off_until_the_admin_turns_it_on(home_client: TestClient, key) -> None:
    c = home_client
    auth = {"Authorization": f"Bearer {c.app.state.dev_key}"}
    opts = c.get("/api/v1/listen/options", headers=auth).json()
    assert_matches(opts, "ListenOptions")
    assert opts == {"shazam": False, "shazamAndroid": False}
    assert c.post("/api/v1/listen/shazam-token", headers=auth).status_code == 409
    assert (
        c.post("/api/v1/listen/history", headers=auth, json={"title": "Pesamale"}).status_code
        == 409
    )

    settings = c.get("/api/v1/admin/recognition/shazam").json()
    assert_matches(settings, "ShazamSettings")
    assert settings == {"enabled": False, "keySet": False, "androidReady": False}

    # On: iPhones and Macs can use it; Android needs the key.
    r = c.put("/api/v1/admin/recognition/shazam", json={"enabled": True})
    assert r.json() == {"enabled": True, "keySet": False, "androidReady": False}
    assert c.get("/api/v1/listen/options", headers=auth).json() == {
        "shazam": True,
        "shazamAndroid": False,
    }
    assert c.post("/api/v1/listen/shazam-token", headers=auth).status_code == 409

    pem, public = key
    assert (
        c.put("/api/v1/admin/recognition/shazam", json={"privateKey": "not a key"}).status_code
        == 422
    )
    assert (
        c.put("/api/v1/admin/recognition/shazam", json={"teamId": "lowercase"}).status_code == 422
    )
    r = c.put(
        "/api/v1/admin/recognition/shazam",
        json={"teamId": "TEAMID1234", "keyId": "KEYID56789", "privateKey": pem},
    )
    assert r.json() == {
        "enabled": True,
        "keySet": True,
        "androidReady": True,
        "teamId": "TEAMID1234",
        "keyId": "KEYID56789",
    }
    assert "privateKey" not in c.get("/api/v1/admin/recognition/shazam").text
    assert c.get("/api/v1/listen/options", headers=auth).json()["shazamAndroid"] is True

    t = c.post("/api/v1/listen/shazam-token", headers=auth)
    assert t.status_code == 200
    assert_matches(t.json(), "ShazamToken")
    assert json.loads(_unb64(t.json()["token"].split(".")[1]))["iss"] == "TEAMID1234"

    actions = [e["action"] for e in c.get("/api/v1/admin/audit").json()["items"]]
    assert "listen.shazam" in actions


def test_what_shazam_named_goes_in_the_history(home_client: TestClient) -> None:
    c = home_client
    auth = {"Authorization": f"Bearer {c.app.state.dev_key}"}
    c.put("/api/v1/admin/recognition/shazam", json={"enabled": True})

    r = c.post(
        "/api/v1/listen/history", headers=auth, json={"title": " Pesamale ", "artist": "Koshal"}
    )
    assert r.status_code == 200, r.text
    assert_matches(r.json(), "ListenResult")
    assert (
        r.json()["title"] == "Pesamale" and r.json()["source"] == "shazam" and r.json()["matched"]
    )

    history = c.get("/api/v1/listen/history", headers=auth).json()["items"]
    assert [(e["source"], e.get("title"), e["matched"]) for e in history] == [
        ("shazam", "Pesamale", True)
    ]

    # Asked for by name from that entry.
    asked = c.post(
        "/api/v1/listen/requests",
        headers=auth,
        json={
            "source": "listen",
            "title": "Pesamale",
            "artist": "Koshal",
            "listenEventId": r.json()["id"],
        },
    )
    assert asked.status_code == 200
    assert c.get("/api/v1/listen/history", headers=auth).json()["items"][0]["requested"] is True

    assert (
        c.post(
            "/api/v1/listen/history", headers=auth, json={"title": "x", "listenEventId": 999}
        ).status_code
        == 404
    )
    assert c.post("/api/v1/listen/history", headers=auth, json={"title": ""}).status_code == 422
    assert c.get("/api/v1/admin/recognition").json()["shazamThisWeek"] == 1
