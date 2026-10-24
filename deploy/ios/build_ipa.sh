#!/bin/bash
# Builds the signed iPhone app on GitHub, once the Apple Developer account's
# details are set. Two ways to reach family iPhones:
#
#  TestFlight (recommended: family members install from the TestFlight app,
#  no cables, no Mac):
#    HIVE_IOS_CERT_P12, HIVE_IOS_CERT_PASSWORD  "Apple Distribution" certificate
#    HIVE_IOS_PROFILE      App Store provisioning profile, base64
#    HIVE_APPLE_TEAM_ID
#    HIVE_ASC_KEY_ID, HIVE_ASC_ISSUER_ID, HIVE_ASC_KEY  App Store Connect API key (.p8 text)
#
#  Ad Hoc (the iPhones registered in the account; an .ipa on the release):
#    the same certificate and team, with HIVE_IOS_PROFILE an Ad Hoc profile,
#    and no HIVE_ASC_* settings.
#
# Writes dist-installer/Hive-<version>.ipa (Ad Hoc) or uploads to TestFlight.
set -euo pipefail
if [ -z "${HIVE_IOS_CERT_P12:-}" ] || [ -z "${HIVE_IOS_PROFILE:-}" ]; then
  echo "::notice title=iPhone app::Not built yet: needs the Apple Developer account (see docs/releasing.md)."
  exit 0
fi
root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
keychain="$work/hive.keychain-db"
security create-keychain -p hive "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p hive "$keychain"
echo "$HIVE_IOS_CERT_P12" | base64 --decode > "$work/cert.p12"
security import "$work/cert.p12" -k "$keychain" -P "$HIVE_IOS_CERT_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k hive "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')

echo "$HIVE_IOS_PROFILE" | base64 --decode > "$work/hive.mobileprovision"
security cms -D -i "$work/hive.mobileprovision" > "$work/profile.plist"
uuid="$(/usr/libexec/PlistBuddy -c 'Print UUID' "$work/profile.plist")"
name="$(/usr/libexec/PlistBuddy -c 'Print Name' "$work/profile.plist")"
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
cp "$work/hive.mobileprovision" "$HOME/Library/MobileDevice/Provisioning Profiles/$uuid.mobileprovision"

if [ -n "${HIVE_ASC_KEY_ID:-}" ]; then method="app-store-connect"; else method="release-testing"; fi
python3 "$root/deploy/ios/manual_signing.py" "$HIVE_APPLE_TEAM_ID" "$name" "Apple Distribution"
cat > "$work/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>$method</string>
  <key>teamID</key><string>$HIVE_APPLE_TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>provisioningProfiles</key><dict><key>dev.hivemusic.hive</key><string>$name</string></dict>
</dict></plist>
PLIST

cd "$root/app"
flutter build ipa --release --export-options-plist="$work/export.plist"
ipa="$(ls build/ios/ipa/*.ipa | head -1)"
version="$(python3 "$root/tools/version.py" | awk '/^server/ {print $2}')"

if [ "$method" = "app-store-connect" ]; then
  mkdir -p "$HOME/.appstoreconnect/private_keys"
  printf '%s' "$HIVE_ASC_KEY" > "$HOME/.appstoreconnect/private_keys/AuthKey_$HIVE_ASC_KEY_ID.p8"
  xcrun altool --upload-app --type ios --file "$ipa" \
    --apiKey "$HIVE_ASC_KEY_ID" --apiIssuer "$HIVE_ASC_ISSUER_ID"
  echo "::notice title=iPhone app::Hive $version sent to TestFlight"
else
  mkdir -p "$root/dist-installer"
  cp "$ipa" "$root/dist-installer/Hive-$version.ipa"
  echo "::notice title=iPhone app::Ad Hoc build Hive-$version.ipa"
fi
