"""Hive Admin: signing in, people, requests, invites, devices, settings, audit."""

from __future__ import annotations

from typing import Any, Literal

from fastapi import APIRouter, Query, Request, Response
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import case, func, select
from sqlalchemy.orm import Session

from hive.auth import ADMIN_COOKIE, AdminCaller, AdminDep, is_home_computer
from hive.models import AccessRequest, Album, AuditEntry, Device, Track, User
from hive.people import crypto as X
from hive.people import mail
from hive.people.admin import Admin, audit_body
from hive.people.api import EMAIL
from hive.people.service import ADMIN_SESSION_HOURS, People, Problem, now

router = APIRouter(prefix="/api/v1/admin", tags=["admin"])


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class SetupBody(Strict):
    name: str = Field(min_length=1, max_length=80)
    email: str = Field(max_length=254, pattern=EMAIL)


class AdminEmailBody(Strict):
    email: str = Field(max_length=254, pattern=EMAIL)


class AdminVerifyBody(Strict):
    verificationId: str = Field(max_length=64)  # noqa: N815
    code: str = Field(pattern=r"^[0-9]{6}$")
    authenticatorCode: str | None = Field(None, pattern=r"^[0-9]{6}$")  # noqa: N815


class CodeBody(Strict):
    code: str = Field(pattern=r"^[0-9]{6}$")


class DecisionBody(Strict):
    note: str | None = Field(None, max_length=200)
    name: str | None = Field(None, max_length=80)


class InviteBody(Strict):
    email: str | None = Field(None, max_length=254, pattern=r"^$|" + EMAIL[1:])
    name: str | None = Field(None, max_length=80)
    role: Literal["member", "admin"] = "member"
    note: str | None = Field(None, max_length=200)
    days: int = Field(7, ge=1, le=30)


class PersonBody(Strict):
    name: str | None = Field(None, min_length=1, max_length=80)
    role: Literal["admin", "member"] | None = None
    status: Literal["active", "suspended"] | None = None
    deviceLimit: int | None = Field(None, ge=1, le=20)  # noqa: N815
    simpleMode: bool | None = None  # noqa: N815
    resetDevices: bool | None = None  # noqa: N815


class EmailSettingsBody(Strict):
    host: str | None = Field(None, max_length=255)
    port: int | None = Field(None, ge=1, le=65535)
    security: Literal["starttls", "ssl", "none"] | None = None
    username: str | None = Field(None, max_length=254)
    password: str | None = Field(None, max_length=512)
    sender: str | None = Field(None, alias="from", max_length=254)


class SettingsBody(Strict):
    homeName: str | None = Field(None, min_length=1, max_length=60)  # noqa: N815
    devicesPerPerson: int | None = Field(None, ge=1, le=20)  # noqa: N815
    swapsPerMonth: int | None = Field(None, ge=0, le=20)  # noqa: N815
    address: str | None = Field(None, max_length=200)
    privateNetworkLink: str | None = Field(None, max_length=500)  # noqa: N815
    email: EmailSettingsBody | None = None


class EmailTestBody(Strict):
    to: str | None = Field(None, max_length=254, pattern=EMAIL)


def _people(request: Request) -> People:
    return request.app.state.people


def _admin(request: Request, who: AdminCaller) -> Admin:
    return Admin(_people(request), who.user)


def _client(request: Request) -> str:
    return request.client.host if request.client else ""


# ------------------------------------------------------------------ session


def session_body(request: Request, user: User | None, on_home: bool) -> dict[str, Any]:
    people = _people(request)
    body: dict[str, Any] = {
        "signedIn": on_home or user is not None,
        "onHomeComputer": on_home,
        "needsSetup": not people.admin_exists(),
        "emailReady": people.home.email.ready,
    }
    if user is not None:
        body["me"] = {
            "id": user.id,
            "name": user.name,
            "email": user.email,
            "authenticator": bool(user.totp_secret),
        }
    return body


@router.get("/session")
def get_session(request: Request) -> dict[str, Any]:
    people = _people(request)
    if is_home_computer(request):
        return session_body(request, people.home_user(), True)
    return session_body(request, people.session_user(request.cookies.get(ADMIN_COOKIE)), False)


@router.delete("/session", status_code=204)
def sign_out(request: Request, response: Response) -> Response:
    _people(request).end_session(request.cookies.get(ADMIN_COOKIE))
    out = Response(status_code=204)
    out.delete_cookie(ADMIN_COOKIE, path="/")
    return out


@router.post("/setup")
def setup(body: SetupBody, request: Request) -> dict[str, Any]:
    if not is_home_computer(request):
        raise Problem(403, "Home computer only", "Set up Hive Admin on the home computer itself.")
    user = _people(request).setup_admin(body.name, body.email)
    return session_body(request, user, True)


@router.post("/session/email")
def start_sign_in(body: AdminEmailBody, request: Request) -> dict[str, Any]:
    return _people(request).start_admin_code(body.email, _client(request))


@router.post("/session/email/verify")
def finish_sign_in(body: AdminVerifyBody, request: Request) -> Response:
    people = _people(request)
    cookie = people.verify_admin(body.verificationId, body.code, body.authenticatorCode)
    user = people.session_user(cookie)
    from fastapi.responses import JSONResponse

    out = JSONResponse(session_body(request, user, is_home_computer(request)))
    out.set_cookie(
        ADMIN_COOKIE,
        cookie,
        max_age=ADMIN_SESSION_HOURS * 3600,
        httponly=True,
        samesite="strict",
        secure=request.url.scheme == "https",
        path="/",
    )
    return out


@router.post("/me/authenticator")
def start_authenticator(request: Request, who: AdminDep) -> dict[str, Any]:
    people = _people(request)
    if who.user is None:
        raise Problem(409, "Set up first", "Create the first admin before an authenticator.")
    secret = X.totp_secret()
    with people.lock, Session(people.db.engine) as s:
        user = s.get(User, who.user.id)
        user.totp_pending = secret
        s.commit()
        uri = X.totp_uri(secret, user.email, f"Hive {people.home.home_name}")
    return {"secret": secret, "uri": uri}


@router.put("/me/authenticator")
def confirm_authenticator(body: CodeBody, request: Request, who: AdminDep) -> dict[str, Any]:
    people = _people(request)
    if who.user is None:
        raise Problem(409, "Set up first", "Create the first admin before an authenticator.")
    with people.lock, Session(people.db.engine) as s:
        user = s.get(User, who.user.id)
        step = X.totp_check(user.totp_pending or "", body.code, None) if user.totp_pending else None
        if step is None:
            raise Problem(
                400, "Wrong code", "Type the 6-digit code the authenticator app shows for Hive."
            )
        user.totp_secret, user.totp_pending, user.totp_last_step = user.totp_pending, None, step
        people.audit(
            s,
            "admin.authenticator",
            f"{user.name} set up an authenticator app.",
            user.name,
            user.id,
            user.id,
        )
        s.commit()
        s.refresh(user)
        s.expunge(user)
    return session_body(request, user, who.on_home_computer)


@router.delete("/me/authenticator")
def remove_authenticator(request: Request, who: AdminDep) -> dict[str, Any]:
    if not who.on_home_computer or who.user is None:
        raise Problem(403, "Home computer only", "Remove the authenticator on the home computer.")
    people = _people(request)
    with people.lock, Session(people.db.engine) as s:
        user = s.get(User, who.user.id)
        user.totp_secret = user.totp_pending = None
        people.audit(
            s, "admin.authenticator", f"{user.name} removed their authenticator.", user.name
        )
        s.commit()
        s.refresh(user)
        s.expunge(user)
    return session_body(request, user, True)


# ------------------------------------------------------------------ overview


@router.get("/overview")
def overview(request: Request, who: AdminDep) -> dict[str, Any]:
    people = _people(request)
    with Session(people.db.engine) as s:
        pending = s.scalar(
            select(func.count())
            .select_from(AccessRequest)
            .where(AccessRequest.status == "pending", AccessRequest.expires_at > now())
        )
        n_people = s.scalar(select(func.count()).select_from(User))
        n_devices = s.scalar(
            select(func.count()).select_from(Device).where(Device.status == "active")
        )
        tracks, lossless, size = s.execute(
            select(
                func.count(Track.id),
                func.coalesce(func.sum(case((Track.lossless.is_(True), 1), else_=0)), 0),
                func.coalesce(func.sum(Track.size), 0),
            )
        ).one()
        albums = s.scalar(select(func.count()).select_from(Album))
        recent = s.scalars(select(AuditEntry).order_by(AuditEntry.id.desc()).limit(8)).all()
        admin_exists = people.admin_exists(s)
        alerts: list[dict[str, str]] = []
        if not admin_exists:
            alerts.append(
                {
                    "level": "warning",
                    "text": "Set up the first admin to switch from the development key to "
                    "invites (Settings → Your sign-in, on the home computer).",
                }
            )
        if not people.home.email.ready:
            alerts.append(
                {
                    "level": "warning",
                    "text": "Email isn't set up, so sign-in codes show on Requests for you to "
                    "pass on. Settings → Email.",
                }
            )
        if who.user is not None and not who.user.totp_secret:
            alerts.append(
                {
                    "level": "info",
                    "text": "Set up an authenticator app to use Hive Admin away from the home "
                    "computer (Settings → Your sign-in).",
                }
            )
        if pending:
            who_waits = "person is" if pending == 1 else "people are"
            alerts.append({"level": "info", "text": f"{pending} {who_waits} waiting for approval."})
        return {
            "homeName": people.home.home_name,
            "pendingRequests": pending or 0,
            "people": n_people or 0,
            "devices": n_devices or 0,
            "tracks": tracks or 0,
            "albums": albums or 0,
            "sizeBytes": int(size or 0),
            "losslessPercent": round(100 * lossless / tracks) if tracks else 0,
            "emailReady": people.home.email.ready,
            "developmentKeyActive": not admin_exists,
            "alerts": alerts,
            "recent": [audit_body(a) for a in recent],
        }


# ------------------------------------------------------------------ requests and invites


@router.get("/requests")
def list_requests(request: Request, who: AdminDep) -> dict[str, Any]:
    return _admin(request, who).requests()


@router.post("/requests/{requestId}/approve")
def approve(
    requestId: str,  # noqa: N803
    request: Request,
    who: AdminDep,
    body: DecisionBody | None = None,
) -> dict[str, Any]:
    b = body or DecisionBody()
    return _admin(request, who).decide(requestId, True, b.note, b.name)


@router.post("/requests/{requestId}/decline")
def decline(
    requestId: str,  # noqa: N803
    request: Request,
    who: AdminDep,
    body: DecisionBody | None = None,
) -> dict[str, Any]:
    b = body or DecisionBody()
    return _admin(request, who).decide(requestId, False, b.note, None)


@router.post("/requests/{requestId}/undo")
def undo(requestId: str, request: Request, who: AdminDep) -> dict[str, Any]:  # noqa: N803
    return _admin(request, who).undo(requestId)


def home_address(request: Request) -> str:
    saved = _people(request).home.get("address")
    if saved:
        return saved
    return f"{request.url.scheme}://{request.url.netloc}"


@router.get("/invites")
def list_invites(request: Request, who: AdminDep) -> dict[str, Any]:
    return _admin(request, who).invites()


@router.post("/invites")
def create_invite(body: InviteBody, request: Request, who: AdminDep) -> dict[str, Any]:
    return _admin(request, who).create_invite(body.model_dump(), home_address(request))


@router.delete("/invites/{inviteId}", status_code=204)
def revoke_invite(inviteId: str, request: Request, who: AdminDep) -> Response:  # noqa: N803
    _admin(request, who).revoke_invite(inviteId)
    return Response(status_code=204)


# ------------------------------------------------------------------ people and devices


@router.get("/people")
def list_people(request: Request, who: AdminDep) -> dict[str, Any]:
    return _admin(request, who).people()


@router.get("/people/{personId}")
def get_person(personId: str, request: Request, who: AdminDep) -> dict[str, Any]:  # noqa: N803
    return _admin(request, who).person(personId)


@router.patch("/people/{personId}")
def update_person(
    personId: str,  # noqa: N803
    body: PersonBody,
    request: Request,
    who: AdminDep,
) -> dict[str, Any]:
    return _admin(request, who).update_person(personId, body.model_dump(exclude_unset=True))


@router.get("/devices")
def list_devices(request: Request, who: AdminDep) -> dict[str, Any]:
    return _admin(request, who).devices()


@router.post("/devices/{deviceId}/revoke")
def revoke_device(deviceId: str, request: Request, who: AdminDep) -> dict[str, Any]:  # noqa: N803
    return _admin(request, who).revoke_device(deviceId)


# ------------------------------------------------------------------ settings


def settings_body(request: Request) -> dict[str, Any]:
    home = _people(request).home
    cfg = home.email
    body: dict[str, Any] = {
        "homeName": home.home_name,
        "devicesPerPerson": home.devices_per_person,
        "swapsPerMonth": home.swaps_per_month,
        "address": home.get("address") or home_address(request),
        "email": {
            "host": cfg.host,
            "port": cfg.port,
            "security": cfg.security,
            "username": cfg.username,
            "from": cfg.sender,
            "passwordSet": bool(cfg.password),
            "ready": cfg.ready,
        },
    }
    if home.get("private_network_link"):
        body["privateNetworkLink"] = home.get("private_network_link")
    return body


@router.get("/settings")
def get_settings_(request: Request, who: AdminDep) -> dict[str, Any]:
    return settings_body(request)


@router.patch("/settings")
def update_settings(body: SettingsBody, request: Request, who: AdminDep) -> dict[str, Any]:
    people = _people(request)
    home = people.home
    given = body.model_dump(exclude_unset=True, by_alias=False)
    keys = {
        "homeName": "home_name",
        "devicesPerPerson": "devices_per_person",
        "swapsPerMonth": "swaps_per_month",
        "address": "address",
        "privateNetworkLink": "private_network_link",
    }
    changed = []
    for field, key in keys.items():
        if field in given:
            value = given[field]
            home.set(key, None if value is None else str(value).strip())
            changed.append(field)
    if body.email is not None:
        e = body.email.model_dump(exclude_unset=True, by_alias=False)
        for field, key in {
            "host": "email_host",
            "port": "email_port",
            "security": "email_security",
            "username": "email_username",
            "password": "email_password",
            "sender": "email_from",
        }.items():
            if field in e:
                value = e[field]
                home.set(key, None if value is None else str(value).strip())
        changed.append("email")
    if changed:
        with Session(people.db.engine) as s:
            Admin(people, who.user).audit(
                s,
                "settings.update",
                f"{Admin(people, who.user).actor_name} changed settings: {', '.join(changed)}.",
            )
            s.commit()
    return settings_body(request)


@router.post("/settings/email/test")
def test_email(request: Request, who: AdminDep, body: EmailTestBody | None = None) -> dict:
    people = _people(request)
    to = (body.to if body else None) or (who.user.email if who.user else None)
    if not to:
        return {"ok": False, "message": "Give an address to send the test to."}
    try:
        mail.send(
            people.home.email,
            to,
            "Hive email works",
            f"Hive at {people.home.home_name} can send email. Sign-in codes will arrive "
            "like this one.\n",
            people.home.home_name,
        )
    except mail.MailError as e:
        return {"ok": False, "message": str(e)}
    return {"ok": True, "message": f"Sent to {to}. Check the inbox (and spam)."}


# ------------------------------------------------------------------ audit


@router.get("/audit")
def audit(
    request: Request,
    who: AdminDep,
    offset: int = Query(0, ge=0),
    limit: int = Query(100, ge=1, le=500),
    action: str | None = Query(None, max_length=64),
) -> dict[str, Any]:
    return _admin(request, who).audit_page(offset, limit, action)
