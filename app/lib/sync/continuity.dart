import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/hive_api.g.dart';
import '../auth/device_auth.dart';
import '../core/api.dart';
import '../core/app_info.dart';
import '../core/home_connection.dart';
import '../player/player_controller.dart';
import '../push/push.dart';
import 'remote.dart';

/// This app on this device: stays the same across sign-ins, so a phone
/// doesn't offer to carry on from itself.
final installIdProvider = Provider<String>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  var id = prefs.getString('app.installId');
  if (id == null) {
    final r = Random.secure();
    id = List.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    unawaited(prefs.setString('app.installId', id));
  }
  return id;
});

/// Something the person's other devices did, heard over the sync link.
sealed class SyncEvent {
  const SyncEvent();
}

/// The person's last play session changed (continuity).
class SessionChanged extends SyncEvent {
  const SessionChanged(this.session);
  final PlaySession? session;
}

/// Another device's playing changed (M6: remotes).
class DeviceChanged extends SyncEvent {
  const DeviceChanged(this.device);
  final Device device;
}

/// A device opened or closed Hive (M6).
class DevicesChanged extends SyncEvent {
  const DevicesChanged();
}

/// Another of the person's devices asks this one to do something (M6).
class CommandReceived extends SyncEvent {
  const CommandReceived(this.fromName, this.command);
  final String fromName;
  final RemoteCommand command;
}

/// A notification for this person while Hive is open (M6).
class NoticeReceived extends SyncEvent {
  const NoticeReceived(this.kind, this.title, this.body);
  final String kind;
  final String title;
  final String body;
}

/// Talks to home about play sessions, devices and remote commands.
/// Replaced in tests.
abstract class SessionLink {
  Future<PlaySession?> fetch();
  Future<void> report(PlaySessionUpdate update);

  /// What the person's other devices do, as it happens; ends when the
  /// connection drops.
  Stream<SyncEvent> events();

  /// The person's devices with Hive open now (this one included).
  Future<List<Device>> devices();

  /// Tell one of them to do something.
  Future<void> command(String installId, DeviceCommand command);
}

class HomeSessionLink implements SessionLink {
  HomeSessionLink(this._ref);
  final Ref _ref;

  @override
  Future<PlaySession?> fetch() async =>
      (await _ref.read(hiveApiProvider).getPlaySession()).session;

  @override
  Future<void> report(PlaySessionUpdate update) =>
      _ref.read(hiveApiProvider).updatePlaySession(body: update);

  @override
  Future<List<Device>> devices() async =>
      (await _ref.read(hiveApiProvider).listDevices()).items;

  @override
  Future<void> command(String installId, DeviceCommand command) => _ref
      .read(hiveApiProvider)
      .commandDevice(installId: installId, body: command);

  @override
  Stream<SyncEvent> events() async* {
    final config = _ref.read(homeConfigProvider);
    if (config == null || kIsWeb) return;
    final auth = _ref.read(deviceAuthProvider);
    final token = auth.signedIn ? await auth.accessToken() : null;
    final headers = token != null
        ? {'Authorization': 'Bearer $token'}
        : config.authHeaders;
    final base = config.address;
    final url = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/api/v1/sync/events',
      queryParameters: {
        'install': _ref.read(installIdProvider),
        'name': defaultDeviceName,
      },
    );
    final ws = await WebSocket.connect(url.toString(), headers: headers);
    ws.pingInterval = const Duration(seconds: 45);
    await for (final raw in ws) {
      if (raw is! String) continue;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      switch (m['type']) {
        case 'session':
          final s = m['session'];
          yield SessionChanged(
            s is Map && s.isNotEmpty
                ? PlaySession.fromJson(s.cast<String, dynamic>())
                : null,
          );
        case 'device':
          yield DeviceChanged(
            Device.fromJson((m['device'] as Map).cast<String, dynamic>()),
          );
        case 'devices':
          yield const DevicesChanged();
        case 'notice':
          yield NoticeReceived(
            m['kind'] as String? ?? '',
            m['title'] as String? ?? 'Hive',
            m['body'] as String? ?? '',
          );
        case 'command':
          yield CommandReceived(
            (m['fromName'] as String?) ?? 'Another device',
            RemoteCommand.fromJson(
              (m['command'] as Map).cast<String, dynamic>(),
            ),
          );
      }
    }
  }
}

final sessionLinkProvider = Provider<SessionLink>(HomeSessionLink.new);

/// What another of your devices was playing, when it's worth offering to
/// carry on here.
@immutable
class ContinuityState {
  const ContinuityState({this.session, this.dismissed});
  final PlaySession? session;

  /// "installId@updatedAt" of a session the person said no to.
  final String? dismissed;
}

/// Reports what this device plays, and hears what the person's other
/// devices played, for the "Continue from …" offer.
class ContinuityController extends Notifier<ContinuityState> {
  Timer? _heartbeat;
  Timer? _debounce;
  StreamSubscription<SyncEvent>? _changes;
  Timer? _retry;
  int _failures = 0;
  String _lastReported = '';
  AppLifecycleListener? _lifecycle;

  SessionLink get _link => ref.read(sessionLinkProvider);
  String get _install => ref.read(installIdProvider);

  @override
  ContinuityState build() {
    ref.listen(playerProvider, (before, now) => _onPlayer(before, now));
    ref.listen(homeStatusProvider, (_, s) {
      if (s is HomeConnected) {
        unawaited(refresh());
        _listen();
      } else {
        _stopListening();
      }
    });
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(refresh()));
    ref.onDispose(() {
      _heartbeat?.cancel();
      _debounce?.cancel();
      _retry?.cancel();
      _lifecycle?.dispose();
      unawaited(_changes?.cancel());
    });
    if (ref.read(homeStatusProvider) is HomeConnected) {
      Future.microtask(() {
        unawaited(refresh());
        _listen();
      });
    }
    return const ContinuityState();
  }

  /// The offer to show, if any: another device's, recent, not dismissed,
  /// and nothing playing here.
  PlaySession? get offer {
    final s = state.session;
    if (s == null || !s.offer || s.installId == _install) return null;
    if (state.dismissed == _keyOf(s)) return null;
    final player = ref.read(playerProvider);
    if (player.playing) return null;
    return s;
  }

  String _keyOf(PlaySession s) =>
      '${s.installId}@${s.updatedAt.toIso8601String()}';

  Future<void> refresh() async {
    try {
      final s = await _link.fetch();
      state = ContinuityState(session: s, dismissed: state.dismissed);
    } catch (_) {
      // Tried again when home is back or the app comes to the front.
    }
  }

  void dismiss() {
    final s = state.session;
    if (s != null) state = ContinuityState(session: s, dismissed: _keyOf(s));
  }

  /// Carry on here: the same queue, from the same place in the song.
  Future<void> carryOn() async {
    final s = state.session;
    if (s == null) return;
    dismiss();
    final player = ref.read(playerProvider.notifier);
    final source = s.source;
    await player.playTracks(
      s.queue,
      start: s.index,
      source: source == null
          ? null
          : PlaySource(kind: source.kind, id: source.id, name: source.name),
    );
    if (s.positionMs > 2000) {
      await player.seek(Duration(milliseconds: s.positionMs));
    }
  }

  // ------------------------------------------------------------ reporting

  void _onPlayer(PlayerState? before, PlayerState now) {
    final changed =
        before == null ||
        before.track?.id != now.track?.id ||
        before.playing != now.playing ||
        before.index != now.index ||
        (before.position - now.position).inSeconds.abs() > 5;
    if (changed) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 1500), _report);
    }
    if (now.playing && _heartbeat == null) {
      _heartbeat = Timer.periodic(
        const Duration(seconds: 15),
        (_) => _report(),
      );
    } else if (!now.playing) {
      _heartbeat?.cancel();
      _heartbeat = null;
    }
  }

  Future<void> _report() async {
    if (ref.read(homeStatusProvider) is! HomeConnected) return;
    final p = ref.read(playerProvider);
    final track = p.track;
    // Up to 100 songs either side of the current one.
    final from = max(0, p.index - 100);
    final queue = p.queue.sublist(from, min(p.queue.length, p.index + 100));
    final update = PlaySessionUpdate(
      installId: _install,
      deviceName: defaultDeviceName,
      trackId: track?.id,
      positionMs: p.position.inMilliseconds,
      playing: p.playing,
      queue: [for (final e in queue) e.track.id],
      index: max(0, p.index - from),
      source: p.source == null
          ? null
          : SessionSource(
              kind: p.source!.kind,
              id: p.source!.id,
              name: p.source!.name,
            ),
    );
    final key =
        '${update.trackId}|${update.playing}|${update.index}|${(update.positionMs ?? 0) ~/ 15000}';
    if (key == _lastReported && !p.playing) return;
    _lastReported = key;
    try {
      await _link.report(update);
    } catch (_) {
      // The next change or heartbeat tries again.
    }
  }

  // ------------------------------------------------------------ listening

  void _listen() {
    if (_changes != null) return;
    _retry?.cancel();
    try {
      _changes = _link.events().listen(
        (e) {
          _failures = 0;
          switch (e) {
            case SessionChanged(:final session):
              state = ContinuityState(
                session: session,
                dismissed: state.dismissed,
              );
            case CommandReceived():
              unawaited(obey(ref, e));
            case NoticeReceived():
              ref.read(noticeProvider.notifier).show(e);
              unawaited(showNoticeIfHidden(ref, e));
            case DeviceChanged() || DevicesChanged():
              ref.read(remoteProvider.notifier).heard(e);
          }
        },
        onError: (_) => _reconnect(),
        onDone: _reconnect,
        cancelOnError: true,
      );
    } catch (_) {
      _reconnect();
    }
  }

  void _reconnect() {
    _changes = null;
    if (ref.read(homeStatusProvider) is! HomeConnected) return;
    _failures++;
    final wait = Duration(seconds: min(60, 2 << min(_failures, 5)));
    _retry = Timer(wait, _listen);
  }

  void _stopListening() {
    _retry?.cancel();
    unawaited(_changes?.cancel());
    _changes = null;
  }
}

final continuityProvider =
    NotifierProvider<ContinuityController, ContinuityState>(
      ContinuityController.new,
    );

/// The offer to show right now (another device's session, recent, not
/// dismissed, nothing playing here), or null.
final continuityOfferProvider = Provider<PlaySession?>((ref) {
  ref.watch(continuityProvider);
  ref.watch(playerProvider.select((s) => s.playing));
  return ref.read(continuityProvider.notifier).offer;
});
