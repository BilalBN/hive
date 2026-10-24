"""Who may use Hive, and how they prove it.

There are no passwords. A person proves their email once (a 6-digit code),
an admin approves them once (or an invite approves them in advance), and each
device then holds its own Ed25519 key. A device's refresh token only works
together with a fresh signature from that key, so a copied token is useless
elsewhere. Access tokens last 15 minutes; every request checks that the
device and the person are still active, so revoking or suspending takes
effect at once.

Hive Admin is open on the home computer itself. Away from it (on the private
network) an admin signs in with an email code plus an authenticator app.
"""

from __future__ import annotations

import logging
import threading
import time
from collections import defaultdict, deque
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import delete, func, select, update
from sqlalchemy.orm import Session

from hive.db import Database
from hive.models import (
    AccessRequest,
    AdminSession,
    AuditEntry,
    Device,
    EmailCode,
    Invite,
    Like,
    PlayCount,
    Playlist,
    RecentContext,
    ServerMeta,
    User,
)
from hive.people import crypto as X
from hive.people import mail
from hive.people.settings import HomeSettings

log = logging.getLogger("hive.people")

DEV_USER_ID = "dev"
CODE_MINUTES = 10
CODE_TRIES = 5
RESEND_SECONDS = 30
CODES_PER_HOUR = 5
REQUEST_DAYS = 7
ACCESS_MINUTES = 15
REFRESH_DAYS = 30
CHALLENGE_SECONDS = 120
ADMIN_SESSION_HOURS = 12
UNDO_SECONDS = 10
SWAP_WINDOW_DAYS = 30


def now() -> datetime:
    return datetime.now(UTC)


def aware(dt: datetime | None) -> datetime | None:
    """SQLite gives back naive times; they're UTC."""
    if dt is None:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=UTC)


def iso(dt: datetime | None) -> str | None:
    dt = aware(dt)
    return dt.isoformat().replace("+00:00", "Z") if dt else None


def mask_email(email: str) -> str:
    local, _, domain = email.partition("@")
    return f"{local[:1]}•••@{domain}" if domain else email


def name_from_email(email: str) -> str:
    local = email.split("@", 1)[0]
    words = [w for w in local.replace(".", " ").replace("_", " ").split() if w.isalpha()]
    return " ".join(w.capitalize() for w in words) or local


class Problem(Exception):
    """An answer the apps show in plain words (becomes a problem+json body)."""

    def __init__(self, status: int, title: str, detail: str | None = None, **extra: Any) -> None:
        super().__init__(detail or title)
        self.status, self.title, self.detail, self.extra = status, title, detail, extra


@dataclass(frozen=True)
class Signed:
    """A person using an app on a registered device."""

    user_id: str
    name: str
    role: str
    device_id: str | None


class People:
    def __init__(self, db: Database, home: HomeSettings) -> None:
        self.db = db
        self.home = home
        self.lock = threading.Lock()
        self._pepper = bytes.fromhex(self._secret("auth_pepper"))
        self.access_secret = bytes.fromhex(self._secret("access_secret"))
        # Codes waiting to be passed on by hand while email isn't set up:
        # {code id: (email, code, purpose, expires)}. Memory only, never saved.
        self.unsent: dict[str, tuple[str, str, str, datetime]] = {}
        self._starts: dict[str, deque[float]] = defaultdict(deque)
        self.resend_seconds = RESEND_SECONDS  # tests turn the waiting off
        self.codes_per_hour = CODES_PER_HOUR
        self.tidy_repeated_devices()

    def tidy_repeated_devices(self) -> int:
        """Devices that joined again before Hive replaced their earlier entry
        (M2) left that entry signed in. Remove an earlier entry with the same
        person, name and platform once it hasn't been seen since the newer
        one joined: that install is gone. Returns how many were removed."""
        removed = 0
        with self.lock, Session(self.db.engine) as s:
            devices = list(
                s.scalars(
                    select(Device).where(Device.status == "active").order_by(Device.created_at)
                )
            )
            newest: dict[tuple[str, str, str], Device] = {}
            for d in reversed(devices):
                key = (d.user_id, d.name, d.platform)
                newer = newest.get(key)
                if newer is None:
                    newest[key] = d
                    continue
                last = aware(d.last_seen_at or d.created_at)
                if last <= aware(newer.created_at):
                    d.status, d.revoked_at, d.revoked_by = "revoked", now(), "replaced"
                    d.refresh_hash = None
                    removed += 1
            if removed:
                self.audit(
                    s,
                    "device.tidy",
                    f"Hive removed {removed} earlier sign-in{'s' if removed != 1 else ''} "
                    "of devices that joined again.",
                    actor="Hive",
                )
                s.commit()
        return removed

    # ------------------------------------------------------------ basics
    def _secret(self, key: str) -> str:
        with Session(self.db.engine) as s:
            row = s.get(ServerMeta, key)
            if row is None:
                row = ServerMeta(key=key, value=X.new_token(32).encode().hex()[:64])
                s.add(row)
                s.commit()
            return row.value

    def hash(self, value: str) -> str:
        return X.keyed_hash(self._pepper, value)

    def audit(
        self,
        s: Session,
        action: str,
        text: str,
        actor: str = "Hive",
        actor_id: str | None = None,
        target_id: str | None = None,
    ) -> None:
        s.add(
            AuditEntry(
                actor=actor, actor_id=actor_id, action=action, text=text, target_id=target_id
            )
        )

    def admin_exists(self, s: Session | None = None) -> bool:
        def ask(s: Session) -> bool:
            return bool(
                s.scalar(
                    select(func.count())
                    .select_from(User)
                    .where(User.role == "admin", User.status == "active")
                )
            )

        if s is not None:
            return ask(s)
        with Session(self.db.engine) as s2:
            return ask(s2)

    def home_user(self) -> User | None:
        """Whose library the home computer itself sees: the first admin."""
        with Session(self.db.engine) as s:
            return s.scalar(
                select(User).where(User.role == "admin").order_by(User.created_at).limit(1)
            )

    def limit_for(self, user: User) -> int:
        return user.device_limit or self.home.devices_per_person

    def active_devices(self, s: Session, user_id: str) -> list[Device]:
        return list(
            s.scalars(
                select(Device)
                .where(Device.user_id == user_id, Device.status == "active")
                .order_by(Device.created_at)
            )
        )

    def swaps_used(self, s: Session, user_id: str) -> int:
        since = now() - timedelta(days=SWAP_WINDOW_DAYS)
        return int(
            s.scalar(
                select(func.count())
                .select_from(Device)
                .where(
                    Device.user_id == user_id,
                    Device.revoked_by == "self",
                    Device.revoked_at >= since,
                )
            )
            or 0
        )

    def swaps_left(self, s: Session, user_id: str) -> int:
        return max(0, self.home.swaps_per_month - self.swaps_used(s, user_id))

    # ------------------------------------------------------------ first admin
    def setup_admin(self, name: str, email: str) -> User:
        email = email.strip().lower()
        with self.lock, Session(self.db.engine) as s:
            if self.admin_exists(s):
                raise Problem(409, "Already set up", "Hive already has an admin.")
            user = s.scalar(select(User).where(User.email == email))
            if user is None:
                user = User(id=X.new_token(12)[:16], email=email, name=name.strip(), role="admin")
                s.add(user)
            else:
                user.role, user.status, user.name = "admin", "active", name.strip()
            s.flush()
            # The music liked and played before M2 (as "dev") becomes theirs.
            for model in (Like, PlayCount, RecentContext):
                s.execute(update(model).where(model.user_id == DEV_USER_ID).values(user_id=user.id))
            s.execute(
                update(Playlist).where(Playlist.owner_id == DEV_USER_ID).values(owner_id=user.id)
            )
            self.audit(
                s,
                "admin.setup",
                f"{user.name} set up Hive Admin on the home computer. "
                "The development key no longer works.",
                actor=user.name,
                actor_id=user.id,
                target_id=user.id,
            )
            s.commit()
            s.refresh(user)
            s.expunge(user)
            return user

    # ------------------------------------------------------------ email codes
    def _limit_starts(self, key: str) -> None:
        q = self._starts[key]
        cutoff = time.monotonic() - 3600
        while q and q[0] < cutoff:
            q.popleft()
        if len(q) >= 20:
            raise Problem(429, "Too many tries", "Try again in an hour.", code="tooMany")
        q.append(time.monotonic())

    def start_code(
        self,
        email: str,
        purpose: str,
        *,
        invite: Invite | None = None,
        device_name: str | None = None,
        platform: str | None = None,
        client: str = "",
        send: bool = True,
    ) -> tuple[EmailCode, bool]:
        """Make a code for [email] and email it. (code row, emailed?)"""
        self._limit_starts(f"ip:{client}")
        email = email.strip().lower()
        with self.lock, Session(self.db.engine) as s:
            recent = s.scalars(
                select(EmailCode)
                .where(
                    EmailCode.email == email,
                    EmailCode.purpose == purpose,
                    EmailCode.created_at >= now() - timedelta(hours=1),
                )
                .order_by(EmailCode.created_at.desc())
            ).all()
            if len(recent) >= self.codes_per_hour:
                raise Problem(
                    429, "Too many codes", "Wait a while before asking again.", code="tooMany"
                )
            gap = timedelta(seconds=self.resend_seconds)
            if recent and aware(recent[0].created_at) > now() - gap:
                wait = self.resend_seconds - int(
                    (now() - aware(recent[0].created_at)).total_seconds()
                )
                raise Problem(
                    429,
                    "Just sent one",
                    "A code was sent a moment ago; check your email.",
                    code="tooMany",
                    retryAfterSeconds=max(1, wait),
                )
            code = X.six_digits()
            row = EmailCode(
                id=X.new_token(12)[:16],
                email=email,
                purpose=purpose,
                code_hash=self.hash(code),
                invite_id=invite.id if invite else None,
                device_name=device_name,
                platform=platform,
                expires_at=now() + timedelta(minutes=CODE_MINUTES),
            )
            s.add(row)
            s.commit()
            s.refresh(row)
            s.expunge(row)
        sent = False
        if send:
            cfg = self.home.email
            if cfg.ready:
                subject, text = mail.code_text(code, self.home.home_name, purpose)
                try:
                    mail.send(cfg, email, subject, text, self.home.home_name)
                    sent = True
                except mail.MailError as e:
                    log.warning("code not emailed: %s", e)
            if not sent:
                # Shown on Hive Admin → Requests, for the admin to pass on.
                self.unsent[row.id] = (email, code, purpose, aware(row.expires_at))
                log.info("email isn't set up: the code is shown in Hive Admin → Requests")
        return row, sent

    def check_code(self, s: Session, code_id: str, code: str, purpose: str) -> EmailCode:
        row = s.get(EmailCode, code_id)
        if row is None or row.purpose != purpose:
            raise Problem(404, "Not found", "Ask for a new code.")
        if row.used_at is not None or aware(row.expires_at) < now():
            raise Problem(410, "Code expired", "Ask for a new code.", code="expired")
        if row.attempts >= CODE_TRIES:
            raise Problem(429, "Too many tries", "Ask for a new code.", code="tooMany")
        if not X.same(row.code_hash, self.hash(code)):
            row.attempts += 1
            s.commit()
            left = CODE_TRIES - row.attempts
            if left <= 0:
                raise Problem(429, "Too many tries", "Ask for a new code.", code="tooMany")
            raise Problem(
                400,
                "Wrong code",
                f"That code isn't right. {left} {'try' if left == 1 else 'tries'} left.",
                attemptsLeft=left,
            )
        row.used_at = now()
        self.unsent.pop(row.id, None)
        return row

    def pending_codes(self) -> list[dict[str, Any]]:
        live = []
        for code_id, (email, code, purpose, expires) in list(self.unsent.items()):
            if expires < now():
                self.unsent.pop(code_id, None)
                continue
            live.append(
                {"email": email, "code": code, "purpose": purpose, "expiresAt": iso(expires)}
            )
        return live

    # ------------------------------------------------------------ joining
    def find_invite(self, s: Session, code: str) -> Invite | None:
        return s.scalar(
            select(Invite).where(Invite.code_hash == self.hash(X.normalise_invite(code)))
        )

    @staticmethod
    def invite_usable(inv: Invite | None) -> bool:
        return bool(
            inv and inv.used_at is None and inv.revoked_at is None and aware(inv.expires_at) > now()
        )

    def start_join(
        self, email: str, invite_code: str | None, device_name: str, platform: str, client: str
    ) -> tuple[EmailCode, bool]:
        email = email.strip().lower()
        invite = None
        with Session(self.db.engine) as s:
            if invite_code:
                invite = self.find_invite(s, invite_code)
                if not self.invite_usable(invite):
                    raise Problem(
                        404,
                        "Invite not valid",
                        "That invite has been used, cancelled or has run out. Ask for a new one.",
                    )
                if invite.email and invite.email != email:
                    raise Problem(
                        403,
                        "Invite for someone else",
                        f"This invite is for {mask_email(invite.email)}.",
                    )
            user = s.scalar(select(User).where(User.email == email))
            if user is not None and user.status == "suspended":
                raise Problem(
                    403,
                    "Access paused",
                    "Your access to this home is paused. Ask whoever runs it.",
                    code="suspended",
                )
            if invite is not None:
                s.expunge(invite)
        return self.start_code(
            email,
            "join",
            invite=invite,
            device_name=device_name,
            platform=platform,
            client=client,
        )

    def verify_join(self, code_id: str, code: str) -> tuple[AccessRequest, str, str | None]:
        """(request, its token, the person's name if known)."""
        token = X.new_token(24)
        with self.lock, Session(self.db.engine) as s:
            row = self.check_code(s, code_id, code, "join")
            email = row.email
            user = s.scalar(select(User).where(User.email == email))
            invite = s.get(Invite, row.invite_id) if row.invite_id else None
            status, existing = "pending", False
            if user is not None and user.status == "active":
                status, existing = "approved", True  # a new device, same person
            elif user is None and self.invite_usable(invite):
                user = User(
                    id=X.new_token(12)[:16],
                    email=email,
                    name=invite.name or name_from_email(email),
                    role=invite.role,
                )
                s.add(user)
                s.flush()
                invite.used_at, invite.used_by = now(), user.id
                status = "approved"
            elif user is not None:
                raise Problem(
                    403,
                    "Access paused",
                    "Your access to this home is paused.",
                    code="suspended",
                )
            req = AccessRequest(
                id=X.new_token(12)[:16],
                token_hash=self.hash(token),
                email=email,
                user_id=user.id if user and status == "approved" else None,
                invite_id=invite.id if invite else None,
                device_name=row.device_name or "A device",
                platform=row.platform or "android",
                status=status,
                existing_person=existing,
                decided_at=now() if status == "approved" else None,
                decided_by="invite" if (status == "approved" and not existing) else None,
                expires_at=now() + timedelta(days=REQUEST_DAYS),
            )
            s.add(req)
            text = {
                "pending": f"{email} asked to join from {req.device_name} ({req.platform}).",
                "approved": (
                    f"{email} added a new device, {req.device_name} ({req.platform})."
                    if existing
                    else f"{email} joined with an invite on {req.device_name}."
                ),
            }[status]
            self.audit(s, "request." + status, text, actor=email, target_id=req.id)
            s.commit()
            s.refresh(req)
            s.expunge(req)
            name = user.name if user is not None and status == "approved" else None
        if status == "pending":
            self._notify_admins()
        return req, token, name

    def _notify_admins(self, note: tuple[str, str] | None = None) -> None:
        """A note to every admin that something is waiting; never who or what."""
        cfg = self.home.email
        if not cfg.ready:
            return
        with Session(self.db.engine) as s:
            admins = s.scalars(
                select(User.email).where(User.role == "admin", User.status == "active")
            ).all()
        subject, text = note or mail.request_note(self.home.home_name)
        for address in admins:
            try:
                mail.send(cfg, address, subject, text, self.home.home_name)
            except mail.MailError as e:
                log.warning("admin note not sent: %s", e)

    def request_for(self, s: Session, request_id: str, token: str) -> AccessRequest:
        req = s.get(AccessRequest, request_id)
        if req is None or not X.same(req.token_hash, self.hash(token)):
            raise Problem(404, "Not found", "Start again with your email.")
        if aware(req.expires_at) < now():
            raise Problem(
                404, "Not found", "This request has run out. Start again with your email."
            )
        return req

    # ------------------------------------------------------------ devices and tokens
    def _issue(self, s: Session, device: Device, user: User) -> dict[str, Any]:
        from hive.auth import sign_ticket

        refresh = X.new_token(32)
        device.refresh_hash = self.hash(refresh)
        device.refresh_expires_at = now() + timedelta(days=REFRESH_DAYS)
        device.last_seen_at = now()
        user.last_active_at = now()
        access, exp = sign_ticket(
            self.access_secret,
            {"k": "access", "u": user.id, "d": device.id},
            ACCESS_MINUTES * 60,
        )
        return {
            "deviceId": device.id,
            "accessToken": access,
            "accessExpiresAt": iso(datetime.fromtimestamp(exp, UTC)),
            "refreshToken": refresh,
            "refreshExpiresAt": iso(device.refresh_expires_at),
            "me": self.me_body(user),
        }

    @staticmethod
    def me_body(user: User) -> dict[str, Any]:
        return {
            "id": user.id,
            "name": user.name,
            "email": user.email,
            "role": user.role,
            "simpleMode": bool(user.simple_mode),
        }

    def device_body(self, d: Device, current: str | None = None) -> dict[str, Any]:
        body: dict[str, Any] = {
            "id": d.id,
            "name": d.name,
            "platform": d.platform,
            "current": d.id == current,
            "createdAt": iso(d.created_at),
        }
        if d.app_version:
            body["appVersion"] = d.app_version
        if d.last_seen_at:
            body["lastSeenAt"] = iso(d.last_seen_at)
        return body

    def register_device(self, body: dict[str, Any]) -> dict[str, Any]:
        if not X.valid_public_key(body["publicKey"]):
            raise Problem(422, "Invalid request", "The device key isn't an Ed25519 public key.")
        with self.lock, Session(self.db.engine) as s:
            req = self.request_for(s, body["requestId"], body["requestToken"])
            if req.status != "approved" or req.user_id is None:
                raise Problem(403, "Not approved yet", "Wait for the admin to approve you.")
            if req.device_id is not None:
                raise Problem(403, "Already used", "Start again with your email.")
            user = s.get(User, req.user_id)
            if user is None or user.status != "active":
                raise Problem(403, "Access paused", "Ask whoever runs this home.", code="suspended")
            # The same phone or computer joining again (reinstalled, or its
            # sign-in reset) replaces its earlier entry instead of sitting
            # beside it, and doesn't count as a device change.
            name = body["name"].strip()[:80]
            for old in self.active_devices(s, user.id):
                if old.name == name and old.platform == body["platform"]:
                    old.status, old.revoked_at, old.revoked_by = "revoked", now(), "replaced"
                    old.refresh_hash = None
                    self.audit(
                        s,
                        "device.replace",
                        f"{user.name} signed in again on {name}; its earlier sign-in was removed.",
                        actor=user.name,
                        actor_id=user.id,
                        target_id=old.id,
                    )
            s.flush()
            devices = self.active_devices(s, user.id)
            if len(devices) >= self.limit_for(user):
                replace = body.get("replaceDeviceId")
                target = next((d for d in devices if d.id == replace), None) if replace else None
                if target is None:
                    raise Problem(
                        409,
                        "All devices in use",
                        f"You're using all {self.limit_for(user)} of your devices. "
                        "Remove one to use this one.",
                        code="deviceLimit",
                        devices=[self.device_body(d) for d in devices],
                        swapsLeft=self.swaps_left(s, user.id),
                    )
                if self.swaps_left(s, user.id) <= 0:
                    raise Problem(
                        409,
                        "No device changes left",
                        "You've changed devices too often this month. Ask whoever runs "
                        "this home to remove one for you.",
                        code="swapLimit",
                    )
                target.status, target.revoked_at, target.revoked_by = "revoked", now(), "self"
                target.refresh_hash = None
                self.audit(
                    s,
                    "device.remove",
                    f"{user.name} removed {target.name} to make room for {body['name']}.",
                    actor=user.name,
                    actor_id=user.id,
                    target_id=target.id,
                )
            device = Device(
                id=X.new_token(12)[:16],
                user_id=user.id,
                name=body["name"].strip()[:80],
                platform=body["platform"],
                app_version=body.get("appVersion"),
                public_key=body["publicKey"],
            )
            s.add(device)
            s.flush()
            req.device_id = device.id
            self.audit(
                s,
                "device.add",
                f"{user.name} signed in on {device.name} ({device.platform}).",
                actor=user.name,
                actor_id=user.id,
                target_id=device.id,
            )
            out = self._issue(s, device, user)
            s.commit()
            return out

    def challenge(self, device_id: str) -> dict[str, Any]:
        with self.lock, Session(self.db.engine) as s:
            d = s.get(Device, device_id)
            if d is None or d.status != "active":
                raise Problem(401, "Signed out", "This device was removed.", code="revoked")
            d.challenge = X.new_token(24)
            d.challenge_expires_at = now() + timedelta(seconds=CHALLENGE_SECONDS)
            s.commit()
            return {"challenge": d.challenge, "expiresAt": iso(d.challenge_expires_at)}

    def refresh(self, body: dict[str, Any]) -> dict[str, Any]:
        with self.lock, Session(self.db.engine) as s:
            d = s.get(Device, body["deviceId"])
            if d is None or d.status != "active":
                raise Problem(401, "Signed out", "This device was removed.", code="revoked")
            user = s.get(User, d.user_id)
            if user is None or user.status != "active":
                raise Problem(401, "Access paused", "Ask whoever runs this home.", code="suspended")
            fresh = (
                d.challenge
                and X.same(d.challenge, body["challenge"])
                and aware(d.challenge_expires_at) > now()
            )
            d.challenge = None  # one use, right or wrong
            if not fresh or not X.signature_ok(d.public_key, body["challenge"], body["signature"]):
                s.commit()
                raise Problem(401, "Sign-in needed", "The device couldn't prove itself.")
            if (
                not d.refresh_hash
                or not X.same(d.refresh_hash, self.hash(body["refreshToken"]))
                or aware(d.refresh_expires_at) < now()
            ):
                s.commit()
                raise Problem(401, "Sign-in needed", "Sign in again with your email.")
            out = self._issue(s, d, user)
            s.commit()
            return out

    def caller_for(self, token: str) -> Signed:
        """The person and device behind an access token, checked against the
        database each time so revoking takes effect at once."""
        from hive.auth import read_ticket

        payload = read_ticket(self.access_secret, token)
        if not payload or payload.get("k") != "access":
            raise Problem(401, "Sign-in needed", "Your sign-in has ended.", code="signInNeeded")
        with Session(self.db.engine) as s:
            d = s.get(Device, payload.get("d"))
            user = s.get(User, payload.get("u"))
            if d is None or d.status != "active" or user is None or d.user_id != user.id:
                raise Problem(401, "Signed out", "This device was removed.", code="revoked")
            if user.status != "active":
                raise Problem(401, "Access paused", "Ask whoever runs this home.", code="suspended")
            stale = d.last_seen_at is None or aware(d.last_seen_at) < now() - timedelta(minutes=5)
            if stale:
                d.last_seen_at = now()
                user.last_active_at = now()
                s.commit()
            return Signed(user.id, user.name, user.role, d.id)

    # ------------------------------------------------------------ the person's own devices
    def my_devices(self, user_id: str, current: str | None) -> dict[str, Any]:
        with Session(self.db.engine) as s:
            user = s.get(User, user_id)
            devices = self.active_devices(s, user_id)
            return {
                "items": [self.device_body(d, current) for d in devices],
                "limit": self.limit_for(user) if user else self.home.devices_per_person,
                "swapsLeft": self.swaps_left(s, user_id),
                "swapsPerMonth": self.home.swaps_per_month,
            }

    def remove_my_device(self, user_id: str, device_id: str, current: str | None) -> None:
        with self.lock, Session(self.db.engine) as s:
            d = s.get(Device, device_id)
            if d is None or d.user_id != user_id or d.status != "active":
                raise Problem(404, "Not found", "That device isn't yours or is already removed.")
            # Signing this device itself out isn't a swap; removing another is.
            if d.id != current and self.swaps_left(s, user_id) <= 0:
                raise Problem(
                    409,
                    "No device changes left",
                    "You've changed devices too often this month. Ask whoever runs this home.",
                    code="swapLimit",
                )
            d.status, d.revoked_at = "revoked", now()
            d.revoked_by = "signout" if d.id == current else "self"
            d.refresh_hash = None
            user = s.get(User, user_id)
            self.audit(
                s,
                "device.remove",
                f"{user.name if user else 'Someone'} removed {d.name}.",
                actor=user.name if user else "Someone",
                actor_id=user_id,
                target_id=d.id,
            )
            s.commit()

    # ------------------------------------------------------------ admin sign-in
    def start_admin_code(self, email: str, client: str) -> dict[str, Any]:
        """The same answer whether or not the address is an admin's."""
        email = email.strip().lower()
        with Session(self.db.engine) as s:
            admin = s.scalar(
                select(User).where(
                    User.email == email, User.role == "admin", User.status == "active"
                )
            )
        row, sent = self.start_code(email, "admin", client=client, send=admin is not None)
        return {
            "verificationId": row.id,
            "expiresAt": iso(row.expires_at),
            "resendAfterSeconds": RESEND_SECONDS,
            "emailSent": sent or admin is None,
        }

    def _admin_session(self, s: Session, user_id: str) -> str:
        cookie = X.new_token(32)
        s.add(
            AdminSession(
                id=self.hash(cookie),
                user_id=user_id,
                expires_at=now() + timedelta(hours=ADMIN_SESSION_HOURS),
            )
        )
        return cookie

    def admin_session_for(self, user_id: str) -> str:
        """A Hive Admin session for [user_id] (the first admin, set up with
        the setup code from another computer)."""
        with Session(self.db.engine) as s:
            cookie = self._admin_session(s, user_id)
            s.commit()
            return cookie

    def verify_admin(self, code_id: str, code: str, authenticator: str | None) -> str:
        """A session cookie value."""
        with self.lock, Session(self.db.engine) as s:
            row = self.check_code(s, code_id, code, "admin")
            user = s.scalar(
                select(User).where(
                    User.email == row.email, User.role == "admin", User.status == "active"
                )
            )
            if user is None:
                s.commit()
                raise Problem(403, "Not an admin", "This address can't sign in to Hive Admin.")
            if not user.totp_secret:
                s.commit()
                raise Problem(
                    403,
                    "Authenticator needed",
                    "Set up an authenticator app first, on the home computer: "
                    "Hive Admin → Settings → Your sign-in.",
                    code="authenticatorNeeded",
                )
            step = (
                X.totp_check(user.totp_secret, authenticator, user.totp_last_step)
                if authenticator
                else None
            )
            if step is None:
                # The email code may be tried again with the right authenticator
                # code, within the same 5 tries.
                row.used_at = None
                row.attempts += 1
                s.commit()
                raise Problem(
                    400,
                    "Wrong authenticator code",
                    "Type the 6-digit code your authenticator app shows for Hive.",
                    code="authenticatorNeeded",
                )
            user.totp_last_step = step
            cookie = self._admin_session(s, user.id)
            self.audit(
                s,
                "admin.signin",
                f"{user.name} signed in to Hive Admin away from the home computer.",
                actor=user.name,
                actor_id=user.id,
                target_id=user.id,
            )
            s.commit()
            return cookie

    def session_user(self, cookie: str | None) -> User | None:
        if not cookie:
            return None
        with Session(self.db.engine) as s:
            row = s.get(AdminSession, self.hash(cookie))
            if row is None or aware(row.expires_at) < now():
                return None
            user = s.get(User, row.user_id)
            if user is None or user.role != "admin" or user.status != "active":
                return None
            s.expunge(user)
            return user

    def end_session(self, cookie: str | None) -> None:
        if not cookie:
            return
        with self.lock, Session(self.db.engine) as s:
            s.execute(delete(AdminSession).where(AdminSession.id == self.hash(cookie)))
            s.commit()
