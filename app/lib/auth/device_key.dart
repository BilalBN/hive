import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// This device's Ed25519 key. The private half never leaves the device; home
/// keeps the public half and checks a fresh signature before each new
/// sign-in token, so a copied refresh token is no use on its own.
class DeviceKey {
  DeviceKey._(this._pair, this.seed);

  final SimpleKeyPair _pair;

  /// The 32-byte private seed, base64url, for the secret store.
  final String seed;

  static final _ed = Ed25519();

  static Future<DeviceKey> generate() async {
    final pair = await _ed.newKeyPair();
    final bytes = await pair.extractPrivateKeyBytes();
    return DeviceKey._(pair, b64(bytes));
  }

  static Future<DeviceKey> fromSeed(String seed) async {
    final pair = await _ed.newKeyPairFromSeed(unb64(seed));
    return DeviceKey._(pair, seed);
  }

  /// The public key as home expects it: 32 bytes, base64url without padding.
  Future<String> publicKey() async {
    final pub = await _pair.extractPublicKey();
    return b64(pub.bytes);
  }

  Future<String> sign(String message) async {
    final sig = await _ed.sign(utf8.encode(message), keyPair: _pair);
    return b64(sig.bytes);
  }
}

String b64(List<int> bytes) =>
    base64Url.encode(Uint8List.fromList(bytes)).replaceAll('=', '');

List<int> unb64(String text) =>
    base64Url.decode(text.padRight(text.length + (-text.length % 4), '='));
