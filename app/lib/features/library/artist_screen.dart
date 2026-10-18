import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/hive_api.g.dart';
import '../../design/tokens.g.dart';
import '../../library/library_providers.dart';
import '../../player/player_controller.dart';
import '../../ui/artwork.dart';
import '../../ui/credits.dart';
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
            kicker: rolesLine(artist.roles).isEmpty
                ? 'Artist'
                : rolesLine(artist.roles),
            title: artist.name,
            facts: _facts(artist),
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
        ..._albumGrid(context, 'Albums', artist.albums, columns),
        ..._albumGrid(
          context,
          'Music for',
          artist.musicFor ?? const [],
          columns,
        ),
        ..._albumGrid(context, 'Films', artist.films ?? const [], columns),
        if (artist.lyricsFor?.isNotEmpty ?? false) ...[
          const SliverToBoxAdapter(child: SectionHeader('Lyrics')),
          SliverList.builder(
            itemCount: artist.lyricsFor!.length.clamp(0, 10),
            itemBuilder: (context, i) => TrackRow(
              track: artist.lyricsFor![i],
              showAlbum: true,
              onTap: () => player.playTracks(
                artist.lyricsFor!,
                start: i,
                source: PlaySource(
                  kind: 'artist',
                  id: artist.id,
                  name: artist.name,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

List<Widget> _albumGrid(
  BuildContext context,
  String title,
  List<AlbumSummary> albums,
  int columns,
) {
  if (albums.isEmpty) return const [];
  return [
    SliverToBoxAdapter(child: SectionHeader(title)),
    SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: HiveSpace.md),
      sliver: SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: HiveSpace.md,
          crossAxisSpacing: HiveSpace.sm,
          childAspectRatio: 0.76,
        ),
        itemCount: albums.length,
        itemBuilder: (context, i) {
          final a = albums[i];
          return CoverTile(
            title: a.title,
            subtitle: [
              if (a.year != null) '${a.year}',
              if (a.kind == 'soundtrack') 'Film',
            ].join(' · ').ifEmpty(a.artistName),
            art: Artwork(artworkId: a.artworkId, title: a.title),
            onTap: () => context.openAlbum(a.id),
          );
        },
      ),
    ),
  ];
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// "2 albums · 14 songs", or for actors and music directors, their films.
String _facts(Artist a) {
  final films = a.films?.length ?? 0;
  final musicFor = a.musicFor?.length ?? 0;
  return [
    if (a.albumCount > 0) plural(a.albumCount, 'album'),
    if (a.trackCount > 0) plural(a.trackCount, 'song'),
    if (films > 0) plural(films, 'film'),
    if (musicFor > 0) 'music for ${plural(musicFor, 'album')}',
  ].join(' · ');
}
