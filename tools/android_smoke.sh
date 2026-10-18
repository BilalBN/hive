#!/usr/bin/env bash
# Installs the release APK on a running emulator, opens it and checks that it
# reaches its first screen. Release builds shrink code with R8, which can break
# plugins in ways no unit test sees; this catches that before a family phone does.
set -euo pipefail
APK="$1"
PKG=dev.hivemusic.hive

adb install -r "$APK"
adb logcat -c
adb shell am start -W -n "$PKG/.MainActivity"

for _ in $(seq 1 60); do
  if adb logcat -d | grep -q "Hive started"; then break; fi
  sleep 2
done

LOG=$(adb logcat -d)
# Our own failure lines, Java errors, and a crash of this app (not other system apps).
PROBLEMS=$(echo "$LOG" | grep -E -A6 "Hive startup failed|Hive error|NoSuchMethodError|Process: $PKG|Fatal signal" | head -40 || true)
if [ -n "$PROBLEMS" ]; then
  echo "$PROBLEMS"
  # Also as an annotation, so it can be read without downloading the log.
  echo "::error title=Release app failed on the emulator::$(echo "$PROBLEMS" | cut -c1-300 | sed ':a;N;$!ba;s/\n/%0A/g')"
  exit 1
fi
if ! echo "$LOG" | grep -q "Hive started"; then
  RELEVANT=$(echo "$LOG" | grep -iE "flutter|hivemusic|AndroidRuntime|libc|DEBUG|ActivityManager.*hive|impeller|vulkan|egl" | tail -40 || true)
  echo "$RELEVANT"
  echo "::error title=Release app never reached its first screen::$(echo "$RELEVANT" | cut -c1-250 | sed ':a;N;$!ba;s/\n/%0A/g')"
  exit 1
fi
if [ -z "$(adb shell pidof "$PKG" | tr -d '\r')" ]; then
  echo "::error::The release app started but then closed."
  exit 1
fi
echo "Release app started on the emulator."
