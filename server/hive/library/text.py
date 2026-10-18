"""Name keys and search text that work across scripts.

Two spellings of one name should land on the same artist or album:
"A.R. Rahman", "AR Rahman" and "A. R. Rahman" all become "ar rahman"; "Beyoncé"
and "Beyonce" both become "beyonce". Accents are only folded on Latin letters:
in Malayalam or Devanagari the marks are vowels, and dropping them would merge
different words.
"""

from __future__ import annotations

import re
import unicodedata

_PUNCT = re.compile(r"[\s\-_.,;:!?'\"’‘“”/\\|()\[\]{}<>*+=~`^@#$%]+")
_FEAT = re.compile(r"\s+(?:feat\.?|ft\.?|featuring|with)\s+", re.IGNORECASE)
_SPLIT_ARTISTS = re.compile(r"\s*(?:,|;|/|\bx\b|\s+(?:feat\.?|ft\.?|featuring)\s+)\s*", re.I)


def _fold(text: str) -> str:
    """Casefold and drop accents from Latin letters only."""
    out: list[str] = []
    base_is_latin = False
    for ch in unicodedata.normalize("NFKD", text):
        if unicodedata.combining(ch):
            if base_is_latin:
                continue
            out.append(ch)
            continue
        base_is_latin = ord(ch) < 0x0250
        out.append(ch)
    return unicodedata.normalize("NFC", "".join(out)).casefold()


def words(text: str) -> list[str]:
    """Lower-case words with punctuation removed and initials joined ("a r" → "ar")."""
    folded = _fold(text.replace("&", " and "))
    parts = [w for w in _PUNCT.split(folded) if w]
    joined: list[str] = []
    run = ""
    for w in parts:
        if len(w) == 1 and w.isalpha() and w.isascii():
            run += w
            continue
        if run:
            joined.append(run)
            run = ""
        joined.append(w)
    if run:
        joined.append(run)
    return joined


def name_key(text: str) -> str:
    """Key for merging artist and album names that differ only in spelling."""
    w = words(text)
    if len(w) > 1 and w[0] == "the":
        w = w[1:]
    return " ".join(w) or "unknown"


def search_text(*parts: str | None) -> str:
    """Space-separated words of every part, for word-start matching."""
    seen: list[str] = []
    for part in parts:
        if not part:
            continue
        for w in words(part):
            # Also index the pieces of initials so "a r rahman" finds "ar rahman".
            seen.append(w)
    return " " + " ".join(seen) + " "


def query_words(q: str) -> list[str]:
    return words(q)[:8]


def primary_artist(credit: str) -> str:
    """The first credited artist: "Mithoon, Jeet Gannguli" → "Mithoon".

    "&" is kept, because duos like "Simon & Garfunkel" are one artist.
    """
    first = _SPLIT_ARTISTS.split(credit.strip(), maxsplit=1)[0].strip()
    first = _FEAT.split(first, maxsplit=1)[0].strip()
    return first or credit.strip()
