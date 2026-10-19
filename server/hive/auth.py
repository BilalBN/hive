"""Who is calling.

Apps send a short-lived access token for their registered device (M2; see
hive.people). Before the first admin is set up, M1's development key still
works so an existing install keeps playing; setting up the admin retires it.

Requests from the home computer itself are trusted: Hive Admin opened at
http://127.0.0.1:8443/admin/ works without signing in, and its library calls
act as the first admin. Away from the home computer, Hive Admin needs an admin
session (email code plus authenticator app).

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

from fastapi import Depends, Request
from sqlalchemy import select
from sqlalchemy.orm import Session

from hive.db import Database
from hive.models import ServerMeta, User
from hive.people.service import DEV_USER_ID, Problem

LOOPBACK = {"127.0.0.1", "::1", "localhost"}


@dataclass(frozen=True)
class Caller:
    user_id: str
    display_name: str
    device_id: str | None = None
    role: str = "admin"


@dataclass(frozen=True)
class AdminCaller:
    """Someone using Hive Admin: on the home computer, or a signed-in admin."""

    user: User | None
    on_home_computer: bool

    @property
    def user_id(self) -> str:
        return self.user.id if self.user else DEV_USER_ID


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


def is_home_computer(request: Request) -> bool:
    host = request.client.host if request.client else ""
    return host in LOOPBACK


def _bearer(request: Request) -> str | None:
    scheme, _, token = request.headers.get("authorization", "").partition(" ")
    return token.strip() if scheme.lower() == "bearer" and token.strip() else None


def current_caller(request: Request) -> Caller:
    state = request.app.state
    people = state.people
    if is_home_computer(request):
        home = people.home_user()
        if home is not None:
            return Caller(home.id, home.name)
        return Caller(DEV_USER_ID, state.settings.admin_display_name)
    token = _bearer(request)
    if token and token.startswith("hive-dev-"):
        if hmac.compare_digest(token, state.dev_key) and not people.admin_exists():
            return Caller(DEV_USER_ID, state.settings.admin_display_name)
        raise Problem(
            401,
            "Sign-in needed",
            "This home now uses invites. Sign in with your email.",
            code="signInNeeded",
        )
    if token:
        signed = people.caller_for(token)
        return Caller(signed.user_id, signed.name, signed.device_id, signed.role)
    raise Problem(401, "Sign-in needed", "Sign in with your email.", code="signInNeeded")


CallerDep = Annotated[Caller, Depends(current_caller)]

ADMIN_COOKIE = "hive_admin"


def current_admin(request: Request) -> AdminCaller:
    people = request.app.state.people
    if is_home_computer(request):
        return AdminCaller(people.home_user(), True)
    user = people.session_user(request.cookies.get(ADMIN_COOKIE))
    if user is not None:
        return AdminCaller(user, False)
    raise Problem(
        401,
        "Sign-in needed",
        "Hive Admin opens on the home computer, or sign in as an admin.",
        code="signInNeeded",
    )


AdminDep = Annotated[AdminCaller, Depends(current_admin)]


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
