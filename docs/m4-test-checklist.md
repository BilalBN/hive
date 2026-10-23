# M4 test checklist

One pass over everything in M4. Tick each line; if one fails, note what you
saw (a screenshot helps) and carry on with the rest.

## 0. Update (on the Mac)

- [ ] In `~/Hive-Project/hive`: `git pull`. No new packages for the server.
- [ ] Hive Admin: download *hive-admin-dist* from the latest green run and
      put it in `admin/dist` as before.
- [ ] Start the server with `start-hive.sh`. It updates the database by
      itself (the log says `database ready`).
- [ ] Apps: install the new builds (Android APK, Mac app) from the same run.

## 1. Backups (Hive Admin → Backups)

- [ ] **Back up now** makes a backup; it shows in the list with the number
      of people.
- [ ] Set **Backup folder** to a folder on another drive and **Save**. A
      folder Hive can't write to is refused with a message.
- [ ] Restore: like a song on the phone, make a backup, then unlike it.
      **Restore** the backup, restart the server: the song is liked again.
- [ ] A device signed out *after* that backup stays signed out after the
      restore.

## 2. Health and logs

- [ ] **System health** shows drive space, the last backup and running time.
- [ ] Set the backup folder to a drive and unplug it: System health and
      Overview show the problem when you refresh (an email follows within
      half an hour if email is set up). Plug it back in.
- [ ] **Logs** shows what Hive did; searching for `backup` finds the backup.
- [ ] Settings → **Oldest app allowed** = `9.0.0`: the app's Home says it
      needs a newer Hive. Set it back to empty.

## 3. Songs (Hive Admin → Albums, Library)

- [ ] Albums → an album → **Edit** beside a song: change the title, **Save
      song**. The phone shows the new title; the song shows *Corrected*.
- [ ] Library → **Scan now**: the correction stays.
- [ ] **Edit** → **Undo** beside the title: the file's title is back.
- [ ] Put the same song in twice (an MP3 copy of a FLAC, on another album
      folder). Library → **Same song twice** lists them, the FLAC marked
      *Better copy*. Like the MP3 on the phone first, then **Keep this copy**
      on the FLAC: the MP3 file is gone and the FLAC is liked.

## 4. Carry on from another device

- [ ] Play an album on the Mac app, pause halfway through a song.
- [ ] Open the phone app: *Continue … from Bilal's MacBook* shows above the
      player. **Continue** plays the same song from the same place, with the
      rest of the album next.
- [ ] **Not now** hides it until something else plays on the Mac.

## 5. App extras

- [ ] Settings → **Simple mode** on: big buttons on Home, bigger controls on
      Now playing. Off again.
- [ ] Settings → **Appearance**: Light and Dark both look right.
- [ ] Mac app: the menu-bar icon shows the song; Pause / Next work from it.
      **Mini player** gives a small window on top; **Full window** returns.
- [ ] Close the Mac app's window while music plays: the music carries on;
      the menu-bar icon → **Show Hive** brings it back; **Quit Hive** ends it.
- [ ] Android: swiping the notification away doesn't stop the music.

## 6. The Windows home PC

- [ ] Install Tailscale on the PC and sign in.
- [ ] Run **HiveServerSetup-<version>.exe** (*hive-server-windows*), choose
      the music folder. Hive Admin opens at `http://localhost:8443/admin/`.
- [ ] Restart the PC: Hive is back without anyone signing in.
- [ ] Windows app: Settings → **Output** lists the speakers / DAC;
      **Exclusive mode** plays (other sounds are blocked while it does).
- [ ] Run the installer again (an update): Backups shows *before update*;
      everything is as it was.

## 7. The move (do this last)

Follow *Moving Hive from the Mac to the PC* in `docs/dev-setup.md`.

- [ ] Restore the Mac's backup on the PC, choosing the new music folder.
- [ ] Songs, likes, playlists, people and devices are all there.
- [ ] After giving the PC the Mac's old Tailscale address, the phone plays
      without signing in again.

## Optional: the Mac package

- [ ] **HiveServer-<version>-mac.pkg** installs, starts at sign-in, and
      **Uninstall Hive** removes it but keeps the data. (Try it on a Mac
      that isn't running your real Hive, or skip it.)
