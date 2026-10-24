# Hive on F-Droid (M6)

F-Droid only publishes free software, built from source on its own
servers. Hive's Android app qualifies once two things are taken out, which
`tools/fdroid_prepare.py` does for the F-Droid build:

- **The QR scanner** (the `mobile_scanner` plugin uses Google's ML Kit).
  People join by typing the invite's address and code instead.
- **Shazam** (Apple's ShazamKit library, which is never in the repository
  anyway). Listen knows the songs at home, as without Shazam.

CI builds that version on every change ("Build Android for F-Droid") and
checks the APK contains no Google ML Kit, Play Services or Firebase code.

## The store listing

`fastlane/metadata/android/en-US/`: title, short and full description,
icon, screenshots (from the app's screenshot tests) and a changelog per
version code (`changelogs/<versionCode>.txt`). F-Droid reads these from the
repository.

## Getting Hive into F-Droid (you, once)

1. Make a release tag (`docs/releasing.md`), e.g. `v0.4.0`.
2. Make a GitLab account, fork https://gitlab.com/fdroid/fdroiddata, add
   `docs/fdroid/dev.hivemusic.hive.yml` as `metadata/dev.hivemusic.hive.yml`
   (update `versionName`, `versionCode` and `commit` to the release), and
   open a merge request titled "New app: Hive". Their reviewers build it
   and may ask questions; answers about the server: it's self-hosted, free
   software in the same repository.
3. After that, new tags are picked up automatically (`UpdateCheckMode: Tags`).

Phones with the F-Droid build can't install the GitHub APK over it (it's
signed by F-Droid), and the other way round; pick one per phone.
