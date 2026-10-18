import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import '../core/api.dart';
import 'player_controller.dart';

/// Lock screen, notification, headphone buttons and media keys: the system's
/// view of the player. audio_service on Android, iOS and macOS;
/// audio_service_win (System Media Transport Controls) on Windows.
class HiveAudioHandler extends BaseAudioHandler with SeekHandler {
  HiveAudioHandler(this._container) {
    _sub = _container.listen<PlayerState>(
      playerProvider,
      (_, s) => _publish(s),
      fireImmediately: true,
    );
  }

  final ProviderContainer _container;
  late final ProviderSubscription<PlayerState> _sub;
  String? _lastItemKey;

  PlayerController get _player => _container.read(playerProvider.notifier);

  void _publish(PlayerState s) {
    final t = s.track;
    final config = _container.read(homeConfigProvider);
    if (t != null) {
      final key = '${s.current!.id}:${s.duration?.inMilliseconds}';
      if (key != _lastItemKey) {
        _lastItemKey = key;
        mediaItem.add(
          MediaItem(
            id: '${s.current!.id}',
            title: t.title,
            artist: t.artistName,
            album: t.albumTitle,
            duration: s.total,
            artUri: t.artworkId == null || config == null
                ? null
                : config.address.resolve(
                    '/api/v1/media/artwork/${t.artworkId}?size=600',
                  ),
            artHeaders: config?.authHeaders,
          ),
        );
      }
    } else if (_lastItemKey != null) {
      _lastItemKey = null;
      mediaItem.add(null);
    }
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (s.playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: s.isEmpty
            ? AudioProcessingState.idle
            : s.loading
            ? AudioProcessingState.loading
            : AudioProcessingState.ready,
        playing: s.playing,
        updatePosition: s.position,
        bufferedPosition: s.buffered,
        queueIndex: s.index < 0 ? null : s.index,
        repeatMode: switch (s.repeat) {
          RepeatMode.off => AudioServiceRepeatMode.none,
          RepeatMode.all => AudioServiceRepeatMode.all,
          RepeatMode.one => AudioServiceRepeatMode.one,
        },
        shuffleMode: s.shuffled
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
      ),
    );
  }

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> skipToNext() => _player.next();
  @override
  Future<void> skipToPrevious() => _player.previous();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> skipToQueueItem(int index) => _player.skipTo(index);
  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async =>
      _player.setRepeat(switch (repeatMode) {
        AudioServiceRepeatMode.none => RepeatMode.off,
        AudioServiceRepeatMode.one => RepeatMode.one,
        _ => RepeatMode.all,
      });
  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final on = shuffleMode != AudioServiceShuffleMode.none;
    if (on != _container.read(playerProvider).shuffled) _player.toggleShuffle();
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  void dispose() => _sub.close();
}

/// Set up audio for this platform before the app starts. Never fatal: without
/// a media session the app still plays, just without lock-screen controls.
Future<void> initAudio(ProviderContainer container) async {
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux)) {
    JustAudioMediaKit.ensureInitialized(windows: true, linux: true);
  }
  try {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  } catch (e) {
    debugPrint('audio session not configured: $e');
  }
  try {
    await AudioService.init(
      builder: () => HiveAudioHandler(container),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'dev.hivemusic.hive.playback',
        androidNotificationChannelName: 'Playback',
        androidNotificationIcon: 'drawable/ic_stat_hive',
        androidStopForegroundOnPause: true,
      ),
    );
  } catch (e) {
    debugPrint('media session unavailable: $e');
  }
}
