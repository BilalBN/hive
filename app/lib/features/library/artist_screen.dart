import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/hive_api.g.dart';
import '../../design/tokens.g.dart';
import '../../library/library_providers.dart';
import '../../player/player_controller.dart';
import '../../ui/artwork.dart';
import '../../ui/nav.dart';
import '../../ui/states.dart';
import '../../ui/tiles.dart';
import 'detail_scaffold.dart';

class ArtistScreen extends ConsumerWidget {
  const ArtistScreen({super.key, required this.artistId});
  final String artistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artist = ref.watch(artistProvider(artistId));
    return AsyncView<Artist>(
      value: artist,
      onRetry: () => ref.invalidate(artistProvider(artistId)),
      data: (a) => _ArtistPage(artist: a),
    );
  }
}

class _ArtistPage extends ConsumerWidget {
  const _ArtistPage({required this.artist});
  final Artist artist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.read(playerProvider.notifier);
    final source = PlaySource(kind: 'artist', id: artist.id, name: artist.name);
    final top = artist.topTracks;
    final width = MediaQuery.sizeOf(context).width;
    final columns = (width / 180).floor().clamp(2, 6);
    return DetailScaffold(
      slivers: [
        SliverToBoxAdapter(
          child: DetailHeader(
            art: Artwork(
              artworkId: artist.artworkId,
              title: artist.name,
              round: true,
              pixels: 600,
            ),
            kicker: 'Artist',
            title: artist.name,
            facts:
                '${plural(artist.albumCount, 'album')} · ${plural(artist.trackCount, 'song')}',
            buttons: PlayButtons(
              onPlay: top.isEmpty
                  ? null
                  : () => player.playTracks(top, source: source),
              onShuffle: top.isEmpty
                  ? null
                  : () => player.playTracks(top, source: source, shuffle: true),
            ),
          ),
        ),
        if (top.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SectionHeader('Popular')),
          SliverList.builder(
            itemCount: top.length.clamp(0, 5),
            itemBuilder: (context, i) => TrackRow(
              track: top[i],
              showAlbum: true,
              onTap: () => player.playTracks(top, start: i, source: source),
            ),
          ),
        ],
        if (artist.albums.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SectionHeader('Albums')),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: HiveSpace.md),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisSpacing: HiveSpace.md,
                crossAxisSpacing: HiveSpace.sm,
                childAspectRatio: 0.76,
              ),
              itemCount: artist.albums.length,
              itemBuilder: (context, i) {
                final a = artist.albums[i];
                return CoverTile(
                  title: a.title,
                  subtitle: a.year == null ? a.artistName : '${a.year}',
                  art: Artwork(artworkId: a.artworkId, title: a.title),
                  onTap: () => context.openAlbum(a.id),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}
