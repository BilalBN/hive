"""M6: notifications, with no personal details in them.

Each notification is one of a few fixed messages ("New music at home",
"Someone is waiting to join"): never a name, a song or an email. They reach:

- apps that are open, over the sync WebSocket ({"type": "notice", ...});
- Android phones through UnifiedPush (a distributor app such as ntfy):
  Web Push, encrypted for the phone (RFC 8291) and signed with home's own
  VAPID key (RFC 8292), so the distributor can't read it;
- iPhones, iPads and Macs through Apple's push service, once the admin adds
  an APNs key in Hive Admin (it needs the Apple Developer account).

People choose which kinds they get (Settings → Notifications in the apps).
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import json
import logging
import os
import time
from collections.abc import Callable, Iterable
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlsplit

from cryptography.hazmat.primitives import hashes, hmac, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from sqlalchemy import select
from sqlalchemy.orm import Session

from hive.models import User

log = logging.getLogger("hive.push")


@dataclass(frozen=True)
class Kind:
    title: str
    body: str
    admins: bool  # only for admins


KINDS: dict[str, Kind] = {
    "new_music": Kind("New music at home", "Open Hive to see what's new.", False),
    "request_added": Kind("A song you asked for is in Hive", "Open Hive to play it.", False),
    "join_waiting": Kind("Someone is waiting to join", "Open Hive Admin to let them in.", True),
    "song_request": Kind("A song was asked for", "Open Hive Admin → Requests to see it.", True),
    "needs_look": Kind("Hive needs a look", "Open Hive Admin → System health.", True),
    "test": Kind("Notifications work", "This is how Hive lets you know.", True),
}
LABELS = {
    "new_music": "New music at home",
    "request_added": "A song you asked for was added",
    "join_waiting": "Someone is waiting to join (admins)",
    "song_request": "Someone asked for a song (admins)",
    "needs_look": "Hive needs a look (admins)",
}

SUBJECT = "https://github.com/BilalBN/hive"


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def unb64u(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _point(key: ec.EllipticCurvePublicKey) -> bytes:
    return key.public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint
    )


def _hmac(key: bytes, data: bytes) -> bytes:
    h = hmac.HMAC(key, hashes.SHA256())
    h.update(data)
    return h.finalize()


def es256_jwt(
    header: dict[str, Any], payload: dict[str, Any], key: ec.EllipticCurvePrivateKey
) -> str:
    head = b64u(json.dumps(header, separators=(",", ":")).encode())
    body = b64u(json.dumps(payload, separators=(",", ":")).encode())
    r, s = decode_dss_signature(key.sign(f"{head}.{body}".encode(), ec.ECDSA(hashes.SHA256())))
    return f"{head}.{body}.{b64u(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}"


def encrypt(plaintext: bytes, p256dh: str, auth: str, *, salt: bytes | None = None,
            sender: ec.EllipticCurvePrivateKey | None = None) -> bytes:  # fmt: skip
    """A Web Push message body for one phone (RFC 8291, aes128gcm)."""
    ua_public = unb64u(p256dh)
    auth_secret = unb64u(auth)
    sender = sender or ec.generate_private_key(ec.SECP256R1())
    as_public = _point(sender.public_key())
    ua_key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), ua_public)
    shared = sender.exchange(ec.ECDH(), ua_key)
    prk_key = _hmac(auth_secret, shared)
    ikm = _hmac(prk_key, b"WebPush: info\x00" + ua_public + as_public + b"\x01")
    salt = salt or os.urandom(16)
    prk = _hmac(salt, ikm)
    cek = _hmac(prk, b"Content-Encoding: aes128gcm\x00\x01")[:16]
    nonce = _hmac(prk, b"Content-Encoding: nonce\x00\x01")[:12]
    record = AESGCM(cek).encrypt(nonce, plaintext + b"\x02", None)
    rs = 4096
    return salt + rs.to_bytes(4, "big") + bytes([len(as_public)]) + as_public + record


def _post(url: str, headers: dict[str, str], content: bytes, http2: bool = False) -> int:
    import httpx

    with httpx.Client(http2=http2, timeout=15) as client:
        return client.post(url, headers=headers, content=content).status_code


class Push:
    def __init__(self, db, home) -> None:
        self.db = db
        self.home = home
        self.loop: asyncio.AbstractEventLoop | None = None
        self.tell: Callable[[str, dict[str, Any]], Any] | None = None  # open apps
        self.post: Callable[..., int] = _post
        self.inline = False  # tests: deliver before returning
        self._pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="hive-push")

    # ------------------------------------------------------------ keys
    def _vapid(self) -> ec.EllipticCurvePrivateKey:
        pem = self.home.get("push_vapid_key")
        if pem:
            return serialization.load_pem_private_key(pem.encode(), password=None)  # type: ignore[return-value]
        key = ec.generate_private_key(ec.SECP256R1())
        self.home.set(
            "push_vapid_key",
            key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            ).decode(),
        )
        return key

    def vapid_public(self) -> str:
        return b64u(_point(self._vapid().public_key()))

    def apns(self) -> dict[str, Any]:
        h = self.home
        return {
            "teamId": h.get("push_apns_team") or None,
            "keyId": h.get("push_apns_key_id") or None,
            "key": h.get("push_apns_key") or None,
            "topic": h.get("push_apns_topic") or "dev.hivemusic.hive",
            "sandbox": h.get("push_apns_sandbox") == "1",
        }

    def apns_ready(self) -> bool:
        a = self.apns()
        return bool(a["teamId"] and a["keyId"] and a["key"])

    # ------------------------------------------------------------ people's settings
    def targets(self, user_id: str) -> dict[str, dict[str, Any]]:
        raw = self.home.get(f"push_targets:{user_id}")
        return json.loads(raw) if raw else {}

    def set_target(self, user_id: str, install: str, target: dict[str, Any] | None) -> None:
        all_ = self.targets(user_id)
        if target is None:
            all_.pop(install, None)
        else:
            all_[install] = target
        self.home.set(f"push_targets:{user_id}", json.dumps(all_) if all_ else None)

    def off(self, user_id: str) -> set[str]:
        raw = self.home.get(f"push_off:{user_id}")
        return set(json.loads(raw)) if raw else set()

    def set_off(self, user_id: str, kinds: Iterable[str]) -> None:
        kinds = sorted(k for k in set(kinds) if k in LABELS)
        self.home.set(f"push_off:{user_id}", json.dumps(kinds) if kinds else None)

    # ------------------------------------------------------------ sending
    def _recipients(self, users: Iterable[str] | None, admins: bool, everyone: bool) -> list[str]:
        with Session(self.db.engine) as s:
            q = select(User.id).where(User.status == "active")
            if admins:
                q = q.where(User.role == "admin")
            ids = list(s.scalars(q)) if (admins or everyone) else []
        return sorted(set(ids) | set(users or ()))

    def notify(
        self,
        kind: str,
        users: Iterable[str] | None = None,
        *,
        admins: bool = False,
        everyone: bool = False,
    ) -> int:
        """Send one of the fixed messages; returns how many people it went to."""
        k = KINDS[kind]
        message = {"kind": kind, "title": k.title, "body": k.body}
        sent = 0
        for uid in self._recipients(users, admins, everyone):
            if kind in self.off(uid):
                continue
            sent += 1
            if self.tell is not None and self.loop is not None:
                with contextlib.suppress(RuntimeError):
                    asyncio.run_coroutine_threadsafe(
                        self.tell(uid, {"type": "notice", **message}), self.loop
                    )
            for install, target in self.targets(uid).items():
                if self.inline:
                    self._deliver(uid, install, target, message)
                else:
                    self._pool.submit(self._deliver, uid, install, target, message)
        return sent

    def _deliver(
        self, uid: str, install: str, target: dict[str, Any], message: dict[str, Any]
    ) -> None:
        try:
            if target.get("kind") == "webpush":
                status = self._webpush(target, message)
                gone = status in (404, 410)
            elif target.get("kind") == "apns":
                if not self.apns_ready():
                    return
                status = self._apns(target, message)
                gone = status == 410 or status == 400
            else:
                return
        except Exception as e:  # noqa: BLE001 - one phone must not stop the others
            log.warning("a notification wasn't delivered: %s", type(e).__name__)
            return
        if gone:
            self.set_target(uid, install, None)
            log.info("a device stopped taking notifications; forgotten")
        elif status >= 300:
            log.warning("a notification wasn't delivered (%d)", status)

    def _webpush(self, target: dict[str, Any], message: dict[str, Any]) -> int:
        url = target["endpoint"]
        body = encrypt(json.dumps(message).encode(), target["p256dh"], target["auth"])
        parts = urlsplit(url)
        jwt = es256_jwt(
            {"typ": "JWT", "alg": "ES256"},
            {
                "aud": f"{parts.scheme}://{parts.netloc}",
                "exp": int(time.time()) + 12 * 3600,
                "sub": SUBJECT,
            },
            self._vapid(),
        )
        headers = {
            "Content-Encoding": "aes128gcm",
            "Content-Type": "application/octet-stream",
            "TTL": "86400",
            "Urgency": "normal",
            "Authorization": f"vapid t={jwt}, k={self.vapid_public()}",
        }
        return self.post(url, headers, body)

    def _apns(self, target: dict[str, Any], message: dict[str, Any]) -> int:
        a = self.apns()
        key = serialization.load_pem_private_key(a["key"].encode(), password=None)
        jwt = es256_jwt(
            {"alg": "ES256", "kid": a["keyId"]}, {"iss": a["teamId"], "iat": int(time.time())}, key
        )  # type: ignore[arg-type]
        host = "api.sandbox.push.apple.com" if a["sandbox"] else "api.push.apple.com"
        payload = {
            "aps": {
                "alert": {"title": message["title"], "body": message["body"]},
                "sound": "default",
            },
            "kind": message["kind"],
        }
        headers = {
            "authorization": f"bearer {jwt}",
            "apns-topic": a["topic"],
            "apns-push-type": "alert",
            "content-type": "application/json",
        }
        return self.post(
            f"https://{host}/3/device/{target['token']}",
            headers,
            json.dumps(payload).encode(),
            True,
        )


NEW_MUSIC_GAP_S = 20 * 3600  # at most one "New music" a day


def new_music_notice(app) -> bool:
    """After the library is read: "New music at home" when albums were added
    (at most once a day; the first library read only sets the count)."""
    from sqlalchemy import func

    from hive.models import Album

    home = app.state.people.home
    with Session(app.state.db.engine) as s:
        count = int(s.scalar(select(func.count()).select_from(Album)) or 0)
    seen = home.get("push_albums_seen")
    if seen is None:
        home.set("push_albums_seen", str(count))
        return False
    if count <= int(seen):
        if count < int(seen):
            home.set("push_albums_seen", str(count))
        return False
    last = float(home.get("push_new_music_at") or 0)
    if time.time() - last < NEW_MUSIC_GAP_S:
        return False
    home.set("push_albums_seen", str(count))
    home.set("push_new_music_at", str(time.time()))
    app.state.push.notify("new_music", everyone=True)
    return True
