#!/usr/bin/env python3
"""Turns this checkout into the F-Droid build of the Android app: only free
software inside.

- The QR scanner (mobile_scanner uses Google's ML Kit) is taken out; the
  invite's address and code are typed instead.
- Shazam (Apple's ShazamKit library) is never included.

Run from anywhere, before `flutter build apk --dart-define=HIVE_FDROID=true`.
It changes files in place, so use it on a checkout made for the build
(F-Droid's build server, or CI)."""

from __future__ import annotations

import os
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "app"

pubspec = APP / "pubspec.yaml"
text = pubspec.read_text()
text, n = re.subn(r"^\s*mobile_scanner:.*\n", "", text, flags=re.M)
pubspec.write_text(text)
print(f"pubspec.yaml: removed mobile_scanner ({n})")

shutil.copy(APP / "fdroid" / "scan_invite.dart", APP / "lib" / "features" / "connect" / "scan_invite.dart")
print("scan_invite.dart: the version without the camera")

aar = APP / "android" / "app" / "libs" / "shazamkit-android-release.aar"
if aar.exists():
    aar.unlink()
    print("removed Apple's ShazamKit library")

# Generated plugin registrations from a previous build would still name it.
for stale in (APP / ".flutter-plugins", APP / ".flutter-plugins-dependencies"):
    if stale.exists():
        stale.unlink()
os.environ["HIVE_NO_SHAZAM"] = "1"
print("ready for: flutter build apk --release --dart-define=HIVE_FDROID=true")
