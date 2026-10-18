# Hive

The family's music, from home. Hive is a private, invite-only music server that
runs on one PC at home, with apps for Android, iPhone, Windows and Mac. Music,
listening history and microphone audio never leave the family's private
network.

- **Lossless** playback, up to Hi-Res, with an honest badge for what reaches your ears
- **Continuity**: carry on from the same second on another device
- **Listen**: recognise songs playing nearby, from the family library first
- **Invite-only**: an admin approves every person, at most 4 devices each
- **Open source** (AGPL-3.0); every feature is free

> **Status: M0 · Foundations.** The skeleton of all three parts is in place and
> builds automatically. Music arrives in M1. See the build plan for the order.

## What's in this repository

| Folder | What it is |
| --- | --- |
| [`api/`](api/openapi.yaml) | The API contract: every endpoint, and the milestone that builds it |
| [`server/`](server/README.md) | The home server (Python, FastAPI, SQLite) |
| [`admin/`](admin/) | Hive Admin, the web panel the server hosts at `/admin` (React) |
| [`app/`](app/) | The app for Android, iOS, Windows and macOS (Flutter) |
| [`design/`](design/) | Design tokens and the icon map; the source for both apps' styles |
| [`tools/`](tools/) | Generators for tokens, icons and the API clients |
| [`docs/`](docs/) | Setup guides |

The server is checked against `api/openapi.yaml` in its tests, and the app and
admin clients are generated from it, so the three can't drift apart.

## Try it on your computer

The full walkthrough, including Tailscale, is in [docs/dev-setup.md](docs/dev-setup.md).

```sh
# 1. Server (Python 3.12+)
cd server && python3 -m venv .venv && .venv/bin/pip install -e ".[dev]"
.venv/bin/python -m hive serve            # http://127.0.0.1:8443

# 2. Admin panel (Node 22+), served by the server at /admin
cd admin && npm ci && npm run build

# 3. App (Flutter 3.47+)
cd app && flutter run                     # pick macOS, an Android phone or iPhone
```

## Downloads

Every push to `main` builds the Android APK and the Windows and macOS apps.
Open the latest run under **Actions → CI** and download them from
**Artifacts**.

## Licence

[AGPL-3.0](LICENSE). Fonts are under the SIL Open Font License and icons
(Lucide) under the ISC licence; their licences sit beside them in
`app/assets/fonts/`.
