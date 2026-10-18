import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/hive_api.g.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../library/library_providers.dart';
import '../../player/player_controller.dart';
import '../../ui/artwork.dart';
import '../../ui/nav.dart';
import '../../ui/states.dart';
import '../../ui/tiles.dart';
import '../../ui/track_actions.dart';
import 'detail_scaffold.dart';

class AlbumScreen extends ConsumerWidget {
  const AlbumScreen({super.key, required this.albumId});
  final String albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final album = ref.watch(albumProvider(albumId));
    return AsyncView<Album>(
      value: album,
      onRetry: () => ref.invalidate(albumProvider(albumId)),
      data: (a) => _AlbumPage(album: a),
    );
  }
}

class _AlbumPage extends ConsumerWidget {
  const _AlbumPage({required this.album});
  final Album album;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final player = ref.read(playerProvider.notifier);
    final multiDisc =
        album.tracks.map((t) => t.discNumber ?? 1).toSet().length > 1;
    final facts = [
      if (album.year != null) '${album.year}',
      plural(album.trackCount, 'song'),
      formatLength(album.durationMs),
    ].join(' · ');

    final rows = <Widget>[];
    int? disc;
    for (var i = 0; i < album.tracks.length; i++) {
      final t = album.tracks[i];
      if (multiDisc && t.discNumber != disc) {
        disc = t.discNumber;
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HiveSpace.md,
              HiveSpace.md,
              HiveSpace.md,
              HiveSpace.xxs,
            ),
            child: Text(
              'DISC ${disc ?? 1}',
              style: HiveType.overline.copyWith(color: p.textSecondary),
            ),
          ),
        );
      }
      rows.add(
        TrackRow(
          track: t,
          number: t.trackNumber ?? i + 1,
          onTap: () => player.playAlbum(album, start: i),
        ),
      );
    }

    return DetailScaffold(
      actions: [
        IconButton(
          tooltip: 'Add album to playlist',
          icon: Icon(HiveIcons.listPlus, color: p.textSecondary),
          onPressed: () => showAddToPlaylist(
            context,
            ref,
            album.tracks.map((t) => t.id).toList(),
          ),
        ),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: DetailHeader(
            art: Artwork(
              artworkId: album.artworkId,
              title: album.title,
              pixels: 600,
            ),
            title: album.title,
            subtitle: album.artistName,
            onSubtitle: album.artistId == null
                ? null
                : () => context.openArtist(album.artistId!),
            facts: facts,
            badge: album.tier == 'lossy'
                ? null
                : QualityChip(label: tierLabel(album.tier), lossless: true),
            buttons: PlayButtons(
              onPlay: album.tracks.isEmpty
                  ? null
                  : () => player.playAlbum(album),
              onShuffle: album.tracks.isEmpty
                  ? null
                  : () => player.playAlbum(album, shuffle: true),
            ),
          ),
        ),
        SliverList.list(children: rows),
      ],
    );
  }
}
