"""Which language an album is in, worked out at home.

In order of trust: what you set in Hive Admin, the files' language tag, the
online lookup, the script of the titles (Malayalam letters mean Malayalam), and
a folder named after a language ("Music/Hindi/…"). Latin letters alone say
nothing: they could be English or a romanised Indian title.
"""

from __future__ import annotations

import unicodedata
from collections import Counter
from collections.abc import Iterable
from dataclasses import dataclass


@dataclass(frozen=True)
class Language:
    code: str
    name: str
    native: str
    iso3: tuple[str, ...]
    wikidata: str
    script: str | None = None  # translit block name when the script says it


LANGUAGES: dict[str, Language] = {
    lang.code: lang
    for lang in [
        Language("ml", "Malayalam", "മലയാളം", ("mal",), "Q36236", "mlym"),
        Language("hi", "Hindi", "हिन्दी", ("hin",), "Q1568", "deva"),
        Language("ta", "Tamil", "தமிழ்", ("tam",), "Q5885", "taml"),
        Language("te", "Telugu", "తెలుగు", ("tel",), "Q8097", "telu"),
        Language("kn", "Kannada", "ಕನ್ನಡ", ("kan",), "Q33673", "knda"),
        Language("bn", "Bengali", "বাংলা", ("ben",), "Q9610", "beng"),
        Language("pa", "Punjabi", "ਪੰਜਾਬੀ", ("pan",), "Q58635", "guru"),
        Language("gu", "Gujarati", "ગુજરાતી", ("guj",), "Q5137", "gujr"),
        Language("mr", "Marathi", "मराठी", ("mar",), "Q1571"),
        Language("ur", "Urdu", "اردو", ("urd",), "Q1617"),
        Language("sa", "Sanskrit", "संस्कृतम्", ("san",), "Q11059"),
        Language("en", "English", "English", ("eng",), "Q1860"),
        Language("ar", "Arabic", "العربية", ("ara",), "Q13955"),
        Language("fr", "French", "Français", ("fra", "fre"), "Q150"),
        Language("es", "Spanish", "Español", ("spa",), "Q1321"),
        Language("ko", "Korean", "한국어", ("kor",), "Q9176"),
        Language("ja", "Japanese", "日本語", ("jpn",), "Q5287"),
        Language("zxx", "Instrumental", "Instrumental", ("zxx",), "Q22282939"),
    ]
}

_BY_NAME: dict[str, str] = {}
for _l in LANGUAGES.values():
    for _k in (_l.code, _l.name, _l.native, *_l.iso3):
        _BY_NAME[_k.casefold()] = _l.code
_BY_NAME.update({"hindustani": "hi", "bangla": "bn", "no linguistic content": "zxx"})

BY_WIKIDATA = {lang.wikidata: lang.code for lang in LANGUAGES.values()}
_BY_SCRIPT = {lang.script: lang.code for lang in LANGUAGES.values() if lang.script}


def from_tag(value: str | None) -> str | None:
    """A language tag ("mal", "ml", "Malayalam", "മലയാളം", "hin; eng") → code."""
    if not value:
        return None
    for part in value.replace(";", ",").replace("/", ",").split(","):
        code = _BY_NAME.get(part.strip().casefold())
        if code:
            return code
    return None


def from_iso3(value: str | None) -> str | None:
    return _BY_NAME.get((value or "").casefold())


def from_script(texts: Iterable[str | None]) -> str | None:
    """The language whose script most of the letters are in, if one clearly is."""
    from hive.library.translit import script_of

    counts: Counter[str] = Counter()
    latin = 0
    for text in texts:
        for ch in text or "":
            if not ch.isalpha() and unicodedata.category(ch) not in ("Mn", "Mc"):
                continue
            sc = script_of(ch)
            if sc:
                counts[sc] += 1
            elif ch.isascii() or "LATIN" in unicodedata.name(ch, ""):
                latin += 1
            elif "ARABIC" in unicodedata.name(ch, ""):
                counts["arab"] += 1
            elif "HANGUL" in unicodedata.name(ch, ""):
                counts["hang"] += 1
    if not counts:
        return None
    script, n = counts.most_common(1)[0]
    if n < 3:
        return None  # a stray letter or symbol
    # Latin text beside an Indian script is usually the English spelling of the
    # same title ("മലരേ (Malare)"), so the script decides.
    return {"arab": "ar", "hang": "ko", **_BY_SCRIPT}.get(script)


def from_folders(parts: Iterable[str]) -> str | None:
    """A folder named after a language: "Malayalam", "Hindi Songs", "Tamil Hits"."""
    for part in parts:
        for word in part.replace("_", " ").replace("-", " ").split():
            code = _BY_NAME.get(word.casefold())
            if code and code not in ("en",):  # "English" folders are rare and ambiguous
                return code
    return None


def search_words(code: str | None) -> str:
    """Names to index, so searching "malayalam" or "മലയാളം" finds the album."""
    lang = LANGUAGES.get(code or "")
    return f"{lang.name} {lang.native}" if lang else ""
