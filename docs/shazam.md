# Shazam in Listen (M5)

Listen asks home first. When home doesn't know the song and Shazam is on,
the phone asks Shazam: Apple gets a fingerprint of the sound (never the
sound), and the answer shows as *Identified by Shazam · not in your music
yet* with **Ask to add it**. It's kept in the person's Listen history and
counts under *Shazam* on Hive Admin → Recognition.

## Turning it on

1. Hive Admin → Recognition → **Shazam for songs that aren't at home** → On.
2. **iPhone, iPad, Mac:** in the Apple Developer account, Certificates, IDs &
   Profiles → Identifiers → `dev.hivemusic.hive` → App Services → tick
   **ShazamKit**. Signed builds then reach Shazam (unsigned test builds
   can't, and Listen behaves as if Shazam didn't know the song).
3. **Android:**
   - Keys → **+** → name it "Hive ShazamKit", tick **ShazamKit** → download
     the .p8 file (only once). In Hive Admin → Recognition paste the Team
     ID, the key's ID and the .p8 file's text → **Save**. It stays on the
     home computer; phones get hour-long tokens made from it.
   - The app has to be built with Apple's ShazamKit library: see
     `app/android/app/libs/README.md`. Without it, Android Listen knows the
     songs at home only.

## Checking it

- Shazam off: a song that isn't at home ends on *Not in your music yet*.
- Shazam on: the same song shows *Asking Shazam…*, then its name and **Ask
  to add it**; the request shows on Hive Admin → Requests with the title
  and artist filled in.
