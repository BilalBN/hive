"""English spellings of Indian-script words, so typing "malare" finds "മലരേ".

Devanagari, Bengali, Gurmukhi, Gujarati, Tamil, Telugu, Kannada and
Malayalam share one layout inside their Unicode blocks, so one table of
offsets romanises all of them, the way people type song names on a phone
keyboard rather than strict scholarly transliteration: long vowels are written
short ("malare", not "malarē"), and a few letters follow each language's habit
(Malayalam ത is "th", Hindi त is "t"; Hindi drops the final inherent "a",
so तुम is "tum").

Search then compares a looser "sound key" of both sides (see text.phonetic),
which absorbs most remaining spelling differences.
"""

from __future__ import annotations

# Unicode block starts.
BLOCKS = {
    "deva": 0x0900,
    "beng": 0x0980,
    "guru": 0x0A00,
    "gujr": 0x0A80,
    "taml": 0x0B80,
    "telu": 0x0C00,
    "knda": 0x0C80,
    "mlym": 0x0D00,
}

INDEPENDENT_VOWELS = {
    0x05: "a", 0x06: "a", 0x07: "i", 0x08: "i", 0x09: "u", 0x0A: "u",
    0x0B: "ru", 0x0C: "lu", 0x0D: "e", 0x0E: "e", 0x0F: "e", 0x10: "ai",
    0x11: "o", 0x12: "o", 0x13: "o", 0x14: "au", 0x60: "ru", 0x61: "lu",
}  # fmt: skip

CONSONANTS = {
    0x15: "k", 0x16: "kh", 0x17: "g", 0x18: "gh", 0x19: "ng",
    0x1A: "ch", 0x1B: "chh", 0x1C: "j", 0x1D: "jh", 0x1E: "nj",
    0x1F: "t", 0x20: "th", 0x21: "d", 0x22: "dh", 0x23: "n",
    0x24: "th", 0x25: "th", 0x26: "d", 0x27: "dh", 0x28: "n", 0x29: "n",
    0x2A: "p", 0x2B: "ph", 0x2C: "b", 0x2D: "bh", 0x2E: "m",
    0x2F: "y", 0x30: "r", 0x31: "r", 0x32: "l", 0x33: "l", 0x34: "zh",
    0x35: "v", 0x36: "sh", 0x37: "sh", 0x38: "s", 0x39: "h",
    # Devanagari nukta letters.
    0x58: "q", 0x59: "kh", 0x5A: "g", 0x5B: "z", 0x5C: "r", 0x5D: "rh", 0x5E: "f", 0x5F: "y",
}  # fmt: skip

VOWEL_SIGNS = {
    0x3E: "a", 0x3F: "i", 0x40: "i", 0x41: "u", 0x42: "u", 0x43: "ru", 0x44: "ru",
    0x46: "e", 0x47: "e", 0x48: "ai", 0x4A: "o", 0x4B: "o", 0x4C: "au",
    0x62: "lu", 0x63: "lu",
}  # fmt: skip

VIRAMA = 0x4D
ANUSVARA = 0x02
VISARGA = 0x03
CANDRABINDU = 0x01

# Malayalam chillu letters: a consonant with no vowel.
CHILLU = {
    0x7A: "n", 0x7B: "n", 0x7C: "r", 0x7D: "l", 0x7E: "l", 0x7F: "k",
    0x54: "m", 0x55: "y", 0x56: "zh",
}  # fmt: skip

# Per-script habits.
DENTAL_T = {"deva": "t", "beng": "t", "guru": "t", "gujr": "t"}  # elsewhere "th"
ANUSVARA_AS = {"deva": "n", "beng": "ng", "guru": "n", "gujr": "n"}  # elsewhere "m"
INHERENT = {"beng": "o"}  # elsewhere "a"
DROPS_FINAL_SCHWA = {"deva", "guru", "gujr", "beng"}


def script_of(ch: str) -> str | None:
    cp = ord(ch)
    for name, start in BLOCKS.items():
        if start <= cp < start + 0x80:
            return name
    return None


def romanise_word(word: str) -> str | None:
    """Latin spelling of one word in an Indian script, or None if it has none."""
    out: list[str] = []
    pending_inherent = False
    script = None
    for ch in word:
        sc = script_of(ch)
        if sc is None:
            if ch in "‌‍":  # zero-width (non-)joiners shape letters only
                continue
            if pending_inherent:
                out.append(INHERENT.get(script or "", "a"))
                pending_inherent = False
            out.append(ch)
            continue
        script = sc
        off = ord(ch) - BLOCKS[sc]
        if off in CONSONANTS:
            if pending_inherent:
                out.append(INHERENT.get(sc, "a"))
            letter = CONSONANTS[off]
            if off in (0x24, 0x25) and sc in DENTAL_T:
                letter = DENTAL_T[sc] if off == 0x24 else "th"
            out.append(letter)
            pending_inherent = True
        elif off in VOWEL_SIGNS:
            out.append(VOWEL_SIGNS[off])
            pending_inherent = False
        elif off == VIRAMA:
            pending_inherent = False
            if sc == "mlym":
                out.append("\0")  # a final Malayalam virama sounds as "u"
        elif off in INDEPENDENT_VOWELS:
            if pending_inherent:
                out.append(INHERENT.get(sc, "a"))
                pending_inherent = False
            out.append(INDEPENDENT_VOWELS[off])
        elif sc == "mlym" and off in CHILLU:
            if pending_inherent:
                out.append("a")
                pending_inherent = False
            out.append(CHILLU[off])
        elif off in (ANUSVARA, CANDRABINDU):
            if pending_inherent:
                out.append(INHERENT.get(sc, "a"))
                pending_inherent = False
            out.append("\1" + ANUSVARA_AS.get(sc, "m"))
        elif off == VISARGA:
            if pending_inherent:
                out.append(INHERENT.get(sc, "a"))
                pending_inherent = False
            out.append("h")
        # Nukta, length marks, accents, digits and the rest add no letters.
    if script is None:
        return None
    if pending_inherent and script not in DROPS_FINAL_SCHWA:
        out.append(INHERENT.get(script, "a"))
    text = "".join(out)
    if script == "mlym":
        # ന്റ is "nt" and റ്റ is "tt" ("ente", "kaattu").
        text = text.replace("n\0r", "nt").replace("r\0r", "tt")
    # Anusvara: "m" before p, b, m; "n" before other consonants (ಮುಂಗಾರು →
    # "mungaru"); the script's habit at the end of a word.
    parts = text.split("\1")
    text = parts[0]
    for rest in parts[1:]:
        # Each part starts with the script's default nasal ("m", "n" or "ng").
        nasal = "ng" if rest.startswith("ng") else rest[:1]
        after = rest[len(nasal) :]
        nxt = after[:1]
        if nxt and nxt in "pbm":
            nasal = "m"
        elif nxt and nxt not in "aeiou":
            nasal = "n"
        text += nasal + after
    # Malayalam virama: "u" at the end of a word, silent inside it.
    if text.endswith("\0"):
        text = text[:-1] + "u"
    text = text.replace("\0", "")
    return text or None


def romanise(text: str) -> list[str]:
    """Latin spellings of each Indian-script word in [text]."""
    words: list[str] = []
    for raw in text.split():
        r = romanise_word(raw)
        if r:
            words.append(r)
    return words
