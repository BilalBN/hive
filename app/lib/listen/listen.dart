import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../api/hive_api.g.dart';
import '../auth/device_auth.dart';
import '../core/api.dart';

/// How long Listen records.
const listenSeconds = 8;

/// The microphone, for a few seconds at a time. Replaced in tests.
abstract class ClipRecorder {
  /// Asks for the microphone if needed; false when it's refused.
  Future<bool> permission();
  Future<void> start();

  /// The recording (WAV), or null if nothing was recorded.
  Future<Uint8List?> stop();
  Future<void> cancel();

  /// Loudness now, 0..1, for the listening animation.
  Stream<double> level();
}

class MicRecorder implements ClipRecorder {
  final _rec = AudioRecorder();
  String? _path;

  @override
  Future<bool> permission() => _rec.hasPermission();

  @override
  Future<void> start() async {
    final dir = await getTemporaryDirectory();
    _path =
        '${dir.path}/hive-listen-${DateTime.now().millisecondsSinceEpoch}.wav';
    await _rec.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        // Room sound as it is: the phone's call processing hides music.
        echoCancel: false,
        noiseSuppress: false,
        autoGain: true,
      ),
      path: _path!,
    );
  }

  @override
  Future<Uint8List?> stop() async {
    final path = await _rec.stop() ?? _path;
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    // The clip goes home once and is never kept on the device.
    await file.delete().catchError((_) => file);
    return bytes;
  }

  @override
  Future<void> cancel() async {
    await _rec.cancel();
  }

  @override
  Stream<double> level() => _rec
      .onAmplitudeChanged(const Duration(milliseconds: 120))
      .map((a) => ((a.current + 50) / 50).clamp(0.0, 1.0));
}

final clipRecorderProvider = Provider<ClipRecorder>((ref) => MicRecorder());

/// Sends a recording home to be recognised. Replaced in tests.
typedef ClipMatcher = Future<ListenResult> Function(Uint8List clip);

final clipMatcherProvider = Provider<ClipMatcher>((ref) {
  return (clip) async {
    final config = ref.read(homeConfigProvider);
    if (config == null) throw StateError('Not connected to a home yet');
    final dio = dioForHome(config, auth: ref.read(deviceAuthProvider));
    try {
      final r = await dio.post<dynamic>(
        '/api/v1/listen/match',
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

/// "Identified by Shazam": songs that aren't at home named by Shazam. The
/// path is built and tested, but stays off until M5 turns it on.
final shazamProvider = Provider<bool>((ref) => false);

enum ListenPhase {
  idle,
  listening,
  matching,
  found,
  notFound,
  micDenied,
  failed,
}

@immutable
class ListenState {
  const ListenState({
    this.phase = ListenPhase.idle,
    this.secondsLeft = listenSeconds,
    this.result,
    this.error,
  });

  final ListenPhase phase;
  final int secondsLeft;
  final ListenResult? result;
  final String? error;

  bool get busy =>
      phase == ListenPhase.listening || phase == ListenPhase.matching;
}

/// Listen: record a few seconds, ask home what song it is.
class ListenController extends Notifier<ListenState> {
  Timer? _timer;

  @override
  ListenState build() {
    ref.onDispose(() => _timer?.cancel());
    return const ListenState();
  }

  ClipRecorder get _rec => ref.read(clipRecorderProvider);

  Future<void> listen() async {
    if (state.busy) return;
    if (!await _rec.permission()) {
      state = const ListenState(phase: ListenPhase.micDenied);
      return;
    }
    try {
      await _rec.start();
    } catch (e) {
      state = ListenState(
        phase: ListenPhase.failed,
        error: "The microphone didn't start. ($e)",
      );
      return;
    }
    state = const ListenState(phase: ListenPhase.listening);
    final done = Completer<void>();
    var left = listenSeconds;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      left--;
      if (left <= 0) {
        t.cancel();
        if (!done.isCompleted) done.complete();
      } else if (state.phase == ListenPhase.listening) {
        state = ListenState(phase: ListenPhase.listening, secondsLeft: left);
      }
    });
    await done.future;
    if (state.phase != ListenPhase.listening) return; // cancelled
    final clip = await _rec.stop();
    if (clip == null || clip.isEmpty) {
      state = const ListenState(
        phase: ListenPhase.failed,
        error: 'Nothing was recorded. Try again.',
      );
      return;
    }
    state = const ListenState(phase: ListenPhase.matching);
    try {
      final result = await ref.read(clipMatcherProvider)(clip);
      final named =
          result.track != null ||
          (ref.read(shazamProvider) &&
              result.source == 'shazam' &&
              result.title != null);
      state = ListenState(
        phase: result.matched && named
            ? ListenPhase.found
            : ListenPhase.notFound,
        result: result,
      );
    } catch (e) {
      state = ListenState(phase: ListenPhase.failed, error: describeError(e));
    }
    ref.invalidate(listenHistoryProvider);
  }

  Future<void> cancel() async {
    _timer?.cancel();
    if (state.phase == ListenPhase.listening) await _rec.cancel();
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
