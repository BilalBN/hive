import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/hive_api.g.dart';
import '../core/api.dart';
import '../core/home_connection.dart';
import '../player/player_controller.dart';
import 'continuity.dart';

/// M6: playback on the person's other devices. Move what's playing here to
/// another device, use this one as its remote, or bring it back here.

/// Carry out what another of the person's devices asked of this one.
Future<void> obey(Ref ref, CommandReceived e) async {
  final c = e.command;
  final player = ref.read(playerProvider.notifier);
  switch (c.action) {
    case 'play':
      await player.play();
    case 'pause':
      await player.pause();
    case 'next':
      await player.next();
    case 'previous':
      await player.previous();
    case 'seek':
      if (c.positionMs != null) {
        await player.seek(Duration(milliseconds: c.positionMs!));
      }
    case 'volume':
      if (c.volume != null) await player.setUserVolume(c.volume!.toDouble());
    case 'load':
      final queue = c.queue ?? const <TrackSummary>[];
      if (queue.isEmpty) return;
      final source = c.source;
      await player.playTracks(
        queue,
        start: (c.index ?? 0).clamp(0, queue.length - 1),
        source: source == null
            ? null
            : PlaySource(kind: source.kind, id: source.id, name: source.name),
      );
      if ((c.positionMs ?? 0) > 2000) {
        await player.seek(Duration(milliseconds: c.positionMs!));
      }
      if (c.playing == false) await player.pause();
  }
}

@immutable
class RemoteState {
  const RemoteState({
    this.devices = const [],
    this.target,
    this.heardAt,
    this.error,
  });

  /// The person's other devices with Hive open.
  final List<Device> devices;

  /// The device this one is the remote for, if any.
  final String? target;

  /// When each device's position was last heard, to count on from.
  final Map<String, DateTime>? heardAt;
  final String? error;

  Device? get controlled =>
      devices.where((d) => d.installId == target).firstOrNull;

  /// Where the controlled device is in its song by now.
  Duration positionOf(Device d) {
    final at = heardAt?[d.installId];
    var ms = d.positionMs ?? 0;
    if (d.playing && at != null) {
      ms += DateTime.now().difference(at).inMilliseconds;
    }
    final total = d.track?.durationMs;
    if (total != null && ms > total) ms = total;
    return Duration(milliseconds: ms);
  }

  RemoteState copyWith({
    List<Device>? devices,
    String? target,
    bool clearTarget = false,
    Map<String, DateTime>? heardAt,
    String? error,
  }) => RemoteState(
    devices: devices ?? this.devices,
    target: clearTarget ? null : (target ?? this.target),
    heardAt: heardAt ?? this.heardAt,
    error: error,
  );
}

class RemoteController extends Notifier<RemoteState> {
  SessionLink get _link => ref.read(sessionLinkProvider);
  String get _me => ref.read(installIdProvider);

  @override
  RemoteState build() {
    ref.listen(homeStatusProvider, (_, s) {
      if (s is HomeConnected) unawaited(refresh());
    });
    if (ref.read(homeStatusProvider) is HomeConnected) {
      Future.microtask(refresh);
    }
    return const RemoteState();
  }

  Map<String, DateTime> _stamp(Iterable<Device> devices) {
    final now = DateTime.now();
    return {...?state.heardAt, for (final d in devices) d.installId: now};
  }

  Future<void> refresh() async {
    try {
      final all = await _link.devices();
      final others = [
        for (final d in all)
          if (d.installId != _me) d,
      ];
      final target = state.target;
      state = state.copyWith(
        devices: others,
        heardAt: _stamp(others),
        clearTarget:
            target != null && !others.any((d) => d.installId == target),
      );
    } catch (_) {
      // Tried again when a device opens or closes, or home is back.
    }
  }

  /// Another device's change, heard over the sync link.
  void heard(SyncEvent e) {
    switch (e) {
      case DeviceChanged(:final device):
        if (device.installId == _me) return;
        final known = state.devices.any((d) => d.installId == device.installId);
        state = state.copyWith(
          devices: known
              ? [
                  for (final d in state.devices)
                    d.installId == device.installId ? device : d,
                ]
              : [...state.devices, device],
          heardAt: _stamp([device]),
        );
      case DevicesChanged():
        unawaited(refresh());
      default:
        break;
    }
  }

  /// Be the remote for [installId].
  void control(String installId) => state = state.copyWith(target: installId);

  void stopControlling() => state = state.copyWith(clearTarget: true);

  Future<bool> _send(String installId, DeviceCommand c) async {
    try {
      await _link.command(installId, c);
      return true;
    } catch (e) {
      state = state.copyWith(error: describeError(e));
      unawaited(refresh());
      return false;
    }
  }

  DeviceCommand _cmd(String action, {int? positionMs, double? volume}) =>
      DeviceCommand(
        action: action,
        fromInstall: _me,
        positionMs: positionMs,
        volume: volume,
      );

  /// Play, pause, skip or seek on the controlled device.
  Future<void> send(String action, {Duration? position, double? volume}) async {
    final d = state.controlled;
    if (d == null) return;
    final ok = await _send(
      d.installId,
      _cmd(action, positionMs: position?.inMilliseconds, volume: volume),
    );
    if (!ok) return;
    // Shown at once; the device's own report follows.
    if (action == 'play' || action == 'pause' || action == 'seek') {
      final updated = Device(
        installId: d.installId,
        deviceName: d.deviceName,
        playing: action == 'seek' ? d.playing : action == 'play',
        track: d.track,
        positionMs: action == 'seek'
            ? position!.inMilliseconds
            : state.positionOf(d).inMilliseconds,
        updatedAt: d.updatedAt,
      );
      heard(DeviceChanged(updated));
    }
  }

  /// Move what's playing here to [installId], and become its remote.
  Future<bool> moveTo(String installId) async {
    final p = ref.read(playerProvider);
    if (p.track == null) {
      control(installId);
      return true;
    }
    final from = (p.index - 100).clamp(0, p.queue.length);
    final to = (p.index + 100).clamp(0, p.queue.length);
    final ok = await _send(
      installId,
      DeviceCommand(
        action: 'load',
        fromInstall: _me,
        queue: [for (final e in p.queue.sublist(from, to)) e.track.id],
        index: p.index - from,
        positionMs: p.position.inMilliseconds,
        playing: p.playing,
        source: p.source == null
            ? null
            : SessionSource(
                kind: p.source!.kind,
                id: p.source!.id,
                name: p.source!.name,
              ),
      ),
    );
    if (!ok) return false;
    await ref.read(playerProvider.notifier).pause();
    control(installId);
    return true;
  }

  /// Bring the controlled device's song here, and pause it there.
  Future<void> bringHere() async {
    final d = state.controlled;
    final track = d?.track;
    if (d == null || track == null) return;
    final position = state.positionOf(d);
    final player = ref.read(playerProvider.notifier);
    // Its whole queue when home has it (the person's latest session).
    final session = await _link.fetch().catchError((_) => null);
    if (session != null &&
        session.installId == d.installId &&
        session.track.id == track.id) {
      await player.playTracks(session.queue, start: session.index);
    } else {
      await player.playTracks([track]);
    }
    if (position.inMilliseconds > 2000) await player.seek(position);
    await _send(d.installId, _cmd('pause'));
    stopControlling();
  }
}

final remoteProvider = NotifierProvider<RemoteController, RemoteState>(
  RemoteController.new,
);
