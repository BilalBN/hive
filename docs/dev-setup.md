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

## Useful commands

| What | Command |
| --- | --- |
| Server tests | `cd server && .venv/bin/python -m pytest` |
| Admin tests | `cd admin && npm test` (unit), `npm run e2e` (browser) |
| App tests | `cd app && flutter test` |
| After editing `design/tokens.json` | `python3 tools/gen_design.py` |
| After editing `api/openapi.yaml` | `python3 tools/gen_dart_client.py` and `npm run gen:api --prefix admin` |
| See the settings in use | `cd server && .venv/bin/python -m hive info` |
