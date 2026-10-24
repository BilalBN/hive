# Run Hive for your family

About half an hour, once. You need:

- **A computer that stays on at home** with your music on it: Windows 10/11,
  a Mac (Apple silicon), or Linux / a NAS with Docker. Wired to the router is
  best.
- **Tailscale** (free for families): it's how phones reach home from
  anywhere, without opening anything to the internet. Hive only listens on
  it.
- Your music as files (FLAC, ALAC, MP3, AAC, Opus…), in folders.

## 1. Tailscale

1. Make a Tailscale account at https://tailscale.com and install Tailscale on
   the home computer; sign in.
2. Family members install Tailscale on their phones and computers. Either
   sign them in to your tailnet (Tailscale admin console → Users → Invite),
   or keep your tailnet to yourself and **share** just the home computer
   with each person (Machines → the home computer → Share).

## 2. The server

### Windows

Download `HiveServerSetup-<version>.exe` from the Releases page and run it.
It asks where the music is, installs Hive as a service that starts at boot,
and opens Hive Admin. Updates: run the newer installer (it backs up first).

### Mac

Download `HiveServer-<version>-mac.pkg` and open it (the first time:
right-click → Open). Hive starts when you sign in, with its data in
`~/Library/Application Support/Hive` and music in **Music → Hive** (add
other folders in Hive Admin). FFmpeg comes from Homebrew if it isn't inside:
`brew install ffmpeg`.

### Docker (Linux, NAS)

```sh
git clone https://github.com/BilalBN/hive && cd hive/deploy/docker
printf 'TS_AUTHKEY=tskey-auth-…\nMUSIC=/srv/music\nHOME_NAME=Our home\n' > .env
docker compose up -d
docker compose logs hive | grep "setup code"
```

Hive runs next to its own Tailscale node called `hive`, reachable only on
your tailnet. Make the auth key in the Tailscale admin console (Settings →
Keys). Data lives in `deploy/docker/data`; back up that folder (or use Hive
Admin → Backups).

### Linux without Docker

```sh
sudo apt install python3.12-venv ffmpeg libchromaprint-tools nodejs npm
sudo useradd --system --home /var/lib/hive --create-home hive
sudo git clone https://github.com/BilalBN/hive /opt/hive/src
sudo python3.12 -m venv /opt/hive/venv
sudo /opt/hive/venv/bin/pip install /opt/hive/src/server
(cd /opt/hive/src/admin && sudo npm ci && sudo npm run build)
sudo -u hive tee /var/lib/hive/hive.toml <<'TOML'
host = "tailscale"
music_folders = ['/srv/music']
admin_dist = '/opt/hive/src/admin/dist'
TOML
sudo cp /opt/hive/src/deploy/linux/hive.service /etc/systemd/system/
sudo systemctl enable --now hive
journalctl -u hive | grep "setup code"
```

The `hive` user needs to read the music folder (and write to it for uploads).

## 3. The first admin (you)

Open **Hive Admin**: on the home computer `http://localhost:8443/admin/`,
or from any device on your tailnet `http://<home computer's Tailscale name or
IP>:8443/admin/`. Enter your name and email. From another device, also type
the **setup code** Hive printed in its log when it started.

Then in Hive Admin:

- **Settings → Email**: an email account Hive sends sign-in codes from (a
  Gmail app password works). Needed for inviting people.
- **Settings**: add an authenticator app, so you can sign in to Hive Admin
  from other devices.
- **Library**: check the music folders; Hive reads everything in them and
  keeps watching for new files.
- **Backups**: point the backup folder at another drive.

## 4. The family

1. Hive Admin → **People → Invite**: their email; Hive shows a QR code and a
   code (and emails them).
2. They install the app (below), make sure Tailscale is on, and scan the QR
   code or type the address and code.
3. Each device someone adds later waits for your OK (Requests), up to the
   limit in Settings.

## 5. The apps

| Device | How |
| --- | --- |
| Android | `Hive-<version>.apk` from Releases (allow installing from your browser once). |
| Windows | `HiveSetup-<version>.exe` from Releases. |
| Mac | `Hive-<version>-mac.dmg` from Releases; drag Hive to Applications. |
| iPhone / iPad | Apple only allows apps from the App Store or a developer account. Build it with your own Apple Developer account (TestFlight for the family, see `docs/releasing.md`), or from a Mac with `flutter run --release` (works 7 days with a free Apple ID). |

## Updating

New releases appear on the Releases page. Update the server first (Windows:
run the newer installer; Mac: open the newer package; Docker: `git pull &&
docker compose up -d --build`; Linux: `git pull`, `pip install`, rebuild
Hive Admin, `systemctl restart hive`), then the apps. Hive backs up before
every server update on Windows and Mac.

## Moving to a new computer

Back up on the old one (Hive Admin → Backups → Back up now), install Hive on
the new one, copy the backup into its backup folder, and **Restore**. Hive
asks where the music folders are now. Tip: give the new computer the old
one's Tailscale address (Tailscale admin console) and the apps carry on
without signing in again.
