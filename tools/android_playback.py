"""Plays and switches songs in the release APK on an emulator, against a real
Hive server, and fails if the app crashes.

The app is driven like a person would: through what Android's accessibility
layer sees (Flutter labels every button and row), plus the media keys a
headset or the lock screen sends. Crashes and Flutter errors in the device
log become CI annotations.

    python3 tools/android_playback.py APK ADDRESS KEY
"""

from __future__ import annotations

import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

PKG = "dev.hivemusic.hive"
CRASH = re.compile(
    r"FATAL EXCEPTION|Process: dev\.hivemusic\.hive|Fatal signal|Hive error|"
    r"Unhandled Exception|ANR in dev\.hivemusic\.hive"
)


def adb(*args: str, check: bool = True) -> str:
    r = subprocess.run(["adb", *args], check=False, capture_output=True, text=True, timeout=120)
    if check and r.returncode != 0:
        raise RuntimeError(f"adb {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout


def annotate(title: str, text: str) -> None:
    body = text.strip().replace("%", "%25").replace("\r", "").replace("\n", "%0A")
    print(f"::error title={title}::{body[:3000]}")


def screen() -> list[tuple[str, tuple[int, int]]]:
    """(label, centre) for every node on screen that has a label."""
    for _ in range(5):
        out = adb("shell", "uiautomator", "dump", "/sdcard/ui.xml", check=False)
        if "dumped" in out:
            break
        time.sleep(1)  # "could not get idle state" while something animates
    else:
        return []
    xml = adb("shell", "cat", "/sdcard/ui.xml")
    nodes = []
    for n in ET.fromstring(xml).iter("node"):
        label = n.get("content-desc") or n.get("text") or ""
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds", ""))
        if label and m:
            x1, y1, x2, y2 = map(int, m.groups())
            nodes.append((label, ((x1 + x2) // 2, (y1 + y2) // 2)))
    return nodes


def find(pattern: str, timeout: float = 30) -> tuple[int, int]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for label, centre in screen():
            if re.search(pattern, label):
                return centre
        alive()
        time.sleep(1)
    labels = "\n".join(label for label, _ in screen())
    raise AssertionError(f"Nothing on screen matches {pattern!r}. On screen:\n{labels}")


def tap(xy: tuple[int, int]) -> None:
    adb("shell", "input", "tap", str(xy[0]), str(xy[1]))


def edit_fields() -> list[tuple[int, int]]:
    adb("shell", "uiautomator", "dump", "/sdcard/ui.xml", check=False)
    xml = adb("shell", "cat", "/sdcard/ui.xml")
    out = []
    for n in ET.fromstring(xml).iter("node"):
        if n.get("class") == "android.widget.EditText":
            x1, y1, x2, y2 = map(int, re.findall(r"\d+", n.get("bounds", ""))[:4])
            out.append(((x1 + x2) // 2, (y1 + y2) // 2))
    return out


def alive() -> None:
    if not adb("shell", "pidof", PKG, check=False).strip():
        raise AssertionError("The app closed.")


def key(code: str) -> None:
    adb("shell", "input", "keyevent", code)


def main(apk: str, address: str, dev_key: str) -> None:
    adb("install", "-r", apk)
    adb("shell", "pm", "clear", PKG)
    adb("logcat", "-c")
    adb("shell", "am", "start", "-W", "-n", f"{PKG}/.MainActivity")

    find(r"Connect to home", 60)
    fields = edit_fields()
    assert len(fields) >= 2, f"expected the address and key fields, found {fields}"
    tap(fields[0])
    adb("shell", "input", "text", address)
    tap(fields[1])
    adb("shell", "input", "text", dev_key)
    key("KEYCODE_ENTER")
    print("connected")

    # The test library has Rumours (Fleetwood Mac) and Premam, among others.
    tap(find(r"^Album: .*Premam", 60))
    rows = []
    for title in (r"^Malare|മലരേ", r"^Aluva Puzha"):
        rows.append(find(title, 30))
    print("album open")

    tap(rows[0])  # play the first song
    time.sleep(4)
    alive()
    print("playing")

    # Switching the way people do: another song in the list, quickly again,
    # the mini player's Next, headset / lock-screen keys, and letting short
    # songs run into each other (gapless hand-over).
    tap(rows[1])
    time.sleep(0.4)
    tap(rows[0])
    time.sleep(3)
    alive()
    for _ in range(3):
        key("KEYCODE_MEDIA_NEXT")
        time.sleep(1.5)
        alive()
    key("KEYCODE_MEDIA_PREVIOUS")
    key("KEYCODE_MEDIA_PREVIOUS")
    time.sleep(2)
    alive()
    tap(rows[1])
    time.sleep(0.2)
    key("KEYCODE_MEDIA_NEXT")
    time.sleep(0.2)
    key("KEYCODE_MEDIA_NEXT")
    time.sleep(8)  # the test songs are a few seconds long: let them run on
    alive()
    print("switched songs without a crash")


if __name__ == "__main__":
    try:
        main(*sys.argv[1:4])
        failure = None
    except Exception as e:  # noqa: BLE001 - report everything the same way
        failure = e
    log = adb("logcat", "-d", check=False)
    problems = [
        "\n".join(log.splitlines()[i : i + 12])
        for i, line in enumerate(log.splitlines())
        if CRASH.search(line)
    ]
    if problems or failure:
        if failure:
            annotate("Playback test on the emulator", str(failure))
        for p in problems[:4]:
            annotate("Crash while switching songs", p)
        relevant = [
            line
            for line in log.splitlines()
            if re.search(r"flutter|AndroidRuntime|ExoPlayer|AudioService|hivemusic", line)
        ]
        print("\n".join(relevant[-200:]))
        sys.exit(1)
