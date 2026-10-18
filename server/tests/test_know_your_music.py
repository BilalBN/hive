"""M1.5 at home: albums grouped by folder, language from tags, scripts and
folders, credits, transliterated search and language filters."""

from __future__ import annotations

import os
import time

from hive.library import languages as L
from hive.library import text as T
from hive.library.translit import romanise

from .audio_fixtures import _flac_tags, _tone
from .conftest import Home, assert_matches, needs_ffmpeg


def test_romanise_common_titles() -> None:
    assert romanise("മലരേ") == ["malare"]
    assert romanise("ആലുവ പുഴ") == ["aluva", "puzha"]
    assert romanise("എന്റെ") == ["ente"]
    assert romanise("तुम ही हो") == ["tum", "hi", "ho"]
    assert romanise("காதல் ரோஜாவே") == ["kathal", "rojave"]
    assert romanise("ಮುಂಗಾರು ಮಳೆ") == ["mungaru", "male"]
    assert romanise("Dreams") == []


def test_sound_keys_meet() -> None:
    assert T.phonetic("kadhal") == T.phonetic("kathal") == T.phonetic("kaadhal")
    assert T.phonetic("neeyum") == T.phonetic("niyum")
    assert T.phonetic("thum") == T.phonetic("tum")


def test_language_from_script_tags_and_folders() -> None:
    assert L.from_script(["മലരേ (Malare)", "Aluva Puzha", "Premam"]) == "ml"
    assert L.from_script(["तुम ही हो"]) == "hi"
    assert L.from_script(["Dreams", "Rumours"]) is None
    assert L.from_tag("mal") == "ml"
    assert L.from_tag("Hindi; English") == "hi"
    assert L.from_tag("xyz") is None
    assert L.from_folders(["Music", "Tamil Hits", "Roja"]) == "ta"
    assert L.from_folders(["Music", "English"]) is None
    assert L.from_folders(["AR Rahman", "OK Kanmani"]) is None  # "AR" isn't Arabic


def _write_soundtrack(home: Home) -> None:
    """A film soundtrack the usual way: one folder, a different singer per
    song, one composer, no album-artist tag, titles in Malayalam only."""
    folder = home.music / "Malayalam" / "Kumbalangi Nights"
    songs = [
        ("01.flac", "ചെരാതുകൾ", "Sithara Krishnakumar"),
        ("02.flac", "ഉയിരിൽ തൊടും", "Sooraj Santhosh, Anne Amie"),
        ("03.flac", "എഴുതാക്കഥ", "Sushin Shyam"),
    ]
    for i, (name, title, singer) in enumerate(songs):
        p = folder / name
        _tone(p, 300 + 37 * i, 2, ["-c:a", "flac"])
        _flac_tags(p, title=title, artist=singer, album="Kumbalangi Nights",
                   composer="Sushin Shyam", lyricist="Anwar Ali",
                   tracknumber=str(i + 1), date="2019")  # fmt: skip
    # An English-titled Hindi album, known only by its folder.
    p = home.music / "Hindi" / "Kal Ho Naa Ho" / "01 Kal Ho Naa Ho.flac"
    _tone(p, 777, 2, ["-c:a", "flac"])
    _flac_tags(p, title="Kal Ho Naa Ho", artist="Sonu Nigam", album="Kal Ho Naa Ho",
               albumartist="Shankar-Ehsaan-Loy", date="2003")  # fmt: skip
    old = time.time() - 600
    for f in [*folder.iterdir(), p]:
        os.utime(f, (old, old))
    home.post("/api/v1/admin/library/scan")
    time.sleep(0.2)
    home.wait()


def _album(home: Home, title: str) -> dict:
    body = home.get("/api/v1/library/albums", params={"limit": 500}).json()
    matches = [a for a in body["items"] if a["title"] == title]
    assert len(matches) == 1, [a["title"] for a in body["items"]]
    return home.get(f"/api/v1/library/albums/{matches[0]['id']}").json()


@needs_ffmpeg
def test_soundtrack_is_one_album_by_its_composer(home: Home) -> None:
    _write_soundtrack(home)
    album = _album(home, "Kumbalangi Nights")
    assert_matches(album, "Album")
    assert len(album["tracks"]) == 3
    assert album["artistName"] == "Sushin Shyam"  # the music director, not one singer
    assert album["language"] == "ml"
    roles = {(c["role"], c["name"]) for c in album["credits"]}
    assert ("composer", "Sushin Shyam") in roles
    assert ("lyricist", "Anwar Ali") in roles
    assert album["tracks"][1]["composer"] == "Sushin Shyam"
    hindi = _album(home, "Kal Ho Naa Ho")
    assert hindi["language"] == "hi"  # from the folder name


@needs_ffmpeg
def test_language_filters_and_list(home: Home) -> None:
    _write_soundtrack(home)
    langs = home.get("/api/v1/library/languages").json()
    assert_matches(langs, "LanguageList")
    codes = {lang["code"]: lang for lang in langs["items"]}
    assert codes["ml"]["nativeName"] == "മലയാളം"
    assert codes["ml"]["albumCount"] == 2  # Premam and Kumbalangi Nights
    assert "hi" in codes

    ml = home.get("/api/v1/library/albums", params={"language": "ml"}).json()
    assert {a["title"] for a in ml["items"]} == {"Premam", "Kumbalangi Nights"}
    songs = home.get("/api/v1/library/tracks", params={"language": "hi", "limit": 50}).json()
    assert {t["title"] for t in songs["items"]} == {"तुम ही हो (Tum Hi Ho)", "Kal Ho Naa Ho"}
    shelf = home.get("/api/v1/library/home", params={"language": "ml"}).json()
    assert {a["title"] for a in shelf["newAtHome"]} == {"Premam", "Kumbalangi Nights"}
    assert home.get("/api/v1/library/albums", params={"language": "Malayalam"}).status_code == 422


@needs_ffmpeg
def test_search_in_english_finds_indian_scripts_and_people(home: Home) -> None:
    _write_soundtrack(home)

    def titles(q: str, **params) -> list[str]:
        r = home.get("/api/v1/library/search", params={"q": q, **params}).json()
        assert_matches(r, "SearchResults")
        return [t["title"] for t in r["tracks"]]

    assert "ചെരാതുകൾ" in titles("cherathukal")
    assert "ഉയിരിൽ തൊടും" in titles("uyiril")
    assert "ഉയിരിൽ തൊടും" in titles("anne amie")  # the second singer
    assert len(titles("anwar ali")) == 3  # lyricist
    r = home.get("/api/v1/library/search", params={"q": "sushin"}).json()
    assert r["artists"][0]["name"] == "Sushin Shyam"
    r = home.get("/api/v1/library/search", params={"q": "malayalam"}).json()
    assert {a["title"] for a in r["albums"]} >= {"Kumbalangi Nights", "Premam"}
    assert titles("cherathukal", language="hi") == []


@needs_ffmpeg
def test_artist_page_by_role(home: Home) -> None:
    _write_soundtrack(home)
    r = home.get("/api/v1/library/search", params={"q": "anwar ali"}).json()
    anwar = [a for a in r["artists"] if a["name"] == "Anwar Ali"][0]
    page = home.get(f"/api/v1/library/artists/{anwar['id']}").json()
    assert_matches(page, "Artist")
    assert page["roles"] == ["lyricist"]
    assert len(page["lyricsFor"]) == 3
    r = home.get("/api/v1/library/search", params={"q": "anne amie"}).json()
    anne = [a for a in r["artists"] if a["name"] == "Anne Amie"][0]
    page = home.get(f"/api/v1/library/artists/{anne['id']}").json()
    assert [a["title"] for a in page["albums"]] == ["Kumbalangi Nights"]
    assert [t["title"] for t in page["topTracks"]] == ["ഉയിരിൽ തൊടും"]
