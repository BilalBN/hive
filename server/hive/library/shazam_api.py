"""M5: Shazam, for songs that aren't at home.

Listen asks home first. Only when home doesn't know the song, and the admin
has turned Shazam on, does the phone ask Shazam (Apple): it sends Apple a
fingerprint of the sound, never the sound itself, and tells home what Shazam
said so the person's history and "Ask to add it" cover it.

iPhones, iPads and Macs reach Shazam through the app itself. Android phones
need a short-lived Apple developer token, made here from the ShazamKit key
the admin pastes into Hive Admin (it never leaves home)."""

from __future__ import annotations

import base64
import json
import time
from typing import Any

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field

from hive.auth import AdminDep, CallerDep
from hive.library.api import SessionDep
from hive.models import AuditEntry, ListenEvent

router = APIRouter(prefix="/api/v1", tags=["listen"])
admin_router = APIRouter(prefix="/api/v1/admin", tags=["admin"])

TOKEN_SECONDS = 3600
_ON, _TEAM, _KEY_ID, _KEY = "shazam_on", "shazam_team_id", "shazam_key_id", "shazam_private_key"


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def load_key(pem: str) -> ec.EllipticCurvePrivateKey:
    """The .p8 file Apple gives: a P-256 private key."""
    try:
        key = serialization.load_pem_private_key(pem.strip().encode(), password=None)
    except (ValueError, TypeError) as e:
        raise HTTPException(422, "That isn't a ShazamKit key (paste the whole .p8 file)") from e
    if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != "secp256r1":
        raise HTTPException(422, "That isn't a ShazamKit key (paste the whole .p8 file)")
    return key


def developer_token(team_id: str, key_id: str, pem: str, now: int | None = None) -> tuple[str, int]:
    """An Apple developer token (a JWT signed with ES256)."""
    now = int(now or time.time())
    exp = now + TOKEN_SECONDS
    header = _b64(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    payload = _b64(json.dumps({"iss": team_id, "iat": now, "exp": exp}).encode())
    signing = f"{header}.{payload}".encode()
    der = load_key(pem).sign(signing, ec.ECDSA(hashes.SHA256()))
    r, s = decode_dss_signature(der)
    return f"{header}.{payload}.{_b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}", exp


def _settings(request: Request) -> dict[str, Any]:
    home = request.app.state.people.home
    return {
        "on": home.get(_ON) == "1",
        "teamId": home.get(_TEAM) or None,
        "keyId": home.get(_KEY_ID) or None,
        "key": home.get(_KEY) or None,
    }


def _android_ready(s: dict[str, Any]) -> bool:
    return bool(s["on"] and s["teamId"] and s["keyId"] and s["key"])


# ------------------------------------------------------------------ the apps


@router.get("/listen/options")
def listen_options(request: Request, caller: CallerDep) -> dict[str, Any]:
    s = _settings(request)
    return {"shazam": s["on"], "shazamAndroid": _android_ready(s)}


@router.post("/listen/shazam-token")
def create_shazam_token(request: Request, caller: CallerDep) -> dict[str, Any]:
    s = _settings(request)
    if not s["on"]:
        raise HTTPException(409, "Shazam is off for this home")
    if not _android_ready(s):
        raise HTTPException(
            409, "Shazam on Android needs the ShazamKit key in Hive Admin → Recognition"
        )
    token, exp = developer_token(s["teamId"], s["keyId"], s["key"])
    return {"token": token, "expiresAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(exp))}


class ShazamFound(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: str = Field(min_length=1, max_length=512)
    artist: str | None = Field(None, max_length=512)
    listenEventId: int | None = None  # noqa: N815


@router.post("/listen/history")
def record_listen_result(
    body: ShazamFound, request: Request, caller: CallerDep, s: SessionDep
) -> dict[str, Any]:
    """What Shazam named, kept in the person's history. Given the attempt home
    couldn't name, that entry becomes Shazam's (one entry, not two)."""
    if not _settings(request)["on"]:
        raise HTTPException(409, "Shazam is off for this home")
    event = None
    if body.listenEventId is not None:
        event = s.get(ListenEvent, body.listenEventId)
        if event is None or event.user_id != caller.user_id:
            raise HTTPException(404, "No such Listen attempt")
        if event.track_id is not None:
            raise HTTPException(409, "Home already knew that song")
    if event is None:
        event = ListenEvent(user_id=caller.user_id)
        s.add(event)
    event.source = "shazam"
    event.title = body.title.strip()
    event.artist = (body.artist or "").strip() or None
    s.commit()
    s.refresh(event)
    out: dict[str, Any] = {
        "id": event.id,
        "matched": True,
        "source": "shazam",
        "title": event.title,
    }
    if event.artist:
        out["artist"] = event.artist
    return out


# ------------------------------------------------------------------ Hive Admin


def _admin_body(request: Request) -> dict[str, Any]:
    s = _settings(request)
    out: dict[str, Any] = {
        "enabled": s["on"],
        "keySet": bool(s["key"]),
        "androidReady": _android_ready(s),
    }
    if s["teamId"]:
        out["teamId"] = s["teamId"]
    if s["keyId"]:
        out["keyId"] = s["keyId"]
    return out


class ShazamSettings(BaseModel):
    model_config = ConfigDict(extra="forbid")
    enabled: bool | None = None
    teamId: str | None = Field(None, pattern=r"^([A-Z0-9]{10})?$")  # noqa: N815
    keyId: str | None = Field(None, pattern=r"^([A-Z0-9]{10})?$")  # noqa: N815
    privateKey: str | None = Field(None, max_length=4000)  # noqa: N815


@admin_router.get("/recognition/shazam")
def admin_shazam(request: Request, who: AdminDep) -> dict[str, Any]:
    return _admin_body(request)


@admin_router.put("/recognition/shazam")
def admin_set_shazam(
    body: ShazamSettings, request: Request, who: AdminDep, s: SessionDep
) -> dict[str, Any]:
    home = request.app.state.people.home
    if body.privateKey:
        load_key(body.privateKey)  # refuse anything that isn't a key
        home.set(_KEY, body.privateKey.strip())
    elif body.privateKey == "":
        home.set(_KEY, "")
    if body.teamId is not None:
        home.set(_TEAM, body.teamId)
    if body.keyId is not None:
        home.set(_KEY_ID, body.keyId)
    if body.enabled is not None:
        home.set(_ON, "1" if body.enabled else "0")
        actor = who.user.name if who.user else request.app.state.settings.admin_display_name
        s.add(
            AuditEntry(
                actor=actor,
                actor_id=who.user.id if who.user else None,
                action="listen.shazam",
                text=f"{actor} turned Shazam {'on' if body.enabled else 'off'} for Listen.",
            )
        )
        s.commit()
    return _admin_body(request)
