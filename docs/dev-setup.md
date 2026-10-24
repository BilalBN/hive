# Run Hive on your Mac (M0 gate)

This gets the server running on your MacBook, the app on the MacBook and your
phone, and proves they talk over the private network. It takes about 30 minutes
the first time.

**The M0 gate:** the app on your phone and on your MacBook both show
**"Connected to home"**.

## 1. Install the tools (once)

| Tool | How |
| --- | --- |
| Homebrew | See [brew.sh](https://brew.sh) |
| Python 3.12+ | `brew install python@3.12` |
| Node 22+ | `brew install node` |
| Flutter | `brew install --cask flutter`, then `flutter doctor` and follow what it asks |
| Xcode | From the App Store; then `sudo xcodebuild -license accept` (needed for the Mac and iPhone apps) |
| Android Studio | Only if your phone is Android: install it, then run `flutter doctor --android-licenses` |
| Tailscale | Install on the MacBook (Mac App Store) **and** on your phone; sign in with the same account on both |

## 2. Get the code

```sh
git clone https://github.com/<you>/hive.git
cd hive
```

## 3. Start the server

```sh
cd server
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"
mkdir -p ../data
cp hive.example.toml ../data/hive.toml   # then edit home_name and admin_display_name
.venv/bin/python -m hive serve
```

With `host = "tailscale"` (the example's setting) the server listens on the Mac
itself and its Tailscale address, and on nothing else. The first lines it prints
include that address, for example:

```
INFO  server  listening on http://100.84.12.7:8443
```

Write down the `100.x.x.x` address; that is "home" for now. Leave this terminal
running.

> If it says no Tailscale address was found, open the Tailscale app and make
> sure it is connected.

## 4. Build the admin panel

In a second terminal:

```sh
cd admin
npm ci
npm run build
```

Open <http://127.0.0.1:8443/admin/>. It should say **Home is running** with your
home name.

## 5. Run the app on the MacBook

Without Flutter installed: download `hive-macos` from the latest GitHub Actions
run, open `Hive-macOS.dmg` and drag **Hive** to **Applications**. It isn't
notarized yet (that needs the Apple Developer account, M5), so clear the
download flag once before opening it:

```sh
xattr -dr com.apple.quarantine /Applications/Hive.app
open /Applications/Hive.app
```

Or, with Flutter installed:

```sh
cd app
flutter run -d macos
```

Type the `100.x.x.x` address and press **Connect**. You should see **Connected
to home**.

## 6. Run the app on your phone

Make sure Tailscale is on, on the phone.

- **Android:** download `hive-android-apk` from the latest GitHub Actions run,
  copy it to the phone and open it (allow installing from this source once;
  uninstall the previous Hive first if Android refuses to update it). Or
  plug the phone in and run `flutter run`.
- **iPhone:** plug it in, open `app/ios/Runner.xcworkspace` in Xcode once to pick
  your Apple ID under *Signing & Capabilities* (a free Apple ID works; the app
  then needs re-installing every 7 days until M5), then run `flutter run`.

Type the same address and press **Connect**. **Connected to home** on both
devices passes the M0 gate.

## M1: play your music

**The M1 gate:** on mobile data away from home, someone searches, plays a
Malayalam album gaplessly with the screen locked, and the badge reads
**High · Bluetooth** on AirPods.

1. **Update the server.** Stop it (Ctrl+C), then:

   ```sh
   git pull
   brew install ffmpeg                  # makes High and Data saver; reads loudness
   cd server && .venv/bin/pip install -e ".[dev]"
   .venv/bin/python -m hive serve
   ```

   It now prints a **development key** (`hive-dev-…`). The apps need it until
   invites arrive in M2. `hive info` prints it again any time.

2. **Point it at your music.** By default it watches `~/Music/Hive`. To use
   other folders, set them in `data/hive.toml` and restart:

   ```toml
   music_folders = ["~/Music/Hive", "/Volumes/Music"]
   ```

   Or drop album folders onto **Hive Admin → Upload**. New files are read
   within a few seconds; **Hive Admin → Library** shows progress and anything
   that needs attention.

3. **Update the admin panel** from the latest run's `hive-admin-dist` (same as
   step 4 above).

4. **Update the apps** from the latest run (`hive-macos`, `hive-android-apk`).
   On first open, type the address **and** the development key from Hive
   Admin → Overview.

5. **Try it:** Search, an album, Now playing (tap the quality badge to see how
   the song reaches you), the queue, lyrics, the lock screen. Then switch Wi-Fi
   off on the phone and keep listening on mobile data.

## M1.5: know your music

**The M1.5 gate:** drop in a folder of untagged Malayalam film songs; within a
few minutes they show as one album with the right cover, under Malayalam, and
searching the lead actor's name finds it.

1. **Update the server** (it needs one new package, so install again):

   ```sh
   git pull
   cd server && .venv/bin/pip install -e ".[dev]"
   .venv/bin/python -m hive serve
   ```

   The first start reads every song once more (composers, lyricists,
   language). Then each album is looked up online, one at a time, about a
   minute per ten albums.

2. **Update the admin panel and the apps** from the latest run, as before.

3. **Hive Admin → Library → Album details from the internet** shows progress
   and what leaves home. **Hive Admin → Albums** lists albums to check
   ("Is this the album?") and lets you correct anything; what you set stays.

4. *Optional:* to recognise songs with no useful tags by their sound, run
   `brew install chromaprint`, get a free key at acoustid.org/new-application
   and paste it under "Recognise songs with no useful tags" on the Library page.

5. **In the app:** language chips on Home, Library and Search; album pages show
   the film, cast and music; search an actor, music director, singer or
   lyricist, in English even for Malayalam or Hindi titles.

### Later additions to M1.5 (19 Oct)

- **Loose songs** (folders like `Uploads/English`, names such as
  `Ee_Puzhayum_-Vijay_Yesudas[www.Mp3MaD.Com].mp3`) are looked up one by one
  and move to their real album, with its cover. Albums that came back
  "Not found" try again with **Look up again**.
- **Lyrics:** Hive Admin → Albums → an album → **Add lyrics** on any song:
  type or paste them (timed LRC lines like `[01:23.45] a line` follow the
  song), or **Find online** (LRCLIB). Songs with no lyrics are also looked up
  on LRCLIB in the background while online lookup is on.
- **Home** has Recently played, Picked for you (a new mix daily), On repeat,
  From the movies and Artists.
- **Duplicate copies** have their own list on the Library page, with Delete
  copy / Keep / Delete all copies; problem files can be ignored.
- After `git pull`, restart the server: the first start reads every song once
  more (quick: unchanged files keep their loudness). No new packages.

## M2: invites, approval and devices

**The M2 gate:** a family member joins with an invite (QR or typed code) and
a code sent to their email, an admin can approve or decline someone without an
invite, and signing a device out in Hive Admin stops it within 15 minutes.

1. **Update the server** (it needs one new package, so install again):

   ```sh
   git pull
   cd server && .venv/bin/pip install -e ".[dev]"
   .venv/bin/python -m hive serve
   ```

2. **Install the new apps first** (app 0.2.0, from the latest run) on every
   device, and the new admin panel. The new apps still work with the
   temporary key until the next step.

3. **Set up the first admin** in Hive Admin on the Mac: Overview → **Set up**
   (your name and email). From now on the temporary key stops working: each
   device joins with its own sign-in. Your likes, plays and playlists so far
   become yours.

4. **Email** (so codes arrive by themselves): Settings → Email → **Use Gmail
   settings**, your Gmail address, and an app password from
   myaccount.google.com/apppasswords (needs 2-Step Verification). Save, then
   **Send test email**. Until then, codes show on Requests for you to pass on.

5. **Settings → Home:** check **Address for the apps** is the Mac's Tailscale
   address (like `http://100.84.12.7:8443`), and paste your Tailscale share
   link for the Mac under **Private-network link**.

6. **Join on each device:** Invite → name and email → **Create invite**. On
   the phone, **Scan the invite** (or type the address and code), then the
   email and its 6-digit code. Without an invite, leave the code empty: the
   request waits on **Requests** for you to approve.

7. *Optional:* Settings → Your sign-in → **Set up authenticator** to use Hive
   Admin from another computer (an emailed code plus the authenticator code).

Also in M2: **People** (suspend, device limit, sign out everywhere),
**Devices**, **Activity** (every admin action), **Library → Tidy song names**
(what Hive shows; files stay as they are), search suggestions as you type,
and a refreshed look for the apps.

## M3: Listen and offline downloads

**The M3 gate:** Listen names a song playing in the room (TV, speaker, car)
when it's at home, and says where it is so it plays from there; a song that
isn't at home can be asked for. Downloaded albums and playlists play with the
Mac off.

1. **Update the server** (one new package, numpy, so install again). The
   first start fingerprints every song in the background: about a minute per
   few hundred songs. Hive Admin → **Recognition** shows how far it is.

   ```sh
   git pull
   cd server && .venv/bin/pip install -e ".[dev]"
   .venv/bin/python -m hive serve
   ```

   Listen uses FFmpeg, which Hive already needs, so nothing else to install.

2. **Install the new apps** (from the latest run). The first time you tap
   Listen, allow the microphone.

3. **Try Listen:** play a song from the Mac's speakers or the TV, tap the big
   button and hold the phone near it for 8 seconds. Found: **Play from 1:42**,
   **Play from the start** or **Add to playlist**. Not found: **Ask to add
   it**, which emails you and shows on Hive Admin → **Requests → Songs people
   asked for** (mark it **Added** once it's in the music folder). Search with
   no results offers the same. The recording goes to the Mac once and is
   thrown away; nothing about it leaves home.

4. **Record the test clips:** about 20 clips of 10 seconds around the house
   (TV, speaker, car, with people talking), each of a song that's at home, and
   send them over. They decide whether Listen needs tuning before M3 closes.

5. **Downloads:** the download button at the top of any album or playlist, or
   **Download** on a song's menu. They're in **Library → Downloads** (also
   under Liked songs), with the space used. Quality: Settings → Playback →
   **Downloads** (High by default; Lossless takes about ten times the space).
   Downloads are locked to the device; they play offline for 30 days at a
   time, and each time the device reaches home adds 30 days (it warns 5 days
   before). Signing a device out in Hive Admin deletes its downloads the next
   time it connects.

## M4: backups (first part of M4)

**Hive Admin → Backups** keeps a copy of everything Hive knows: people,
devices, likes, playlists, history, settings and covers. It doesn't copy
the music files themselves: back up the music drive separately.

1. Restart the server after updating (no new packages).
2. Backups → **Schedule and place**: the daily backup is on at 03:00 and
   keeps the last 14. Set **Backup folder** to a folder on another drive
   (an external drive, for example `/Volumes/Backup/Hive` on the Mac or
   `E:\Hive backups` on Windows) and **Save**. Hive checks it can write
   there.
3. **Back up now** to make the first one.
4. **Restore** puts a backup back the next time Hive starts: stop the server
   and start it again. Today's state is backed up first (so a restore can be
   undone), and anyone signed out or paused since the backup stays that way.

Your data lives in the `data` folder inside the code folder (unless you set
`HIVE_DATA_DIR`). Never delete that folder when updating the code.

## M4: Hive on the Windows home PC

The Windows server comes as one installer, **HiveServerSetup-<version>.exe**
(GitHub → Actions → the latest green run → *hive-server-windows*). It carries
everything: Hive with Python inside, FFmpeg and fpcalc. Nothing else is
installed by hand.

1. On the home PC: install Tailscale and sign in (same account as your
   other devices).
2. Run the installer. It asks where the music is (for example `D:\Music`),
   then installs Hive to `C:\Program Files\Hive` and starts it as a Windows
   service: it starts by itself at boot, and restarts itself if it stops.
   Everything Hive knows lives in `C:\ProgramData\Hive`, apart from the
   program.
3. Open Hive Admin on the PC (`http://localhost:8443/admin/`).
4. **Updating:** run the newer installer. It stops Hive, makes a backup
   ("Safety copy before an update"), replaces the program and starts Hive
   again. If the backup can't be made (for example the backup drive isn't
   connected) it changes nothing and says so.
5. **Removing** Hive (Settings → Apps) keeps `C:\ProgramData\Hive`.

## M4: moving Hive from the Mac to the PC

Everything Hive knows moves with one backup; the music is copied separately.

1. Copy the music to the PC (for example to `D:\Music`), keeping the same
   folders inside.
2. On the Mac: Hive Admin → Backups → **Back up now**. The backup is a zip
   in the Mac's backup folder.
3. On the PC: install Hive (above), point it at the music folder, then copy
   the zip into the PC's backup folder (`C:\ProgramData\Hive\backups`
   unless you changed it). It shows in Hive Admin → Backups.
4. **Restore** it. Hive asks where each of the Mac's music folders is now
   (for example `/Users/bilal/Music` → *Now in D:\Music*), so every song
   keeps its likes, plays and playlists. Settings that belong to the
   computer (its address, backup folder) stay the PC's own.
5. Restart Hive (Services → Hive → Restart, or restart the PC). The restore
   finishes as it starts; today's PC state is backed up first.
6. Stop Hive on the Mac.
7. **Keep the phones working without signing in again:** in the Tailscale
   admin console (Machines), give the Mac a different address, then give
   the PC the Mac's old one (machine menu → *Edit machine IPv4*). The apps
   already point at that address, so they just carry on.

## M4: Hive on a Mac, as a package

**HiveServer-<version>-mac.pkg** (Actions → *hive-server-mac*) installs
Hive the same way on a Mac (Apple silicon), for when the home computer is a
Mac. It goes in **Applications → Hive Server** with Python, Hive Admin and
fpcalc inside; FFmpeg comes from Homebrew (`brew install ffmpeg`) if it
isn't inside. It starts when you sign in and again if it stops; its data is
in `~/Library/Application Support/Hive` (the music starts in **Music →
Hive**). The package isn't signed by Apple yet, so the first time
right-click it → **Open**. Installing a newer one backs up first; **Uninstall
Hive** in that folder keeps the data. Your current way of running Hive
(`start-hive.sh` with `HIVE_DATA_DIR`) keeps working; you don't need this.

## M4: health, logs and the oldest app allowed

- Hive Admin → **System health**: drive space, the last backup, how long
  Hive has been running, and anything wrong. Overview shows the same
  problems. With email set up, the admin gets a short note when something
  goes wrong (no personal details in it).
- **Logs**: what Hive has been doing, searchable, for when something looks
  off; the log files are in the data folder's `logs`.
- Hive Admin → Settings → **Oldest app allowed**: older apps are asked to update.

## M4: carry on from another device, and the app extras

- **Continue:** play something on the Mac, stop it, then open Hive on the
  phone: a bar offers *Continue <song> from <device>*. **Continue** picks
  up the same queue at the same place; **Not now** hides it.
- Settings → **Simple mode**: big buttons that start music at once, fewer
  choices (for the grandparents). **Appearance**: system, light or dark.
- Computers: Hive stays in the menu bar / tray with play, pause, next and
  a **Mini player** that stays on top. **Keep playing when the window
  closes** is on by default.
- Windows: Settings → **Output** chooses the speakers or DAC, and
  **Exclusive mode** sends the music bit-perfect.
- Hive Admin → Albums → an album → **Edit** beside a song corrects its
  title, singers, number, music and lyrics (the file isn't changed; Undo
  puts back what the file says).
- Hive Admin → Library → **Same song twice**: the same song in two files
  (an MP3 and a FLAC, say). **Keep this copy** moves likes, plays and
  playlists to it and deletes the other file; **They're different, keep
  both** stops suggesting them.

**Releases:** how to make one, and the signing keys, are in `docs/releasing.md`.

**Testing M4:** one checklist for all of it is in `docs/m4-test-checklist.md`.

## Useful commands

| What | Command |
| --- | --- |
| Server tests | `cd server && .venv/bin/python -m pytest` |
| Admin tests | `cd admin && npm test` (unit), `npm run e2e` (browser) |
| App tests | `cd app && flutter test` |
| After changing the app icon design | `python3 tools/gen_app_icons.py` (needs Pillow) |
| After editing `design/tokens.json` | `python3 tools/gen_design.py` |
| After editing `api/openapi.yaml` | `python3 tools/gen_dart_client.py` and `npm run gen:api --prefix admin` |
| See the settings in use | `cd server && .venv/bin/python -m hive info` |
