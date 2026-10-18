#!/usr/bin/env bash
# Checks the macOS disk image the family downloads: the app inside is intact
# (frameworks, symlinks, signature) and actually starts. A broken bundle fails
# at launch with "Hive cannot be opened because of a problem".
set -euo pipefail
trap 'echo "::error title=macOS smoke test::failed at line $LINENO: $BASH_COMMAND"' ERR
DMG="$1"
MNT=$(mktemp -d)
WORK=$(mktemp -d)

hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" >/dev/null
ditto "$MNT/Hive.app" "$WORK/Hive.app"
hdiutil detach "$MNT" >/dev/null

APP="$WORK/Hive.app"
test -f "$APP/Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS" \
  || { echo "::error::FlutterMacOS.framework is broken inside the disk image."; ls -laR "$APP/Contents/Frameworks" | head -40; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"

LOG="$WORK/hive.log"
"$APP/Contents/MacOS/Hive" >"$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 30); do
  grep -q "Hive started" "$LOG" && break
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
if ! kill -0 "$PID" 2>/dev/null; then
  cat "$LOG"
  echo "::error title=The macOS app closed at launch::$(tail -c 1500 "$LOG" | sed ':a;N;$!ba;s/\n/%0A/g')"
  exit 1
fi
kill "$PID" || true
if grep -E "Hive startup failed|Hive error" "$LOG"; then
  echo "::error::The macOS app reported a startup error."
  exit 1
fi
cat "$LOG"
echo "macOS app starts from the disk image."
