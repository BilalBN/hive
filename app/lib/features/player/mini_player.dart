import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/glass.dart';
import '../../design/glyphs.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../player/player_controller.dart';
import '../../ui/artwork.dart';
import '../../ui/nav.dart';
import 'player_parts.dart';
import 'side_panel.dart';

/// Height of the floating mini player on phones, without its margin.
const miniPlayerHeight = 60.0;

/// The floating glass bar above the tabs on phones: what's playing,
/// play/pause and next. Tap it for Now playing. Hidden until something has
/// played.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final track = ref.watch(playerProvider.select((s) => s.track));
    if (track == null) return const SizedBox.shrink();
    final position = ref.watch(playerProvider.select((s) => s.position));
    final total = ref.watch(playerProvider.select((s) => s.total));
    final error = ref.watch(playerProvider.select((s) => s.error));
    final progress = total.inMilliseconds <= 0
        ? 0.0
        : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    const radius = BorderRadius.all(Radius.circular(20));

    return Glass(
      borderRadius: radius,
      shadow: true,
      opacity: 0.78,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: context.openNowPlaying,
          child: SizedBox(
            height: miniPlayerHeight,
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                  child: Row(
                    children: [
                      Artwork(
                        artworkId: track.artworkId,
                        title: track.albumTitle,
                        size: 44,
                        pixels: 96,
                        radius: 10,
                      ),
                      const SizedBox(width: HiveSpace.sm),
                      Expanded(
                        child: Semantics(
                          label:
                              'Now playing: ${track.title}, ${track.artistName}. Open Now playing',
                          excludeSemantics: true,
                          button: true,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: HiveType.callout.copyWith(
                                  color: p.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                error ?? track.artistName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: HiveType.caption.copyWith(
                                  color: error != null
                                      ? p.danger
                                      : p.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const PlayPauseButton(size: 22),
                      GlyphButton(
                        tooltip: 'Next',
                        glyph: Glyph.next,
                        size: 22,
                        color: p.textPrimary,
                        onPressed: () =>
                            ref.read(playerProvider.notifier).next(),
                      ),
                      const SizedBox(width: 2),
                    ],
                  ),
                ),
                // How far into the song, as a hairline along the bottom edge.
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 0,
                  height: 2,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(1),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: progress,
                        child: ColoredBox(
                          color: p.accent.withValues(alpha: 0.9),
                        ),
                      ),
                    ),
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

/// The player bar along the bottom of the window on computers: controls on
/// the left, the song with its progress in the middle, and quality, lyrics,
/// queue and volume on the right.
class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final panel = ref.watch(sidePanelProvider);

    Widget panelButton(SidePanel which, String label, IconData icon) {
      final on = panel == which;
      return IconButton(
        tooltip: label,
        visualDensity: VisualDensity.compact,
        isSelected: on,
        style: IconButton.styleFrom(
          backgroundColor: on ? p.accent.withValues(alpha: 0.16) : null,
        ),
        icon: Icon(icon, size: 18, color: on ? p.accentText : p.textSecondary),
        onPressed: () => ref.read(sidePanelProvider.notifier).toggle(which),
      );
    }

    return Container(
      height: 84,
      padding: const EdgeInsets.symmetric(horizontal: HiveSpace.md),
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(top: BorderSide(color: p.border, width: 0.5)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 300,
            child: Center(child: TransportControls(size: 28)),
          ),
          const SizedBox(width: HiveSpace.md),
          const Expanded(child: _NowPlayingPanel()),
          const SizedBox(width: HiveSpace.md),
          SizedBox(
            width: 300,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Flexible(child: BadgeButton(showDetail: false)),
                const SizedBox(width: HiveSpace.xxs),
                panelButton(
                  SidePanel.lyrics,
                  'Lyrics',
                  HiveIcons.messageSquareQuote,
                ),
                panelButton(SidePanel.queue, 'Queue', HiveIcons.listMusic),
                const VolumeControl(width: 76),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The song in the middle of the computer's player bar: cover, title and
/// artist, and the scrubber along the bottom.
class _NowPlayingPanel extends ConsumerWidget {
  const _NowPlayingPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final track = ref.watch(playerProvider.select((s) => s.track));
    final error = ref.watch(playerProvider.select((s) => s.error));
    final dark = Theme.of(context).brightness == Brightness.dark;
    final box = BoxDecoration(
      color: dark ? p.raised.withValues(alpha: 0.6) : p.raised,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: dark
            ? Colors.white.withValues(alpha: 0.06)
            : Colors.black.withValues(alpha: 0.05),
        width: 0.5,
      ),
    );

    if (track == null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Container(
            height: 60,
            decoration: box,
            child: Row(
              children: [
                const SizedBox(width: 8),
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: p.border.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(HiveIcons.music, size: 18, color: p.textTertiary),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      'Nothing playing',
                      style: HiveType.callout.copyWith(color: p.textSecondary),
                    ),
                  ),
                ),
                const SizedBox(width: 52),
              ],
            ),
          ),
        ),
      );
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          height: 60,
          decoration: box,
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              Tooltip(
                message: 'Open Now playing',
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: context.openNowPlaying,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Artwork(
                      artworkId: track.artworkId,
                      title: track.albumTitle,
                      size: 44,
                      pixels: 192,
                      radius: 8,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: HiveSpace.sm),
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          const SizedBox(width: 30),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                InkWell(
                                  onTap: () => context.openAlbum(track.albumId),
                                  child: Text(
                                    track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: HiveType.callout.copyWith(
                                      color: p.textPrimary,
                                      fontWeight: FontWeight.w600,
                                      height: 1.2,
                                    ),
                                  ),
                                ),
                                InkWell(
                                  onTap: track.artistId == null
                                      ? null
                                      : () =>
                                            context.openArtist(track.artistId!),
                                  child: Text(
                                    error ?? track.artistName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: HiveType.caption.copyWith(
                                      color: error != null
                                          ? p.danger
                                          : p.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(
                            width: 30,
                            child: LikeButton(size: 15),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16, child: SeekBar(dense: true)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
