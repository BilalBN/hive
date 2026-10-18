"""Lyrics from tags or a .lrc file next to the song, synced when timestamped."""

from __future__ import annotations

import re
from dataclasses import dataclass

_STAMP = re.compile(r"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]")
_META = re.compile(r"^\[(?:ar|ti|al|au|by|length|offset|re|ve|#):.*\]\s*$", re.IGNORECASE)
_OFFSET = re.compile(r"^\[offset:\s*([+-]?\d+)\s*\]", re.IGNORECASE | re.MULTILINE)


@dataclass
class Line:
    text: str
    time_ms: int | None = None


def parse(raw: str | None) -> tuple[str, list[Line]]:
    """('synced' | 'plain' | 'none', lines)."""
    if not raw or not raw.strip():
        return "none", []
    offset_match = _OFFSET.search(raw)
    offset = int(offset_match.group(1)) if offset_match else 0
    synced: list[Line] = []
    plain: list[Line] = []
    for row in raw.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if _META.match(row.strip()):
            continue
        stamps = list(_STAMP.finditer(row))
        if stamps:
            text = _STAMP.sub("", row).strip()
            for m in stamps:
                frac = m.group(3) or "0"
                ms = int(frac.ljust(3, "0")[:3])
                t = (int(m.group(1)) * 60 + int(m.group(2))) * 1000 + ms
                # LRC offset: positive means lyrics appear sooner.
                synced.append(Line(text=text, time_ms=max(0, t - offset)))
        else:
            plain.append(Line(text=row.strip()))
    if synced:
        synced.sort(key=lambda line: line.time_ms or 0)
        return "synced", synced
    # Trim blank lines at the ends; keep blank lines between verses.
    while plain and not plain[0].text:
        plain.pop(0)
    while plain and not plain[-1].text:
        plain.pop()
    return ("plain", plain) if plain else ("none", [])
