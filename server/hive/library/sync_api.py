"""M4: continuity. The device that's playing reports what it's playing; the
person's other devices offer to carry on from there ("Continue from Bilal's
MacBook"). One session per person, kept with the server's settings so it
survives a restart. Changes reach the person's other open devices over a
WebSocket at /api/v1/sync/events; they also ask when they open.

Only the person's own devices see it.

M6: moving playback between devices and using a phone as a remote. Each open
app says which device it is when it connects; GET /devices lists the
person's devices that are open now and what each is playing, and a command
(play, pause, next, previous, seek, volume, or load a queue to play there)
reaches one of them over its WebSocket."""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
from datetime import UTC, datetime, timedelta
from typing import Any

from fastapi import APIRouter, Request, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select

from hive.auth import Caller, CallerDep, current_caller
from hive.library.api import SessionDep
from hive.library.views import iso, track_summaries
from hive.models import Track
from hive.people.service import Problem

log = logging.getLogger("hive.sync")
router = APIRouter(prefix="/api/v1/sync", tags=["sync"])

MAX_QUEUE = 200
OFFER_HOURS = 12  # an older session isn't offered


class Source(BaseModel):
    model_config = ConfigDict(extra="forbid")
    kind: str = Field(max_length=16)
    id: str = Field(max_length=64)
    name: str = Field(max_length=200)


class SessionBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    installId: str = Field(min_length=8, max_length=64)  # noqa: N815
    deviceName: str = Field(min_length=1, max_length=80)  # noqa: N815
    trackId: str | None = Field(None, max_length=32)  # noqa: N815 — None: stopped
    positionMs: int = Field(0, ge=0)  # noqa: N815
    playing: bool = False
    queue: list[str] = Field(default_factory=list, max_length=MAX_QUEUE)
    index: int = Field(0, ge=0)
    source: Source | None = None


class Listeners:
    """Open WebSockets by person: (install id, socket), each device's name,
    and what each last said it was playing (M6)."""

    def __init__(self) -> None:
        self.by_user: dict[str, set[tuple[str, WebSocket]]] = {}
        self.names: dict[tuple[str, str], str] = {}
        self.states: dict[tuple[str, str], dict[str, Any]] = {}

    def add(self, user_id: str, install: str, ws: WebSocket, name: str = "") -> None:
        self.by_user.setdefault(user_id, set()).add((install, ws))
        if name:
            self.names[(user_id, install)] = name[:80]

    def remove(self, user_id: str, install: str, ws: WebSocket) -> None:
        self.by_user.get(user_id, set()).discard((install, ws))

    def online(self, user_id: str) -> list[str]:
        seen: list[str] = []
        for install, _ in self.by_user.get(user_id, ()):
            if install and install not in seen:
                seen.append(install)
        return sorted(seen)

    async def send_to(self, user_id: str, install: str, message: dict[str, Any]) -> bool:
        text = json.dumps(message)
        sent = False
        for i, ws in list(self.by_user.get(user_id, ())):
            if i != install:
                continue
            with contextlib.suppress(Exception):
                await ws.send_text(text)
                sent = True
        return sent

    async def tell(self, user_id: str, except_install: str, message: dict[str, Any]) -> None:
        text = json.dumps(message)
        for install, ws in list(self.by_user.get(user_id, ())):
            if install == except_install:
                continue
            # A closed socket is removed when it disconnects.
            with contextlib.suppress(Exception):
                await ws.send_text(text)


listeners = Listeners()


def _key(user_id: str) -> str:
    return f"play_session:{user_id}"


def _stored(request_or_ws, caller: Caller) -> dict[str, Any] | None:
    raw = request_or_ws.app.state.people.home.get(_key(caller.user_id))
    return json.loads(raw) if raw else None


def session_body(s, caller: Caller, stored: dict[str, Any] | None) -> dict[str, Any]:
    if not stored or not stored.get("trackId"):
        return {}
    updated = datetime.fromisoformat(stored["updatedAt"].replace("Z", "+00:00"))
    ids = stored["queue"] or [stored["trackId"]]
    found = {t.id: t for t in s.scalars(select(Track).where(Track.id.in_(set(ids))))}
    queue = [found[i] for i in ids if i in found]
    if stored["trackId"] not in found:
        return {}  # the song has gone from home since
    summaries = track_summaries(s, caller, queue)
    index = next((n for n, t in enumerate(queue) if t.id == stored["trackId"]), 0)
    at = stored.get("index")
    if at is not None and 0 <= at < len(queue) and queue[at].id == stored["trackId"]:
        index = at
    position = stored["positionMs"]
    if stored["playing"]:
        # Still playing: where it is by now, as far as home knows.
        position += int((datetime.now(UTC) - updated).total_seconds() * 1000)
        position = min(position, found[stored["trackId"]].duration_ms)
    body: dict[str, Any] = {
        "installId": stored["installId"],
        "deviceName": stored["deviceName"],
        "track": summaries[index],
        "positionMs": position,
        "playing": stored["playing"],
        "queue": summaries,
        "index": index,
        "updatedAt": iso(updated),
        "offer": datetime.now(UTC) - updated < timedelta(hours=OFFER_HOURS),
    }
    if stored.get("source"):
        body["source"] = stored["source"]
    return body


@router.get("/session")
def get_play_session(request: Request, caller: CallerDep, s: SessionDep) -> dict[str, Any]:
    return {"session": body} if (body := session_body(s, caller, _stored(request, caller))) else {}


@router.put("/session")
async def update_play_session(
    body: SessionBody, request: Request, caller: CallerDep, s: SessionDep
) -> dict[str, Any]:
    stored = body.model_dump()
    stored["updatedAt"] = iso(datetime.now(UTC))
    if body.trackId is None:
        previous = _stored(request, caller)
        # Stopped: keep where it was, as no longer playing, for the offer.
        if previous and previous.get("installId") == body.installId:
            previous.update(playing=False, updatedAt=previous["updatedAt"])
            stored = previous
        else:
            return get_play_session(request, caller, s)
    request.app.state.people.home.set(_key(caller.user_id), json.dumps(stored))
    out = session_body(s, caller, stored)
    await listeners.tell(caller.user_id, body.installId, {"type": "session", "session": out})
    # M6: what this device is playing, for remotes.
    now = body.model_dump()
    now["updatedAt"] = iso(datetime.now(UTC))
    listeners.states[(caller.user_id, body.installId)] = now
    listeners.names[(caller.user_id, body.installId)] = body.deviceName
    device = _device(s, caller, body.installId)
    await listeners.tell(caller.user_id, body.installId, {"type": "device", "device": device})
    return {"session": out} if out else {}


# ------------------------------------------------------------------ M6: devices and remotes


def _device(s, caller: Caller, install: str) -> dict[str, Any]:
    name = listeners.names.get((caller.user_id, install)) or "Another device"
    body: dict[str, Any] = {"installId": install, "deviceName": name, "playing": False}
    state = listeners.states.get((caller.user_id, install))
    if state and state.get("trackId"):
        track = s.get(Track, state["trackId"])
        if track is not None:
            updated = datetime.fromisoformat(state["updatedAt"].replace("Z", "+00:00"))
            position = state["positionMs"]
            if state["playing"]:
                position += int((datetime.now(UTC) - updated).total_seconds() * 1000)
            body.update(
                playing=bool(state["playing"]),
                track=track_summaries(s, caller, [track])[0],
                positionMs=min(position, track.duration_ms),
                updatedAt=state["updatedAt"],
            )
    return body


@router.get("/devices")
def list_devices(caller: CallerDep, s: SessionDep) -> dict[str, Any]:
    """The person's devices with Hive open now, and what each is playing."""
    return {"items": [_device(s, caller, i) for i in listeners.online(caller.user_id)]}


class CommandBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    action: str = Field(pattern="^(play|pause|next|previous|seek|volume|load)$")
    fromInstall: str = Field(min_length=8, max_length=64)  # noqa: N815
    positionMs: int | None = Field(None, ge=0)  # noqa: N815
    volume: float | None = Field(None, ge=0, le=1)
    queue: list[str] | None = Field(None, max_length=MAX_QUEUE)
    index: int | None = Field(None, ge=0)
    playing: bool | None = None
    source: Source | None = None


@router.post("/devices/{installId}/command")
async def command_device(
    installId: str,  # noqa: N803
    body: CommandBody,
    caller: CallerDep,
    s: SessionDep,
) -> dict[str, Any]:
    """Tell one of the person's open devices to do something. "load" plays a
    queue there (moving playback there from another device)."""
    if installId not in listeners.online(caller.user_id):
        raise Problem(409, "That device isn't open any more")
    if body.action == "seek" and body.positionMs is None:
        raise Problem(422, "Say where to seek to")
    if body.action == "volume" and body.volume is None:
        raise Problem(422, "Say how loud")
    command: dict[str, Any] = {"action": body.action}
    if body.action == "load":
        if not body.queue:
            raise Problem(422, "Say what to play")
        found = {t.id: t for t in s.scalars(select(Track).where(Track.id.in_(set(body.queue))))}
        tracks = [found[i] for i in body.queue if i in found]
        if not tracks:
            raise Problem(422, "Those songs aren't at home any more")
        command["queue"] = track_summaries(s, caller, tracks)
        command["index"] = min(body.index or 0, len(tracks) - 1)
        command["playing"] = True if body.playing is None else body.playing
        if body.source:
            command["source"] = body.source.model_dump()
    for key in ("positionMs", "volume"):
        if getattr(body, key) is not None:
            command[key] = getattr(body, key)
    message = {
        "type": "command",
        "from": body.fromInstall,
        "fromName": listeners.names.get((caller.user_id, body.fromInstall)) or "Another device",
        "command": command,
    }
    if not await listeners.send_to(caller.user_id, installId, message):
        raise Problem(409, "That device isn't open any more")
    return {"sent": True}


@router.websocket("/events")
async def sync_events(ws: WebSocket, install: str = "", name: str = "") -> None:
    """The person's other devices playing: a message on every change.
    Sign in as for any call (the Authorization header)."""
    try:
        caller = current_caller(ws)  # type: ignore[arg-type]  # same headers and client as a request
    except Problem:
        await ws.close(code=4401)
        return
    await ws.accept()
    listeners.add(caller.user_id, install, ws, name)
    await listeners.tell(caller.user_id, install, {"type": "devices"})
    try:
        while True:
            # Nothing to receive; a ping now and then keeps the connection open.
            try:
                await asyncio.wait_for(ws.receive_text(), timeout=30)
            except TimeoutError:
                await ws.send_text(json.dumps({"type": "ping"}))
    except WebSocketDisconnect:
        pass
    finally:
        listeners.remove(caller.user_id, install, ws)
        if install not in listeners.online(caller.user_id):
            listeners.states.pop((caller.user_id, install), None)
            await listeners.tell(caller.user_id, install, {"type": "devices"})
