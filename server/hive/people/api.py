"""The apps' way in: invites, email codes, approval, devices, tokens, and the
person's own account and devices."""

from __future__ import annotations

from typing import Any, Literal

from fastapi import APIRouter, Request, Response
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.orm import Session

from hive.auth import CallerDep
from hive.models import Invite, User
from hive.people.service import RESEND_SECONDS, People, Problem, iso, mask_email

router = APIRouter(prefix="/api/v1", tags=["auth"])

# Good enough to catch typos; the code sent to it proves the rest.
EMAIL = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"

Platform = Literal["android", "ios", "macos", "windows", "linux", "web"]


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class InviteCodeBody(Strict):
    code: str = Field(min_length=4, max_length=64)


class EmailStartBody(Strict):
    email: str = Field(max_length=254, pattern=EMAIL)
    inviteCode: str | None = Field(None, max_length=64)  # noqa: N815
    deviceName: str = Field(min_length=1, max_length=80)  # noqa: N815
    platform: Platform


class EmailVerifyBody(Strict):
    verificationId: str = Field(max_length=64)  # noqa: N815
    code: str = Field(pattern=r"^[0-9]{6}$")


class RequestPollBody(Strict):
    requestToken: str = Field(max_length=200)  # noqa: N815


class DeviceRegistrationBody(Strict):
    requestId: str = Field(max_length=64)  # noqa: N815
    requestToken: str = Field(max_length=200)  # noqa: N815
    publicKey: str = Field(max_length=64)  # noqa: N815
    name: str = Field(min_length=1, max_length=80)
    platform: Platform
    appVersion: str | None = Field(None, max_length=32)  # noqa: N815
    replaceDeviceId: str | None = Field(None, max_length=64)  # noqa: N815


class ChallengeBody(Strict):
    deviceId: str = Field(max_length=64)  # noqa: N815


class TokenBody(Strict):
    deviceId: str = Field(max_length=64)  # noqa: N815
    refreshToken: str = Field(max_length=200)  # noqa: N815
    challenge: str = Field(max_length=200)
    signature: str = Field(max_length=200)


class MeEditBody(Strict):
    name: str | None = Field(None, min_length=1, max_length=80)
    simpleMode: bool | None = None  # noqa: N815


def _people(request: Request) -> People:
    return request.app.state.people


def _client(request: Request) -> str:
    return request.client.host if request.client else ""


@router.post("/auth/invites/resolve")
def resolve_invite(body: InviteCodeBody, request: Request) -> dict[str, Any]:
    people = _people(request)
    with Session(people.db.engine) as s:
        inv: Invite | None = people.find_invite(s, body.code)
        if inv is None:
            raise Problem(404, "Invite not found", "Check the code and try again.")
        out: dict[str, Any] = {
            "homeName": people.home.home_name,
            "valid": people.invite_usable(inv),
            "expiresAt": iso(inv.expires_at),
        }
        if inv.email:
            out["email"] = mask_email(inv.email)
        return out


@router.post("/auth/email/start")
def start_email(body: EmailStartBody, request: Request) -> dict[str, Any]:
    row, sent = _people(request).start_join(
        str(body.email), body.inviteCode, body.deviceName, body.platform, _client(request)
    )
    return {
        "verificationId": row.id,
        "expiresAt": iso(row.expires_at),
        "resendAfterSeconds": RESEND_SECONDS,
        "emailSent": sent,
    }


@router.post("/auth/email/verify")
def verify_email(body: EmailVerifyBody, request: Request) -> dict[str, Any]:
    people = _people(request)
    req, token, name = people.verify_join(body.verificationId, body.code)
    out: dict[str, Any] = {
        "requestId": req.id,
        "requestToken": token,
        "status": req.status,
        "homeName": people.home.home_name,
    }
    if name:
        out["name"] = name
    return out


@router.post("/auth/requests/{requestId}")
def poll_request(requestId: str, body: RequestPollBody, request: Request) -> dict[str, Any]:  # noqa: N803
    people = _people(request)
    with Session(people.db.engine) as s:
        req = people.request_for(s, requestId, body.requestToken)
        out: dict[str, Any] = {
            "requestId": req.id,
            "requestToken": body.requestToken,
            "status": req.status,
            "homeName": people.home.home_name,
        }
        if req.status == "approved" and req.user_id:
            user = s.get(User, req.user_id)
            if user is not None:
                out["name"] = user.name
        return out


@router.post("/auth/devices")
def register_device(body: DeviceRegistrationBody, request: Request) -> dict[str, Any]:
    return _people(request).register_device(body.model_dump())


@router.post("/auth/challenge")
def challenge(body: ChallengeBody, request: Request) -> dict[str, Any]:
    return _people(request).challenge(body.deviceId)


@router.post("/auth/token")
def token(body: TokenBody, request: Request) -> dict[str, Any]:
    return _people(request).refresh(body.model_dump())


# ------------------------------------------------------------------ me


def _me(people: People, caller) -> User:
    with Session(people.db.engine) as s:
        user = s.get(User, caller.user_id)
        if user is None:
            raise Problem(
                404,
                "Not set up",
                "This home has no people yet: it's still on the development key.",
            )
        s.expunge(user)
        return user


@router.get("/me")
def get_me(request: Request, caller: CallerDep) -> dict[str, Any]:
    people = _people(request)
    return people.me_body(_me(people, caller))


@router.patch("/me")
def update_me(body: MeEditBody, request: Request, caller: CallerDep) -> dict[str, Any]:
    people = _people(request)
    _me(people, caller)
    with people.lock, Session(people.db.engine) as s:
        user = s.get(User, caller.user_id)
        if body.name:
            user.name = body.name.strip()
        if body.simpleMode is not None:
            user.simple_mode = body.simpleMode
        s.commit()
        return people.me_body(user)


@router.get("/me/devices")
def my_devices(request: Request, caller: CallerDep) -> dict[str, Any]:
    return _people(request).my_devices(caller.user_id, caller.device_id)


@router.delete("/me/devices/{deviceId}", status_code=204)
def remove_my_device(deviceId: str, request: Request, caller: CallerDep) -> Response:  # noqa: N803
    _people(request).remove_my_device(caller.user_id, deviceId, caller.device_id)
    return Response(status_code=204)
