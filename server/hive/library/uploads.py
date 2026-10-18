"""Resumable uploads from Hive Admin (tus 1.0: creation, HEAD, PATCH, termination).

Chunks are written to ``<data>/uploads-tmp`` so a half-uploaded album never
appears in the library. When the last byte arrives the file moves into the
upload folder (keeping the dropped folder's structure) and is queued for
scanning. A dropped connection resumes from the last saved byte.
"""

from __future__ import annotations

import base64
import json
import os
import re
import secrets
import shutil
import time
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException, Request, Response

from hive.auth import CallerDep
from hive.library.tags import IMAGE_EXTENSIONS, is_audio

router = APIRouter(prefix="/api/v1/admin/uploads", tags=["admin"])

TUS_VERSION = "1.0.0"
_BAD_CHARS = re.compile(r'[<>:"|?*\x00-\x1f]')
STALE_SECONDS = 7 * 24 * 3600


def _tmp_dir(request: Request) -> Path:
    d = request.app.state.settings.data_dir / "uploads-tmp"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _tus_headers(**extra: Any) -> dict[str, str]:
    h = {"Tus-Resumable": TUS_VERSION, "Cache-Control": "no-store"}
    h.update({k.replace("_", "-"): str(v) for k, v in extra.items()})
    return h


def _parse_metadata(header: str | None) -> dict[str, str]:
    meta: dict[str, str] = {}
    if not header:
        return meta
    for pair in header.split(","):
        pair = pair.strip()
        if not pair:
            continue
        key, _, value = pair.partition(" ")
        try:
            meta[key] = base64.b64decode(value).decode("utf-8") if value else ""
        except (ValueError, UnicodeDecodeError) as e:
            raise HTTPException(400, "Upload-Metadata isn't valid") from e
    return meta


def safe_relative(name: str) -> Path:
    """A relative path that stays inside the upload folder on every OS."""
    parts = []
    for raw in re.split(r"[\\/]+", name):
        part = _BAD_CHARS.sub("_", raw).strip().rstrip(".")
        if part in ("", ".", ".."):
            continue
        parts.append(part[:180])
    if not parts:
        raise HTTPException(400, "The file needs a name")
    return Path(*parts[-5:])


def _allowed(rel: Path) -> bool:
    suffix = rel.suffix.lower()
    return is_audio(rel) or suffix in IMAGE_EXTENSIONS or suffix == ".lrc"


def _check_version(request: Request) -> None:
    if request.headers.get("tus-resumable") != TUS_VERSION:
        raise HTTPException(412, "Tus-Resumable 1.0.0 is required")


def _paths(request: Request, upload_id: str) -> tuple[Path, Path]:
    if not re.fullmatch(r"[0-9a-f]{32}", upload_id):
        raise HTTPException(404, "No such upload")
    d = _tmp_dir(request)
    return d / f"{upload_id}.part", d / f"{upload_id}.json"


def _load(meta_path: Path) -> dict[str, Any]:
    try:
        return json.loads(meta_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        raise HTTPException(404, "No such upload") from e


def _clean_stale(request: Request) -> None:
    now = time.time()
    for p in _tmp_dir(request).iterdir():
        try:
            if now - p.stat().st_mtime > STALE_SECONDS:
                p.unlink(missing_ok=True)
        except OSError:
            pass


@router.post("", status_code=201)
def admin_create_upload(request: Request, caller: CallerDep) -> Response:
    _check_version(request)
    settings = request.app.state.settings
    try:
        length = int(request.headers.get("upload-length", ""))
    except ValueError as e:
        raise HTTPException(400, "Upload-Length is required") from e
    if length < 1:
        raise HTTPException(400, "The file is empty")
    if length > settings.upload_max_bytes:
        raise HTTPException(413, "The file is larger than the upload limit")
    meta = _parse_metadata(request.headers.get("upload-metadata"))
    rel = safe_relative(meta.get("relativePath") or meta.get("filename") or "")
    if not _allowed(rel):
        raise HTTPException(415, f"{rel.name} isn't a music file Hive can play")
    _clean_stale(request)
    upload_id = secrets.token_hex(16)
    part, meta_path = _paths(request, upload_id)
    part.touch()
    meta_path.write_text(
        json.dumps({"length": length, "relative": rel.as_posix(), "created": time.time()}),
        encoding="utf-8",
    )
    return Response(
        status_code=201,
        headers=_tus_headers(Location=f"/api/v1/admin/uploads/{upload_id}", Upload_Offset=0),
    )


@router.head("/{uploadId}")
def admin_get_upload_offset(uploadId: str, request: Request, caller: CallerDep) -> Response:  # noqa: N803
    part, meta_path = _paths(request, uploadId)
    meta = _load(meta_path)
    offset = part.stat().st_size if part.exists() else 0
    return Response(
        status_code=200, headers=_tus_headers(Upload_Offset=offset, Upload_Length=meta["length"])
    )


@router.patch("/{uploadId}", status_code=204)
async def admin_append_upload(uploadId: str, request: Request, caller: CallerDep) -> Response:  # noqa: N803
    _check_version(request)
    if (
        request.headers.get("content-type", "").split(";")[0].strip()
        != "application/offset+octet-stream"
    ):
        raise HTTPException(415, "Chunks must be application/offset+octet-stream")
    part, meta_path = _paths(request, uploadId)
    meta = _load(meta_path)
    try:
        offset = int(request.headers.get("upload-offset", ""))
    except ValueError as e:
        raise HTTPException(400, "Upload-Offset is required") from e
    current = part.stat().st_size if part.exists() else 0
    if offset != current:
        raise HTTPException(409, f"Expected offset {current}")
    length = int(meta["length"])
    written = current
    with part.open("ab") as f:
        async for chunk in request.stream():
            if written + len(chunk) > length:
                raise HTTPException(400, "More bytes than Upload-Length")
            f.write(chunk)
            written += len(chunk)
    if written == length:
        dest = _finish(request, part, meta_path, meta)
        library = request.app.state.library
        if is_audio(dest):
            library.enqueue(dest, force=True)
        else:
            library.picture_added(dest.parent)
    return Response(status_code=204, headers=_tus_headers(Upload_Offset=written))


@router.delete("/{uploadId}", status_code=204)
def admin_cancel_upload(uploadId: str, request: Request, caller: CallerDep) -> Response:  # noqa: N803
    part, meta_path = _paths(request, uploadId)
    _load(meta_path)
    part.unlink(missing_ok=True)
    meta_path.unlink(missing_ok=True)
    return Response(status_code=204, headers=_tus_headers())


def _finish(request: Request, part: Path, meta_path: Path, meta: dict[str, Any]) -> Path:
    target_root: Path = request.app.state.settings.uploads_path
    dest = target_root / Path(meta["relative"])
    dest.parent.mkdir(parents=True, exist_ok=True)
    stem, suffix, n = dest.stem, dest.suffix, 2
    while dest.exists():
        dest = dest.with_name(f"{stem} ({n}){suffix}")
        n += 1
    try:
        os.replace(part, dest)
    except OSError:
        shutil.move(str(part), str(dest))  # different drive
    meta_path.unlink(missing_ok=True)
    return dest
