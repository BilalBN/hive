"""Draws Hive's app icon for every platform from one design.

The design is admin/public/favicon.svg: a dark hexagon outline on Hive's
accent orange. Android also gets an adaptive icon (vector XML, written by
hand in res/), so only its pre-Android 8 PNGs come from here.

    server/.venv/bin/python tools/gen_app_icons.py
"""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "app"

ACCENT = (0xF2, 0x99, 0x4A, 255)
INK = (0x1C, 0x12, 0x08, 255)
# The hexagon in the favicon's 32-unit box, and its stroke.
HEXAGON = [(16, 7), (23.8, 11.5), (23.8, 20.5), (16, 25), (8.2, 20.5), (8.2, 11.5)]
STROKE = 2.4
SUPERSAMPLE = 4


def _hexagon(draw: ImageDraw.ImageDraw, ox: float, oy: float, scale: float) -> None:
    pts = [(ox + x * scale, oy + y * scale) for x, y in HEXAGON]
    width = STROKE * scale
    for a, b in zip(pts, pts[1:] + pts[:1], strict=True):
        draw.line([a, b], fill=INK, width=round(width))
    r = width / 2
    for x, y in pts:  # round joins
        draw.ellipse([x - r, y - r, x + r, y + r], fill=INK)


def icon(size: int, *, corner: float, inset: float = 0.0, alpha: bool = True) -> Image.Image:
    """[size] px. [corner] radius as a fraction of the tile; [inset] is the
    transparent margin around the tile (macOS draws icons smaller than the
    canvas). Without [alpha] the square is filled to the edges (iOS)."""
    big = size * SUPERSAMPLE
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0) if alpha else ACCENT)
    draw = ImageDraw.Draw(img)
    pad = inset * big
    tile = big - 2 * pad
    if alpha:
        draw.rounded_rectangle([pad, pad, pad + tile - 1, pad + tile - 1], radius=corner * tile, fill=ACCENT)
    _hexagon(draw, pad, pad, tile / 32)
    out = img.resize((size, size), Image.LANCZOS)
    return out if alpha else out.convert("RGB")


def android() -> None:
    res = APP / "android/app/src/main/res"
    for density, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        # Pre-Android 8 launchers show the PNG as is: a rounded tile.
        icon(px, corner=0.22, inset=1 / 24).save(res / f"mipmap-{density}/ic_launcher.png")


def ios() -> None:
    folder = APP / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    contents = json.loads((folder / "Contents.json").read_text())
    for entry in contents["images"]:
        name = entry.get("filename")
        if not name:
            continue
        points = float(entry["size"].split("x")[0])
        scale = int(entry["scale"].rstrip("x"))
        # iOS rounds the corners itself and refuses icons with transparency.
        icon(round(points * scale), corner=0, alpha=False).save(folder / name)


def macos() -> None:
    folder = APP / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for px in (16, 32, 64, 128, 256, 512, 1024):
        # Apple's grid: an 824 px tile with 185 px corners on a 1024 px canvas.
        icon(px, corner=185 / 824, inset=100 / 1024).save(folder / f"app_icon_{px}.png")


def windows() -> None:
    target = APP / "windows/runner/resources/app_icon.ico"
    sizes = [16, 24, 32, 48, 64, 128, 256]
    big = icon(256, corner=0.2, inset=1 / 32)
    big.save(target, sizes=[(s, s) for s in sizes])


if __name__ == "__main__":
    android()
    ios()
    macos()
    windows()
    print("app icons written")
