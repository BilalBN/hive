# Hive app

One Flutter codebase for Android, iOS, Windows and macOS.

| Path | What it holds |
| --- | --- |
| `lib/app.dart` | Routes and the app root |
| `lib/core/` | Home connection (address, health checks) |
| `lib/design/` | Theme, shared widgets; `*.g.dart` are generated from `design/tokens.json` |
| `lib/api/hive_api.g.dart` | API client generated from `api/openapi.yaml` |
| `lib/features/` | One folder per screen or area |
| `assets/fonts/` | Bundled fonts and icon font, with their licences |
| `test/` | Widget tests; `screenshots_test.dart` renders key screens to `test/goldens/` |

Generated `*.g.dart` files are never reformatted by hand or by `dart format`;
CI checks them against their generators.

```sh
find lib test -name '*.dart' ! -name '*.g.dart' | xargs dart format   # format
flutter test                                              # tests
flutter test --tags screenshots --run-skipped --update-goldens   # refresh screenshots
```
