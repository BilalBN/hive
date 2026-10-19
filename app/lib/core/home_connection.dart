import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/hive_api.g.dart';

/// Where home is, and (until M2) the key Hive Admin shows for the apps.
/// Saved on the device; in M2 both come from the invite instead of being typed.
class HomeAddressStore extends ChangeNotifier {
  HomeAddressStore(this._prefs);

  static const _addressKey = 'home.address';
  static const _devKey = 'home.developmentKey';
  final SharedPreferences _prefs;

  Uri? get address {
    final raw = _prefs.getString(_addressKey);
    return raw == null ? null : Uri.tryParse(raw);
  }

  /// The temporary key for the M1 library API (Hive Admin → Overview).
  String? get key => _prefs.getString(_devKey);

  Future<void> save(Uri address, {String? key}) async {
    await _prefs.setString(_addressKey, address.toString());
    if (key != null) await _prefs.setString(_devKey, key);
    notifyListeners();
  }

  Future<void> forget() async {
    await _prefs.remove(_addressKey);
    await _prefs.remove(_devKey);
    await clearPending();
    notifyListeners();
  }

  /// Joined with an invite: M1's development key is no use any more.
  Future<void> clearKey() async {
    await _prefs.remove(_devKey);
    notifyListeners();
  }

  static const _pendingKey = 'home.pendingRequest';

  /// A request waiting for the admin, so the app can pick it up again after
  /// being closed: (id, token, device name).
  ({String id, String token, String deviceName})? get pending {
    final raw = _prefs.getStringList(_pendingKey);
    if (raw == null || raw.length != 3) return null;
    return (id: raw[0], token: raw[1], deviceName: raw[2]);
  }

  Future<void> savePending(String id, String token, String deviceName) =>
      _prefs.setStringList(_pendingKey, [id, token, deviceName]);

  Future<void> clearPending() => _prefs.remove(_pendingKey);
}

final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('overridden in main()'),
);

final homeAddressStoreProvider = Provider<HomeAddressStore>(
  (ref) => HomeAddressStore(ref.watch(sharedPreferencesProvider)),
);

/// Turns what someone typed into a server address, or explains what's wrong.
/// Accepts "100.84.12.7", "hive-pc:8443", "http://…" or "https://…".
Uri? parseHomeAddress(String input) {
  var text = input.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'http://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri.replace(
    port: uri.hasPort ? uri.port : 8443,
    path: '',
    query: null,
    fragment: null,
  );
}

/// Asks a server for its health. Replaced in tests.
typedef HealthCheck = Future<Health> Function(Uri address);

Dio dioFor(Uri address) => Dio(
  BaseOptions(
    baseUrl: address.toString(),
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 10),
    headers: {'Accept': 'application/json'},
  ),
);

/// Checks the M1 key against home (a library call that needs it). Replaced in tests.
typedef KeyCheck = Future<void> Function(Uri address, String key);

final keyCheckProvider = Provider<KeyCheck>(
  (ref) => (address, key) async {
    final dio = dioFor(address)
      ..options.headers['Authorization'] = 'Bearer $key';
    await HiveApi(dio).listPlaylists();
  },
);

final healthCheckProvider = Provider<HealthCheck>(
  (ref) =>
      (address) => HiveApi(dioFor(address)).getHealth(),
);

/// What the app knows about its link to home right now.
@immutable
sealed class HomeStatus {
  const HomeStatus();
}

class HomeChecking extends HomeStatus {
  const HomeChecking();
}

class HomeConnected extends HomeStatus {
  const HomeConnected(this.health);
  final Health health;
}

class HomeUnreachable extends HomeStatus {
  const HomeUnreachable(this.reason);
  final String reason;
}

/// Checks home every 15 seconds while the app is open.
class HomeStatusNotifier extends Notifier<HomeStatus> {
  static const interval = Duration(seconds: 15);
  Timer? _timer;

  @override
  HomeStatus build() {
    final store = ref.watch(homeAddressStoreProvider);
    void onChange() => check();
    store.addListener(onChange);
    _timer = Timer.periodic(interval, (_) => check());
    ref.onDispose(() {
      _timer?.cancel();
      store.removeListener(onChange);
    });
    Future.microtask(check);
    return const HomeChecking();
  }

  Future<void> check() async {
    final address = ref.read(homeAddressStoreProvider).address;
    if (address == null) {
      state = const HomeUnreachable('No home address yet.');
      return;
    }
    try {
      final health = await ref.read(healthCheckProvider)(address);
      state = HomeConnected(health);
    } on HiveApiException catch (e) {
      state = HomeUnreachable(describeFailure(e));
    } catch (e) {
      state = HomeUnreachable(describeFailure(e));
    }
  }
}

final homeStatusProvider = NotifierProvider<HomeStatusNotifier, HomeStatus>(
  HomeStatusNotifier.new,
);

/// A short, plain explanation for the family; no error codes.
String describeFailure(Object error) {
  if (error is HiveApiException) {
    if (error.unreachable) {
      return 'The music PC may be asleep, or the private connection is off on this device.';
    }
    return 'Home answered, but not as expected (${error.status}).';
  }
  if (error is FormatException || error is TypeError) {
    return "That address answered, but it isn't a Hive home.";
  }
  return 'The music PC may be asleep, or the private connection is off on this device.';
}
