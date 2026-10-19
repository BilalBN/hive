import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/glyphs.dart';
import '../../design/glass.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../library/library_providers.dart';
import '../../player/badge.dart';
import '../../player/output_route.dart';
import '../../player/player_controller.dart';
import '../../player/quality.dart';
import '../../ui/art_backdrop.dart';
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

/// Position and length as a slim capsule. It thickens under the finger, and
/// doesn't seek until you let go, so the song doesn't stutter.
class SeekBar extends ConsumerStatefulWidget {
  const SeekBar({
    super.key,
    this.dense = false,
    this.onArt = false,
    this.middle,
  });

  /// Shown between the two times (Now playing's quality badge).
  final Widget? middle;

  /// One line with the times either side (the computer's player bar).
  final bool dense;

  /// White on the artwork backdrop (Now playing) instead of theme colours.
  final bool onArt;

  @override
  ConsumerState<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<SeekBar> {
  double? _drag; // 0..1 while dragging
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final position = ref.watch(playerProvider.select((s) => s.position));
    final total = ref.watch(playerProvider.select((s) => s.total));
    final buffered = ref.watch(playerProvider.select((s) => s.buffered));
    final max = total.inMilliseconds;
    final live = max <= 0 ? 0.0 : position.inMilliseconds / max;
    final fraction = (_drag ?? live).clamp(0.0, 1.0);
    final shown = Duration(milliseconds: (fraction * max).round());
    final active = _drag != null;
    final strong = widget.onArt ? OnArt.primary : p.textPrimary;
    final weak = widget.onArt ? OnArt.track : p.border;
    final soft = widget.onArt
        ? Colors.white.withValues(alpha: 0.32)
        : p.textTertiary.withValues(alpha: 0.4);
    final time = HiveType.caption.copyWith(
      color: active
          ? strong
          : (widget.onArt ? OnArt.secondary : p.textSecondary),
      fontFeatures: const [FontFeature.tabularFigures()],
      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
    );

    void seekTo(double f) => ref
        .read(playerProvider.notifier)
        .seek(Duration(milliseconds: (f.clamp(0.0, 1.0) * max).round()));

    final bar = LayoutBuilder(
      builder: (context, c) {
        final width = c.maxWidth;
        double at(Offset local) => (local.dx / width).clamp(0.0, 1.0);
        final thick = active || _hover;
        final height = widget.dense
            ? (thick ? 6.0 : 4.0)
            : (thick ? 11.0 : 6.0);
        return MouseRegion(
          cursor: max <= 0 ? MouseCursor.defer : SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: max <= 0
                ? null
                : (d) => setState(() => _drag = at(d.localPosition)),
            onHorizontalDragUpdate: max <= 0
                ? null
                : (d) => setState(() => _drag = at(d.localPosition)),
            onHorizontalDragEnd: max <= 0
                ? null
                : (_) {
                    final f = _drag;
                    setState(() => _drag = null);
                    if (f != null) seekTo(f);
                  },
            onHorizontalDragCancel: () => setState(() => _drag = null),
            onTapUp: max <= 0 ? null : (d) => seekTo(at(d.localPosition)),
            child: SizedBox(
              height: widget.dense ? 16 : 28,
              child: Center(
                child: AnimatedContainer(
                  duration: HiveMotion.fast,
                  curve: Curves.easeOut,
                  height: height,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(height),
                    child: CustomPaint(
                      size: Size(width, height),
                      painter: _CapsulePainter(
                        fraction: fraction,
                        buffered: max <= 0
                            ? 0
                            : (buffered.inMilliseconds / max).clamp(0.0, 1.0),
                        strong: strong,
                        weak: weak,
                        soft: soft,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    final semantic = Semantics(
      slider: true,
      label: 'Position',
      value: '${formatDuration(shown)} of ${formatDuration(total)}',
      increasedValue: formatDuration(
        shown + const Duration(seconds: 10) > total
            ? total
            : shown + const Duration(seconds: 10),
      ),
      decreasedValue: formatDuration(
        shown - const Duration(seconds: 10) < Duration.zero
            ? Duration.zero
            : shown - const Duration(seconds: 10),
      ),
      onIncrease: max <= 0 ? null : () => seekTo(fraction + 10000 / max),
      onDecrease: max <= 0 ? null : () => seekTo(fraction - 10000 / max),
      excludeSemantics: true,
      child: bar,
    );

    if (widget.dense) {
      return Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(
              formatDuration(shown),
              textAlign: TextAlign.end,
              style: time,
            ),
          ),
          const SizedBox(width: HiveSpace.xs),
          Expanded(child: semantic),
          const SizedBox(width: HiveSpace.xs),
          SizedBox(
            width: 40,
            child: Text('-${formatDuration(total - shown)}', style: time),
          ),
        ],
      );
    }
    return Column(
      children: [
        semantic,
        Row(
          children: [
            SizedBox(
              width: 56,
              child: Text(formatDuration(shown), style: time),
            ),
            Expanded(child: Center(child: widget.middle)),
            SizedBox(
              width: 56,
              child: Text(
                '-${formatDuration(total - shown)}',
                textAlign: TextAlign.end,
                style: time,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _CapsulePainter extends CustomPainter {
  _CapsulePainter({
    required this.fraction,
    required this.buffered,
    required this.strong,
    required this.weak,
    required this.soft,
  });
  final double fraction, buffered;
  final Color strong, weak, soft;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Offset.zero & size;
    canvas.drawRect(full, Paint()..color = weak);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width * buffered, size.height),
      Paint()..color = soft,
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width * fraction, size.height),
      Paint()..color = strong,
    );
  }

  @override
  bool shouldRepaint(_CapsulePainter old) =>
      old.fraction != fraction ||
      old.buffered != buffered ||
      old.strong != strong ||
      old.weak != weak;
}

/// The player's own volume as a slim capsule, speaker icons either side.
class VolumeControl extends ConsumerStatefulWidget {
  const VolumeControl({super.key, this.width = 96, this.onArt = false});
  final double? width;
  final bool onArt;

  @override
  ConsumerState<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends ConsumerState<VolumeControl> {
  late double _value = ref.read(playerProvider.notifier).userVolume;
  double _beforeMute = 1;
  bool _active = false;

  void _set(double v) {
    setState(() => _value = v.clamp(0.0, 1.0));
    ref.read(playerProvider.notifier).setUserVolume(_value);
  }

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final strong = widget.onArt ? OnArt.primary : p.textPrimary;
    final weak = widget.onArt ? OnArt.track : p.border;
    final quiet = widget.onArt ? OnArt.secondary : p.textSecondary;
    final icon = _value == 0
        ? HiveIcons.volumeX
        : _value < 0.5
        ? HiveIcons.volume1
        : HiveIcons.volume2;
    final bar = LayoutBuilder(
      builder: (context, c) {
        double at(Offset o) => (o.dx / c.maxWidth).clamp(0.0, 1.0);
        final h = _active ? 7.0 : 4.0;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _active = true),
          onExit: (_) => setState(() => _active = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (d) {
              setState(() => _active = true);
              _set(at(d.localPosition));
            },
            onHorizontalDragUpdate: (d) => _set(at(d.localPosition)),
            onHorizontalDragEnd: (_) => setState(() => _active = false),
            onTapUp: (d) => _set(at(d.localPosition)),
            child: SizedBox(
              height: 28,
              child: Center(
                child: AnimatedContainer(
                  duration: HiveMotion.fast,
                  height: h,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(h),
                    child: CustomPaint(
                      size: Size(c.maxWidth, h),
                      painter: _CapsulePainter(
                        fraction: _value,
                        buffered: 0,
                        strong: strong,
                        weak: weak,
                        soft: weak,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    final slider = Semantics(
      slider: true,
      label: 'Volume',
      value: '${(_value * 100).round()}%',
      increasedValue: '${((_value + 0.1).clamp(0.0, 1.0) * 100).round()}%',
      decreasedValue: '${((_value - 0.1).clamp(0.0, 1.0) * 100).round()}%',
      onIncrease: () => _set(_value + 0.1),
      onDecrease: () => _set(_value - 0.1),
      excludeSemantics: true,
      child: bar,
    );
    return Row(
      mainAxisSize: widget.width == null ? MainAxisSize.max : MainAxisSize.min,
      children: [
        IconButton(
          tooltip: _value == 0 ? 'Unmute' : 'Mute',
          visualDensity: VisualDensity.compact,
          icon: Icon(icon, size: 16, color: quiet),
          onPressed: () {
            if (_value == 0) {
              _set(_beforeMute == 0 ? 1 : _beforeMute);
            } else {
              _beforeMute = _value;
              _set(0);
            }
          },
        ),
        if (widget.width == null)
          Expanded(child: slider)
        else
          SizedBox(width: widget.width, child: slider),
      ],
    );
  }
}

/// Previous · play/pause · next, as solid shapes; shuffle and repeat either
/// side when [showModes] (the computer's player bar).
class TransportControls extends ConsumerWidget {
  const TransportControls({
    super.key,
    this.size = 64,
    this.showModes = true,
    this.onArt = false,
  });

  /// The play/pause shape's size; previous and next scale from it.
  final double size;
  final bool showModes;
  final bool onArt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final s = ref.watch(playerProvider);
    final player = ref.read(playerProvider.notifier);
    final ink = onArt ? OnArt.primary : p.textPrimary;
    final quiet = onArt ? OnArt.secondary : p.textSecondary;
    final on = onArt ? OnArt.primary : p.accentText;
    final skip = size * 0.72;
    final gap = size < 50 ? HiveSpace.xs : size * 0.45;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showModes) ...[
          ModeButton(
            tooltip: s.shuffled ? 'Shuffle on' : 'Shuffle off',
            icon: HiveIcons.shuffle,
            on: s.shuffled,
            onColor: on,
            offColor: quiet,
            size: size < 50 ? 16 : 20,
            onPressed: s.isEmpty ? null : player.toggleShuffle,
          ),
          SizedBox(width: gap),
        ],
        GlyphButton(
          tooltip: 'Previous',
          glyph: Glyph.previous,
          size: skip,
          color: ink,
          onPressed: s.isEmpty ? null : player.previous,
        ),
        SizedBox(width: gap),
        PlayPauseButton(size: size, color: ink),
        SizedBox(width: gap),
        GlyphButton(
          tooltip: 'Next',
          glyph: Glyph.next,
          size: skip,
          color: ink,
          onPressed: s.isEmpty ? null : player.next,
        ),
        if (showModes) ...[
          SizedBox(width: gap),
          ModeButton(
            tooltip: switch (s.repeat) {
              RepeatMode.off => 'Repeat off',
              RepeatMode.all => 'Repeat all',
              RepeatMode.one => 'Repeat this song',
            },
            icon: s.repeat == RepeatMode.one
                ? HiveIcons.repeat1
                : HiveIcons.repeat,
            on: s.repeat != RepeatMode.off,
            onColor: on,
            offColor: quiet,
            size: size < 50 ? 16 : 20,
            onPressed: s.isEmpty ? null : player.cycleRepeat,
          ),
        ],
      ],
    );
  }
}

/// A solid transport shape that dips when pressed.
class GlyphButton extends StatefulWidget {
  const GlyphButton({
    super.key,
    required this.tooltip,
    required this.glyph,
    required this.size,
    required this.color,
    required this.onPressed,
    this.semanticLabel,
  });

  final String tooltip;
  final Glyph glyph;
  final double size;
  final Color color;
  final VoidCallback? onPressed;
  final String? semanticLabel;

  @override
  State<GlyphButton> createState() => _GlyphButtonState();
}

class _GlyphButtonState extends State<GlyphButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final pad = widget.size * 0.3;
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: widget.semanticLabel ?? widget.tooltip,
        excludeSemantics: true,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: enabled ? (_) => setState(() => _down = true) : null,
            onTapCancel: () => setState(() => _down = false),
            onTapUp: enabled ? (_) => setState(() => _down = false) : null,
            onTap: widget.onPressed,
            child: Padding(
              padding: EdgeInsets.all(pad),
              child: AnimatedScale(
                scale: _down ? 0.84 : 1,
                duration: HiveMotion.fast,
                curve: Curves.easeOut,
                child: AnimatedOpacity(
                  opacity: _down ? 0.6 : (enabled ? 1 : 0.35),
                  duration: HiveMotion.fast,
                  child: HiveGlyph(
                    widget.glyph,
                    size: widget.size,
                    color: widget.color,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shuffle and repeat: an outline icon that turns the accent when on, with a
/// small dot underneath so "on" doesn't rely on colour alone.
class ModeButton extends StatelessWidget {
  const ModeButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.on,
    required this.onColor,
    required this.offColor,
    required this.onPressed,
    this.size = 20,
  });

  final String tooltip;
  final IconData icon;
  final bool on;
  final Color onColor;
  final Color offColor;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      isSelected: on,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
      icon: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: size, color: on ? onColor : offColor),
          const SizedBox(height: 2),
          AnimatedOpacity(
            opacity: on ? 1 : 0,
            duration: HiveMotion.fast,
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(color: onColor, shape: BoxShape.circle),
            ),
          ),
        ],
      ),
    );
  }
}

class PlayPauseButton extends ConsumerWidget {
  const PlayPauseButton({super.key, this.size = 64, this.color});

  /// The shape's size; the touch area is larger.
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final playing = ref.watch(playerProvider.select((s) => s.playing));
    final loading = ref.watch(playerProvider.select((s) => s.loading));
    final empty = ref.watch(playerProvider.select((s) => s.isEmpty));
    final ink = color ?? p.textPrimary;
    return Stack(
      alignment: Alignment.center,
      children: [
        GlyphButton(
          tooltip: playing ? 'Pause' : 'Play',
          glyph: playing ? Glyph.pause : Glyph.play,
          size: size,
          color: ink,
          onPressed: empty
              ? null
              : () => ref.read(playerProvider.notifier).toggle(),
        ),
        if (loading)
          IgnorePointer(
            child: SizedBox.square(
              dimension: size * 1.35,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: ink.withValues(alpha: 0.5),
              ),
            ),
          ),
      ],
    );
  }
}

/// The heart for the playing song.
class LikeButton extends ConsumerWidget {
  const LikeButton({super.key, this.size = 22, this.onArt = false});
  final double size;

  /// A see-through round button on the artwork backdrop (Now playing).
  final bool onArt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final track = ref.watch(playerProvider.select((s) => s.track));
    ref.watch(likesProvider);
    if (track == null) return const SizedBox.shrink();
    final liked = ref.read(likesProvider.notifier).isLiked(track);
    Future<void> toggle() async {
      try {
        await ref.read(likesProvider.notifier).toggle(track);
      } catch (e) {
        if (context.mounted) {
          showToast(context, 'Couldn\'t update liked songs.');
        }
      }
    }

    final tooltip = liked ? 'Remove from liked' : 'Like';
    if (onArt) {
      return GlassCircleButton(
        tooltip: tooltip,
        onPressed: toggle,
        child: liked
            ? FilledHeart(size: size, color: OnArt.primary)
            : Icon(HiveIcons.heart, size: size, color: OnArt.primary),
      );
    }
    return IconButton(
      tooltip: tooltip,
      icon: liked
          ? FilledHeart(size: size, color: p.accent)
          : Icon(HiveIcons.heart, size: size, color: p.textSecondary),
      onPressed: toggle,
    );
  }
}

/// The quality badge for the playing song; tap for how it reaches you.
class BadgeButton extends ConsumerWidget {
  const BadgeButton({super.key, this.showDetail = true, this.onArt = false});
  final bool showDetail;
  final bool onArt;

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
                  onArt: onArt,
                ),
              ),
              if (showDetail) ...[
                const SizedBox(width: HiveSpace.xs),
                Flexible(
                  child: Text(
                    badge.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HiveType.caption.copyWith(
                      color: onArt ? OnArt.secondary : p.textSecondary,
                    ),
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
