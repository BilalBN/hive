import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/hive_api.g.dart';

/// Where home is. Saved on the device; in M2 it comes from the invite instead
/// of being typed.
class HomeAddressStore extends ChangeNotifier {
  HomeAddressStore(this._prefs);

  static const _key = 'home.address';
  final SharedPreferences _prefs;

  Uri? get address {
    final raw = _prefs.getString(_key);
    return raw == null ? null : Uri.tryParse(raw);
  }

  Future<void> save(Uri address) async {
    await _prefs.setString(_key, address.toString());
    notifyListeners();
  }

  Future<void> forget() async {
    await _prefs.remove(_key);
    notifyListeners();
  }
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
