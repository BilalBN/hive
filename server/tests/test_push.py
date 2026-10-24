"""M6: notifications with no personal details: people's choices, devices,
Web Push encrypted for each phone, Apple push, and the events that send them."""

from __future__ import annotations

import json

import pytest
from cryptography.hazmat.primitives import hashes, hmac, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session

from hive.models import User
from hive.push import b64u, encrypt, new_music_notice, unb64u

from .conftest import assert_matches
from .test_people import invite, join, set_up_admin


def _hmac(key: bytes, data: bytes) -> bytes:
    h = hmac.HMAC(key, hashes.SHA256())
    h.update(data)
    return h.finalize()


class Phone:
    """A phone's Web Push keys, and decrypting what it receives (RFC 8291)."""

    def __init__(self) -> None:
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.public = self.key.public_key().public_bytes(
            serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
        )
        self.auth = b"0123456789abcdef"
        self.p256dh = b64u(self.public)
        self.auth_b64 = b64u(self.auth)

    def decrypt(self, body: bytes) -> dict:
        salt, idlen = body[:16], body[20]
        as_public = body[21 : 21 + idlen]
        record = body[21 + idlen :]
        sender = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), as_public)
        shared = self.key.exchange(ec.ECDH(), sender)
        ikm = _hmac(
            _hmac(self.auth, shared), b"WebPush: info\x00" + self.public + as_public + b"\x01"
        )
        prk = _hmac(salt, ikm)
        cek = _hmac(prk, b"Content-Encoding: aes128gcm\x00\x01")[:16]
        nonce = _hmac(prk, b"Content-Encoding: nonce\x00\x01")[:12]
        plain = AESGCM(cek).decrypt(nonce, record, None)
        assert plain.endswith(b"\x02")
        return json.loads(plain[:-1])


def test_web_push_encryption_round_trip() -> None:
    phone = Phone()
    body = encrypt(b'{"hello": "home"}', phone.p256dh, phone.auth_b64)
    assert int.from_bytes(body[16:20], "big") == 4096
    assert phone.decrypt(body) == {"hello": "home"}


@pytest.fixture
def sent(server: TestClient) -> list[tuple[str, dict, bytes, bool]]:
    calls: list = []
    push = server.app.state.push
    push.inline = True
    push.post = lambda url, headers, content, http2=False: (
        calls.append((url, headers, content, http2)) or 201
    )
    return calls


def _admin_id(server: TestClient) -> str:
    with Session(server.app.state.db.engine) as s:
        return s.scalar(select(User.id).where(User.role == "admin"))


def test_choices_and_devices(server: TestClient) -> None:
    set_up_admin(server)
    phone = join(server, "amma@example.com", invite(server, "amma@example.com"))
    auth = phone.auth
    c = phone.client
    got = c.get("/api/v1/push/settings", headers=auth).json()
    assert_matches(got, "PushSettings")
    assert len(unb64u(got["webPushKey"])) == 65 and got["apns"] is False
    # A member sees only the kinds for members.
    assert [k["kind"] for k in got["kinds"]] == ["new_music", "request_added"]
    assert all(k["on"] for k in got["kinds"])

    r = c.put("/api/v1/push/settings", headers=auth, json={"off": ["new_music"]})
    assert [k["on"] for k in r.json()["kinds"]] == [False, True]
    assert c.put("/api/v1/push/settings", headers=auth, json={"off": ["spam"]}).status_code == 422

    p = Phone()
    good = {
        "kind": "webpush",
        "endpoint": "https://ntfy.sh/upAbc123",
        "p256dh": p.p256dh,
        "auth": p.auth_b64,
    }
    assert c.put("/api/v1/push/targets/install-amma-1", headers=auth, json=good).status_code == 204
    bad = {**good, "p256dh": "bm90IGEga2V5"}
    assert c.put("/api/v1/push/targets/install-amma-1", headers=auth, json=bad).status_code == 422
    plain_http = {**good, "endpoint": "http://ntfy.local/up"}
    assert (
        c.put("/api/v1/push/targets/install-amma-1", headers=auth, json=plain_http).status_code
        == 422
    )
    apple = {"kind": "apns", "token": "ABCDEF0123456789"}
    assert (
        c.put("/api/v1/push/targets/install-amma-ipad", headers=auth, json=apple).status_code == 204
    )
    with Session(server.app.state.db.engine) as s:
        uid = s.scalar(select(User.id).where(User.email == "amma@example.com"))
    assert set(server.app.state.push.targets(uid)) == {"install-amma-1", "install-amma-ipad"}
    assert c.delete("/api/v1/push/targets/install-amma-ipad", headers=auth).status_code == 204
    assert set(server.app.state.push.targets(uid)) == {"install-amma-1"}


def test_web_push_to_a_phone_carries_nothing_personal(server: TestClient, sent) -> None:
    set_up_admin(server)
    push = server.app.state.push
    uid = _admin_id(server)
    p = Phone()
    push.set_target(
        uid,
        "install-bilal",
        {
            "kind": "webpush",
            "endpoint": "https://ntfy.sh/upXyz",
            "p256dh": p.p256dh,
            "auth": p.auth_b64,
        },
    )

    r = server.post("/api/v1/admin/push/test")
    assert r.json() == {"sent": 1}
    url, headers, body, http2 = sent[-1]
    assert url == "https://ntfy.sh/upXyz" and not http2
    assert headers["Content-Encoding"] == "aes128gcm" and headers["TTL"] == "86400"
    assert (
        headers["Authorization"].startswith("vapid t=")
        and f"k={push.vapid_public()}" in headers["Authorization"]
    )
    jwt_payload = json.loads(
        unb64u(headers["Authorization"].split("t=")[1].split(",")[0].split(".")[1])
    )
    assert jwt_payload["aud"] == "https://ntfy.sh"
    message = p.decrypt(body)
    assert message == {
        "kind": "test",
        "title": "Notifications work",
        "body": "This is how Hive lets you know.",
    }

    # Turned off: nothing sent. A phone that's gone: forgotten.
    push.set_off(uid, ["join_waiting"])
    before = len(sent)
    push.notify("join_waiting", admins=True)
    assert len(sent) == before
    push.post = lambda *a, **k: 410
    push.notify("song_request", admins=True)
    assert push.targets(uid) == {}


def test_apple_push_once_the_key_is_set(server: TestClient, sent) -> None:
    set_up_admin(server)
    push = server.app.state.push
    uid = _admin_id(server)
    push.set_target(uid, "install-iphone", {"kind": "apns", "token": "abcdef0123"})
    push.notify("needs_look", admins=True)
    assert sent == []  # no key yet

    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode()
    assert server.put("/api/v1/admin/push", json={"privateKey": "nope"}).status_code == 422
    r = server.put(
        "/api/v1/admin/push",
        json={"teamId": "TEAMID1234", "keyId": "KEYID56789", "privateKey": pem, "sandbox": True},
    )
    assert_matches(r.json(), "AdminPush")
    assert (
        r.json()["apnsReady"] is True and "privateKey" not in server.get("/api/v1/admin/push").text
    )
    push.notify("needs_look", admins=True)
    url, headers, body, http2 = sent[-1]
    assert url == "https://api.sandbox.push.apple.com/3/device/abcdef0123" and http2
    assert headers["apns-topic"] == "dev.hivemusic.hive" and headers["apns-push-type"] == "alert"
    head = json.loads(unb64u(headers["authorization"].split(" ")[1].split(".")[0]))
    assert head == {"alg": "ES256", "kid": "KEYID56789"}
    assert json.loads(body)["aps"]["alert"]["title"] == "Hive needs a look"


def test_events_that_notify(server: TestClient, monkeypatch) -> None:
    set_up_admin(server)
    phone = join(server, "amma@example.com", invite(server, "amma@example.com"))
    calls: list = []
    push = server.app.state.push
    monkeypatch.setattr(
        push,
        "notify",
        lambda kind, users=None, **kw: calls.append((kind, list(users or []), kw)) or 1,
    )

    # Someone asks for a song: the admins hear "A song was asked for".
    asked = phone.client.post(
        "/api/v1/listen/requests",
        headers=phone.auth,
        json={"source": "search", "title": "Pesamale"},
    ).json()
    assert calls[-1] == ("song_request", [], {"admins": True})
    # Marked added: the person who asked hears it (only them).
    server.patch(f"/api/v1/admin/song-requests/{asked['id']}", json={"status": "added"})
    kind, users, _ = calls[-1]
    assert kind == "request_added" and len(users) == 1 and users[0] != _admin_id(server)
    n = len(calls)
    server.patch(f"/api/v1/admin/song-requests/{asked['id']}", json={"status": "added"})
    assert len(calls) == n  # not twice

    # New albums: once, then not again within the day.
    app = server.app
    app.state.people.home.set("push_albums_seen", None)
    assert new_music_notice(app) is False  # the first read only counts
    app.state.people.home.set("push_albums_seen", "-1")
    assert new_music_notice(app) is True and calls[-1][0] == "new_music"
    app.state.people.home.set("push_albums_seen", "-1")
    assert new_music_notice(app) is False
