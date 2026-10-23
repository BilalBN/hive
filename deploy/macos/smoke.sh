#!/bin/bash
# Installs the built package on this (throwaway) Mac and checks it the way a
# family would use it: Hive starts at sign-in, answers, has FFmpeg, makes
# backups; installing again updates it after a backup; removing Hive keeps
# the data. Used by CI after build.sh.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
pkg="$(ls "$root"/dist-installer/HiveServer-*-mac.pkg | head -1)"
data="$HOME/Library/Application Support/Hive"
music="${RUNNER_TEMP:-/tmp}/HiveMusic"
base="http://127.0.0.1:8443"
app="/Applications/Hive Server"

# Steps and failures also go to GitHub as annotations, readable without the log.
step() { echo "== $1"; echo "::notice title=Mac install test::$1"; }
fail() { echo "::error title=Mac install test::$1"; exit 1; }
wait_for_hive() {
  for _ in $(seq 60); do
    curl -fsS "$base/api/v1/health" && return 0
    sleep 2
  done
  fail "Hive didn't answer within 2 minutes"
}

# No Tailscale on CI machines, so listen on this computer only.
mkdir -p "$data" "$music"
printf 'host = "127.0.0.1"\nmusic_folders = [%s]\n' "'$music'" > "$data/hive.toml"

step "install"
sudo installer -pkg "$pkg" -target / || fail "the installer stopped"
health="$(wait_for_hive)"
echo "$health" | grep -q '"status":"ok"' || fail "health: $health"
launchctl print "gui/$(id -u)/family.hive.server" >/dev/null || fail "Hive doesn't start at sign-in"
[ -f "$HOME/Library/LaunchAgents/family.hive.server.plist" ] || fail "no sign-in item"

step "Hive Admin, FFmpeg and fpcalc"
curl -fsS "$base/admin/" | grep -q "Hive Admin" || fail "Hive Admin isn't served"
library="$(curl -fsS "$base/api/v1/admin/library/imports")"
echo "$library" | grep -q '"ffmpeg":true' || fail "Hive can't find FFmpeg"
echo "$library" | grep -q "$music" || fail "music folder not set"
ls -l "$app/tools" || true
[ -x "$app/tools/fpcalc" ] && "$app/tools/fpcalc" -version

step "a backup from Hive Admin"
curl -fsS -X POST "$base/api/v1/admin/backups" >/dev/null || fail "backup failed"

step "update: install again"
sudo installer -pkg "$pkg" -target / || fail "the update stopped"
ls "$data"/backups/hive-backup-*-before-update.zip >/dev/null 2>&1 || fail "no backup was made before the update"
wait_for_hive >/dev/null
n="$(curl -fsS "$base/api/v1/admin/backups" | grep -o '"id":' | wc -l)"
[ "$n" -ge 2 ] || fail "backups were lost in the update"

step "remove Hive"
"$app/Uninstall Hive.command" || fail "the uninstaller stopped"
sleep 3
[ ! -d "$app" ] || fail "Hive is still in Applications"
launchctl print "gui/$(id -u)/family.hive.server" >/dev/null 2>&1 && fail "Hive still starts at sign-in"
[ -f "$data/server.db" ] || fail "removing Hive deleted its data"
echo "removed; the data stays in $data"
