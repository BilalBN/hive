"""Resumable uploads from Hive Admin (tus 1.0)."""

from __future__ import annotations

import base64

import pytest

from hive.library.uploads import safe_relative

from .conftest import Home, away, needs_ffmpeg

TUS = {"Tus-Resumable": "1.0.0"}


def _meta(**kv: str) -> str:
    return ",".join(f"{k} {base64.b64encode(v.encode()).decode()}" for k, v in kv.items())


def _create(home: Home, length: int, **meta: str):
    return home.post(
        "/api/v1/admin/uploads",
        headers={
            **home.auth,
            **TUS,
            "Upload-Length": str(length),
            "Upload-Metadata": _meta(**meta),
        },
    )


def _patch(home: Home, location: str, offset: int, data: bytes):
    return home.client.patch(
        location,
        content=data,
        headers={
            **home.auth,
            **TUS,
            "Upload-Offset": str(offset),
            "Content-Type": "application/offset+octet-stream",
        },
    )


@needs_ffmpeg
def test_upload_in_chunks_resume_and_scan(home: Home) -> None:
    data = home.paths["dreams"].read_bytes()
    # A different file, so it isn't skipped as a duplicate.
    data = home.paths["okkanmani"].read_bytes()
    r = _create(
        home,
        len(data),
        filename="Mental.flac",
        relativePath="AR Rahman/OK Kanmani 2/01 Mental.flac",
    )
    assert r.status_code == 201, r.text
    location = r.headers["location"]
    assert r.headers["tus-resumable"] == "1.0.0"

    half = len(data) // 2
    r = _patch(home, location, 0, data[:half])
    assert r.status_code == 204 and r.headers["upload-offset"] == str(half)

    # The connection drops; the browser asks where to resume.
    r = home.client.head(location, headers={**home.auth, **TUS})
    assert r.status_code == 200
    assert r.headers["upload-offset"] == str(half)
    assert r.headers["upload-length"] == str(len(data))

    assert _patch(home, location, 0, data[:10]).status_code == 409  # wrong offset
    r = _patch(home, location, half, data[half:])
    assert r.status_code == 204 and r.headers["upload-offset"] == str(len(data))

    dest = (
        home.client.app.state.settings.uploads_path
        / "AR Rahman"
        / "OK Kanmani 2"
        / "01 Mental.flac"
    )
    assert dest.read_bytes() == data
    home.wait()
    status = home.get("/api/v1/admin/library/imports").json()
    dupes = [i for i in status["duplicates"] if "Mental" in i["path"]]
    # Same bytes as a song already in the library: skipped, and said so.
    assert dupes and dupes[0]["problem"].startswith("Same file as")


def test_upload_refuses_non_audio_and_unsafe_names(home_client) -> None:
    client = home_client
    key = client.app.state.dev_key
    auth = {"Authorization": f"Bearer {key}", **TUS}
    r = client.post(
        "/api/v1/admin/uploads",
        headers={**auth, "Upload-Length": "10", "Upload-Metadata": _meta(filename="notes.exe")},
    )
    assert r.status_code == 415
    r = client.post(
        "/api/v1/admin/uploads",
        headers={**auth, "Upload-Length": "10", "Upload-Metadata": _meta(filename="a.flac")},
    )
    assert r.status_code == 201
    r = client.post("/api/v1/admin/uploads", headers={**auth, "Upload-Length": "10"})
    assert r.status_code == 400
    r = client.post(
        "/api/v1/admin/uploads",
        headers={
            "Authorization": f"Bearer {key}",
            "Upload-Length": "10",
            "Upload-Metadata": _meta(filename="a.flac"),
        },  # fmt: skip
    )
    assert r.status_code == 412
    # Away from the home computer, Hive Admin needs an admin session.
    r = away(client).post("/api/v1/admin/uploads", headers={**TUS, "Upload-Length": "10"})
    assert r.status_code == 401


def test_cancel_upload(home_client) -> None:
    client = home_client
    auth = {"Authorization": f"Bearer {client.app.state.dev_key}", **TUS}
    r = client.post(
        "/api/v1/admin/uploads",
        headers={**auth, "Upload-Length": "100", "Upload-Metadata": _meta(filename="a.mp3")},
    )
    loc = r.headers["location"]
    assert client.delete(loc, headers=auth).status_code == 204
    assert client.head(loc, headers=auth).status_code == 404


@pytest.mark.parametrize(
    ("name", "expected"),
    [
        ("../../etc/passwd.flac", "etc/passwd.flac"),
        ("Album\\..\\..\\x.mp3", "Album/x.mp3"),
        ("a<b>:c?.flac", "a_b__c_.flac"),
        ("/abs/path/song.flac", "abs/path/song.flac"),
    ],
)
def test_safe_relative(name: str, expected: str) -> None:
    assert safe_relative(name).as_posix() == expected
