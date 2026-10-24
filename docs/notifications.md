# Notifications (M6)

Hive sends a few fixed messages, and never says who or what (no names,
songs or emails):

| For | When |
| --- | --- |
| Everyone | **New music at home** (at most once a day, after albums are added) |
| The person who asked | **A song you asked for is in Hive** (when it's marked added on Requests) |
| Admins | **Someone is waiting to join**, **A song was asked for**, **Hive needs a look** (as the emails) |

Each person chooses which they get in the app: Settings → Notifications.

**How they arrive**

- **Hive open** (any device): straight away, as a note at the bottom of the
  screen. A Mac or Windows computer with Hive in the menu bar / tray shows
  it as a normal notification.
- **Android, Hive closed:** through UnifiedPush. Install a distributor app
  such as **ntfy** (F-Droid or Google Play), then open Hive: Settings →
  Notifications → **When Hive is closed** turns on. Messages are encrypted
  for the phone, so ntfy can't read them.
- **iPhone/iPad, Hive closed:** Apple's push service. Needs the Apple
  Developer account: make a key with *Apple Push Notifications* ticked and
  paste it in Hive Admin → Settings → Notifications; turn on *Push
  Notifications* for `dev.hivemusic.hive` and add it to the release build.

Hive Admin → Settings → Notifications → **Send a test notification** checks
it reaches the admins.
