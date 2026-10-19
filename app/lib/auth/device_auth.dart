import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/hive_api.g.dart';
import '../core/home_connection.dart';
import 'device_key.dart';
import 'secret_store.dart';

/// Why this device isn't signed in to home right now.
enum SignInProblem {
  /// Never joined, or the sign-in ran out: join again with your email.
  none,

  /// Removed in Hive Admin or from another of your devices.
  revoked,

  /// Paused by whoever runs this home; nothing is deleted.
  suspended,
}

/// Asks home for a challenge and swaps a refresh token. Unauthenticated, so it
/// takes the address rather than the signed-in API. Replaced in tests.
typedef AuthApiFor = HiveApi Function(Uri address);

final authApiForProvider = Provider<AuthApiFor>(
  (ref) =>
      (address) => HiveApi(dioFor(address)),
);

final secretStoreProvider = Provider<SecretStore>(
  (ref) => SecretStore.forPlatform(ref.watch(sharedPreferencesProvider)),
);

/// This device's sign-in to home: its key, the rotating refresh token, and a
/// short-lived access token kept in memory. Tokens are refreshed shortly
/// before they run out, with a fresh signature each time.
class DeviceAuth extends ChangeNotifier {
  DeviceAuth(this._secrets, this._apiFor, this._address);

  final SecretStore _secrets;
  final AuthApiFor _apiFor;
  final Uri? Function() _address;

  static const _kDevice = 'auth.deviceId';
  static const _kRefresh = 'auth.refreshToken';
  static const _kSeed = 'auth.deviceKey';
  static const _kMe = 'auth.me';

  String? _deviceId;
  String? _refresh;
  DeviceKey? _key;
  Me? _me;
  String? _access;
  DateTime? _accessExpires;
  Future<String?>? _refreshing;
  Timer? _timer;
  bool _loaded = false;

  SignInProblem problem = SignInProblem.none;

  /// Set when a problem's words come from home.
  String? problemDetail;

  bool get loaded => _loaded;
  bool get signedIn => _deviceId != null && _refresh != null;
  String? get deviceId => _deviceId;
  Me? get me => _me;

  /// The access token as it stands, for places that can't wait (cover art
  /// headers). Kept fresh in the background.
  String? get currentAccessToken => _access;

  Map<String, String> get headers =>
      _access == null ? const {} : {'Authorization': 'Bearer $_access'};

  /// Read what's saved. Call once at start-up.
  Future<void> load() async {
    try {
      _deviceId = await _secrets.read(_kDevice);
      _refresh = await _secrets.read(_kRefresh);
      final seed = await _secrets.read(_kSeed);
      _key = seed == null ? null : await DeviceKey.fromSeed(seed);
      final me = await _secrets.read(_kMe);
      _me = me == null
          ? null
          : Me.fromJson((jsonDecode(me) as Map).cast<String, dynamic>());
      if (_key == null) {
        _deviceId = null;
        _refresh = null;
      }
    } catch (_) {
      // An unreadable keystore (restored backup, changed lock screen) means
      // joining again; nothing else is lost.
      _deviceId = _refresh = null;
      _key = null;
    }
    _loaded = true;
    notifyListeners();
    if (signedIn) unawaited(accessToken());
  }

  /// A key for joining: made once, kept until this device leaves.
  Future<DeviceKey> keyForJoining() async {
    if (_key != null) return _key!;
    final key = await DeviceKey.generate();
    await _secrets.write(_kSeed, key.seed);
    return _key = key;
  }

  /// Home let this device in.
  Future<void> adopt(DeviceSession session) async {
    _deviceId = session.deviceId;
    await _secrets.write(_kDevice, session.deviceId);
    await _store(session);
    problem = SignInProblem.none;
    problemDetail = null;
    notifyListeners();
  }

  Future<void> _store(DeviceSession session) async {
    _refresh = session.refreshToken;
    _access = session.accessToken;
    _accessExpires = session.accessExpiresAt;
    _me = session.me;
    await _secrets.write(_kRefresh, session.refreshToken);
    await _secrets.write(_kMe, jsonEncode(session.me.toJson()));
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    final at = _accessExpires;
    if (at == null) return;
    final wait = at.difference(DateTime.now()) - const Duration(minutes: 2);
    _timer = Timer(
      wait.isNegative ? Duration.zero : wait,
      () => unawaited(refresh().catchError((_) => null)),
    );
  }

  /// An access token that's good for at least another half minute, refreshing
  /// if needed. Null when this device isn't signed in.
  Future<String?> accessToken() async {
    if (!signedIn) return null;
    final at = _accessExpires;
    if (_access != null &&
        at != null &&
        at.isAfter(DateTime.now().add(const Duration(seconds: 30)))) {
      return _access;
    }
    return refresh();
  }

  /// One refresh at a time; everyone waiting gets the same answer.
  Future<String?> refresh() =>
      _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);

  Future<String?> _doRefresh() async {
    final address = _address();
    final key = _key;
    final deviceId = _deviceId;
    final token = _refresh;
    if (address == null || key == null || deviceId == null || token == null) {
      return null;
    }
    final api = _apiFor(address);
    try {
      final challenge = await api.createChallenge(
        body: ChallengeRequest(deviceId: deviceId),
      );
      final session = await api.refreshToken(
        body: TokenRefresh(
          deviceId: deviceId,
          refreshToken: token,
          challenge: challenge.challenge,
          signature: await key.sign(challenge.challenge),
        ),
      );
      await _store(session);
      if (problem != SignInProblem.none) {
        problem = SignInProblem.none;
        problemDetail = null;
      }
      notifyListeners();
      return _access;
    } on HiveApiException catch (e) {
      if (e.status == 401 || e.status == 403) {
        await _signedOutBy(e.problem);
        return null;
      }
      rethrow; // unreachable or a hiccup: keep the sign-in, try again later
    }
  }

  /// Home said no to this device (a 401 on any call, or the refresh).
  Future<void> _signedOutBy(Problem? p) async {
    final code = p?.code;
    if (code == 'suspended') {
      problem = SignInProblem.suspended;
      problemDetail = p?.detail;
      _access = null;
      _timer?.cancel();
      notifyListeners(); // keep the device; it works again once reinstated
      return;
    }
    problem = code == 'revoked' ? SignInProblem.revoked : SignInProblem.none;
    problemDetail = p?.detail;
    await forget();
  }

  /// A call came back 401: try one refresh. True when the call can be retried.
  Future<bool> recoverFrom(HiveApiException e) async {
    final code = e.problem?.code;
    if (code == 'revoked' || code == 'suspended') {
      await _signedOutBy(e.problem);
      return false;
    }
    _access = null;
    try {
      return await refresh() != null;
    } catch (_) {
      return false;
    }
  }

  /// Leave home on this device: forget its key and sign-in.
  Future<void> forget() async {
    _timer?.cancel();
    _deviceId = _refresh = _access = null;
    _accessExpires = null;
    _key = null;
    _me = null;
    for (final k in [_kDevice, _kRefresh, _kSeed, _kMe]) {
      await _secrets.delete(k);
    }
    notifyListeners();
  }

  /// Try again after "Access paused".
  Future<void> retry() async {
    try {
      await refresh();
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final deviceAuthProvider = Provider<DeviceAuth>((ref) {
  final store = ref.watch(homeAddressStoreProvider);
  final auth = DeviceAuth(
    ref.watch(secretStoreProvider),
    ref.watch(authApiForProvider),
    () => store.address,
  );
  ref.onDispose(auth.dispose);
  return auth;
});

/// The access token, so cover art picks up a new one after a refresh.
final accessTokenProvider = Provider<String?>((ref) {
  final auth = ref.watch(deviceAuthProvider);
  void changed() => ref.invalidateSelf();
  auth.addListener(changed);
  ref.onDispose(() => auth.removeListener(changed));
  return auth.currentAccessToken;
});
