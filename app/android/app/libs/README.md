# ShazamKit for Android

Apple's ShazamKit library isn't on a public package registry, so it isn't
in the repository. To build the Android app with Shazam:

1. Sign in at developer.apple.com → ShazamKit → download **ShazamKit for
   Android** (`shazamkit-android-release.aar`).
2. Put it here: `app/android/app/libs/shazamkit-android-release.aar`.
3. Build as usual. The build picks the Shazam code (`src/shazam`) when the
   file is here, and the version without it (`src/noshazam`) otherwise.

For GitHub releases, add the file's base64 as the `HIVE_SHAZAMKIT_AAR_B64`
secret (`base64 -i shazamkit-android-release.aar | pbcopy`).
