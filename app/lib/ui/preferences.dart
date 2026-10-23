import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/device_auth.dart';
import '../core/home_connection.dart';

/// Light, dark, or following the device.
enum Appearance {
  system('Same as this device', ThemeMode.system),
  light('Light', ThemeMode.light),
  dark('Dark', ThemeMode.dark);

  const Appearance(this.label, this.mode);
  final String label;
  final ThemeMode mode;
}

class AppearanceNotifier extends Notifier<Appearance> {
  static const _key = 'app.appearance';

  @override
  Appearance build() {
    final saved = ref.watch(sharedPreferencesProvider).getString(_key);
    return Appearance.values.firstWhere(
      (a) => a.name == saved,
      orElse: () => Appearance.system,
    );
  }

  Future<void> set(Appearance a) async {
    await ref.read(sharedPreferencesProvider).setString(_key, a.name);
    state = a;
  }
}

final appearanceProvider = NotifierProvider<AppearanceNotifier, Appearance>(
  AppearanceNotifier.new,
);

/// Simple mode on this device: what whoever runs Hive set for this person
/// (Hive Admin → People), unless changed here in Settings.
class SimpleModeNotifier extends Notifier<bool> {
  static const _key = 'app.simpleMode';

  @override
  bool build() {
    final auth = ref.watch(deviceAuthProvider);
    void changed() => ref.invalidateSelf();
    auth.addListener(changed);
    ref.onDispose(() => auth.removeListener(changed));
    final here = ref.watch(sharedPreferencesProvider).getBool(_key);
    return here ?? auth.me?.simpleMode ?? false;
  }

  /// Set it on this device (overrides Hive Admin's choice here).
  Future<void> set(bool on) async {
    await ref.read(sharedPreferencesProvider).setBool(_key, on);
    state = on;
  }
}

final simpleModeProvider = NotifierProvider<SimpleModeNotifier, bool>(
  SimpleModeNotifier.new,
);
