"""Joins home with an invite in the release APK on an emulator, the whole way:
the first admin is set up and an invite made (as on the home computer), then
the app is wiped and a person types the address and invite code, their email,
and the 6-digit code (read from Hive Admin -> Requests, as email isn't set up
here). Passes when the app shows home connected and the server lists the
device. Runs after android_playback.py, which still uses the development key.

    python3 tools/android_join.py ADDRESS_FOR_THE_PHONE SERVER_URL
"""

from __future__ import annotations

import json
import sys
import time
import urllib.request

import android_playback as phone

EMAIL = "phone@example.com"


def call(server: str, method: str, path: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(
        server + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        text = r.read().decode()
        return json.loads(text) if text else {}


def type_into(field: int, text: str) -> None:
    phone.hide_keyboard()
    fields = phone.edit_fields()
    assert len(fields) > field, f"expected at least {field + 1} text fields, found {fields}"
    phone.tap(fields[field])
    time.sleep(0.5)
    phone.adb("shell", "input", "keyevent", "KEYCODE_MOVE_END")
    for _ in range(40):
        phone.adb("shell", "input", "keyevent", "KEYCODE_DEL")
    phone.adb("shell", "input", "text", text.replace(" ", "%s"))


def main(address: str, server: str) -> None:
    call(server, "POST", "/api/v1/admin/setup", {"name": "CI admin", "email": "admin@example.com"})
    invite = call(server, "POST", "/api/v1/admin/invites", {"email": EMAIL, "name": "Phone"})
    phone.step("admin set up, invite made")

    phone.adb("shell", "am", "force-stop", phone.PKG)
    phone.adb("shell", "pm", "clear", phone.PKG)
    phone.adb("logcat", "-c")
    time.sleep(2)
    phone.launch()
    for _ in range(10):
        if phone.in_front():
            break
        time.sleep(2)
        phone.launch()
    phone.find(r"Connect to home", 60)
    type_into(0, address)
    type_into(1, invite["code"])
    phone.key("KEYCODE_ENTER")
    phone.hide_keyboard()
    phone.find(r"^Join ", 30)
    phone.step("invite accepted")

    type_into(0, EMAIL)
    phone.hide_keyboard()
    phone.tap(phone.find(r"^Send me a code$", 30))
    phone.find(r"Ask for your code|Check your email", 30)
    codes = call(server, "GET", "/api/v1/admin/requests")["codes"]
    code = next(c["code"] for c in codes if c["email"] == EMAIL)
    phone.step("code shown in Hive Admin")

    type_into(0, code)
    phone.hide_keyboard()
    phone.find(r"Connected to home", 45)
    phone.step("joined: home connected")

    devices = call(server, "GET", "/api/v1/admin/devices")["items"]
    assert any(d["personName"] == "Phone" for d in devices), f"no device for Phone: {devices}"
    phone.alive()
    phone.step("the device is listed in Hive Admin")


if __name__ == "__main__":
    try:
        main(*sys.argv[1:3])
        failure = None
    except Exception as e:  # noqa: BLE001 - report everything the same way
        failure = e
    if failure:
        phone.screenshot("join-failure")
        log = phone.adb("logcat", "-d", check=False)
        relevant = [
            line[-220:]
            for line in log.splitlines()
            if "flutter" in line or "AndroidRuntime" in line or "hivemusic" in line
        ]
        phone.annotate(
            "Joining with an invite on the emulator",
            f"{failure}\nSteps: {' | '.join(phone.STEPS)}",
        )
        phone.annotate("Device log (last lines)", "\n".join(relevant[-25:]))
        sys.exit(1)
