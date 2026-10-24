#!/bin/bash
# Signs the Hive Mac app with the family's Developer ID and has Apple notarise
# it, so family Macs open it without the "unidentified developer" warning.
# Skipped (with a note) until the Apple Developer account's details are set:
#
#   HIVE_MAC_CERT_P12      the "Developer ID Application" certificate, base64
#   HIVE_MAC_CERT_PASSWORD its password
#   HIVE_APPLE_ID          the Apple ID email used for notarising
#   HIVE_APPLE_APP_PASSWORD an app-specific password for that Apple ID
#   HIVE_APPLE_TEAM_ID     the team ID (10 characters)
#   HIVE_MAC_PROFILE       optional: a Developer ID provisioning profile, base64
#
# Usage: deploy/macos/sign_app.sh path/to/Hive.app
set -euo pipefail
app="$1"
if [ -z "${HIVE_MAC_CERT_P12:-}" ]; then
  echo "::notice title=Mac app::Not signed by Apple yet (no Developer ID set up); right-click → Open the first time."
  exit 0
fi
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
keychain="$work/hive.keychain-db"
security create-keychain -p hive "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p hive "$keychain"
echo "$HIVE_MAC_CERT_P12" | base64 --decode > "$work/cert.p12"
security import "$work/cert.p12" -k "$keychain" -P "$HIVE_MAC_CERT_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k hive "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
identity="$(security find-identity -v -p codesigning "$keychain" | grep 'Developer ID Application' | head -1 | awk '{print $2}')"
[ -n "$identity" ] || { echo "::error title=Mac app::No Developer ID Application certificate in HIVE_MAC_CERT_P12"; exit 1; }

if [ -n "${HIVE_MAC_PROFILE:-}" ]; then
  echo "$HIVE_MAC_PROFILE" | base64 --decode > "$app/Contents/embedded.provisionprofile"
fi

# Inside out: frameworks and helpers first, then the app with its entitlements.
find "$app/Contents" \( -name "*.dylib" -o -name "*.so" \) -type f -print0 |
  xargs -0 -I{} codesign --force --timestamp --options runtime --sign "$identity" {}
for fw in "$app"/Contents/Frameworks/*.framework; do
  [ -d "$fw" ] && codesign --force --timestamp --options runtime --sign "$identity" "$fw"
done
codesign --force --timestamp --options runtime --sign "$identity" \
  --entitlements "$root/app/macos/Runner/Release.entitlements" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

ditto -c -k --keepParent "$app" "$work/Hive.zip"
xcrun notarytool submit "$work/Hive.zip" --apple-id "$HIVE_APPLE_ID" \
  --password "$HIVE_APPLE_APP_PASSWORD" --team-id "$HIVE_APPLE_TEAM_ID" --wait
xcrun stapler staple "$app"
echo "::notice title=Mac app::Signed and notarised by Apple"
