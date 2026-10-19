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


def screenshot(name: str) -> None:
    """Save what the emulator shows, for the job's artifacts."""
    with open(f"emulator-{name}.png", "wb") as f:
        subprocess.run(["adb", "exec-out", "screencap", "-p"], stdout=f, check=False, timeout=60)


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


def hide_keyboard() -> None:
    shown = adb("shell", "dumpsys", "input_method", check=False)
    if "mInputShown=true" in shown or "isInputViewShown=true" in shown:
        key("KEYCODE_BACK")
        time.sleep(0.7)


def key(code: str) -> None:
    adb("shell", "input", "keyevent", code)


STEPS: list[str] = []


def step(text: str) -> None:
    STEPS.append(text)
    print(text, flush=True)


def in_front() -> bool:
    focus = adb("shell", "dumpsys", "window", check=False)
    return any(PKG in line for line in focus.splitlines() if "mCurrentFocus" in line)


def launch() -> None:
    out = adb("shell", "am", "start", "-W", "-n", f"{PKG}/.MainActivity", check=False)
    step("launch: " + " ".join(line.strip() for line in out.splitlines() if line.strip())[:200])


def main(apk: str, address: str, dev_key: str) -> None:
    adb("install", "-r", apk)
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "pm", "clear", PKG)
    adb("logcat", "-c")
    time.sleep(2)
    launch()
    for _ in range(10):
        if in_front():
            break
        time.sleep(2)
        launch()
    step(f"in front: {in_front()}")

    find(r"Connect to home", 60)
    # The on-screen keyboard covers the lower field and its toolbar catches
    # taps meant for the app, so it's put away before each tap.
    for i, text in enumerate((address, dev_key)):
        hide_keyboard()
        fields = edit_fields()
        assert len(fields) >= 2, f"expected the address and key fields, found {fields}"
        tap(fields[i])
        time.sleep(0.5)
        adb("shell", "input", "text", text)
    key("KEYCODE_ENTER")
    hide_keyboard()
    step("address and key entered")

    # The test library has Rumours (Fleetwood Mac) and Premam, among others.
    # Search for the album: Home's rows scroll sideways, search doesn't.
    tap(find(r"^Search$", 60))
    time.sleep(1)
    fields = edit_fields()
    assert fields, "no search box"
    tap(fields[0])
    time.sleep(0.5)
    adb("shell", "input", "text", "Premam")
    time.sleep(1.5)
    hide_keyboard()
    tap(into_view(r"^Premam, "))
    # The tab bar and mini player float over the page's lower part: bring the
    # rows up first, since once music plays the screen can't be read (it
    # never settles while the progress moves) and these taps reuse places.
    into_view(r"^Aluva Puzha")
    rows = []
    for title in (r"^Malare|മലരേ", r"^Aluva Puzha"):
        rows.append(find(title, 30))
    screenshot("album")
    step(f"album open, rows at {rows}")

    tap(rows[0])  # play the first song
    time.sleep(4)
    alive()
    step("playing")

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
    step("switched songs without a crash")

    # From outside the app: the lock screen, notification and headphones.
    # "Long Songs" (CI adds it) has songs long enough not to end by themselves.
    open_album("Long Songs", r"^Long One")
    tap(into_view(r"^Long One"))
    time.sleep(4)
    key("KEYCODE_HOME")
    time.sleep(2)
    first = playing_title()
    step(f"in the background, playing {first!r}")
    key("KEYCODE_MEDIA_NEXT")
    second = wait_title(lambda t: t and t != first)
    step(f"after Next: {second!r}")
    assert second == "Long Two", f"Next from outside the app didn't move on (still {second!r})"
    key("KEYCODE_MEDIA_PREVIOUS")
    back = wait_title(lambda t: t == "Long One")
    step(f"after Previous: {back!r}")
    assert back == "Long One", f"Previous from outside the app didn't go back ({back!r})"
    alive()
    step("lock-screen and headphone keys work")


def playing_title() -> str | None:
    """The song the system's media controls show (lock screen, notification)."""
    out = adb("shell", "dumpsys", "media_session", check=False)
    for line in out.splitlines():
        m = re.search(r"metadata:.*description=([^,]+),", line)
        if m:
            return m.group(1).strip()
    return None


def wait_title(ok, timeout: float = 15):
    deadline = time.monotonic() + timeout
    title = None
    while time.monotonic() < deadline:
        title = playing_title()
        if ok(title):
            return title
        time.sleep(0.5)
    return title


def screen_size() -> tuple[int, int]:
    out = adb("shell", "wm", "size")
    sizes = re.findall(r"(\d+)x(\d+)", out)
    w, h = sizes[-1]  # an override, when there is one, comes last
    return int(w), int(h)


def into_view(pattern: str, limit: float = 0.5) -> tuple[int, int]:
    """Scroll until the row is in the top part of the screen, clear of the
    floating tab bar and mini player, and return where it is."""
    w, h = screen_size()
    xy = find(pattern, 30)
    for _ in range(5):
        if xy[1] <= h * limit:
            step(f"{pattern} at y={xy[1]} of {h}")
            return xy
        start = int(h * 0.75)
        distance = xy[1] - int(h * 0.35)
        adb(
            "shell",
            "input",
            "swipe",
            str(w // 2),
            str(start),
            str(w // 2),
            str(max(start - distance, 10)),
            "700",
        )
        time.sleep(1.5)
        xy = find(pattern, 30)
    screenshot("not-in-view")
    raise AssertionError(f"Couldn't scroll {pattern!r} into view: y={xy[1]} of {h}")


def open_album(name: str, first_song: str) -> None:
    if not in_front():
        launch()
    # Paused, the screen settles and can be read.
    key("KEYCODE_MEDIA_PAUSE")
    time.sleep(1.5)
    hide_keyboard()
    tap(find(r"^Search$", 30))
    time.sleep(1)
    fields = edit_fields()
    assert fields, "no search box"
    tap(fields[0])
    adb("shell", "input", "keyevent", "KEYCODE_MOVE_END")
    for _ in range(20):
        adb("shell", "input", "keyevent", "KEYCODE_DEL")
    adb("shell", "input", "text", name.replace(" ", "%s"))
    time.sleep(1.5)
    hide_keyboard()
    tap(into_view(rf"^{re.escape(name)}, "))
    find(first_song, 30)


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
        relevant = [
            line
            for line in log.splitlines()
            if re.search(
                r"flutter|AndroidRuntime|ExoPlayer|AudioService|hivemusic|ActivityTaskManager",
                line,
            )
        ]
        if failure:
            screenshot("failure")
            annotate(
                "Playback test on the emulator",
                f"{failure}\nSteps: {' | '.join(STEPS)}\nFocus now: {in_front()}",
            )
        for p in problems[:4]:
            annotate("Crash while switching songs", p)
        annotate("Device log (last lines)", "\n".join(line[-220:] for line in relevant[-25:]))
        print("\n".join(relevant[-200:]))
        sys.exit(1)
