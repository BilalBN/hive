"""M6: notifications: each person's choices and devices, and Hive Admin's
Apple push key."""

from __future__ import annotations

from typing import Any, Literal

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import APIRouter, HTTPException, Request, Response
from pydantic import BaseModel, ConfigDict, Field

from hive.auth import AdminDep, CallerDep
from hive.push import KINDS, LABELS, unb64u

router = APIRouter(prefix="/api/v1/push", tags=["push"])
admin_router = APIRouter(prefix="/api/v1/admin/push", tags=["admin"])


def _settings(request: Request, caller) -> dict[str, Any]:
    push = request.app.state.push
    off = push.off(caller.user_id)
    admin = caller.role == "admin"
    return {
        "webPushKey": push.vapid_public(),
        "apns": push.apns_ready(),
        "kinds": [
            {"kind": k, "label": label, "on": k not in off}
            for k, label in LABELS.items()
            if admin or not KINDS[k].admins
        ],
    }


@router.get("/settings")
def push_settings(request: Request, caller: CallerDep) -> dict[str, Any]:
    return _settings(request, caller)


class Choices(BaseModel):
    model_config = ConfigDict(extra="forbid")
    off: list[str] = Field(max_length=20)


@router.put("/settings")
def set_push_settings(body: Choices, request: Request, caller: CallerDep) -> dict[str, Any]:
    if unknown := [k for k in body.off if k not in LABELS]:
        raise HTTPException(422, f"Unknown kind: {unknown[0]}")
    request.app.state.push.set_off(caller.user_id, body.off)
    return _settings(request, caller)


class Target(BaseModel):
    model_config = ConfigDict(extra="forbid")
    kind: Literal["webpush", "apns"]
    endpoint: str | None = Field(None, max_length=2000, pattern=r"^https://")
    p256dh: str | None = Field(None, max_length=200)
    auth: str | None = Field(None, max_length=100)
    token: str | None = Field(None, max_length=200, pattern=r"^[0-9a-fA-F]+$")


@router.put("/targets/{installId}", status_code=204)
def set_push_target(installId: str, body: Target, request: Request, caller: CallerDep) -> Response:  # noqa: N803
    """Where this device takes notifications while Hive is closed."""
    if len(installId) < 8 or len(installId) > 64:
        raise HTTPException(422, "That isn't a device")
    if body.kind == "webpush":
        if not (body.endpoint and body.p256dh and body.auth):
            raise HTTPException(422, "Web Push needs the endpoint and its keys")
        try:
            ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), unb64u(body.p256dh))
            if len(unb64u(body.auth)) != 16:
                raise ValueError
        except ValueError as e:
            raise HTTPException(422, "Those aren't Web Push keys") from e
        target = {
            "kind": "webpush",
            "endpoint": body.endpoint,
            "p256dh": body.p256dh,
            "auth": body.auth,
        }
    else:
        if not body.token:
            raise HTTPException(422, "Apple push needs the device token")
        target = {"kind": "apns", "token": body.token.lower()}
    request.app.state.push.set_target(caller.user_id, installId, target)
    return Response(status_code=204)


@router.delete("/targets/{installId}", status_code=204)
def delete_push_target(installId: str, request: Request, caller: CallerDep) -> Response:  # noqa: N803
    request.app.state.push.set_target(caller.user_id, installId, None)
    return Response(status_code=204)


# ------------------------------------------------------------------ Hive Admin


def _admin(request: Request) -> dict[str, Any]:
    a = request.app.state.push.apns()
    out: dict[str, Any] = {
        "apnsReady": request.app.state.push.apns_ready(),
        "keySet": bool(a["key"]),
        "topic": a["topic"],
        "sandbox": a["sandbox"],
    }
    if a["teamId"]:
        out["teamId"] = a["teamId"]
    if a["keyId"]:
        out["keyId"] = a["keyId"]
    return out


class ApnsSettings(BaseModel):
    model_config = ConfigDict(extra="forbid")
    teamId: str | None = Field(None, pattern=r"^([A-Z0-9]{10})?$")  # noqa: N815
    keyId: str | None = Field(None, pattern=r"^([A-Z0-9]{10})?$")  # noqa: N815
    privateKey: str | None = Field(None, max_length=4000)  # noqa: N815
    topic: str | None = Field(None, max_length=200, pattern=r"^[A-Za-z0-9.\-]+$")
    sandbox: bool | None = None


@admin_router.get("")
def admin_push(request: Request, who: AdminDep) -> dict[str, Any]:
    return _admin(request)


@admin_router.put("")
def admin_set_push(body: ApnsSettings, request: Request, who: AdminDep) -> dict[str, Any]:
    home = request.app.state.people.home
    if body.privateKey:
        try:
            key = serialization.load_pem_private_key(
                body.privateKey.strip().encode(), password=None
            )
        except (ValueError, TypeError) as e:
            raise HTTPException(422, "That isn't an APNs key (paste the whole .p8 file)") from e
        if not isinstance(key, ec.EllipticCurvePrivateKey):
            raise HTTPException(422, "That isn't an APNs key (paste the whole .p8 file)")
        home.set("push_apns_key", body.privateKey.strip())
    elif body.privateKey == "":
        home.set("push_apns_key", None)
    for field, key in (
        ("teamId", "push_apns_team"),
        ("keyId", "push_apns_key_id"),
        ("topic", "push_apns_topic"),
    ):
        value = getattr(body, field)
        if value is not None:
            home.set(key, value)
    if body.sandbox is not None:
        home.set("push_apns_sandbox", "1" if body.sandbox else None)
    return _admin(request)


@admin_router.post("/test")
def admin_test_push(request: Request, who: AdminDep) -> dict[str, Any]:
    """A test notification to every admin's devices."""
    return {"sent": request.app.state.push.notify("test", admins=True)}
