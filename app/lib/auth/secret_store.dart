import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where this device keeps its private key and sign-in: the system keystore
/// on phones and Windows (Android Keystore, iOS Keychain, Windows Credential
/// Manager). On Mac and Linux the app's own private settings: the Mac
/// keychain needs a signing team, which family builds don't have, and the Mac
/// app's settings already live in its sandbox.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  factory SecretStore.forPlatform(SharedPreferences prefs) {
    if (kIsWeb) return PrefsSecretStore(prefs);
    return switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.windows => SystemSecretStore(),
      _ => PrefsSecretStore(prefs),
    };
  }
}

class SystemSecretStore implements SecretStore {
  SystemSecretStore()
    : _storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(),
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
      );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class PrefsSecretStore implements SecretStore {
  PrefsSecretStore(this._prefs);
  final SharedPreferences _prefs;
  static const _prefix = 'secret.';

  @override
  Future<String?> read(String key) async => _prefs.getString('$_prefix$key');
  @override
  Future<void> write(String key, String value) =>
      _prefs.setString('$_prefix$key', value);
  @override
  Future<void> delete(String key) => _prefs.remove('$_prefix$key');
}

/// For tests.
class MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}
