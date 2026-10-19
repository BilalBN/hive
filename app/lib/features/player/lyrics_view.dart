import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/hive_api.g.dart';
import '../../design/glass.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../library/library_providers.dart';
import '../../player/player_controller.dart';
import '../../ui/art_backdrop.dart';
import '../../ui/artwork.dart';
import '../../ui/states.dart';
import 'player_parts.dart';

/// Lyrics as their own screen (phones): big lines on the cover's colours,
/// with the song's controls underneath.
class LyricsScreen extends ConsumerWidget {
  const LyricsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(playerProvider.select((s) => s.track));
    return Theme(
      data: buildHiveTheme(Brightness.dark),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: ArtBackdrop(
          artworkId: track?.artworkId,
          title: track?.albumTitle ?? 'Lyrics',
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    HiveSpace.lg,
                    HiveSpace.sm,
                    HiveSpace.md,
                    HiveSpace.xs,
                  ),
                  child: Row(
                    children: [
                      if (track != null) ...[
                        Artwork(
                          artworkId: track.artworkId,
                          title: track.albumTitle,
                          size: 48,
                          pixels: 96,
                          radius: 8,
                        ),
                        const SizedBox(width: HiveSpace.sm),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              track?.title ?? 'Lyrics',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HiveType.headline.copyWith(
                                color: OnArt.primary,
                              ),
                            ),
                            if (track != null)
                              Text(
                                track.artistName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: HiveType.callout.copyWith(
                                  color: OnArt.secondary,
                                ),
                              ),
                          ],
                        ),
                      ),
                      GlassCircleButton(
                        tooltip: 'Close',
                        onPressed: () => context.pop(),
                        child: const Icon(
                          HiveIcons.chevronDown,
                          size: 20,
                          color: OnArt.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ShaderMask(
                    // Lines fade in and out at the edges instead of being cut.
                    shaderCallback: (rect) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.white,
                        Colors.white,
                        Colors.transparent,
                      ],
                      stops: [0, 0.06, 0.9, 1],
                    ).createShader(rect),
                    blendMode: BlendMode.dstIn,
                    child: const LyricsView(large: true),
                  ),
                ),
                if (track != null)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(
                      HiveSpace.lg + 4,
                      0,
                      HiveSpace.lg + 4,
                      HiveSpace.sm,
                    ),
                    child: Column(
                      children: [
                        SeekBar(onArt: true),
                        TransportControls(
                          size: 34,
                          showModes: false,
                          onArt: true,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Lyrics for the playing song. Timed lyrics follow the song and a tap on a
/// line jumps there; plain lyrics just scroll.
class LyricsView extends ConsumerWidget {
  const LyricsView({super.key, this.large = false});
  final bool large;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(playerProvider.select((s) => s.track));
    if (track == null) {
      return const EmptyState(
        icon: HiveIcons.micVocal,
        title: 'No song playing',
        text: 'Lyrics show here while a song plays.',
      );
    }
    if (track.hasLyrics == false) {
      return const EmptyState(
        icon: HiveIcons.micVocal,
        title: 'No lyrics for this song',
        text: 'Lyrics come from the file\'s tags or a .lrc file beside it at home.',
      );
    }
    final lyrics = ref.watch(lyricsProvider(track.id));
    return AsyncView<Lyrics>(
      value: lyrics,
      onRetry: () => ref.invalidate(lyricsProvider(track.id)),
      data: (l) => l.lines.isEmpty
          ? const EmptyState(
              icon: HiveIcons.micVocal,
              title: 'No lyrics for this song',
              text: 'Lyrics come from the file\'s tags or a .lrc file beside it at home.',
            )
          : _Lines(key: ValueKey(track.id), lyrics: l, large: large),
    );
  }
}

class _Lines extends ConsumerStatefulWidget {
  const _Lines({super.key, required this.lyrics, required this.large});
  final Lyrics lyrics;
  final bool large;

  @override
  ConsumerState<_Lines> createState() => _LinesState();
}

class _LinesState extends ConsumerState<_Lines> {
  final _keys = <int, GlobalKey>{};
  int _shown = -1;

  bool get _timed =>
      widget.lyrics.kind == 'synced' ||
      widget.lyrics.lines.any((l) => l.timeMs != null);

  int _activeAt(Duration position) {
    final ms = position.inMilliseconds;
    var active = -1;
    for (var i = 0; i < widget.lyrics.lines.length; i++) {
      final t = widget.lyrics.lines[i].timeMs;
      if (t != null && t <= ms) active = i;
    }
    return active;
  }

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final timed = _timed;
    final position = timed
        ? ref.watch(playerProvider.select((s) => s.position))
        : Duration.zero;
    final active = timed ? _activeAt(position) : -1;
    if (active != _shown && active >= 0) {
      _shown = active;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _keys[active]?.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.35,
            duration: HiveMotion.screen,
            curve: Curves.easeOut,
          );
        }
      });
    }
    final onArt = widget.large;
    final base = onArt
        ? HiveType.title1.copyWith(fontSize: 26, height: 1.25)
        : HiveType.headline;
    return ListView.builder(
      padding: EdgeInsets.symmetric(
        horizontal: HiveSpace.lg,
        vertical: widget.large ? HiveSpace.xl : HiveSpace.md,
      ),
      itemCount: widget.lyrics.lines.length + (timed ? 0 : 1),
      itemBuilder: (context, i) {
        if (i == widget.lyrics.lines.length) {
          return Padding(
            padding: const EdgeInsets.only(top: HiveSpace.lg),
            child: Text(
              'These lyrics aren\'t timed, so they don\'t follow the song.',
              style: HiveType.caption.copyWith(
                color: onArt ? OnArt.tertiary : p.textTertiary,
              ),
            ),
          );
        }
        final line = widget.lyrics.lines[i];
        final key = _keys.putIfAbsent(i, GlobalKey.new);
        final color = onArt
            ? (!timed || i == active
                  ? OnArt.primary
                  : Colors.white.withValues(alpha: i < active ? 0.3 : 0.45))
            : !timed
            ? p.textPrimary
            : i == active
            ? p.textPrimary
            : (i < active ? p.textTertiary : p.textSecondary);
        final text = Padding(
          key: key,
          padding: EdgeInsets.symmetric(vertical: timed ? 6 : 2),
          child: AnimatedDefaultTextStyle(
            duration: HiveMotion.fast,
            style:
                (timed
                        ? base
                        : (onArt
                              ? HiveType.title2.copyWith(
                                  fontWeight: FontWeight.w600,
                                )
                              : HiveType.body))
                    .copyWith(color: color, height: 1.35),
            child: Text(line.text.isEmpty ? '♪' : line.text),
          ),
        );
        if (!timed || line.timeMs == null) return text;
        return InkWell(
          borderRadius: BorderRadius.circular(HiveRadius.art),
          onTap: () => ref
              .read(playerProvider.notifier)
              .seek(Duration(milliseconds: line.timeMs!)),
          child: text,
        );
      },
    );
  }
}
