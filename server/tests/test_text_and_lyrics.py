from __future__ import annotations

import pytest

from hive.library.lyrics import parse
from hive.library.text import name_key, primary_artist, search_text
from hive.library.views import audio_format


@pytest.mark.parametrize(
    ("a", "b"),
    [
        ("A.R. Rahman", "AR Rahman"),
        ("A. R. Rahman", "a r rahman"),
        ("Beyoncé", "Beyonce"),
        ("The Beatles", "Beatles"),
        ("Simon & Garfunkel", "Simon and Garfunkel"),
        ("  K.S.  Chithra ", "KS Chithra"),
    ],
)
def test_same_name_key(a: str, b: str) -> None:
    assert name_key(a) == name_key(b)


def test_indic_marks_are_kept() -> None:
    # Vowel signs change the word; they must not be folded away.
    assert name_key("മല") != name_key("മലി")
    assert name_key("तुम") != name_key("तम")


def test_primary_artist() -> None:
    assert primary_artist("Mithoon, Jeet Gannguli") == "Mithoon"
    assert primary_artist("Daft Punk feat. Pharrell Williams") == "Daft Punk"
    assert primary_artist("Simon & Garfunkel") == "Simon & Garfunkel"


def test_search_text_word_starts() -> None:
    assert " malare " in search_text("മലരേ (Malare)")


def test_lrc_parsing() -> None:
    kind, lines = parse("[ti:x]\n[offset:+200]\n[00:01.50][00:10.00]Chorus\n[00:05.2]Verse\n")
    assert kind == "synced"
    assert [(line.time_ms, line.text) for line in lines] == [
        (1300, "Chorus"),
        (5000, "Verse"),
        (9800, "Chorus"),
    ]
    kind, lines = parse("\n\nLine one\n\nLine two\n\n")
    assert kind == "plain"
    assert [line.text for line in lines] == ["Line one", "", "Line two"]
    assert parse(None) == ("none", [])


@pytest.mark.parametrize(
    ("args", "tier", "label"),
    [
        (("flac", True, 44100, 2, 16), "lossless", "Lossless 16/44.1"),
        (("flac", True, 96000, 2, 24), "hires", "Hi-Res 24/96"),
        (("flac", True, 48000, 2, 24), "hires", "Hi-Res 24/48"),
        (("alac", True, 88200, 2, 24), "hires", "Hi-Res 24/88.2"),
        (("mp3", False, 44100, 2, None, 320), "lossy", "MP3 320"),
        (("aac", False, 44100, 2, None, 256), "lossy", "AAC 256"),
    ],
)
def test_badge_labels(args, tier: str, label: str) -> None:
    f = audio_format(*args)
    assert (f["tier"], f["label"]) == (tier, label)


def test_loopback_is_trusted_but_others_need_the_key(client) -> None:
    from fastapi.testclient import TestClient

    r = client.get("/api/v1/admin/development-key")
    assert r.status_code == 401  # the test client isn't on this computer
    local = TestClient(client.app, client=("127.0.0.1", 50000))
    r = local.get("/api/v1/admin/development-key")
    assert r.status_code == 200
    assert r.json()["key"].startswith("hive-dev-")
