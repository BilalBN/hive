"""Who is calling.

M1 has one temporary development key for the apps (``hive info`` prints it;
Hive Admin shows it on Overview). Requests from this computer itself are
trusted, so Hive Admin opened at http://127.0.0.1:8443/admin/ works without
it. M2 replaces all of this with invites, approved devices and tokens; the
``Caller`` that routes receive stays the same shape.

Stream tickets are signed with a server secret so media players can fetch audio
without sending headers, and expire on their own.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
import time
from dataclasses import dataclass
from typing import Annotated

from fastapi import Depends, HTTPException, Request
from sqlalchemy import select
from sqlalchemy.orm import Session

from hive.db import Database
from hive.models import ServerMeta

DEV_USER_ID = "dev"
LOOPBACK = {"127.0.0.1", "::1", "localhost"}


@dataclass(frozen=True)
class Caller:
    user_id: str
    display_name: str


def _meta(db: Database, key: str, make) -> str:
    with Session(db.engine) as s:
        row = s.get(ServerMeta, key)
        if row is None:
            row = ServerMeta(key=key, value=make())
            s.add(row)
            s.commit()
        return row.value


def development_key(db: Database) -> str:
    def make() -> str:
        alphabet = "abcdefghjkmnpqrstuvwxyz23456789"
        groups = ["".join(secrets.choice(alphabet) for _ in range(4)) for _ in range(4)]
        return "hive-dev-" + "-".join(groups)

    return _meta(db, "development_key", make)


def ticket_secret(db: Database) -> bytes:
    return bytes.fromhex(_meta(db, "ticket_secret", lambda: secrets.token_hex(32)))


def _is_loopback(request: Request) -> bool:
    host = request.client.host if request.client else ""
    return host in LOOPBACK


def current_caller(request: Request) -> Caller:
    state = request.app.state
    if _is_loopback(request):
        return Caller(DEV_USER_ID, state.settings.admin_display_name)
    header = request.headers.get("authorization", "")
    scheme, _, token = header.partition(" ")
    key = state.dev_key
    if scheme.lower() == "bearer" and token and hmac.compare_digest(token.strip(), key):
        return Caller(DEV_USER_ID, state.settings.admin_display_name)
    raise HTTPException(401, "Sign-in needed")


CallerDep = Annotated[Caller, Depends(current_caller)]


# ------------------------------------------------------------------ tickets


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def sign_ticket(secret: bytes, payload: dict, ttl_seconds: int) -> tuple[str, int]:
    body = dict(payload, exp=int(time.time()) + ttl_seconds)
    raw = json.dumps(body, separators=(",", ":"), sort_keys=True).encode()
    sig = hmac.new(secret, raw, hashlib.sha256).digest()[:18]
    return f"{_b64(raw)}.{_b64(sig)}", body["exp"]


def read_ticket(secret: bytes, ticket: str) -> dict | None:
    """The payload, or None when forged, damaged or expired."""
    try:
        raw_b64, sig_b64 = ticket.split(".", 1)
        raw = _unb64(raw_b64)
        sig = _unb64(sig_b64)
    except (ValueError, TypeError):
        return None
    expected = hmac.new(secret, raw, hashlib.sha256).digest()[:18]
    if not hmac.compare_digest(sig, expected):
        return None
    try:
        payload = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(payload, dict) or payload.get("exp", 0) < time.time():
        return None
    return payload


def select_meta(s: Session, key: str) -> str | None:
    row = s.scalar(select(ServerMeta).where(ServerMeta.key == key))
    return row.value if row else None
