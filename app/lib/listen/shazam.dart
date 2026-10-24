import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';

/// What Shazam named.
@immutable
class ShazamHit {
  const ShazamHit({required this.title, this.artist});
  final String title;
  final String? artist;
}

/// Shazam on this device, for songs home doesn't know. Only a fingerprint of
/// the sound goes to Apple, never the sound. Replaced in tests.
abstract class ShazamLink {
  /// This device can ask Shazam at all (built with ShazamKit).
  Future<bool> available();

  /// What Shazam calls the song in [pcm] (16-bit mono at [rate]); null when
  /// it doesn't know.
  Future<ShazamHit?> match(Uint8List pcm, {required int rate});
}

class DeviceShazam implements ShazamLink {
  DeviceShazam(this._ref);
  final Ref _ref;
  static const _channel = MethodChannel('hive/shazam');

  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _apple =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Future<bool> available() async {
    if (!_android && !_apple) return false;
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<ShazamHit?> match(Uint8List pcm, {required int rate}) async {
    String? token;
    if (_android) {
      // Android reaches Shazam with an hour-long token made at home.
      token = (await _ref.read(hiveApiProvider).createShazamToken()).token;
    }
    final r = await _channel.invokeMapMethod<String, dynamic>('match', {
      'pcm': pcm,
      'rate': rate,
      'token': ?token,
    });
    final title = r?['title'] as String?;
    if (title == null || title.trim().isEmpty) return null;
    return ShazamHit(
      title: title.trim(),
      artist: (r?['artist'] as String?)?.trim(),
    );
  }
}

final shazamLinkProvider = Provider<ShazamLink>(DeviceShazam.new);

/// Listen may ask Shazam: the admin turned it on, and this device can
/// (Android also needs home to have the ShazamKit key).
final shazamReadyProvider = FutureProvider.autoDispose<bool>((ref) async {
  final link = ref.watch(shazamLinkProvider);
  if (!await link.available()) return false;
  try {
    final o = await ref.watch(hiveApiProvider).getListenOptions();
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    return o.shazam && (!android || o.shazamAndroid);
  } catch (_) {
    return false;
  }
});
