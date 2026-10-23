# just_audio_media_kit, with Hive's changes

A copy of [just_audio_media_kit](https://pub.dev/packages/just_audio_media_kit)
2.1.0 (public domain, see LICENSE), used by Hive on Windows. Hive adds a way
to set mpv properties on every player, for the output device and exclusive
mode in Settings:

- `JustAudioMediaKit.mpvProperties`, `setMpvProperty()`, `audioDevices`
  and `livePlayers` in lib/just_audio_media_kit.dart;
- each player registers itself and applies those properties
  (lib/mediakit_player.dart).

Nothing else is changed. Drop this copy if the package gains an equivalent.
