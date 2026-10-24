import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/device_auth.dart';
import '../core/api.dart';
import '../player/player_controller.dart';
import 'desktop.dart';

/// M6: song controls by the Mac's notch. The Mac's own code
/// (macos/Runner/MainFlutterWindow.swift) draws a small black panel that
/// grows out of the notch on hover (and for a moment when the song
/// changes): the cover, title and artist, previous, play/pause and next.
/// Macs without a notch don't show it.
class NotchBridge {
  NotchBridge(this._ref);
  final Ref _ref;
  static const _channel = MethodChannel('hive/notch');
  String _sent = '';
  String? _artFor;
  Uint8List? _art;

  static bool get here =>
      desktopFeatures && defaultTargetPlatform == TargetPlatform.macOS;

  /// [force]: start even where it wouldn't (tests).
  Future<void> start({bool force = false}) async {
    if (!here && !force) return;
    _channel.setMethodCallHandler(_onCall);
    _ref.listen(playerProvider, (_, _) => unawaited(_update()));
    _ref.listen(desktopSettingsProvider, (_, _) => unawaited(_update()));
    await _update();
  }

  Future<dynamic> _onCall(MethodCall call) async {
    final player = _ref.read(playerProvider.notifier);
    switch (call.arguments as String?) {
      case 'toggle':
        await player.toggle();
      case 'next':
        await player.next();
      case 'previous':
        await player.previous();
    }
  }

  Future<Uint8List?> _cover(String? artworkId) async {
    if (artworkId == null) return null;
    if (artworkId == _artFor) return _art;
    final config = _ref.read(homeConfigProvider);
    if (config == null) return null;
    try {
      final dio = dioForHome(config, auth: _ref.read(deviceAuthProvider));
      final r = await dio.get<List<int>>(
        '/api/v1/media/artwork/${Uri.encodeComponent(artworkId)}',
        queryParameters: {'size': 192},
        options: Options(responseType: ResponseType.bytes),
      );
      _artFor = artworkId;
      _art = r.data == null ? null : Uint8List.fromList(r.data!);
    } catch (_) {
      _art = null;
    }
    return _art;
  }

  Future<void> _update() async {
    final on = _ref.read(desktopSettingsProvider).notchControls;
    final s = _ref.read(playerProvider);
    final t = s.track;
    final key = '$on|${t?.id}|${s.playing}';
    if (key == _sent) return;
    _sent = key;
    try {
      if (!on || t == null) {
        await _channel.invokeMethod('hide');
        return;
      }
      await _channel.invokeMethod('update', {
        'title': t.title,
        'artist': t.artistName,
        'playing': s.playing,
        'trackId': t.id,
        'art': await _cover(t.artworkId),
      });
    } on MissingPluginException {
      // An older Mac build without the panel.
    } on PlatformException {
      // The panel couldn't be shown; the rest of Hive carries on.
    }
  }
}

final notchBridgeProvider = Provider<NotchBridge>(NotchBridge.new);
