# Making a Hive release

A release is every install file, built on GitHub from one tag and put on the
repository's **Releases** page. The family downloads from there.

## Each release

1. Write what's new in `docs/releases/<version>.md` (the release page shows it).
2. Set the version everywhere and push:
   ```sh
   python3 tools/version.py set 0.4.0
   git commit -am "Hive 0.4.0" && git push
   ```
3. Tag it:
   ```sh
   git tag v0.4.0 && git push origin v0.4.0
   ```
4. GitHub → Actions → *Release* builds everything (about 30 minutes) and
   publishes **Hive 0.4.0** with all the files. To try the workflow without
   publishing, run *Release* by hand (Actions → Release → Run workflow): it
   makes a draft only you can see.

Raise **Hive Admin → Settings → Oldest app allowed** only once the family
has the new apps.

## Signing (once)

Everything is built without these; each piece is signed as soon as its
secrets are added in GitHub → Settings → Secrets and variables → Actions.

### Android: the family's release key

Phones only accept an update signed with the same key as the app they have,
so make this key once and keep a copy somewhere safe (a password manager).
Losing it means everyone reinstalls.

```sh
keytool -genkeypair -v -keystore hive-release.jks -alias hive \
  -keyalg RSA -keysize 4096 -validity 36500
base64 -i hive-release.jks | pbcopy     # copies it, ready to paste
```

| Secret | Value |
| --- | --- |
| `HIVE_ANDROID_KEYSTORE_B64` | the copied text |
| `HIVE_ANDROID_KEYSTORE_PASSWORD` | the keystore password |
| `HIVE_ANDROID_KEY_ALIAS` | `hive` |
| `HIVE_ANDROID_KEY_PASSWORD` | the key password (often the same) |

The apps installed so far are signed with the debug key, so the first
release-signed APK needs Hive uninstalled once on each phone (sign in again
afterwards; downloads are fetched again).

To sign builds on your Mac too, put the same details in
`app/android/key.properties` (never committed):
`storeFile=/path/to/hive-release.jks`, `storePassword=…`, `keyAlias=hive`,
`keyPassword=…`.

### Apple (after joining the Apple Developer Program)

| Secret | What |
| --- | --- |
| `HIVE_APPLE_TEAM_ID` | Membership → Team ID |
| `HIVE_MAC_CERT_P12`, `HIVE_MAC_CERT_PASSWORD` | a *Developer ID Application* certificate exported from Keychain Access as .p12, base64, and its password |
| `HIVE_APPLE_ID`, `HIVE_APPLE_APP_PASSWORD` | your Apple ID and an app-specific password (appleid.apple.com) for notarising |
| `HIVE_IOS_CERT_P12`, `HIVE_IOS_CERT_PASSWORD` | an *Apple Distribution* certificate as .p12, base64, and its password |
| `HIVE_IOS_PROFILE` | the provisioning profile for `dev.hivemusic.hive`, base64: *App Store* for TestFlight, *Ad Hoc* for registered iPhones |
| `HIVE_ASC_KEY_ID`, `HIVE_ASC_ISSUER_ID`, `HIVE_ASC_KEY` | an App Store Connect API key (Users and Access → Integrations), for TestFlight; leave out for Ad Hoc |

With these, the Mac app is signed and notarised (opens without a warning),
and the iPhone app goes to TestFlight: add family members as testers in App
Store Connect and they install Hive from the TestFlight app, no Mac or cable
needed.
