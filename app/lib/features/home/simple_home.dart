import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/hive_api.g.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../library/library_providers.dart';
import '../../player/player_controller.dart';
import '../../ui/artwork.dart';
import '../../ui/states.dart';

/// Simple mode's Home: a few big buttons that start music at once. Nothing
/// to browse; every tile plays.
class SimpleHome extends ConsumerWidget {
  const SimpleHome({super.key, required this.home});
  final Home home;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final player = ref.read(playerProvider.notifier);
    final recent = home.recentlyPlayed ?? const <TrackSummary>[];
    final tiles = home.jumpBackIn
        .where((t) => t.kind != 'artist')
        .take(6)
        .toList();

    Future<void> playTile(HomeTile t) async {
      final source = PlaySource(kind: t.kind, id: t.id, name: t.title);
      switch (t.kind) {
        case 'album':
          final a = await ref.read(albumProvider(t.id).future);
          await player.playTracks(a.tracks, source: source);
        case 'playlist':
          final pl = await ref.read(playlistProvider(t.id).future);
          await player.playTracks([
            for (final i in pl.items) i.track,
          ], source: source);
        default:
          final liked = await ref.read(likedSongsProvider.future);
          await player.playTracks(liked, shuffle: true, source: source);
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HiveSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BigButton(
            icon: HiveIcons.heart,
            title: 'Play my favourites',
            subtitle: 'Songs you liked, shuffled',
            accent: true,
            onTap: () async {
              final liked = await ref.read(likedSongsProvider.future);
              if (liked.isEmpty) return;
              await player.playTracks(
                liked,
                shuffle: true,
                source: const PlaySource(
                  kind: 'liked',
                  id: 'liked',
                  name: 'Liked songs',
                ),
              );
            },
          ),
          if (recent.isNotEmpty) ...[
            const SizedBox(height: HiveSpace.sm),
            _BigButton(
              icon: HiveIcons.history,
              title: 'Play what I had on',
              subtitle: recent.first.title,
              onTap: () => player.playTracks(recent),
            ),
          ],
          const SizedBox(height: HiveSpace.sm),
          _BigButton(
            icon: HiveIcons.audioWaveform,
            title: 'What song is this?',
            subtitle: 'Listen',
            onTap: () => context.go('/listen'),
          ),
          if (tiles.isNotEmpty) ...[
            const SizedBox(height: HiveSpace.lg),
            Text(
              'Play again',
              style: HiveType.title2.copyWith(color: p.textPrimary),
            ),
            const SizedBox(height: HiveSpace.sm),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: HiveSpace.sm,
              crossAxisSpacing: HiveSpace.sm,
              childAspectRatio: 0.82,
              children: [
                for (final t in tiles)
                  Semantics(
                    button: true,
                    label: 'Play ${t.title}',
                    excludeSemantics: true,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(HiveRadius.card),
                      onTap: () => playTile(t),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AspectRatio(
                            aspectRatio: 1,
                            child: (t.artworkIds?.length ?? 0) > 1
                                ? Mosaic(
                                    artworkIds: t.artworkIds!,
                                    title: t.title,
                                  )
                                : Artwork(
                                    artworkId: t.artworkIds?.firstOrNull,
                                    title: t.title,
                                    radius: 14,
                                  ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            t.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HiveType.headline.copyWith(
                              color: p.textPrimary,
                              fontSize: 19,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (home.libraryEmpty)
            const EmptyState(
              icon: HiveIcons.music,
              title: 'No music yet',
              text: 'Whoever runs Hive is still adding it.',
            ),
        ],
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.accent = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final fg = accent ? p.onAccent : p.textPrimary;
    return Semantics(
      button: true,
      label: title,
      excludeSemantics: true,
      child: Material(
        color: accent ? p.accent : p.raised,
        borderRadius: BorderRadius.circular(HiveRadius.card),
        child: InkWell(
          borderRadius: BorderRadius.circular(HiveRadius.card),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(HiveSpace.md),
            child: Row(
              children: [
                Icon(icon, size: 34, color: fg),
                const SizedBox(width: HiveSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: HiveType.title2.copyWith(color: fg)),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HiveType.body.copyWith(
                          color: fg.withValues(alpha: 0.8),
                        ),
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
