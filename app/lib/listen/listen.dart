import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';

import '../api/hive_api.g.dart';
import '../auth/device_auth.dart';
import '../core/api.dart';
import 'shazam.dart';

/// Listen keeps the microphone on and checks as it goes: the first check
/// after [firstCheck], then every [checkEvery], each with the most recent
/// [window] of sound, so a song that started partway through (or the one
/// before it ending) drops out of what's checked. It stops as soon as home
/// is sure, or gives up after [giveUpAfter].
const firstCheck = Duration(seconds: 4);
const checkEvery = Duration(seconds: 2);
const window = Duration(seconds: 12);
const giveUpAfter = Duration(seconds: 24);

/// Microphone sound for Listen: 16 kHz mono, 16-bit.
const listenRate = 16000;

/// The microphone, as a stream of sound. Replaced in tests.
abstract class ClipRecorder {
  /// Asks for the microphone if needed; false when it's refused.
  Future<bool> permission();

  /// Starts listening: 16-bit mono samples at [listenRate].
  Future<Stream<Uint8List>> start();
  Future<void> stop();
}

class MicRecorder implements ClipRecorder {
  final _rec = AudioRecorder();

  @override
  Future<bool> permission() => _rec.hasPermission();

  @override
  Future<Stream<Uint8List>> start() => _rec.startStream(
    const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: listenRate,
      numChannels: 1,
      // Room sound as it is: the phone's call processing hides music.
      echoCancel: false,
      noiseSuppress: false,
      autoGain: true,
    ),
  );

  // Nothing is written to the device: the sound stays in memory and goes
  // home a few seconds at a time.
  @override
  Future<void> stop() => _rec.cancel();
}

final clipRecorderProvider = Provider<ClipRecorder>((ref) => MicRecorder());

/// A WAV file of 16-bit mono samples.
Uint8List wavOf(Uint8List pcm, {int rate = listenRate}) {
  final out = BytesBuilder(copy: false);
  final h = ByteData(44);
  void tag(int at, String t) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(at + i, t.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  h.setUint32(4, 36 + pcm.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  h.setUint32(16, 16, Endian.little);
  h.setUint16(20, 1, Endian.little); // PCM
  h.setUint16(22, 1, Endian.little); // mono
  h.setUint32(24, rate, Endian.little);
  h.setUint32(28, rate * 2, Endian.little);
  h.setUint16(32, 2, Endian.little);
  h.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  h.setUint32(40, pcm.length, Endian.little);
  out
    ..add(h.buffer.asUint8List())
    ..add(pcm);
  return out.takeBytes();
}

/// Sends a recording home to be recognised. [last] is the final try: home
/// keeps it in the history even when nothing matched. Replaced in tests.
typedef ClipMatcher = Future<ListenResult> Function(
  Uint8List clip, {
  required bool last,
});

final clipMatcherProvider = Provider<ClipMatcher>((ref) {
  return (clip, {required last}) async {
    final config = ref.read(homeConfigProvider);
    if (config == null) throw StateError('Not connected to a home yet');
    final dio = dioForHome(config, auth: ref.read(deviceAuthProvider));
    try {
      final r = await dio.post<dynamic>(
        '/api/v1/listen/match',
        queryParameters: {'last': last},
        data: Stream.fromIterable([clip]),
        options: Options(
          contentType: 'audio/wav',
          headers: {Headers.contentLengthHeader: clip.length},
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      return ListenResult.fromJson((r.data as Map).cast<String, dynamic>());
    } on DioException catch (e) {
      final body = e.response?.data;
      throw HiveApiException(
        e.response?.statusCode,
        body is Map ? Problem.fromJson(body.cast<String, dynamic>()) : null,
        e,
      );
    }
  };
});

enum ListenPhase { idle, listening, found, notFound, micDenied, failed }

@immutable
class ListenState {
  const ListenState({
    this.phase = ListenPhase.idle,
    this.heard = Duration.zero,
    this.result,
    this.error,
    this.askingShazam = false,
  });

  final ListenPhase phase;

  /// How long it has been listening.
  final Duration heard;
  final ListenResult? result;
  final String? error;

  /// Home didn't know it; Shazam is being asked (M5).
  final bool askingShazam;

  bool get busy => phase == ListenPhase.listening;
}

/// Listen: keep the microphone on, ask home every couple of seconds what
/// song it is, and stop as soon as home knows.
class ListenController extends Notifier<ListenState> {
  Timer? _ticker;
  StreamSubscription<Uint8List>? _mic;
  final _sound = BytesBuilder(copy: false);
  int _run = 0;
  bool _asking = false;
  Duration _nextCheck = firstCheck;
  int _ticks = 0;
  static const _tickEvery = Duration(milliseconds: 250);

  /// A match from a short check waits for the next check to agree.
  String? _unconfirmed;

  @override
  ListenState build() {
    ref.onDispose(_stopMic);
    return const ListenState();
  }

  ClipRecorder get _rec => ref.read(clipRecorderProvider);

  Future<void> listen() async {
    if (state.busy) return;
    final run = ++_run;
    if (!await _rec.permission()) {
      if (run == _run) state = const ListenState(phase: ListenPhase.micDenied);
      return;
    }
    final Stream<Uint8List> sound;
    try {
      sound = await _rec.start();
    } catch (e) {
      if (run == _run) {
        state = ListenState(
          phase: ListenPhase.failed,
          error: "The microphone didn't start. ($e)",
        );
      }
      return;
    }
    if (run != _run) {
      unawaited(_rec.stop()); // stopped while the microphone was starting
      return;
    }
    _sound.clear();
    _asking = false;
    _nextCheck = firstCheck;
    _ticks = 0;
    _unconfirmed = null;
    state = const ListenState(phase: ListenPhase.listening);
    _mic = sound.listen(_onSound, onError: (_) {});
    _ticker = Timer.periodic(_tickEvery, (_) => _tick(run));
  }

  void _onSound(Uint8List chunk) {
    _sound.add(chunk);
    // Only the last [window] is ever needed.
    final max = window.inMilliseconds * listenRate * 2 ~/ 1000;
    if (_sound.length > max * 2) {
      final all = _sound.takeBytes();
      _sound.add(Uint8List.sublistView(all, all.length - max));
    }
  }

  Uint8List _latest() {
    final max = window.inMilliseconds * listenRate * 2 ~/ 1000;
    final all = _sound.toBytes();
    return all.length <= max
        ? all
        : Uint8List.sublistView(all, all.length - max);
  }

  void _tick(int run) {
    if (run != _run || state.phase != ListenPhase.listening) return;
    final heard = _tickEvery * ++_ticks;
    state = ListenState(phase: ListenPhase.listening, heard: heard);
    final last = heard >= giveUpAfter;
    if (_asking || (heard < _nextCheck && !last)) return;
    _nextCheck = heard + checkEvery;
    unawaited(_ask(run, last: last));
  }

  Future<void> _ask(int run, {required bool last}) async {
    final pcm = _latest();
    if (pcm.length < listenRate * 2 * 3) return; // not 3 seconds yet
    _asking = true;
    if (last) _stopMic();
    try {
      final result = await ref.read(clipMatcherProvider)(
        wavOf(pcm),
        last: last,
      );
      if (run != _run) return;
      final named = result.track != null;
      final short = pcm.length < listenRate * 2 * 6;
      final which = result.track?.id ?? result.title;
      if (result.matched && named && short && !last && which != _unconfirmed) {
        // A few seconds can mislead; the next check has to agree.
        // (2 seconds later, with more to go on: the same few seconds
        // again would agree with themselves.)
        _unconfirmed = which;
        return;
      }
      if (!(result.matched && named)) _unconfirmed = null;
      if (result.matched && named) {
        _stopMic();
        state = ListenState(phase: ListenPhase.found, result: result);
        ref.invalidate(listenHistoryProvider);
      } else if (last) {
        // Not at home: Shazam, when the admin turned it on (M5).
        final shazam = await _askShazam(run, pcm, result.id);
        if (run != _run) return;
        state = shazam != null
            ? ListenState(phase: ListenPhase.found, result: shazam)
            : ListenState(phase: ListenPhase.notFound, result: result);
        ref.invalidate(listenHistoryProvider);
      }
    } catch (e) {
      if (run != _run) return;
      _stopMic();
      _run++;
      state = ListenState(phase: ListenPhase.failed, error: describeError(e));
    } finally {
      _asking = false;
    }
  }

  /// What Shazam calls the song, kept in the history at home; null when
  /// Shazam is off here, doesn't know it, or can't be reached.
  Future<ListenResult?> _askShazam(int run, Uint8List pcm, int? eventId) async {
    try {
      if (!await ref.read(shazamReadyProvider.future)) return null;
      if (run != _run) return null;
      state = ListenState(
        phase: ListenPhase.listening,
        heard: state.heard,
        askingShazam: true,
      );
      final hit = await ref
          .read(shazamLinkProvider)
          .match(pcm, rate: listenRate);
      if (hit == null || run != _run) return null;
      return await ref
          .read(hiveApiProvider)
          .recordListenResult(
            body: ShazamFound(
              title: hit.title,
              artist: hit.artist,
              listenEventId: eventId,
            ),
          );
    } catch (_) {
      return null; // as if Shazam didn't know it
    }
  }

  void _stopMic() {
    _ticker?.cancel();
    _ticker = null;
    final mic = _mic;
    _mic = null;
    if (mic != null) {
      unawaited(mic.cancel());
      unawaited(_rec.stop().catchError((_) {}));
    }
  }

  /// Stop listening now; anything still on its way back is ignored.
  void cancel() {
    _run++;
    _stopMic();
    state = const ListenState();
  }

  void reset() => state = const ListenState();
}

final listenProvider = NotifierProvider<ListenController, ListenState>(
  ListenController.new,
);

final listenHistoryProvider = FutureProvider.autoDispose<List<ListenEvent>>(
  (ref) async => (await ref.watch(hiveApiProvider).listListenHistory()).items,
);
