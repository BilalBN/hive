import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/hive_api.g.dart';
import '../../core/home_connection.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../design/widgets.dart';
import '../../library/library_providers.dart';
import '../../player/player_controller.dart';
import '../../ui/artwork.dart';
import '../../ui/language_chips.dart';
import '../../ui/nav.dart';
import '../../ui/states.dart';
import '../../ui/tiles.dart';
import '../shell/app_shell.dart' show desktopBreakpoint;

String greeting(DateTime now) {
  final h = now.hour;
  if (h < 5) return 'Good evening';
  if (h < 12) return 'Good morning';
  if (h < 17) return 'Good afternoon';
  return 'Good evening';
}

/// Home (design 1a): a quick-pick grid of what you played recently, then
/// rows of songs you played, picks for you, new albums, films, artists and
/// the family's playlists, so there's always something to start from.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final status = ref.watch(homeStatusProvider);
    final shelves = ref.watch(homeShelvesProvider);
    final wide = MediaQuery.sizeOf(context).width >= desktopBreakpoint;

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: p.accent,
        onRefresh: () async {
          ref.invalidate(homeShelvesProvider);
          await ref
              .read(homeShelvesProvider.future)
              .catchError(
                (_) => const Home(
                  jumpBackIn: [],
                  newAtHome: [],
                  playlists: [],
                  libraryEmpty: true,
                ),
              );
        },
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                HiveSpace.md,
                HiveSpace.md,
                HiveSpace.md,
                0,
              ),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          greeting(DateTime.now()),
                          style: HiveType.title1.copyWith(color: p.textPrimary),
                        ),
                      ),
                    ),
                    // On computers Settings sits at the foot of the sidebar instead.
                    if (!wide)
                      Semantics(
                        key: const Key('open-settings'),
                        label: 'Settings',
                        button: true,
                        container: true,
                        excludeSemantics: true,
                        child: InkResponse(
                          onTap: () => context.push('/settings'),
                          radius: 28,
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: p.raised,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              HiveIcons.settings,
                              size: 20,
                              color: p.textSecondary,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                HiveSpace.md,
                HiveSpace.sm,
                HiveSpace.md,
                0,
              ),
              sliver: SliverToBoxAdapter(
                child: switch (status) {
                  HomeChecking() => const StatusLine(
                    ok: true,
                    text: 'Checking home…',
                  ),
                  HomeConnected(:final health) => StatusLine(
                    ok: true,
                    text: 'Connected to home',
                    detail: health.homeName,
                  ),
                  HomeUnreachable(:final reason) => HiveBanner(
                    title: "Can't reach home right now",
                    body: reason,
                    action: TextButton(
                      onPressed: () {
                        ref.read(homeStatusProvider.notifier).check();
                        ref.invalidate(homeShelvesProvider);
                      },
                      child: Text(
                        'Try again',
                        style: HiveType.callout.copyWith(
                          color: p.accentText,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                },
              ),
            ),
            const SliverPadding(
              padding: EdgeInsets.only(top: HiveSpace.sm),
              sliver: SliverToBoxAdapter(child: LanguageChips()),
            ),
            AsyncView<Home>(
              sliver: true,
              value: shelves,
              onRetry: () => ref.invalidate(homeShelvesProvider),
              data: (home) =>
                  SliverList.list(children: _shelves(context, ref, home, wide)),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: MediaQuery.paddingOf(context).bottom + HiveSpace.lg,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _shelves(
    BuildContext context,
    WidgetRef ref,
    Home home,
    bool wide,
  ) {
    if (home.libraryEmpty) {
      return const [
        SizedBox(height: HiveSpace.xxl),
        EmptyState(
          icon: HiveIcons.libraryBig,
          title: 'Nothing at home yet',
          text: 'Copy albums into the music folder on the home PC, or use Upload in Hive Admin. They appear here on their own.',
        ),
      ];
    }
    final size = wide ? 168.0 : 144.0;
    final recent = home.recentlyPlayed ?? const <TrackSummary>[];
    final onRepeat = home.onRepeat ?? const <TrackSummary>[];
    final forYou = home.forYou ?? const <AlbumSummary>[];
    final films = home.films ?? const <AlbumSummary>[];
    final artists = home.artists ?? const <ArtistSummary>[];
    return [
      if (home.jumpBackIn.isNotEmpty) ...[
        const SizedBox(height: HiveSpace.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HiveSpace.md),
          child: _QuickPicks(tiles: home.jumpBackIn, columns: wide ? 3 : 2),
        ),
      ],
      if (recent.isNotEmpty) ...[
        const SectionHeader('Recently played'),
        _SongRow(songs: recent, size: size, from: 'Recently played'),
      ],
      if (forYou.isNotEmpty) ...[
        const SectionHeader('Picked for you'),
        _AlbumRow(albums: forYou, size: size),
      ],
      if (home.newAtHome.isNotEmpty) ...[
        const SectionHeader('New at home'),
        _AlbumRow(albums: home.newAtHome, size: size),
      ],
      if (onRepeat.isNotEmpty) ...[
        const SectionHeader('On repeat'),
        _SongRow(songs: onRepeat, size: size, from: 'On repeat'),
      ],
      if (films.isNotEmpty) ...[
        const SectionHeader('From the movies'),
        _AlbumRow(albums: films, size: size, films: true),
      ],
      if (artists.isNotEmpty) ...[
        const SectionHeader('Artists'),
        _ArtistRow(artists: artists, size: wide ? 136 : 112),
      ],
      if (home.playlists.isNotEmpty) ...[
        const SectionHeader('Playlists'),
        _PlaylistRow(playlists: home.playlists, size: size),
      ],
    ];
  }
}

class _QuickPicks extends ConsumerWidget {
  const _QuickPicks({required this.tiles, required this.columns});

  final List<HomeTile> tiles;
  final int columns;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < tiles.length; i += columns) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: HiveSpace.xs),
          child: Row(
            children: [
              for (var j = i; j < i + columns; j++) ...[
                if (j > i) const SizedBox(width: HiveSpace.xs),
                Expanded(
                  child: j < tiles.length
                      ? _QuickPick(tile: tiles[j])
                      : const SizedBox(),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return DefaultTextStyle(
      style: HiveType.callout.copyWith(color: p.textPrimary),
      child: Column(children: rows),
    );
  }
}

class _QuickPick extends StatelessWidget {
  const _QuickPick({required this.tile});
  final HomeTile tile;

  void _open(BuildContext context) {
    switch (tile.kind) {
      case 'album':
        context.openAlbum(tile.id);
      case 'playlist':
        context.openPlaylist(tile.id);
      case 'artist':
        context.openArtist(tile.id);
      default:
        context.openLiked();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return Semantics(
      button: true,
      label:
          '${tile.title}${tile.subtitle == null ? '' : ', ${tile.subtitle}'}',
      excludeSemantics: true,
      child: Material(
        color: p.surface,
        borderRadius: BorderRadius.circular(HiveRadius.art),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _open(context),
          child: SizedBox(
            height: 56,
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 56,
                  child: tile.kind == 'liked'
                      ? Container(
                          color: p.accent,
                          child: Icon(
                            HiveIcons.heart,
                            color: p.onAccent,
                            size: 22,
                          ),
                        )
                      : Mosaic(
                          artworkIds: tile.artworkIds ?? const [],
                          title: tile.title,
                          pixels: 192,
                        ),
                ),
                const SizedBox(width: HiveSpace.sm),
                Expanded(
                  child: Text(
                    tile.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: HiveType.callout.copyWith(
                      color: p.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: HiveSpace.xs),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Songs as cover tiles; a tap plays the row from that song.
class _SongRow extends ConsumerWidget {
  const _SongRow({required this.songs, required this.size, required this.from});
  final List<TrackSummary> songs;
  final double size;
  final String from;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: size + 52,
      child: ScrollConfiguration(
        behavior: const DragScrollBehavior(),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: HiveSpace.md),
          itemCount: songs.length,
          separatorBuilder: (_, _) => const SizedBox(width: HiveSpace.sm),
          itemBuilder: (context, i) {
            final t = songs[i];
            return CoverTile(
              width: size,
              semanticsKind: 'Song',
              title: t.title,
              subtitle: t.artistName,
              art: Artwork(
                artworkId: t.artworkId,
                title: t.albumTitle,
                size: size,
              ),
              onTap: () => ref
                  .read(playerProvider.notifier)
                  .playTracks(
                    songs,
                    start: i,
                    source: PlaySource(kind: 'songs', id: from, name: from),
                  ),
            );
          },
        ),
      ),
    );
  }
}

class _ArtistRow extends StatelessWidget {
  const _ArtistRow({required this.artists, required this.size});
  final List<ArtistSummary> artists;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: size + 52,
      child: ScrollConfiguration(
        behavior: const DragScrollBehavior(),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: HiveSpace.md),
          itemCount: artists.length,
          separatorBuilder: (_, _) => const SizedBox(width: HiveSpace.sm),
          itemBuilder: (context, i) {
            final a = artists[i];
            return CoverTile(
              width: size,
              semanticsKind: 'Artist',
              title: a.name,
              subtitle: plural(a.trackCount, 'song'),
              art: Artwork(
                artworkId: a.artworkId,
                title: a.name,
                size: size,
                round: true,
              ),
              onTap: () => context.openArtist(a.id),
            );
          },
        ),
      ),
    );
  }
}

class _AlbumRow extends StatelessWidget {
  const _AlbumRow({
    required this.albums,
    required this.size,
    this.films = false,
  });
  final List<AlbumSummary> albums;
  final double size;

  /// Captioned with the film and its year rather than the album artist.
  final bool films;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: size + 52,
      child: ScrollConfiguration(
        behavior: const DragScrollBehavior(),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: HiveSpace.md),
          itemCount: albums.length,
          separatorBuilder: (_, _) => const SizedBox(width: HiveSpace.sm),
          itemBuilder: (context, i) {
            final a = albums[i];
            return CoverTile(
              width: size,
              title: films ? (a.filmTitle ?? a.title) : a.title,
              subtitle: films
                  ? [a.artistName, if (a.year != null) '${a.year}'].join(' · ')
                  : a.artistName,
              art: Artwork(artworkId: a.artworkId, title: a.title, size: size),
              onTap: () => context.openAlbum(a.id),
            );
          },
        ),
      ),
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({required this.playlists, required this.size});
  final List<PlaylistSummary> playlists;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: size + 52,
      child: ScrollConfiguration(
        behavior: const DragScrollBehavior(),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: HiveSpace.md),
          itemCount: playlists.length,
          separatorBuilder: (_, _) => const SizedBox(width: HiveSpace.sm),
          itemBuilder: (context, i) {
            final pl = playlists[i];
            return CoverTile(
              width: size,
              semanticsKind: 'Playlist',
              title: pl.name,
              subtitle: pl.mine
                  ? plural(pl.trackCount, 'song')
                  : '${pl.ownerName} · ${plural(pl.trackCount, 'song')}',
              art: Mosaic(
                artworkIds: pl.artworkIds,
                title: pl.name,
                size: size,
              ),
              onTap: () => context.openPlaylist(pl.id),
            );
          },
        ),
      ),
    );
  }
}

/// Used by tests and the shell: the song that's playing, if any.
TrackSummary? nowPlayingTrack(WidgetRef ref) =>
    ref.watch(playerProvider.select((s) => s.track));
