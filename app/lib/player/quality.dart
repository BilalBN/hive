import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/hive_api.g.dart';
import '../core/home_connection.dart';

/// The three ways a song can be sent (build plan: Lossless, High, Data saver).
enum QualityMode {
  lossless('lossless', 'Lossless', 'The original file, untouched'),
  high('high', 'High', '256 kbps'),
  dataSaver('dataSaver', 'Data saver', '96 kbps');

  const QualityMode(this.wire, this.label, this._detail);

  /// The value in api/openapi.yaml's StreamRequest.quality.
  final String wire;
  final String label;
  final String _detail;

  /// Apple's player gets AAC for the lossy modes (it can't stream Opus).
  String get detail => this == QualityMode.lossless
      ? _detail
      : '${isApplePlayer ? 'AAC' : 'Opus'} $_detail';

  /// Roughly how much data an hour of music uses.
  String get perHour => switch (this) {
    QualityMode.lossless => 'about 300–1,500 MB an hour',
    QualityMode.high => 'about 115 MB an hour',
    QualityMode.dataSaver => 'about 45 MB an hour',
  };

  static QualityMode fromWire(String? v) => QualityMode.values.firstWhere(
    (m) => m.wire == v,
    orElse: () => QualityMode.lossless,
  );
}

/// How this device is connected right now.
enum NetworkKind { wifi, mobile, offline }

bool get isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux);

bool get isApplePlayer =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// Streaming quality per network, and volume levelling. Saved on the device.
@immutable
class PlaybackSettings {
  const PlaybackSettings({
    this.onWifi = QualityMode.lossless,
    this.onMobile = QualityMode.high,
    this.levelling = true,
  });

  final QualityMode onWifi;
  final QualityMode onMobile;

  /// Volume levelling (EBU R128). Off means the samples reach the output as sent.
  final bool levelling;

  QualityMode modeFor(NetworkKind network) =>
      network == NetworkKind.mobile ? onMobile : onWifi;

  PlaybackSettings copyWith({
    QualityMode? onWifi,
    QualityMode? onMobile,
    bool? levelling,
  }) => PlaybackSettings(
    onWifi: onWifi ?? this.onWifi,
    onMobile: onMobile ?? this.onMobile,
    levelling: levelling ?? this.levelling,
  );
}

class PlaybackSettingsNotifier extends Notifier<PlaybackSettings> {
  static const _wifi = 'playback.onWifi';
  static const _mobile = 'playback.onMobile';
  static const _levelling = 'playback.levelling';

  @override
  PlaybackSettings build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return PlaybackSettings(
      onWifi: QualityMode.fromWire(prefs.getString(_wifi)),
      onMobile: prefs.getString(_mobile) == null
          ? QualityMode.high
          : QualityMode.fromWire(prefs.getString(_mobile)),
      levelling: prefs.getBool(_levelling) ?? true,
    );
  }

  Future<void> update(PlaybackSettings next) async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(_wifi, next.onWifi.wire);
    await prefs.setString(_mobile, next.onMobile.wire);
    await prefs.setBool(_levelling, next.levelling);
    state = next;
  }
}

final playbackSettingsProvider =
    NotifierProvider<PlaybackSettingsNotifier, PlaybackSettings>(
      PlaybackSettingsNotifier.new,
    );

NetworkKind networkKindOf(List<ConnectivityResult> results) {
  if (results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet)) {
    return NetworkKind.wifi;
  }
  if (results.contains(ConnectivityResult.mobile)) return NetworkKind.mobile;
  // VPN-only or unknown: Tailscale shows as VPN; treat it as Wi-Fi unless
  // the phone also reports mobile data.
  if (results.contains(ConnectivityResult.vpn) ||
      results.contains(ConnectivityResult.other)) {
    return NetworkKind.wifi;
  }
  return NetworkKind.offline;
}

/// Wi-Fi or mobile data, kept up to date. Computers always count as Wi-Fi.
final networkKindProvider = StreamProvider<NetworkKind>((ref) async* {
  if (isDesktop) {
    yield NetworkKind.wifi;
    return;
  }
  final c = Connectivity();
  try {
    yield networkKindOf(await c.checkConnectivity());
  } catch (_) {
    yield NetworkKind.wifi;
  }
  yield* c.onConnectivityChanged.map(networkKindOf);
});

/// The quality to ask for right now.
final currentQualityProvider = Provider<QualityMode>((ref) {
  final settings = ref.watch(playbackSettingsProvider);
  final network = ref.watch(networkKindProvider).value ?? NetworkKind.wifi;
  return settings.modeFor(network);
});

// ----------------------------------------------------------------- levelling

/// Loudness everything is levelled to. Quieter songs aren't pushed up (that
/// would need amplification above full scale); louder ones are brought down.
const targetLufs = -14.0;

/// Player volume (0–1) for a song, so songs play at similar loudness.
double levellingGain(Loudness? loudness, {bool albumMode = false}) {
  if (loudness == null) return 1.0;
  final measured = albumMode && loudness.albumLufs != null
      ? loudness.albumLufs!
      : loudness.integratedLufs;
  var gainDb = targetLufs - measured;
  // Never let the loudest peak go above full scale.
  gainDb = math.min(gainDb, -loudness.truePeakDbtp);
  final gain = math.pow(10, gainDb / 20).toDouble();
  return gain.clamp(0.1, 1.0);
}
