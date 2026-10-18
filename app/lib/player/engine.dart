import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// One song the engine can play: a stream URL from a ticket.
class EngineSource {
  const EngineSource({required this.uri, required this.entryId});
  final Uri uri;

  /// The queue entry this source plays, so index changes can be matched up.
  final int entryId;
}

enum EngineProcessing { idle, loading, buffering, ready, completed }

/// What the player controller needs from an audio engine. just_audio in the
/// app; a fake in tests, so the queue logic is tested without audio.
abstract class AudioEngine {
  Stream<int?> get indexStream;
  Stream<bool> get playingStream;
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Stream<Duration> get bufferedStream;
  Stream<EngineProcessing> get processingStream;

  int? get index;
  Duration get position;
  bool get playing;

  /// Replace everything with these sources (the current song and the next).
  Future<void> setSources(
    List<EngineSource> sources, {
    Duration position = Duration.zero,
  });
  Future<void> addSource(EngineSource source);
  Future<void> removeAt(int index);
  int get length;

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setRepeatOne(bool on);
  Future<void> stop();
  Future<void> dispose();
}

/// just_audio: ExoPlayer on Android, AVQueuePlayer on Apple, media_kit (mpv)
/// on Windows. Keeping the next song loaded is what makes playback gapless.
class JustAudioEngine implements AudioEngine {
  JustAudioEngine()
    : _player = AudioPlayer(
        // Buffer well ahead so a short network dip doesn't stop lossless.
        audioLoadConfiguration: const AudioLoadConfiguration(
          androidLoadControl: AndroidLoadControl(
            minBufferDuration: Duration(seconds: 30),
            maxBufferDuration: Duration(minutes: 3),
          ),
          darwinLoadControl: DarwinLoadControl(
            preferredForwardBufferDuration: Duration(seconds: 60),
          ),
        ),
      );

  final AudioPlayer _player;
  int _length = 0;

  @override
  Stream<int?> get indexStream => _player.currentIndexStream;
  @override
  Stream<bool> get playingStream => _player.playingStream;
  @override
  Stream<Duration> get positionStream => _player.createPositionStream(
    minPeriod: const Duration(milliseconds: 200),
    maxPeriod: const Duration(milliseconds: 500),
  );
  @override
  Stream<Duration?> get durationStream => _player.durationStream;
  @override
  Stream<Duration> get bufferedStream => _player.bufferedPositionStream;
  @override
  Stream<EngineProcessing> get processingStream =>
      _player.processingStateStream.map(
        (s) => switch (s) {
          ProcessingState.idle => EngineProcessing.idle,
          ProcessingState.loading => EngineProcessing.loading,
          ProcessingState.buffering => EngineProcessing.buffering,
          ProcessingState.ready => EngineProcessing.ready,
          ProcessingState.completed => EngineProcessing.completed,
        },
      );

  @override
  int? get index => _player.currentIndex;
  @override
  Duration get position => _player.position;
  @override
  bool get playing => _player.playing;
  @override
  int get length => _length;

  AudioSource _source(EngineSource s) => AudioSource.uri(s.uri, tag: s.entryId);

  @override
  Future<void> setSources(
    List<EngineSource> sources, {
    Duration position = Duration.zero,
  }) async {
    _length = sources.length;
    await _player.setAudioSources(
      sources.map(_source).toList(),
      initialIndex: 0,
      initialPosition: position,
    );
  }

  @override
  Future<void> addSource(EngineSource source) async {
    _length += 1;
    await _player.addAudioSource(_source(source));
  }

  @override
  Future<void> removeAt(int index) async {
    _length -= 1;
    await _player.removeAudioSourceAt(index);
  }

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);
  @override
  Future<void> setRepeatOne(bool on) =>
      _player.setLoopMode(on ? LoopMode.one : LoopMode.off);
  @override
  Future<void> stop() async {
    _length = 0;
    await _player.stop();
  }

  @override
  Future<void> dispose() => _player.dispose();
}
