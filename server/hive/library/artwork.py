"""Cover art: stored once per distinct image, resized on request and cached."""

from __future__ import annotations

import hashlib
import io
import logging
import os
from pathlib import Path

from PIL import Image, UnidentifiedImageError

log = logging.getLogger("hive.artwork")

SIZES = (96, 192, 300, 600, 1200)
# Keep a reasonable master; giant scans are shrunk once on the way in.
MASTER_MAX = 1600


class ArtworkStore:
    def __init__(self, artwork_dir: Path, cache_dir: Path) -> None:
        self.dir = artwork_dir
        self.cache = cache_dir / "artwork"

    def master(self, artwork_id: str) -> Path:
        return self.dir / artwork_id[:2] / f"{artwork_id}.jpg"

    def save(self, data: bytes) -> str | None:
        """Store an image; returns its id, or None if it isn't a readable image."""
        artwork_id = hashlib.sha256(data).hexdigest()[:24]
        target = self.master(artwork_id)
        if target.is_file():
            return artwork_id
        try:
            with Image.open(io.BytesIO(data)) as im:
                im = _rgb(im)
                if max(im.size) > MASTER_MAX:
                    im.thumbnail((MASTER_MAX, MASTER_MAX), Image.Resampling.LANCZOS)
                target.parent.mkdir(parents=True, exist_ok=True)
                tmp = target.with_suffix(".part")
                im.save(tmp, "JPEG", quality=90, optimize=True)
                os.replace(tmp, target)
        except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError) as e:
            log.info("ignoring unreadable cover art: %s", e)
            return None
        return artwork_id

    def sized(self, artwork_id: str, size: int) -> Path | None:
        """The image at this size (never enlarged), cached; None if unknown."""
        if not artwork_id.isalnum():
            return None
        master = self.master(artwork_id)
        if not master.is_file():
            return None
        size = min(SIZES, key=lambda s: abs(s - size))
        out = self.cache / artwork_id[:2] / f"{artwork_id}-{size}.jpg"
        if out.is_file():
            return out
        with Image.open(master) as im:
            if max(im.size) <= size:
                return master
            im = _rgb(im)
            im.thumbnail((size, size), Image.Resampling.LANCZOS)
            out.parent.mkdir(parents=True, exist_ok=True)
            tmp = out.with_suffix(".part")
            im.save(tmp, "JPEG", quality=85, optimize=True, progressive=size >= 600)
            os.replace(tmp, out)
        return out


def _rgb(im: Image.Image) -> Image.Image:
    if im.mode in ("RGB", "L"):
        return im.convert("RGB")
    if im.mode in ("RGBA", "LA", "P"):
        im = im.convert("RGBA")
        bg = Image.new("RGB", im.size, (0, 0, 0))
        bg.paste(im, mask=im.split()[-1])
        return bg
    return im.convert("RGB")
