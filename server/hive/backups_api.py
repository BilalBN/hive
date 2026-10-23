"""M4: Hive Admin → Backups."""

from __future__ import annotations

import re
from typing import Any

from fastapi import APIRouter, HTTPException, Request, Response
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.orm import Session

from hive.auth import AdminDep
from hive.backups import BackupProblem, Backups
from hive.models import AuditEntry

router = APIRouter(prefix="/api/v1/admin/backups", tags=["admin"])


class FolderMove(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)
    from_: str = Field(alias="from", max_length=1024)
    to: str = Field(max_length=1024)


class RestoreBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    folders: list[FolderMove] = Field(default_factory=list, max_length=20)


class SettingsBody(BaseModel):
    model_config = ConfigDict(extra="forbid")
    folder: str | None = Field(None, max_length=1024)
    enabled: bool | None = None
    time: str | None = Field(None, pattern=r"^([01]\d|2[0-3]):[0-5]\d$")
    keep: int | None = Field(None, ge=1, le=90)


def _backups(request: Request) -> Backups:
    return request.app.state.backups


def _audit(request: Request, who, action: str, text: str) -> None:
    actor = who.user.name if who.user else request.app.state.settings.admin_display_name
    with Session(request.app.state.db.engine) as s:
        s.add(
            AuditEntry(
                actor=actor,
                actor_id=who.user.id if who.user else None,
                action=action,
                text=text.format(actor=actor),
            )
        )
        s.commit()


def status_body(request: Request) -> dict[str, Any]:
    b = _backups(request)
    home = b.home
    body: dict[str, Any] = {
        "folder": str(b.folder),
        "enabled": b.enabled,
        "time": b.time,
        "keep": b.keep,
        "running": b.running,
        "items": b.items(),
    }
    if home.get("backup_last_at"):
        body["lastAt"] = home.get("backup_last_at")
    if home.get("backup_last_error"):
        body["lastError"] = home.get("backup_last_error")
    pending = b.pending()
    if pending:
        body["pendingRestore"] = {
            "id": pending["id"],
            "backupAt": pending["backupAt"],
            "stagedAt": pending["stagedAt"],
        }
    restored = home.get("backup_restored")
    if restored:
        name, _, at = restored.partition("|")
        body["restored"] = {"id": name, "at": at}
    return body


@router.get("")
def list_backups(request: Request, who: AdminDep) -> dict[str, Any]:
    return status_body(request)


@router.post("")
async def run_backup(request: Request, who: AdminDep) -> dict[str, Any]:
    b = _backups(request)
    if b.running:
        raise HTTPException(409, "A backup is already being made")
    try:
        item = await run_in_threadpool(b.run, "manual")
    except BackupProblem as e:
        raise HTTPException(503, str(e)) from e
    _audit(request, who, "backup.run", "{actor} made a backup.")
    return item


@router.put("/settings")
def backup_settings(body: SettingsBody, request: Request, who: AdminDep) -> dict[str, Any]:
    try:
        _backups(request).configure(**body.model_dump(exclude_none=True))
    except BackupProblem as e:
        raise HTTPException(422, str(e)) from e
    _audit(request, who, "backup.settings", "{actor} changed the backup settings.")
    return status_body(request)


@router.delete("/restore")
def cancel_restore(request: Request, who: AdminDep) -> dict[str, Any]:
    if _backups(request).pending():
        _backups(request).cancel_restore()
        _audit(request, who, "backup.restore.cancel", "{actor} cancelled a restore.")
    return status_body(request)


@router.post("/{backupId}/restore")
async def restore_backup(
    backupId: str,  # noqa: N803
    request: Request,
    who: AdminDep,
    body: RestoreBody | None = None,
) -> dict[str, Any]:
    b = _backups(request)
    folders = {f.from_: f.to for f in (body.folders if body else []) if f.from_ != f.to}
    try:
        await run_in_threadpool(b.stage_restore, backupId, folders)
    except FileNotFoundError as e:
        raise HTTPException(404, "No such backup") from e
    except BackupProblem as e:
        raise HTTPException(422, str(e)) from e
    when = re.sub(r"^hive-backup-|\.zip$", "", backupId)
    _audit(
        request,
        who,
        "backup.restore",
        f"{{actor}} chose to restore the backup from {when}; it's finished when Hive restarts.",
    )
    return status_body(request)


@router.delete("/{backupId}", status_code=204)
def delete_backup(backupId: str, request: Request, who: AdminDep) -> Response:  # noqa: N803
    try:
        _backups(request).delete(backupId)
    except FileNotFoundError as e:
        raise HTTPException(404, "No such backup") from e
    _audit(request, who, "backup.delete", "{actor} deleted a backup.")
    return Response(status_code=204)
