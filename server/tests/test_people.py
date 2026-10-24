"""M2: invites, email codes, approval, devices and their tokens, admin
sign-in, the audit log, and retiring the development key."""

from __future__ import annotations

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from fastapi.testclient import TestClient

from hive.people import crypto as X
from hive.people import mail

from .conftest import assert_matches, away


class Phone:
    """An app on a device: its own key pair, like the real app keeps."""

    def __init__(self, client: TestClient, name: str = "Pixel 8", platform: str = "android"):
        self.client = client
        self.name = name
        self.platform = platform
        self.key = Ed25519PrivateKey.generate()
        raw = self.key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
        self.public = X.b64(raw)
        self.session: dict | None = None

    def sign(self, text: str) -> str:
        return X.b64(self.key.sign(text.encode()))

    @property
    def auth(self) -> dict[str, str]:
        assert self.session
        return {"Authorization": f"Bearer {self.session['accessToken']}"}

    def start(self, email: str, invite: str | None = None):
        body = {"email": email, "deviceName": self.name, "platform": self.platform}
        if invite:
            body["inviteCode"] = invite
        return self.client.post("/api/v1/auth/email/start", json=body)

    def verify(self, verification_id: str, code: str):
        return self.client.post(
            "/api/v1/auth/email/verify", json={"verificationId": verification_id, "code": code}
        )

    def register(self, request: dict, replace: str | None = None):
        body = {
            "requestId": request["requestId"],
            "requestToken": request["requestToken"],
            "publicKey": self.public,
            "name": self.name,
            "platform": self.platform,
            "appVersion": "0.2.0",
        }
        if replace:
            body["replaceDeviceId"] = replace
        r = self.client.post("/api/v1/auth/devices", json=body)
        if r.status_code == 200:
            self.session = r.json()
        return r

    def refresh(self):
        assert self.session
        c = self.client.post(
            "/api/v1/auth/challenge", json={"deviceId": self.session["deviceId"]}
        ).json()
        r = self.client.post(
            "/api/v1/auth/token",
            json={
                "deviceId": self.session["deviceId"],
                "refreshToken": self.session["refreshToken"],
                "challenge": c["challenge"],
                "signature": self.sign(c["challenge"]),
            },
        )
        if r.status_code == 200:
            self.session = r.json()
        return r


def code_for(home: TestClient, email: str) -> str:
    """Email isn't set up in tests, so codes show in Hive Admin → Requests."""
    codes = home.get("/api/v1/admin/requests").json()["codes"]
    return next(c["code"] for c in reversed(codes) if c["email"] == email)


def set_up_admin(home: TestClient, email: str = "bilal@example.com") -> dict:
    r = home.post("/api/v1/admin/setup", json={"name": "Bilal", "email": email})
    assert r.status_code == 200, r.text
    return r.json()


def join(home: TestClient, email: str, invite: str | None = None, name: str = "Pixel 8") -> Phone:
    """Through the whole flow with an invite (approved at once)."""
    phone = Phone(away(home), name=name)
    started = phone.start(email, invite)
    assert started.status_code == 200, started.text
    req = phone.verify(started.json()["verificationId"], code_for(home, email)).json()
    assert req["status"] == "approved", req
    r = phone.register(req)
    assert r.status_code == 200, r.text
    return phone


def invite(home: TestClient, email: str | None = None, **kw) -> str:
    r = home.post("/api/v1/admin/invites", json={"email": email, **kw} if email else kw)
    assert r.status_code == 200, r.text
    assert_matches(r.json(), "AdminInvite")
    return r.json()["code"]


# ------------------------------------------------------------------ the switch from M1


def test_development_key_until_the_first_admin(server: TestClient) -> None:
    other = away(server)
    dev = {"Authorization": f"Bearer {server.app.state.dev_key}"}
    health = other.get("/api/v1/health").json()
    assert health["access"] == "developmentKey"
    assert other.get("/api/v1/library/home", headers=dev).status_code == 200
    session = other.get("/api/v1/admin/session").json()
    assert_matches(session, "AdminSession")
    assert session == {
        "signedIn": False,
        "onHomeComputer": False,
        "needsSetup": True,
        "emailReady": False,
    }
    # Setting up only works on the home computer.
    r = other.post("/api/v1/admin/setup", json={"name": "X", "email": "x@example.com"})
    assert r.status_code == 403

    # Something liked with the development key stays liked.
    session = set_up_admin(server)
    assert session["signedIn"] and session["onHomeComputer"] and not session["needsSetup"]
    assert session["me"]["name"] == "Bilal"
    assert other.get("/api/v1/health").json()["access"] == "invites"
    r = other.get("/api/v1/library/home", headers=dev)
    assert r.status_code == 401 and r.json()["code"] == "signInNeeded"
    assert (
        server.post("/api/v1/admin/setup", json={"name": "Y", "email": "y@x.com"}).status_code
        == 409
    )
    audit = server.get("/api/v1/admin/audit").json()
    assert_matches(audit, "AuditPage")
    assert audit["items"][0]["action"] == "admin.setup"


# ------------------------------------------------------------------ joining


def test_join_with_an_invite(server: TestClient) -> None:
    set_up_admin(server)
    code = invite(server, "amma@example.com", name="Amma")
    info = away(server).post("/api/v1/auth/invites/resolve", json={"code": code.lower()}).json()
    assert_matches(info, "InviteInfo")
    assert info["valid"] and info["email"] == "a•••@example.com"
    assert info["homeName"] == "Test home"

    phone = Phone(away(server))
    assert phone.start("someone@else.com", code).status_code == 403  # for Amma only
    started = phone.start("Amma@Example.com", code)
    assert_matches(started.json(), "EmailStarted")
    assert started.json()["emailSent"] is False  # email isn't set up in tests
    req = phone.verify(started.json()["verificationId"], code_for(server, "amma@example.com"))
    assert_matches(req.json(), "AccessRequestStatus")
    assert req.json()["status"] == "approved" and req.json()["name"] == "Amma"
    r = phone.register(req.json())
    assert_matches(r.json(), "DeviceSession")
    assert r.json()["me"]["email"] == "amma@example.com"

    # Signed in: the library, and who I am.
    assert phone.client.get("/api/v1/library/home", headers=phone.auth).status_code == 200
    me = phone.client.get("/api/v1/me", headers=phone.auth).json()
    assert_matches(me, "Me")
    assert me["role"] == "member"
    devices = phone.client.get("/api/v1/me/devices", headers=phone.auth).json()
    assert_matches(devices, "MyDevices")
    assert devices["limit"] == 4 and devices["items"][0]["current"] is True
    # The invite is used up.
    assert phone.start("amma@example.com", code).status_code == 404


def test_one_invite_after_another(server: TestClient, monkeypatch) -> None:
    """Each person gets their own invite; making one doesn't stop the next."""
    set_up_admin(server)
    sent: list[str] = []
    monkeypatch.setattr(
        server.app.state.people.home.email.__class__, "ready", property(lambda _: True)
    )
    monkeypatch.setattr("hive.people.mail.send", lambda cfg, to, *a, **k: sent.append(to))
    first = server.post(
        "/api/v1/admin/invites", json={"email": "amma@example.com", "name": "Amma"}
    ).json()
    second = server.post("/api/v1/admin/invites", json={"email": "basith@example.com"}).json()
    no_email = server.post("/api/v1/admin/invites", json={"name": "Uncle"}).json()
    assert first["emailSent"] is True and second["emailSent"] is True
    assert "emailSent" not in no_email
    assert sent == ["amma@example.com", "basith@example.com"]
    assert first["code"] != second["code"]
    listed = server.get("/api/v1/admin/invites").json()["items"]
    assert len(listed) == 3


def test_join_without_an_invite_waits_for_approval(server: TestClient) -> None:
    set_up_admin(server)
    phone = Phone(away(server), name="Ammu's iPhone", platform="ios")
    started = phone.start("cousin@example.com").json()
    req = phone.verify(started["verificationId"], code_for(server, "cousin@example.com")).json()
    assert req["status"] == "pending"
    poll = lambda: phone.client.post(  # noqa: E731
        f"/api/v1/auth/requests/{req['requestId']}", json={"requestToken": req["requestToken"]}
    ).json()
    assert poll()["status"] == "pending"
    assert phone.register(req).status_code == 403

    waiting = server.get("/api/v1/admin/requests").json()
    assert_matches(waiting, "AdminRequests")
    item = waiting["items"][0]
    assert item["status"] == "pending" and item["deviceName"] == "Ammu's iPhone"
    assert item["invited"] is False and item["existingPerson"] is False

    # Approve, undo, approve again.
    r = server.post(f"/api/v1/admin/requests/{item['id']}/approve", json={"name": "Ammu"})
    assert r.json()["status"] == "approved" and "undoUntil" in r.json()
    assert server.post(f"/api/v1/admin/requests/{item['id']}/undo").json()["status"] == "pending"
    assert server.get("/api/v1/admin/people").json()["items"][-1]["name"] == "Bilal"
    server.post(
        f"/api/v1/admin/requests/{item['id']}/approve", json={"name": "Ammu", "note": "cousin"}
    )
    assert poll() == {**req, "status": "approved", "name": "Ammu"}
    assert phone.register(req).status_code == 200
    people = server.get("/api/v1/admin/people").json()
    assert_matches(people, "AdminPeople")
    assert {p["name"] for p in people["items"]} == {"Bilal", "Ammu"}
    # The request can't be used for a second device.
    assert Phone(away(server)).register(req).status_code == 403


def test_declined(server: TestClient) -> None:
    set_up_admin(server)
    phone = Phone(away(server))
    started = phone.start("stranger@example.com").json()
    req = phone.verify(started["verificationId"], code_for(server, "stranger@example.com")).json()
    server.post(f"/api/v1/admin/requests/{req['requestId']}/decline")
    r = phone.client.post(
        f"/api/v1/auth/requests/{req['requestId']}", json={"requestToken": req["requestToken"]}
    )
    assert r.json()["status"] == "declined"
    assert (
        phone.client.post(
            f"/api/v1/auth/requests/{req['requestId']}", json={"requestToken": "guess"}
        ).status_code
        == 404
    )


def test_codes_wrong_tries_and_resend(server: TestClient) -> None:
    set_up_admin(server)
    server.app.state.people.resend_seconds = 30
    phone = Phone(away(server))
    started = phone.start("cousin@example.com").json()
    right = code_for(server, "cousin@example.com")
    wrong = "000000" if right != "000000" else "111111"
    r = phone.verify(started["verificationId"], wrong)
    assert r.status_code == 400 and r.json()["attemptsLeft"] == 4
    for _ in range(3):
        phone.verify(started["verificationId"], wrong)
    r = phone.verify(started["verificationId"], wrong)
    assert r.status_code == 429
    assert phone.verify(started["verificationId"], right).status_code == 429  # spent
    r = phone.start("cousin@example.com")  # straight away: too soon
    assert r.status_code == 429 and r.json()["retryAfterSeconds"] > 0


# ------------------------------------------------------------------ tokens and devices


def test_refresh_needs_the_device_key(server: TestClient) -> None:
    set_up_admin(server)
    phone = join(server, "amma@example.com", invite(server, "amma@example.com"))
    old = dict(phone.session)
    assert phone.refresh().status_code == 200
    assert phone.session["refreshToken"] != old["refreshToken"]
    # The old refresh token is gone.
    c = phone.client.post("/api/v1/auth/challenge", json={"deviceId": old["deviceId"]}).json()
    r = phone.client.post(
        "/api/v1/auth/token",
        json={
            "deviceId": old["deviceId"],
            "refreshToken": old["refreshToken"],
            "challenge": c["challenge"],
            "signature": phone.sign(c["challenge"]),
        },
    )
    assert r.status_code == 401
    # A copied refresh token without the key is useless.
    thief = Phone(phone.client)
    c = phone.client.post("/api/v1/auth/challenge", json={"deviceId": old["deviceId"]}).json()
    r = phone.client.post(
        "/api/v1/auth/token",
        json={
            "deviceId": old["deviceId"],
            "refreshToken": phone.session["refreshToken"],
            "challenge": c["challenge"],
            "signature": thief.sign(c["challenge"]),
        },
    )
    assert r.status_code == 401
    assert phone.client.get("/api/v1/library/home", headers=phone.auth).status_code == 200


def test_the_same_device_joining_again_replaces_itself(server: TestClient) -> None:
    """Reinstalling the app on a phone doesn't leave a second Pixel 8 behind."""
    set_up_admin(server)
    server.patch("/api/v1/admin/settings", json={"devicesPerPerson": 1, "swapsPerMonth": 0})
    old = join(server, "amma@example.com", invite(server, "amma@example.com"))
    again = join(server, "amma@example.com")  # same name and platform; no limit hit
    devices = again.client.get("/api/v1/me/devices", headers=again.auth).json()
    assert [d["name"] for d in devices["items"]] == ["Pixel 8"]
    assert devices["items"][0]["current"] is True
    assert devices["swapsLeft"] == 0  # not counted as a device change
    r = old.client.get("/api/v1/library/home", headers=old.auth)
    assert r.status_code == 401 and r.json()["code"] == "revoked"


def test_repeats_from_before_are_tidied_once(server: TestClient) -> None:
    """Entries left by devices that joined again before the fix are removed,
    but only when they haven't been used since the newer one joined."""
    from datetime import timedelta

    from sqlalchemy import select
    from sqlalchemy.orm import Session

    from hive.models import Device

    set_up_admin(server)
    code = invite(server, "amma@example.com")
    join(server, "amma@example.com", code, name="Phone")
    join(server, "amma@example.com", name="Laptop")
    people = server.app.state.people
    with Session(people.db.engine) as s:
        user_id = s.scalars(select(Device.user_id)).first()
        base = s.scalars(select(Device).where(Device.name == "Phone")).one()
        t = base.created_at
        s.add_all(
            [
                # An old install of the phone, last seen before the newer joined.
                Device(
                    id="oldphone",
                    user_id=user_id,
                    name="Phone",
                    platform="android",
                    public_key=base.public_key,
                    created_at=t - timedelta(days=3),
                    last_seen_at=t - timedelta(days=1),
                ),
                # A second laptop that is still in use: kept.
                Device(
                    id="stillused",
                    user_id=user_id,
                    name="Laptop",
                    platform="android",
                    public_key=base.public_key,
                    created_at=t - timedelta(days=3),
                    last_seen_at=t + timedelta(days=1),
                ),
            ]
        )
        s.commit()
    assert people.tidy_repeated_devices() == 1
    assert people.tidy_repeated_devices() == 0
    with Session(people.db.engine) as s:
        status = {d.id: d.status for d in s.scalars(select(Device))}
    assert status["oldphone"] == "revoked" and status["stillused"] == "active"


def test_device_limit_swaps_and_removal(server: TestClient) -> None:
    set_up_admin(server)
    server.patch("/api/v1/admin/settings", json={"devicesPerPerson": 2, "swapsPerMonth": 1})
    code = invite(server, "amma@example.com")
    first = join(server, "amma@example.com", code, name="Phone")
    join(server, "amma@example.com", name="Laptop")  # a known person: approved at once

    third = Phone(away(server), name="Tablet")
    started = third.start("amma@example.com").json()
    req = third.verify(started["verificationId"], code_for(server, "amma@example.com")).json()
    r = third.register(req)
    assert r.status_code == 409
    body = r.json()
    assert body["code"] == "deviceLimit" and body["swapsLeft"] == 1
    assert {d["name"] for d in body["devices"]} == {"Phone", "Laptop"}
    assert third.register(req, replace=first.session["deviceId"]).status_code == 200
    # The phone that made room is signed out.
    r = first.client.get("/api/v1/library/home", headers=first.auth)
    assert r.status_code == 401 and r.json()["code"] == "revoked"
    # No swaps left this month for removing another device.
    mine = third.client.get("/api/v1/me/devices", headers=third.auth).json()
    assert mine["swapsLeft"] == 0
    other = next(d for d in mine["items"] if not d["current"])
    r = third.client.delete(f"/api/v1/me/devices/{other['id']}", headers=third.auth)
    assert r.status_code == 409 and r.json()["code"] == "swapLimit"
    # Signing this device out is always allowed.
    me = third.session["deviceId"]
    assert third.client.delete(f"/api/v1/me/devices/{me}", headers=third.auth).status_code == 204
    assert third.client.get("/api/v1/me", headers=third.auth).status_code == 401


def test_admin_revokes_and_suspends(server: TestClient) -> None:
    set_up_admin(server)
    phone = join(server, "amma@example.com", invite(server, "amma@example.com"))
    devices = server.get("/api/v1/admin/devices").json()
    assert_matches(devices, "AdminDevices")
    device = devices["items"][0]
    assert device["personName"] and device["status"] == "active"
    person_id = device["personId"]

    r = server.patch(f"/api/v1/admin/people/{person_id}", json={"status": "suspended"})
    assert_matches(r.json(), "AdminPersonDetail")
    r = phone.client.get("/api/v1/library/home", headers=phone.auth)
    assert r.status_code == 401 and r.json()["code"] == "suspended"
    assert phone.refresh().status_code == 401
    assert Phone(away(server)).start("amma@example.com").status_code == 403
    server.patch(f"/api/v1/admin/people/{person_id}", json={"status": "active"})
    assert phone.client.get("/api/v1/library/home", headers=phone.auth).status_code == 200

    r = server.post(f"/api/v1/admin/devices/{device['id']}/revoke")
    assert r.json()["status"] == "revoked"
    r = phone.client.get("/api/v1/library/home", headers=phone.auth)
    assert r.status_code == 401 and r.json()["code"] == "revoked"
    detail = server.get(f"/api/v1/admin/people/{person_id}").json()
    assert detail["person"]["devicesUsed"] == 0
    texts = " ".join(a["text"] for a in detail["activity"])
    assert "signed out" in texts and "suspended" in texts


def test_people_settings(server: TestClient) -> None:
    me = set_up_admin(server)["me"]
    # Hive always keeps an admin.
    r = server.patch(f"/api/v1/admin/people/{me['id']}", json={"role": "member"})
    assert r.status_code == 409
    phone = join(server, "amma@example.com", invite(server, "amma@example.com"))
    pid = server.get("/api/v1/admin/devices").json()["items"][0]["personId"]
    r = server.patch(
        f"/api/v1/admin/people/{pid}",
        json={"name": "Amma", "deviceLimit": 6, "simpleMode": True},
    ).json()
    assert r["person"]["deviceLimit"] == 6 and r["person"]["deviceLimitOverride"]
    assert phone.client.get("/api/v1/me", headers=phone.auth).json()["simpleMode"] is True
    r = server.patch(f"/api/v1/admin/people/{pid}", json={"resetDevices": True}).json()
    assert r["person"]["devicesUsed"] == 0


# ------------------------------------------------------------------ Hive Admin away from home


def test_admin_signs_in_with_email_and_authenticator(server: TestClient) -> None:
    set_up_admin(server)
    browser = away(server)
    assert browser.get("/api/v1/admin/people").status_code == 401

    def email_code() -> tuple[str, str]:
        started = browser.post("/api/v1/admin/session/email", json={"email": "bilal@example.com"})
        assert started.status_code == 200
        return started.json()["verificationId"], code_for(server, "bilal@example.com")

    # No authenticator yet: away from home is refused, with the way to fix it.
    vid, code = email_code()
    r = browser.post(
        "/api/v1/admin/session/email/verify", json={"verificationId": vid, "code": code}
    )
    assert r.status_code == 403 and r.json()["code"] == "authenticatorNeeded"

    # Set it up on the home computer.
    setup = server.post("/api/v1/admin/me/authenticator").json()
    assert_matches(setup, "AuthenticatorSetup")
    assert setup["uri"].startswith("otpauth://totp/")
    assert server.put("/api/v1/admin/me/authenticator", json={"code": "000000"}).status_code in (
        200,
        400,
    )
    secret = setup["secret"]
    # (a code that happens to be right the first time is fine too)
    session = server.get("/api/v1/admin/session").json()
    if not session["me"]["authenticator"]:
        r = server.put("/api/v1/admin/me/authenticator", json={"code": X.totp_now(secret)})
        assert r.status_code == 200 and r.json()["me"]["authenticator"] is True

    # Away: email code plus authenticator code.
    import time

    vid, code = email_code()
    r = browser.post(
        "/api/v1/admin/session/email/verify",
        json={"verificationId": vid, "code": code, "authenticatorCode": "123456"},
    )
    assert r.status_code == 400 or X.totp_now(secret) == "123456"
    r = browser.post(
        "/api/v1/admin/session/email/verify",
        json={
            "verificationId": vid,
            "code": code,
            "authenticatorCode": X.totp_now(secret, time.time() + 30),
        },
    )
    assert r.status_code == 200, r.text
    assert r.json()["signedIn"] and not r.json()["onHomeComputer"]
    assert "hive_admin" in r.headers["set-cookie"] and "HttpOnly" in r.headers["set-cookie"]
    assert browser.get("/api/v1/admin/people").status_code == 200
    # Removing the authenticator only works at home.
    assert browser.delete("/api/v1/admin/me/authenticator").status_code == 403
    assert browser.delete("/api/v1/admin/session").status_code == 204
    assert browser.get("/api/v1/admin/people").status_code == 401

    # A member's address gets the same answer but can't sign in.
    r = browser.post("/api/v1/admin/session/email", json={"email": "nobody@example.com"})
    assert r.status_code == 200


def test_settings_and_email(server: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    set_up_admin(server)
    settings = server.get("/api/v1/admin/settings").json()
    assert_matches(settings, "AdminSettings")
    assert settings["email"]["ready"] is False and settings["devicesPerPerson"] == 4
    r = server.post("/api/v1/admin/settings/email/test").json()
    assert r["ok"] is False and "isn't set up" in r["message"]

    sent: list[tuple[str, str, str]] = []
    monkeypatch.setattr(
        mail, "send", lambda cfg, to, subject, text, home: sent.append((to, subject, text))
    )
    r = server.patch(
        "/api/v1/admin/settings",
        json={
            "homeName": "Nazar home",
            "privateNetworkLink": "https://login.tailscale.com/admin/invite/abc",
            "email": {
                "host": "smtp.gmail.com",
                "port": 587,
                "security": "starttls",
                "username": "hive.home@gmail.com",
                "password": "app password",
                "from": "hive.home@gmail.com",
            },
        },
    ).json()
    assert r["homeName"] == "Nazar home" and r["email"]["ready"] is True
    assert r["email"]["passwordSet"] is True and "password" not in r["email"]
    assert server.post("/api/v1/admin/settings/email/test").json()["ok"] is True
    assert sent[-1][0] == "bilal@example.com"

    # Codes and invites now go by email, and aren't shown in Hive Admin.
    created = server.post("/api/v1/admin/invites", json={"email": "amma@example.com"}).json()
    assert sent[-1][0] == "amma@example.com" and created["code"] in sent[-1][2]
    assert "tailscale.com" in sent[-1][2]
    started = Phone(away(server)).start("amma@example.com", created["code"]).json()
    assert started["emailSent"] is True
    assert server.get("/api/v1/admin/requests").json()["codes"] == []
    assert "Your code to join Nazar home" in sent[-1][2]
    overview = server.get("/api/v1/admin/overview").json()
    assert_matches(overview, "AdminOverview")
    assert overview["emailReady"] is True and overview["developmentKeyActive"] is False


def test_invites_carry_the_private_network_address(
    server: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Opened on the home computer, the page's own address is loopback: no use to
    a phone. Invites carry the Tailscale address instead, until one is saved."""
    from hive.people import admin_api

    monkeypatch.setattr(admin_api, "private_network_ip", lambda: "100.84.12.7")
    r = server.post("http://127.0.0.1:8443/api/v1/admin/invites", json={})
    assert "a=http%3A%2F%2F100.84.12.7%3A8443" in r.json()["joinLink"]
    server.patch("/api/v1/admin/settings", json={"address": "http://hive-pc:8443"})
    r = server.post("http://127.0.0.1:8443/api/v1/admin/invites", json={})
    assert "a=http%3A%2F%2Fhive-pc%3A8443" in r.json()["joinLink"]


def test_first_admin_from_another_computer_with_the_setup_code(server: TestClient, caplog) -> None:
    """A server without a screen (or in Docker): the setup code from Hive's log."""
    other = away(server)
    code = server.app.state.setup_code
    assert code and len(code) == 9 and code[4] == "-"
    body = {"name": "Bilal", "email": "bilal@example.com"}
    assert other.post("/api/v1/admin/setup", json=body).status_code == 403
    wrong = other.post("/api/v1/admin/setup", json={**body, "setupCode": "0000-0000"})
    assert wrong.status_code == 403 and wrong.json()["code"] == "setupCodeNeeded"

    r = other.post(
        "/api/v1/admin/setup", json={**body, "setupCode": code.lower().replace("-", " ")}
    )
    assert r.status_code == 200, r.text
    assert r.json()["signedIn"] and not r.json()["onHomeComputer"]
    assert "hive_admin" in r.headers.get("set-cookie", "").lower() or r.cookies
    # Signed in from there, and the code is used up.
    assert other.get("/api/v1/admin/session").json()["signedIn"] is True
    assert server.app.state.setup_code is None
