import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/glass.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../player/output_route.dart';
import '../../player/player_controller.dart';
import '../../ui/art_backdrop.dart';
import '../../ui/artwork.dart';
import '../../ui/preferences.dart';
import '../../ui/nav.dart';
import '../../ui/track_actions.dart';
import 'player_parts.dart';
import 'side_panel.dart';
import 'lyrics_view.dart';

/// Now playing: the cover on a wash of its own colours, the song, a slim
/// scrubber with the quality badge, solid controls, and the way to lyrics,
/// where the sound goes, and the queue. The cover settles back when paused.
class NowPlayingScreen extends ConsumerWidget {
  const NowPlayingScreen({super.key});

  void _close(BuildContext context) =>
      context.canPop() ? context.pop() : context.go('/home');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final s = ref.watch(playerProvider);
    final track = s.track;

    if (track == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) _close(context);
      });
      return Scaffold(backgroundColor: p.bg);
    }

    final more = Builder(
      builder: (b) => GlassCircleButton(
        tooltip: 'More',
        child: const Icon(HiveIcons.ellipsis, size: 18, color: OnArt.primary),
        onPressed: () {
          final box = b.findRenderObject() as RenderBox?;
          showTrackActions(
            context,
            ref,
            track,
            at: box?.localToGlobal(box.size.center(Offset.zero)),
          );
        },
      ),
    );

    final titleBlock = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () {
                  _close(context);
                  context.openAlbum(track.albumId);
                },
                child: Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HiveType.title2.copyWith(
                    color: OnArt.primary,
                    fontSize: 21,
                  ),
                ),
              ),
              GestureDetector(
                onTap: track.artistId == null
                    ? null
                    : () {
                        _close(context);
                        context.openArtist(track.artistId!);
                      },
                child: Text(
                  track.artistName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HiveType.headline.copyWith(
                    color: OnArt.secondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (track.composer != null || track.lyricist != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    [
                      if (track.composer != null) 'Music: ${track.composer}',
                      if (track.lyricist != null) 'Lyrics: ${track.lyricist}',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HiveType.caption.copyWith(color: OnArt.tertiary),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: HiveSpace.sm),
        const LikeButton(size: 18, onArt: true),
        const SizedBox(width: HiveSpace.xs),
        if (track.videoId != null) ...[
          GlassCircleButton(
            tooltip: 'Watch the video',
            onPressed: () => context.push('/video'),
            child: const Icon(
              HiveIcons.clapperboard,
              size: 18,
              color: OnArt.primary,
            ),
          ),
          const SizedBox(width: HiveSpace.xs),
        ],
        more,
      ],
    );

    final simple = ref.watch(simpleModeProvider);
    Widget controls({required bool wide}) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        titleBlock,
        if (s.error != null)
          Padding(
            padding: const EdgeInsets.only(top: HiveSpace.xs),
            child: Text(
              s.error!,
              style: HiveType.callout.copyWith(color: const Color(0xFFFFB4AB)),
            ),
          ),
        const SizedBox(height: HiveSpace.md),
        const SeekBar(
          onArt: true,
          middle: BadgeButton(showDetail: false, onArt: true),
        ),
        SizedBox(height: wide ? HiveSpace.md : HiveSpace.lg),
        TransportControls(
          size: simple ? 60 : 44,
          showModes: wide && !simple,
          onArt: true,
        ),
        SizedBox(height: wide ? HiveSpace.md : HiveSpace.lg),
        if (wide)
          const Padding(
            padding: EdgeInsets.only(bottom: HiveSpace.md),
            child: VolumeControl(width: null, onArt: true),
          ),
        // Simple mode: just the song and its controls.
        if (!simple)
          _BottomRow(
            lyricsOn: wide && ref.watch(wideLyricsProvider),
            // On computers the lyrics open right here, beside the cover; the
            // queue opens in the window's side panel, so this closes.
            onLyrics: wide
                ? () => ref.read(wideLyricsProvider.notifier).toggle()
                : context.openLyrics,
            onQueue: wide
                ? () {
                    ref.read(sidePanelProvider.notifier).show(SidePanel.queue);
                    _close(context);
                  }
                : context.openQueue,
          ),
      ],
    );

    final art = SwipeToSkip(
      key: ValueKey(s.current?.id),
      child: _BreathingArt(
        playing: s.playing || s.loading,
        child: Hero(
          tag: 'now-playing-art',
          child: Artwork(
            artworkId: track.artworkId,
            title: track.albumTitle,
            pixels: 1200,
            radius: 12,
          ),
        ),
      ),
    );

    final grabber = Semantics(
      button: true,
      label: 'Close',
      excludeSemantics: true,
      child: Tooltip(
        message: 'Close',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _close(context),
          child: SizedBox(
            height: 28,
            width: 96,
            child: Center(
              child: Container(
                width: 38,
                height: 5,
                decoration: BoxDecoration(
                  color: OnArt.tertiary,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return Theme(
      data: buildHiveTheme(Brightness.dark),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: ArtBackdrop(
          artworkId: track.artworkId,
          title: track.albumTitle,
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, c) {
                final wide = c.maxWidth >= 840;
                if (wide) {
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(HiveSpace.sm),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: GlassCircleButton(
                            tooltip: 'Close',
                            onPressed: () => _close(context),
                            child: const Icon(
                              HiveIcons.chevronDown,
                              size: 20,
                              color: OnArt.primary,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1040),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                HiveSpace.xxl,
                                0,
                                HiveSpace.xxl,
                                HiveSpace.xxl,
                              ),
                              child: ref.watch(wideLyricsProvider)
                                  ? Row(
                                      children: [
                                        SizedBox(
                                          width: 380,
                                          child: SingleChildScrollView(
                                            child: Column(
                                              children: [
                                                ConstrainedBox(
                                                  constraints:
                                                      const BoxConstraints(
                                                        maxWidth: 240,
                                                      ),
                                                  child: AspectRatio(
                                                    aspectRatio: 1,
                                                    child: art,
                                                  ),
                                                ),
                                                const SizedBox(
                                                  height: HiveSpace.lg,
                                                ),
                                                controls(wide: true),
                                              ],
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 72),
                                        const Expanded(
                                          child: LyricsView(large: true),
                                        ),
                                      ],
                                    )
                                  : Row(
                                      children: [
                                        Expanded(
                                          child: Center(
                                            child: AspectRatio(
                                              aspectRatio: 1,
                                              child: art,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 72),
                                        Expanded(
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxWidth: 440,
                                            ),
                                            child: controls(wide: true),
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                }
                return GestureDetector(
                  // Down closes Now playing; up opens the lyrics.
                  onVerticalDragEnd: (d) {
                    final v = d.primaryVelocity ?? 0;
                    if (v > 400) _close(context);
                    if (v < -400) context.openLyrics();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: HiveSpace.lg + 4,
                    ),
                    child: Column(
                      children: [
                        grabber,
                        Expanded(
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: HiveSpace.md,
                              ),
                              child: AspectRatio(aspectRatio: 1, child: art),
                            ),
                          ),
                        ),
                        controls(wide: false),
                        const SizedBox(height: HiveSpace.sm),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Full size while the music plays; settles back, smaller, when paused.
class _BreathingArt extends StatelessWidget {
  const _BreathingArt({required this.playing, required this.child});
  final bool playing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: playing ? 1 : 0.8,
      duration: const Duration(milliseconds: 520),
      curve: playing ? Curves.easeOutBack : Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 520),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: playing ? 0.45 : 0.25),
              blurRadius: playing ? 48 : 24,
              offset: Offset(0, playing ? 22 : 10),
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}

/// Lyrics · where the sound goes · queue.
/// Lyrics beside the cover in the computer's full player.
class WideLyrics extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
}

final wideLyricsProvider = NotifierProvider<WideLyrics, bool>(WideLyrics.new);

class _BottomRow extends ConsumerWidget {
  const _BottomRow({
    required this.onLyrics,
    required this.onQueue,
    this.lyricsOn = false,
  });
  final VoidCallback onLyrics;
  final VoidCallback onQueue;
  final bool lyricsOn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final output = ref.watch(currentOutputProvider);
    final icon = switch (output.kind) {
      OutputKind.bluetooth => HiveIcons.bluetooth,
      OutputKind.wired || OutputKind.usb => HiveIcons.headphones,
      OutputKind.airplay => HiveIcons.airplay,
      OutputKind.hdmi => HiveIcons.tv,
      _ => HiveIcons.speaker,
    };
    return Row(
      children: [
        IconButton(
          tooltip: 'Lyrics',
          onPressed: onLyrics,
          isSelected: lyricsOn,
          style: IconButton.styleFrom(
            backgroundColor: lyricsOn ? OnArt.fill : null,
          ),
          icon: Icon(
            HiveIcons.messageSquareQuote,
            size: 22,
            color: lyricsOn ? OnArt.primary : OnArt.secondary,
          ),
        ),
        Expanded(
          child: Center(
            child: TextButton.icon(
              onPressed: () => showSignalPath(context),
              style: TextButton.styleFrom(
                foregroundColor: OnArt.secondary,
                shape: const StadiumBorder(),
              ),
              icon: Icon(icon, size: 16, color: OnArt.secondary),
              label: Text(
                output.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HiveType.caption.copyWith(color: OnArt.secondary),
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Queue',
          onPressed: onQueue,
          icon: Icon(HiveIcons.listMusic, size: 22, color: OnArt.secondary),
        ),
      ],
    );
  }
}

/// The artwork follows a sideways swipe: to the right plays the next song,
/// to the left the previous one (as Bilal asked, 19 Oct 2026).
class SwipeToSkip extends ConsumerStatefulWidget {
  const SwipeToSkip({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<SwipeToSkip> createState() => _SwipeToSkipState();
}

class _SwipeToSkipState extends ConsumerState<SwipeToSkip> {
  double _dx = 0;

  void _end(DragEndDetails d, double width) {
    final v = d.primaryVelocity ?? 0;
    final far = _dx.abs() > width * 0.25;
    final player = ref.read(playerProvider.notifier);
    if (v > 300 || (far && _dx > 0)) {
      player.next();
    } else if (v < -300 || (far && _dx < 0)) {
      player.previous(restart: false);
    }
    setState(() => _dx = 0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => Semantics(
        hint: 'Swipe right for the next song, left for the previous one',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => setState(() => _dx += d.delta.dx),
          onHorizontalDragEnd: (d) => _end(d, c.maxWidth),
          onHorizontalDragCancel: () => setState(() => _dx = 0),
          child: AnimatedContainer(
            duration: _dx == 0 ? HiveMotion.fast : Duration.zero,
            curve: Curves.easeOut,
            transform: Matrix4.translationValues(_dx * 0.6, 0, 0),
            child: Opacity(
              opacity: (1 - (_dx.abs() / (c.maxWidth * 1.5))).clamp(0.4, 1.0),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
