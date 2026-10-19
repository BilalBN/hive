import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../player/player_controller.dart';
import '../../ui/artwork.dart';
import '../../ui/nav.dart';
import '../../ui/track_actions.dart';
import 'player_parts.dart';

/// Now playing: big artwork, the song, the quality badge (tap for the signal
/// path), seek, controls, and the way to lyrics and the queue.
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

    final header = Row(
      children: [
        IconButton(
          tooltip: 'Close',
          icon: Icon(HiveIcons.chevronDown, size: 26, color: p.textPrimary),
          onPressed: () => _close(context),
        ),
        Expanded(
          child: Column(
            children: [
              Text(
                'PLAYING FROM',
                style: HiveType.overline.copyWith(
                  color: p.textSecondary,
                  fontSize: 10,
                ),
              ),
              Text(
                s.source?.name ?? 'Your queue',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HiveType.callout.copyWith(
                  color: p.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        Builder(
          builder: (b) => IconButton(
            tooltip: 'More',
            icon: Icon(HiveIcons.ellipsis, color: p.textPrimary),
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
        ),
      ],
    );

    final titleBlock = Row(
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
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HiveType.title2.copyWith(color: p.textPrimary),
                ),
              ),
              const SizedBox(height: 2),
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
                  style: HiveType.body.copyWith(color: p.textSecondary),
                ),
              ),
              if (track.composer != null || track.lyricist != null)
                Text(
                  [
                    if (track.composer != null) 'Music: ${track.composer}',
                    if (track.lyricist != null) 'Lyrics: ${track.lyricist}',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HiveType.caption.copyWith(color: p.textTertiary),
                ),
            ],
          ),
        ),
        const LikeButton(size: 26),
      ],
    );

    final controls = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        titleBlock,
        const SizedBox(height: HiveSpace.xs),
        const Align(alignment: Alignment.centerLeft, child: BadgeButton()),
        if (s.error != null)
          Padding(
            padding: const EdgeInsets.only(top: HiveSpace.xs),
            child: Text(
              s.error!,
              style: HiveType.callout.copyWith(color: p.danger),
            ),
          ),
        const SizedBox(height: HiveSpace.sm),
        const SeekBar(),
        const SizedBox(height: HiveSpace.sm),
        const TransportControls(),
        const SizedBox(height: HiveSpace.lg),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton.icon(
              onPressed: context.openLyrics,
              icon: Icon(HiveIcons.micVocal, size: 18, color: p.textSecondary),
              label: Text(
                'Lyrics',
                style: HiveType.callout.copyWith(color: p.textSecondary),
              ),
            ),
            TextButton.icon(
              onPressed: context.openQueue,
              icon: Icon(HiveIcons.listMusic, size: 18, color: p.textSecondary),
              label: Text(
                'Queue',
                style: HiveType.callout.copyWith(color: p.textSecondary),
              ),
            ),
          ],
        ),
      ],
    );

    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= 840;
            final art = SwipeToSkip(
              key: ValueKey(s.current?.id),
              child: Hero(
                tag: 'now-playing-art',
                child: Artwork(
                  artworkId: track.artworkId,
                  title: track.albumTitle,
                  pixels: 1200,
                  radius: HiveRadius.card,
                ),
              ),
            );
            if (wide) {
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(HiveSpace.xs),
                    child: header,
                  ),
                  Expanded(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1000),
                        child: Padding(
                          padding: const EdgeInsets.all(HiveSpace.xl),
                          child: Row(
                            children: [
                              Expanded(
                                child: AspectRatio(aspectRatio: 1, child: art),
                              ),
                              const SizedBox(width: HiveSpace.xxl),
                              Expanded(child: controls),
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
                padding: const EdgeInsets.symmetric(horizontal: HiveSpace.lg),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: HiveSpace.xs,
                      ),
                      child: header,
                    ),
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
                    controls,
                    const SizedBox(height: HiveSpace.md),
                  ],
                ),
              ),
            );
          },
        ),
      ),
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
