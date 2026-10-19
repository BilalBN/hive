"""Secrets: hashing codes and tokens, device signatures, authenticator codes.

Nothing secret is stored as given: email codes, invite codes, request tokens,
refresh tokens and admin session cookies are kept only as keyed hashes, so a
copy of the database can't be used to sign in.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import secrets
import struct
import time
from urllib.parse import quote

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

# Codes people type: no 0/O, 1/I/L.
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def new_token(nbytes: int = 32) -> str:
    return secrets.token_urlsafe(nbytes)


def keyed_hash(pepper: bytes, value: str) -> str:
    return hmac.new(pepper, value.encode(), hashlib.sha256).hexdigest()


def same(a: str, b: str) -> bool:
    return hmac.compare_digest(a, b)


def six_digits() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


def invite_code() -> str:
    """HIVE-7K2Q-9MXP: easy to read out and type."""
    groups = ["".join(secrets.choice(CODE_ALPHABET) for _ in range(4)) for _ in range(2)]
    return "HIVE-" + "-".join(groups)


def normalise_invite(code: str) -> str:
    """What people type, the way codes are made: upper case, dashes, no spaces."""
    text = "".join(ch for ch in code.upper() if ch.isalnum())
    if text.startswith("HIVE"):
        text = text[4:]
    if len(text) != 8:
        return code.strip().upper()
    return f"HIVE-{text[:4]}-{text[4:]}"


# ------------------------------------------------------------------ devices


def valid_public_key(text: str) -> bool:
    try:
        raw = unb64(text)
    except (ValueError, TypeError):
        return False
    if len(raw) != 32:
        return False
    try:
        Ed25519PublicKey.from_public_bytes(raw)
    except ValueError:
        return False
    return True


def signature_ok(public_key: str, message: str, signature: str) -> bool:
    try:
        key = Ed25519PublicKey.from_public_bytes(unb64(public_key))
        key.verify(unb64(signature), message.encode())
        return True
    except (InvalidSignature, ValueError, TypeError):
        return False


# ------------------------------------------------------------------ authenticator apps


def totp_secret() -> str:
    return base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")


def _hotp(secret: str, counter: int) -> str:
    key = base64.b32decode(secret + "=" * (-len(secret) % 8), casefold=True)
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    value = struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF
    return f"{value % 1_000_000:06d}"


def totp_now(secret: str, at: float | None = None) -> str:
    return _hotp(secret, int((at if at is not None else time.time()) // 30))


def totp_check(
    secret: str, code: str, last_step: int | None, at: float | None = None
) -> int | None:
    """The time step the code belongs to (one step either side is allowed for
    clock drift), or None. A step already used is refused."""
    step = int((at if at is not None else time.time()) // 30)
    for candidate in (step, step - 1, step + 1):
        if last_step is not None and candidate <= last_step:
            continue
        if hmac.compare_digest(_hotp(secret, candidate), code):
            return candidate
    return None


def totp_uri(secret: str, account: str, issuer: str) -> str:
    label = quote(f"{issuer}:{account}")
    return f"otpauth://totp/{label}?secret={secret}&issuer={quote(issuer)}&digits=6&period=30"
