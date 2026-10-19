"""What Hive Admin does with people: approve, invite, suspend, revoke."""

from __future__ import annotations

import contextlib
from datetime import timedelta
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from hive.models import AccessRequest, AuditEntry, Device, Invite, User
from hive.people import crypto as X
from hive.people import mail
from hive.people.service import (
    UNDO_SECONDS,
    People,
    Problem,
    aware,
    iso,
    name_from_email,
    now,
)


def clean(d: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in d.items() if v is not None}


class Admin:
    """[actor] is the admin acting (their user, or None on the home computer
    before anyone is set up)."""

    def __init__(self, people: People, actor: User | None) -> None:
        self.p = people
        self.actor = actor

    @property
    def actor_name(self) -> str:
        return self.actor.name if self.actor else "The home computer"

    @property
    def actor_id(self) -> str | None:
        return self.actor.id if self.actor else None

    def audit(self, s: Session, action: str, text: str, target_id: str | None = None) -> None:
        self.p.audit(s, action, text, self.actor_name, self.actor_id, target_id)

    # ------------------------------------------------------------ requests
    def request_body(self, r: AccessRequest) -> dict[str, Any]:
        undo = None
        if r.decided_at and r.decided_by not in (None, "invite") and r.device_id is None:
            until = aware(r.decided_at) + timedelta(seconds=UNDO_SECONDS)
            if until > now():
                undo = iso(until)
        return clean(
            {
                "id": r.id,
                "email": r.email,
                "deviceName": r.device_name,
                "platform": r.platform,
                "status": r.status,
                "invited": r.invite_id is not None,
                "existingPerson": bool(r.existing_person),
                "note": r.note,
                "createdAt": iso(r.created_at),
                "decidedAt": iso(r.decided_at),
                "undoUntil": undo,
            }
        )

    def requests(self) -> dict[str, Any]:
        with Session(self.p.db.engine) as s:
            waiting = s.scalars(
                select(AccessRequest)
                .where(AccessRequest.status == "pending", AccessRequest.expires_at > now())
                .order_by(AccessRequest.created_at)
            ).all()
            recent = s.scalars(
                select(AccessRequest)
                .where(AccessRequest.status != "pending")
                .order_by(AccessRequest.decided_at.desc())
                .limit(20)
            ).all()
            return {
                "items": [self.request_body(r) for r in [*waiting, *recent]],
                "codes": self.p.pending_codes(),
            }

    def decide(self, request_id: str, approve: bool, note: str | None, name: str | None) -> dict:
        with self.p.lock, Session(self.p.db.engine) as s:
            r = s.get(AccessRequest, request_id)
            if r is None:
                raise Problem(404, "Not found", "No such request.")
            if r.status != "pending":
                raise Problem(409, "Already decided", f"This request was already {r.status}.")
            if note:
                r.note = note.strip()[:200]
            if approve:
                user = s.scalar(select(User).where(User.email == r.email))
                if user is None:
                    user = User(
                        id=X.new_token(12)[:16],
                        email=r.email,
                        name=(name or "").strip()[:80] or name_from_email(r.email),
                        role="member",
                        note=r.note,
                    )
                    s.add(user)
                    s.flush()
                elif user.status != "active":
                    raise Problem(
                        409, "Access paused", "This person is suspended; reinstate them first."
                    )
                r.user_id = user.id
            r.status = "approved" if approve else "declined"
            r.decided_at, r.decided_by = now(), self.actor_id or "home"
            self.audit(
                s,
                "request.approve" if approve else "request.decline",
                f"{self.actor_name} {'approved' if approve else 'declined'} {r.email} "
                f"on {r.device_name}.",
                r.id,
            )
            s.commit()
            s.refresh(r)
            return self.request_body(r)

    def undo(self, request_id: str) -> dict:
        with self.p.lock, Session(self.p.db.engine) as s:
            r = s.get(AccessRequest, request_id)
            if r is None:
                raise Problem(404, "Not found", "No such request.")
            if self.request_body(r).get("undoUntil") is None:
                raise Problem(409, "Too late to undo", "The 10 seconds have passed.")
            if r.status == "approved" and r.user_id:
                user = s.get(User, r.user_id)
                # A person made by this approval, with no device yet, goes again.
                if (
                    user is not None
                    and not self.p.active_devices(s, user.id)
                    and aware(user.created_at) >= aware(r.decided_at) - timedelta(seconds=2)
                ):
                    s.delete(user)
            r.status, r.user_id, r.decided_at, r.decided_by = "pending", None, None, None
            self.audit(
                s, "request.undo", f"{self.actor_name} undid the decision on {r.email}.", r.id
            )
            s.commit()
            s.refresh(r)
            return self.request_body(r)

    # ------------------------------------------------------------ invites
    def invite_body(self, inv: Invite, extra: dict | None = None) -> dict[str, Any]:
        return clean(
            {
                "id": inv.id,
                "email": inv.email,
                "name": inv.name,
                "role": inv.role,
                "note": inv.note,
                "createdAt": iso(inv.created_at),
                "expiresAt": iso(inv.expires_at),
                "privateNetworkLink": self.p.home.get("private_network_link"),
                **(extra or {}),
            }
        )

    def invites(self) -> dict[str, Any]:
        with Session(self.p.db.engine) as s:
            rows = s.scalars(
                select(Invite)
                .where(
                    Invite.used_at.is_(None),
                    Invite.revoked_at.is_(None),
                    Invite.expires_at > now(),
                )
                .order_by(Invite.created_at.desc())
            ).all()
            return {"items": [self.invite_body(i) for i in rows]}

    def create_invite(self, body: dict[str, Any], address: str) -> dict[str, Any]:
        code = X.invite_code()
        email = (body.get("email") or "").strip().lower() or None
        with self.p.lock, Session(self.p.db.engine) as s:
            inv = Invite(
                id=X.new_token(12)[:16],
                code_hash=self.p.hash(code),
                email=email,
                name=(body.get("name") or "").strip() or None,
                role=body.get("role") or "member",
                note=(body.get("note") or "").strip() or None,
                created_by=self.actor_id,
                expires_at=now() + timedelta(days=int(body.get("days") or 7)),
            )
            s.add(inv)
            self.audit(
                s,
                "invite.create",
                f"{self.actor_name} created an invite"
                + (f" for {email}" if email else "")
                + f" ({inv.role}).",
                inv.id,
            )
            s.commit()
            s.refresh(inv)
            from urllib.parse import quote

            join = f"hive://join?a={quote(address, safe='')}&c={code}"
            out = self.invite_body(inv, {"code": code, "joinLink": join})
        if email and self.p.home.email.ready:
            subject, text = mail.invite_text(
                self.p.home.home_name,
                code,
                join,
                address,
                self.p.home.get("private_network_link"),
            )
            # If it fails, the admin still has the code and QR to share.
            with contextlib.suppress(mail.MailError):
                mail.send(self.p.home.email, email, subject, text, self.p.home.home_name)
        return out

    def revoke_invite(self, invite_id: str) -> None:
        with self.p.lock, Session(self.p.db.engine) as s:
            inv = s.get(Invite, invite_id)
            if inv is None or inv.used_at or inv.revoked_at:
                raise Problem(404, "Not found", "No such invite.")
            inv.revoked_at = now()
            self.audit(s, "invite.revoke", f"{self.actor_name} cancelled an invite.", inv.id)
            s.commit()

    # ------------------------------------------------------------ people
    def person_body(self, s: Session, u: User) -> dict[str, Any]:
        return clean(
            {
                "id": u.id,
                "name": u.name,
                "email": u.email,
                "role": u.role,
                "status": u.status,
                "devicesUsed": len(self.p.active_devices(s, u.id)),
                "deviceLimit": self.p.limit_for(u),
                "deviceLimitOverride": u.device_limit is not None,
                "simpleMode": bool(u.simple_mode),
                "createdAt": iso(u.created_at),
                "lastActiveAt": iso(u.last_active_at),
            }
        )

    def device_body(self, d: Device, person: User | None) -> dict[str, Any]:
        return clean(
            {
                "id": d.id,
                "personId": d.user_id,
                "personName": person.name if person else "",
                "name": d.name,
                "platform": d.platform,
                "appVersion": d.app_version,
                "status": d.status,
                "createdAt": iso(d.created_at),
                "lastSeenAt": iso(d.last_seen_at),
            }
        )

    def people(self) -> dict[str, Any]:
        with Session(self.p.db.engine) as s:
            users = s.scalars(select(User).order_by(User.role, User.name)).all()
            return {"items": [self.person_body(s, u) for u in users]}

    def person(self, person_id: str) -> dict[str, Any]:
        with Session(self.p.db.engine) as s:
            u = s.get(User, person_id)
            if u is None:
                raise Problem(404, "Not found", "No such person.")
            devices = s.scalars(
                select(Device)
                .where(Device.user_id == u.id)
                .order_by(Device.status, Device.created_at.desc())
            ).all()
            device_ids = [d.id for d in devices]
            activity = s.scalars(
                select(AuditEntry)
                .where(
                    (AuditEntry.target_id == u.id)
                    | (AuditEntry.actor_id == u.id)
                    | (AuditEntry.target_id.in_(device_ids))
                )
                .order_by(AuditEntry.at.desc())
                .limit(30)
            ).all()
            return {
                "person": self.person_body(s, u),
                "devices": [self.device_body(d, u) for d in devices],
                "swapsUsed": self.p.swaps_used(s, u.id),
                "swapsPerMonth": self.p.home.swaps_per_month,
                "activity": [audit_body(a) for a in activity],
            }

    def update_person(self, person_id: str, body: dict[str, Any]) -> dict[str, Any]:
        with self.p.lock, Session(self.p.db.engine) as s:
            u = s.get(User, person_id)
            if u is None:
                raise Problem(404, "Not found", "No such person.")
            changes = []
            leaving_admin = (body.get("role") == "member" and u.role == "admin") or (
                body.get("status") == "suspended" and u.role == "admin"
            )
            if leaving_admin:
                admins = s.scalar(
                    select(func.count())
                    .select_from(User)
                    .where(User.role == "admin", User.status == "active", User.id != u.id)
                )
                if not admins:
                    raise Problem(409, "Last admin", "Hive needs at least one admin.")
            if body.get("name"):
                u.name = body["name"].strip()[:80]
                changes.append("renamed")
            if body.get("role") and body["role"] != u.role:
                u.role = body["role"]
                changes.append(f"made {u.role}")
            if body.get("status") and body["status"] != u.status:
                u.status = body["status"]
                changes.append("suspended" if u.status == "suspended" else "reinstated")
            if "deviceLimit" in body:
                u.device_limit = body["deviceLimit"]
                changes.append(
                    f"device limit {u.device_limit}" if u.device_limit else "device limit default"
                )
            if "simpleMode" in body and body["simpleMode"] is not None:
                u.simple_mode = bool(body["simpleMode"])
                changes.append("Simple mode " + ("on" if u.simple_mode else "off"))
            if body.get("resetDevices"):
                for d in self.p.active_devices(s, u.id):
                    d.status, d.revoked_at, d.revoked_by, d.refresh_hash = (
                        "revoked",
                        now(),
                        "reset",
                        None,
                    )
                changes.append("signed out every device")
            if changes:
                self.audit(
                    s,
                    "person.update",
                    f"{self.actor_name} changed {u.name}: {', '.join(changes)}.",
                    u.id,
                )
            s.commit()
        return self.person(person_id)

    # ------------------------------------------------------------ devices
    def devices(self) -> dict[str, Any]:
        with Session(self.p.db.engine) as s:
            rows = s.execute(
                select(Device, User)
                .join(User, User.id == Device.user_id)
                .order_by(Device.status, Device.last_seen_at.desc())
            ).all()
            return {"items": [self.device_body(d, u) for d, u in rows]}

    def revoke_device(self, device_id: str) -> dict[str, Any]:
        with self.p.lock, Session(self.p.db.engine) as s:
            d = s.get(Device, device_id)
            if d is None:
                raise Problem(404, "Not found", "No such device.")
            u = s.get(User, d.user_id)
            if d.status == "active":
                d.status, d.revoked_at, d.revoked_by, d.refresh_hash = (
                    "revoked",
                    now(),
                    "admin",
                    None,
                )
                self.audit(
                    s,
                    "device.revoke",
                    f"{self.actor_name} signed out {u.name if u else 'someone'}'s {d.name}.",
                    d.id,
                )
                s.commit()
            return self.device_body(d, u)

    # ------------------------------------------------------------ audit
    def audit_page(self, offset: int, limit: int, action: str | None) -> dict[str, Any]:
        with Session(self.p.db.engine) as s:
            q = select(AuditEntry)
            if action:
                q = q.where(AuditEntry.action == action)
            total = s.scalar(select(func.count()).select_from(q.subquery()))
            rows = s.scalars(q.order_by(AuditEntry.id.desc()).offset(offset).limit(limit)).all()
            return {"items": [audit_body(a) for a in rows], "total": total, "offset": offset}


def audit_body(a: AuditEntry) -> dict[str, Any]:
    return {
        "id": str(a.id),
        "at": iso(a.at),
        "actor": a.actor,
        "action": a.action,
        "text": a.text,
    }
