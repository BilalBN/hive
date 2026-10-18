import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../library/library_providers.dart';
import '../../player/badge.dart';
import '../../player/output_route.dart';
import '../../player/player_controller.dart';
import '../../player/quality.dart';
import '../../ui/states.dart';
import '../../ui/track_actions.dart';

/// Where the sound goes right now; "this device" until the system says.
final currentOutputProvider = Provider<OutputRoute>((ref) {
  return ref.watch(outputRouteProvider).value ??
      (isDesktop ? OutputRoute.thisComputer : OutputRoute.thisPhone);
});

/// The badge for the playing song, or null before its stream is known.
final currentBadgeProvider = Provider<QualityBadge?>((ref) {
  final ticket = ref.watch(playerProvider.select((s) => s.ticket));
  final mode = ref.watch(playerProvider.select((s) => s.mode));
  if (ticket == null) return null;
  return qualityBadge(
    ticket: ticket,
    mode: mode,
    output: ref.watch(currentOutputProvider),
  );
});

/// The audio player underneath, named in the signal path.
String get playerName {
  if (kIsWeb) return 'Browser';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Android player (ExoPlayer)',
    TargetPlatform.iOS || TargetPlatform.macOS => 'Apple player (AVPlayer)',
    TargetPlatform.windows => 'mpv (media_kit)',
    _ => 'System player',
  };
}

/// Position and length with a draggable thumb. Dragging doesn't seek until you
/// let go, so the song doesn't stutter.
class SeekBar extends ConsumerStatefulWidget {
  const SeekBar({super.key, this.dense = false});
  final bool dense;

  @override
  ConsumerState<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final position = ref.watch(playerProvider.select((s) => s.position));
    final total = ref.watch(playerProvider.select((s) => s.total));
    final buffered = ref.watch(playerProvider.select((s) => s.buffered));
    final max = total.inMilliseconds.toDouble();
    final value = (_drag ?? position.inMilliseconds.toDouble()).clamp(
      0.0,
      max <= 0 ? 0.0 : max,
    );
    final shown = Duration(milliseconds: value.round());
    final time = HiveType.caption.copyWith(
      color: p.textSecondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: widget.dense ? 3 : 4,
        thumbShape: RoundSliderThumbShape(
          enabledThumbRadius: widget.dense ? 5 : 7,
        ),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        activeTrackColor: p.textPrimary,
        inactiveTrackColor: p.border,
        secondaryActiveTrackColor: p.textTertiary.withValues(alpha: 0.5),
        thumbColor: p.textPrimary,
        overlayColor: p.textPrimary.withValues(alpha: 0.1),
      ),
      child: Slider(
        value: value,
        max: max <= 0 ? 1 : max,
        secondaryTrackValue: buffered.inMilliseconds.toDouble().clamp(
          0.0,
          max <= 0 ? 1.0 : max,
        ),
        semanticFormatterCallback: (v) =>
            '${formatDuration(Duration(milliseconds: v.round()))} of ${formatDuration(total)}',
        onChanged: max <= 0 ? null : (v) => setState(() => _drag = v),
        onChangeEnd: max <= 0
            ? null
            : (v) {
                setState(() => _drag = null);
                ref
                    .read(playerProvider.notifier)
                    .seek(Duration(milliseconds: v.round()));
              },
      ),
    );

    if (widget.dense) {
      return Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(
              formatDuration(shown),
              textAlign: TextAlign.end,
              style: time,
            ),
          ),
          Expanded(child: slider),
          SizedBox(width: 44, child: Text(formatDuration(total), style: time)),
        ],
      );
    }
    return Column(
      children: [
        slider,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HiveSpace.xs),
          child: Row(
            children: [
              Text(formatDuration(shown), style: time),
              const Spacer(),
              Text('-${formatDuration(total - shown)}', style: time),
            ],
          ),
        ),
      ],
    );
  }
}

/// Shuffle · previous · play/pause · next · repeat.
class TransportControls extends ConsumerWidget {
  const TransportControls({super.key, this.size = 64, this.showModes = true});
  final double size;
  final bool showModes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final s = ref.watch(playerProvider);
    final player = ref.read(playerProvider.notifier);
    final small = size < 50;
    final side = small ? 20.0 : 28.0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (showModes)
          IconButton(
            tooltip: s.shuffled ? 'Shuffle on' : 'Shuffle off',
            isSelected: s.shuffled,
            icon: Icon(
              HiveIcons.shuffle,
              size: small ? 18 : 22,
              color: s.shuffled ? p.accentText : p.textSecondary,
            ),
            onPressed: s.isEmpty ? null : player.toggleShuffle,
          ),
        SizedBox(width: small ? HiveSpace.xxs : HiveSpace.md),
        IconButton(
          tooltip: 'Previous',
          icon: Icon(HiveIcons.skipBack, size: side, color: p.textPrimary),
          onPressed: s.isEmpty ? null : player.previous,
        ),
        SizedBox(width: small ? HiveSpace.xxs : HiveSpace.md),
        PlayPauseButton(size: size),
        SizedBox(width: small ? HiveSpace.xxs : HiveSpace.md),
        IconButton(
          tooltip: 'Next',
          icon: Icon(HiveIcons.skipForward, size: side, color: p.textPrimary),
          onPressed: s.isEmpty ? null : player.next,
        ),
        SizedBox(width: small ? HiveSpace.xxs : HiveSpace.md),
        if (showModes)
          IconButton(
            tooltip: switch (s.repeat) {
              RepeatMode.off => 'Repeat off',
              RepeatMode.all => 'Repeat all',
              RepeatMode.one => 'Repeat this song',
            },
            icon: Icon(
              s.repeat == RepeatMode.one ? HiveIcons.repeat1 : HiveIcons.repeat,
              size: small ? 18 : 22,
              color: s.repeat == RepeatMode.off
                  ? p.textSecondary
                  : p.accentText,
            ),
            onPressed: s.isEmpty ? null : player.cycleRepeat,
          ),
      ],
    );
  }
}

class PlayPauseButton extends ConsumerWidget {
  const PlayPauseButton({super.key, this.size = 64, this.filled = true});
  final double size;
  final bool filled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final playing = ref.watch(playerProvider.select((s) => s.playing));
    final loading = ref.watch(playerProvider.select((s) => s.loading));
    final empty = ref.watch(playerProvider.select((s) => s.isEmpty));
    final icon = Icon(
      playing ? HiveIcons.pause : HiveIcons.play,
      size: size * 0.42,
      color: filled ? p.bg : p.textPrimary,
    );
    return Semantics(
      button: true,
      label: playing ? 'Pause' : 'Play',
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: size,
        child: Material(
          color: filled ? p.textPrimary : Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: empty
                ? null
                : () => ref.read(playerProvider.notifier).toggle(),
            child: Stack(
              alignment: Alignment.center,
              children: [
                icon,
                if (loading)
                  SizedBox.square(
                    dimension: size - 6,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: filled ? p.accent : p.textSecondary,
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

/// The heart for the playing song.
class LikeButton extends ConsumerWidget {
  const LikeButton({super.key, this.size = 22});
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final track = ref.watch(playerProvider.select((s) => s.track));
    ref.watch(likesProvider);
    if (track == null) return const SizedBox.shrink();
    final liked = ref.read(likesProvider.notifier).isLiked(track);
    return IconButton(
      tooltip: liked ? 'Remove from liked' : 'Like',
      icon: liked
          ? FilledHeart(size: size, color: p.accent)
          : Icon(HiveIcons.heart, size: size, color: p.textSecondary),
      onPressed: () async {
        try {
          await ref.read(likesProvider.notifier).toggle(track);
        } catch (e) {
          if (context.mounted) {
            showToast(context, 'Couldn\'t update liked songs.');
          }
        }
      },
    );
  }
}

/// The quality badge for the playing song; tap for how it reaches you.
class BadgeButton extends ConsumerWidget {
  const BadgeButton({super.key, this.showDetail = true});
  final bool showDetail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final badge = ref.watch(currentBadgeProvider);
    if (badge == null) return const SizedBox(height: 22);
    return Semantics(
      button: true,
      label:
          'Quality: ${badge.label}. ${badge.detail}. Show how this song reaches you',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(HiveRadius.badge),
        onTap: () => showSignalPath(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: QualityChip(
                  label: badge.label,
                  lossless: badge.lossless,
                  icon: badge.bluetooth ? HiveIcons.bluetooth : null,
                ),
              ),
              if (showDetail) ...[
                const SizedBox(width: HiveSpace.xs),
                Flexible(
                  child: Text(
                    badge.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HiveType.caption.copyWith(color: p.textSecondary),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// "How this song reaches you": file → stream → player → output.
Future<void> showSignalPath(BuildContext context) {
  final p = HiveTheme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: p.surface,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 560),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(HiveRadius.sheet),
      ),
    ),
    builder: (_) => const _SignalPathSheet(),
  );
}

class _SignalPathSheet extends ConsumerWidget {
  const _SignalPathSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final s = ref.watch(playerProvider);
    final ticket = s.ticket;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          HiveSpace.lg,
          HiveSpace.md,
          HiveSpace.lg,
          HiveSpace.lg,
        ),
        child: ticket == null
            ? Text(
                'Play a song to see how it reaches you.',
                style: HiveType.body.copyWith(color: p.textSecondary),
              )
            : Builder(
                builder: (context) {
                  final path = signalPath(
                    ticket: ticket,
                    mode: s.mode,
                    output: ref.watch(currentOutputProvider),
                    playerName: playerName,
                    levelling: ref.watch(playbackSettingsProvider).levelling,
                  );
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: p.border,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: HiveSpace.md),
                      Text(
                        'How this song reaches you',
                        style: HiveType.headline.copyWith(color: p.textPrimary),
                      ),
                      const SizedBox(height: HiveSpace.xxs),
                      Text(
                        path.verdict,
                        style: HiveType.callout.copyWith(
                          color: p.textSecondary,
                        ),
                      ),
                      const SizedBox(height: HiveSpace.md),
                      for (var i = 0; i < path.hops.length; i++)
                        _Hop(
                          hop: path.hops[i],
                          last: i == path.hops.length - 1,
                        ),
                      if (path.fix != null) ...[
                        const SizedBox(height: HiveSpace.sm),
                        Container(
                          padding: const EdgeInsets.all(HiveSpace.sm),
                          decoration: BoxDecoration(
                            color: p.raised,
                            borderRadius: BorderRadius.circular(
                              HiveRadius.card,
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                HiveIcons.info,
                                size: 18,
                                color: p.textSecondary,
                              ),
                              const SizedBox(width: HiveSpace.sm),
                              Expanded(
                                child: Text(
                                  path.fix!,
                                  style: HiveType.callout.copyWith(
                                    color: p.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
      ),
    );
  }
}

class _Hop extends StatelessWidget {
  const _Hop({required this.hop, required this.last});
  final PathHop hop;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final color = hop.weakest ? p.warning : p.lossless;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 20,
            child: Column(
              children: [
                const SizedBox(height: 4),
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                  ),
                ),
                if (!last)
                  Expanded(child: Container(width: 2, color: p.border)),
              ],
            ),
          ),
          const SizedBox(width: HiveSpace.sm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: HiveSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          hop.title,
                          style: HiveType.callout.copyWith(
                            color: p.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        hop.quality,
                        style: HiveType.callout.copyWith(
                          color: hop.weakest ? p.warning : p.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    hop.weakest ? '${hop.detail} · weakest link' : hop.detail,
                    style: HiveType.caption.copyWith(color: p.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A solid heart (the icon font only has the outline) for liked songs.
class FilledHeart extends StatelessWidget {
  const FilledHeart({super.key, required this.size, required this.color});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _HeartPainter(color)),
  );
}

class _HeartPainter extends CustomPainter {
  _HeartPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 24;
    final path = Path()
      ..moveTo(12 * k, 21 * k)
      ..cubicTo(12 * k, 21 * k, 2 * k, 14.5 * k, 2 * k, 8.5 * k)
      ..cubicTo(2 * k, 5.4 * k, 4.4 * k, 3 * k, 7.5 * k, 3 * k)
      ..cubicTo(9.3 * k, 3 * k, 10.9 * k, 3.9 * k, 12 * k, 5.3 * k)
      ..cubicTo(13.1 * k, 3.9 * k, 14.7 * k, 3 * k, 16.5 * k, 3 * k)
      ..cubicTo(19.6 * k, 3 * k, 22 * k, 5.4 * k, 22 * k, 8.5 * k)
      ..cubicTo(22 * k, 14.5 * k, 12 * k, 21 * k, 12 * k, 21 * k)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_HeartPainter old) => old.color != color;
}
