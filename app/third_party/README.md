# Third-party code kept in this repository

| Folder | From | Why it's here |
| --- | --- | --- |
| `audio_service_win/` | [audio_service_win 0.0.3](https://pub.dev/packages/audio_service_win) (MIT) | Windows media keys and the volume-overlay controls. Patched to build with current Visual Studio: compiled as C++20 (C++/WinRT's coroutines) and one log line converts the wide string first. Drop the copy once a release builds as is. |
