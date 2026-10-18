// audio_session marks device types experimental; they are stable enough here.
// ignore_for_file: experimental_member_use
import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'quality.dart';

/// Where the sound comes out. Bluetooth is lossy almost everywhere; wired,
/// USB and built-in outputs can carry the file as it is.
enum OutputKind { builtIn, wired, usb, bluetooth, airplay, hdmi, unknown }

@immutable
class OutputRoute {
  const OutputRoute(this.kind, this.name);

  final OutputKind kind;
  final String name;

  bool get lossyLink => kind == OutputKind.bluetooth;

  static const thisComputer = OutputRoute(OutputKind.unknown, 'This computer');
  static const thisPhone = OutputRoute(OutputKind.builtIn, 'Phone speaker');

  @override
  bool operator ==(Object other) =>
      other is OutputRoute && other.kind == kind && other.name == name;

  @override
  int get hashCode => Object.hash(kind, name);
}

OutputKind _kindOf(AudioDeviceType t) => switch (t) {
  AudioDeviceType.bluetoothA2dp ||
  AudioDeviceType.bluetoothSco ||
  AudioDeviceType.bluetoothLe => OutputKind.bluetooth,
  AudioDeviceType.wiredHeadset ||
  AudioDeviceType.wiredHeadphones ||
  AudioDeviceType.lineAnalog ||
  AudioDeviceType.lineDigital ||
  AudioDeviceType.auxLine => OutputKind.wired,
  AudioDeviceType.usbAudio ||
  AudioDeviceType.dock ||
  AudioDeviceType.thunderbolt => OutputKind.usb,
  AudioDeviceType.airPlay => OutputKind.airplay,
  AudioDeviceType.hdmi ||
  AudioDeviceType.hdmiArc ||
  AudioDeviceType.displayPort => OutputKind.hdmi,
  AudioDeviceType.builtInSpeaker ||
  AudioDeviceType.builtInSpeakerSafe ||
  AudioDeviceType.builtInEarpiece => OutputKind.builtIn,
  _ => OutputKind.unknown,
};

const _priority = [
  OutputKind.usb,
  OutputKind.wired,
  OutputKind.bluetooth,
  OutputKind.airplay,
  OutputKind.hdmi,
  OutputKind.builtIn,
];

/// The output in use, guessed from the connected outputs the way phones route
/// audio: a plugged-in device wins, then Bluetooth, then the speaker.
OutputRoute pickRoute(Iterable<({OutputKind kind, String name})> outputs) {
  for (final k in _priority) {
    for (final o in outputs) {
      if (o.kind == k) {
        return OutputRoute(k, o.name.isEmpty ? _defaultName(k) : o.name);
      }
    }
  }
  return OutputRoute.thisPhone;
}

String _defaultName(OutputKind k) => switch (k) {
  OutputKind.builtIn => 'Phone speaker',
  OutputKind.wired => 'Headphones',
  OutputKind.usb => 'USB audio',
  OutputKind.bluetooth => 'Bluetooth',
  OutputKind.airplay => 'AirPlay',
  OutputKind.hdmi => 'HDMI',
  OutputKind.unknown => 'This device',
};

/// The current output, updated when headphones connect or disconnect.
final outputRouteProvider = StreamProvider<OutputRoute>((ref) async* {
  final mobile =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  if (!mobile || isDesktop) {
    yield OutputRoute.thisComputer;
    return;
  }
  AudioSession session;
  try {
    session = await AudioSession.instance;
  } catch (_) {
    yield OutputRoute.thisPhone;
    return;
  }
  Future<OutputRoute> read() async {
    try {
      final devices = await session.getDevices(includeInputs: false);
      return pickRoute(
        devices.map((d) => (kind: _kindOf(d.type), name: d.name)),
      );
    } catch (_) {
      return OutputRoute.thisPhone;
    }
  }

  yield await read();
  await for (final _ in session.devicesChangedEventStream) {
    yield await read();
  }
});
