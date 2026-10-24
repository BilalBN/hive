import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

import '../../core/api.dart';
import '../../design/icons.g.dart';
import '../../design/tokens.g.dart';
import '../../player/player_controller.dart';

/// A playing video. The app's own player in use; replaced in tests.
abstract class VideoHandle {
  Future<void> start(Duration at);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration to);
  Duration get position;
  Duration get duration;
  bool get playing;
  double get aspectRatio;
  Listenable get changes;
  Widget view();
  Future<void> dispose();
}

class _PluginVideo implements VideoHandle {
  _PluginVideo(Uri url) : _c = VideoPlayerController.networkUrl(url);
  final VideoPlayerController _c;

  @override
  Future<void> start(Duration at) async {
    await _c.initialize();
    if (at > Duration.zero && at < _c.value.duration) await _c.seekTo(at);
    await _c.play();
  }

  @override
  Future<void> play() => _c.play();
  @override
  Future<void> pause() => _c.pause();
  @override
  Future<void> seek(Duration to) => _c.seekTo(to);
  @override
  Duration get position => _c.value.position;
  @override
  Duration get duration => _c.value.duration;
  @override
  bool get playing => _c.value.isPlaying;
  @override
  double get aspectRatio =>
      _c.value.isInitialized ? _c.value.aspectRatio : 16 / 9;
  @override
  Listenable get changes => _c;
  @override
  Widget view() => VideoPlayer(_c);
  @override
  Future<void> dispose() => _c.dispose();
}

final videoHandleFactory = Provider<VideoHandle Function(Uri url)>(
  (ref) => _PluginVideo.new,
);

String _clock(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// M6: the playing song's music video, from where the song was; going back
/// carries the song on from where the video got to.
class VideoScreen extends ConsumerStatefulWidget {
  const VideoScreen({super.key});

  @override
  ConsumerState<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends ConsumerState<VideoScreen> {
  VideoHandle? _video;
  String? _error;
  bool _wasPlaying = false;
  double? _drag;

  @override
  void initState() {
    super.initState();
    // After the first frame: opening pauses the song, which can't change
    // while the screen is being built.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_open()));
  }

  Future<void> _open() async {
    final player = ref.read(playerProvider);
    final track = player.track;
    final config = ref.read(homeConfigProvider);
    if (track == null || config == null) return;
    _wasPlaying = player.playing;
    final at = player.position;
    await ref.read(playerProvider.notifier).pause();
    try {
      final ticket = await ref
          .read(hiveApiProvider)
          .createVideoTicket(trackId: track.id);
      final video = ref.read(videoHandleFactory)(
        config.address.resolve(ticket.url),
      );
      if (!mounted) {
        unawaited(video.dispose());
        return;
      }
      setState(() => _video = video);
      await video.start(at);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  Future<void> _back() async {
    final video = _video;
    final router = GoRouter.of(context);
    if (video != null) {
      final at = video.position;
      final going = video.playing || _wasPlaying;
      await video.pause();
      final player = ref.read(playerProvider.notifier);
      await player.seek(at);
      if (going) await player.play();
    }
    if (router.canPop()) router.pop();
  }

  @override
  void dispose() {
    unawaited(_video?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final track = ref.watch(playerProvider.select((s) => s.track));
    final video = _video;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) unawaited(_back());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Back to the song',
                    icon: const Icon(
                      HiveIcons.chevronDown,
                      color: Colors.white,
                    ),
                    onPressed: _back,
                  ),
                  Expanded(
                    child: Text(
                      track == null
                          ? ''
                          : '${track.title} · ${track.artistName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HiveType.headline.copyWith(color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: HiveSpace.md),
                ],
              ),
              Expanded(
                child: Center(
                  child: _error != null
                      ? Padding(
                          padding: const EdgeInsets.all(HiveSpace.lg),
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: HiveType.body.copyWith(
                              color: Colors.white70,
                            ),
                          ),
                        )
                      : video == null
                      ? const CircularProgressIndicator(color: Colors.white)
                      : ListenableBuilder(
                          listenable: video.changes,
                          builder: (_, _) => AspectRatio(
                            aspectRatio: video.aspectRatio,
                            child: video.view(),
                          ),
                        ),
                ),
              ),
              if (video != null)
                ListenableBuilder(
                  listenable: video.changes,
                  builder: (context, _) {
                    final total = video.duration;
                    final at = video.position;
                    final fraction = total.inMilliseconds <= 0
                        ? 0.0
                        : (_drag ?? at.inMilliseconds / total.inMilliseconds)
                              .clamp(0.0, 1.0);
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(
                        HiveSpace.md,
                        0,
                        HiveSpace.md,
                        HiveSpace.md,
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: video.playing ? 'Pause' : 'Play',
                            icon: Icon(
                              video.playing ? HiveIcons.pause : HiveIcons.play,
                              color: Colors.white,
                            ),
                            onPressed: video.playing ? video.pause : video.play,
                          ),
                          Text(
                            _clock(total * fraction),
                            style: HiveType.caption.copyWith(
                              color: Colors.white,
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              value: fraction,
                              activeColor: Colors.white,
                              inactiveColor: Colors.white24,
                              onChanged: (v) => setState(() => _drag = v),
                              onChangeEnd: (v) {
                                setState(() => _drag = null);
                                unawaited(video.seek(total * v));
                              },
                            ),
                          ),
                          Text(
                            _clock(total),
                            style: HiveType.caption.copyWith(
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
