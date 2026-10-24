import 'package:flutter/foundation.dart';

/// This app's version, as home sees it (kept equal to pubspec.yaml by a test).
const appVersion = '0.2.0';

/// The platform name the API uses.
String get platformWire {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.windows => 'windows',
    _ => 'linux',
  };
}

/// What this device is called until its owner renames it.
String get defaultDeviceName {
  if (kIsWeb) return 'Browser';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Android phone',
    TargetPlatform.iOS => 'iPhone',
    TargetPlatform.macOS => 'Mac',
    TargetPlatform.windows => 'Windows PC',
    _ => 'Computer',
  };
}

/// Phones can scan an invite's QR code with the camera.
/// The F-Droid build: only free software inside, so no QR scanner (M6).
const fdroidBuild = bool.fromEnvironment('HIVE_FDROID');

bool get canScanQr =>
    !fdroidBuild &&
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// True when [version] is older than [minimum] ("0.1.9" < "0.2.0").
bool isOlder(String version, String minimum) {
  List<int> parts(String v) =>
      v.split('+').first.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final a = parts(version), b = parts(minimum);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return x < y;
  }
  return false;
}

/// What an invite's QR holds: `hive://join?a=<home address>&c=<code>`.
({Uri? address, String? code}) parseJoinLink(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || uri.scheme != 'hive' || uri.host != 'join') {
    return (address: null, code: null);
  }
  final a = uri.queryParameters['a'];
  return (
    address: a == null ? null : Uri.tryParse(a),
    code: uri.queryParameters['c'],
  );
}
