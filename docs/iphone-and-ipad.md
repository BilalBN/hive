# iPhone and iPad (M5)

What the iPhone and iPad app does beyond the phone basics:

- **Lock screen, Control Centre, Dynamic Island, CarPlay's Now Playing and
  AirPods controls** come from iOS's Now Playing (title, artist, cover,
  play/pause, next, previous, scrubbing). Music keeps playing with the
  screen locked.
- **iPad:** upright it uses the phone layout; on its side (wider than 840
  points) the computer layout with the sidebar and player bar, with
  finger-sized buttons. Sheets stay phone-width in the middle. Split View
  and Slide Over work.
- **VoiceOver and large text:** every button says what it is, tap targets
  are at least 44 points, text has enough contrast in light and dark, and
  nothing is cut off at large text sizes (Settings rows stack the value
  under the name, as iOS does). `app/test/accessibility_test.dart` checks
  this on a phone, an iPad both ways and with large text, so it stays true.

## Installing on family iPhones

Needs the Apple Developer account; see `docs/releasing.md` (TestFlight is
the easy way: family members install from the TestFlight app).

## Trying it on your iPhone now (from your Mac, with a cable)

`cd app && flutter run --release` with the iPhone plugged in. Xcode signs
it with your free Apple ID; the app then works for 7 days.
