import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/hive_api.g.dart';
import '../../core/api.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../library/library_providers.dart';
import '../../player/player_controller.dart';
import '../../ui/artwork.dart';
import '../../ui/language_chips.dart';
import '../../ui/nav.dart';
import '../../ui/states.dart';
import '../../ui/tiles.dart';
import '../../ui/track_actions.dart';

enum _Section {
  playlists('Playlists'),
  albums('Albums'),
  artists('Artists'),
  songs('Songs');

  const _Section(this.label);
  final String label;
}

/// Library tab: playlists (with Liked songs first), albums, artists and every
/// song at home.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  _Section _section = _Section.playlists;
  AlbumSort _sort = AlbumSort.recent;

  Future<void> _newPlaylist() async {
    final name = await askForName(
      context,
      title: 'New playlist',
      action: 'Create',
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      final pl = await ref.read(playlistActionsProvider).create(name.trim());
      if (mounted) context.openPlaylist(pl.id);
    } catch (e) {
      if (mounted) showToast(context, describeError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final body = switch (_section) {
      _Section.playlists => const _Playlists(),
      _Section.albums => _Albums(sort: _sort),
      _Section.artists => const _Artists(),
      _Section.songs => const _Songs(),
    };
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HiveSpace.md,
              HiveSpace.md,
              HiveSpace.xs,
              HiveSpace.xs,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      'Library',
                      style: HiveType.title1.copyWith(color: p.textPrimary),
                    ),
                  ),
                ),
                if (_section == _Section.albums)
                  PopupMenuButton<AlbumSort>(
                    tooltip: 'Sort albums',
                    color: p.raised,
                    initialValue: _sort,
                    onSelected: (s) => setState(() => _sort = s),
                    icon: Icon(HiveIcons.arrowDownUp, color: p.textSecondary),
                    itemBuilder: (_) => [
                      for (final s in AlbumSort.values)
                        PopupMenuItem(
                          value: s,
                          child: Text(
                            s.label,
                            style: HiveType.callout.copyWith(
                              color: p.textPrimary,
                            ),
                          ),
                        ),
                    ],
                  ),
                IconButton(
                  tooltip: 'New playlist',
                  icon: Icon(HiveIcons.plus, color: p.textSecondary),
                  onPressed: _newPlaylist,
                ),
              ],
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: HiveSpace.md),
              children: [
                for (final s in _Section.values)
                  Padding(
                    padding: const EdgeInsets.only(right: HiveSpace.xs),
                    child: ChoiceChip(
                      label: Text(s.label),
                      selected: s == _section,
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _section = s),
                      labelStyle: HiveType.callout.copyWith(
                        color: s == _section ? p.onAccent : p.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                      selectedColor: p.accent,
                      backgroundColor: p.raised,
                      side: BorderSide.none,
                      shape: const StadiumBorder(),
                    ),
                  ),
              ],
            ),
          ),
          if (_section == _Section.albums || _section == _Section.songs)
            const Padding(
              padding: EdgeInsets.only(top: HiveSpace.xs),
              child: LanguageChips(),
            ),
          const SizedBox(height: HiveSpace.xs),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _Playlists extends ConsumerWidget {
  const _Playlists();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final lists = ref.watch(playlistsProvider);
    final liked = ListRow(
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: p.accent,
          borderRadius: BorderRadius.circular(HiveRadius.art),
        ),
        child: Icon(HiveIcons.heart, color: p.onAccent, size: 22),
      ),
      title: 'Liked songs',
      subtitle: 'Songs you\'ve liked',
      onTap: context.openLiked,
    );
    return AsyncView<List<PlaylistSummary>>(
      value: lists,
      onRetry: () => ref.invalidate(playlistsProvider),
      data: (items) => RefreshIndicator(
        color: p.accent,
        onRefresh: () async => ref.invalidate(playlistsProvider),
        child: ListView(
          padding: const EdgeInsets.only(bottom: HiveSpace.xl),
          children: [
            liked,
            for (final pl in items)
              ListRow(
                leading: Mosaic(
                  artworkIds: pl.artworkIds,
                  title: pl.name,
                  size: 48,
                  pixels: 96,
                ),
                title: pl.name,
                subtitle: [
                  pl.mine
                      ? (pl.shared ? 'Yours · shared with family' : 'Yours')
                      : 'By ${pl.ownerName}',
                  plural(pl.trackCount, 'song'),
                ].join(' · '),
                onTap: () => context.openPlaylist(pl.id),
              ),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(HiveSpace.md),
                child: Text(
                  'No playlists yet. Tap + to start one, or use Add to playlist on any song.',
                  style: HiveType.callout.copyWith(color: p.textSecondary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Loads the next page when the list nears its end.
Widget _paged<T>({
  required BuildContext context,
  required Paged<T> paged,
  required VoidCallback more,
  required VoidCallback retry,
  required Widget Function(List<T> items) builder,
  required Widget empty,
}) {
  if (paged.items.isEmpty) {
    if (paged.error != null) {
      return ErrorState(message: describeError(paged.error!), onRetry: retry);
    }
    if (paged.loading || paged.total == null) return const LoadingState();
    return empty;
  }
  return NotificationListener<ScrollNotification>(
    onNotification: (n) {
      if (n.metrics.extentAfter < 800 &&
          !paged.done &&
          !paged.loading &&
          paged.error == null) {
        more();
      }
      return false;
    },
    child: builder(paged.items),
  );
}

class _Albums extends ConsumerWidget {
  const _Albums({required this.sort});
  final AlbumSort sort;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paged = ref.watch(albumsProvider(sort));
    final notifier = ref.read(albumsProvider(sort).notifier);
    return _paged<AlbumSummary>(
      context: context,
      paged: paged,
      more: notifier.more,
      retry: () => ref.invalidate(albumsProvider(sort)),
      empty: const EmptyState(
        icon: HiveIcons.discAlbum,
        title: 'No albums yet',
        text: 'Albums appear here once music is added at home (Hive Admin → Upload).',
      ),
      builder: (items) => GridView.builder(
        padding: const EdgeInsets.fromLTRB(
          HiveSpace.md,
          HiveSpace.xs,
          HiveSpace.md,
          HiveSpace.xl,
        ),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 200,
          mainAxisSpacing: HiveSpace.md,
          crossAxisSpacing: HiveSpace.md,
          childAspectRatio: 0.74,
        ),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final a = items[i];
          return CoverTile(
            title: a.title,
            subtitle: [
              a.artistName,
              if (sort == AlbumSort.year && a.year != null) '${a.year}',
            ].join(' · '),
            art: Artwork(artworkId: a.artworkId, title: a.title),
            onTap: () => context.openAlbum(a.id),
          );
        },
      ),
    );
  }
}

class _Artists extends ConsumerWidget {
  const _Artists();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paged = ref.watch(artistsProvider);
    return _paged<ArtistSummary>(
      context: context,
      paged: paged,
      more: ref.read(artistsProvider.notifier).more,
      retry: () => ref.invalidate(artistsProvider),
      empty: const EmptyState(
        icon: HiveIcons.micVocal,
        title: 'No artists yet',
        text: 'Artists appear as music is added at home.',
      ),
      builder: (items) => ListView.builder(
        padding: const EdgeInsets.only(bottom: HiveSpace.xl),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final a = items[i];
          return ListRow(
            leading: Artwork(
              artworkId: a.artworkId,
              title: a.name,
              size: 48,
              round: true,
              pixels: 96,
            ),
            title: a.name,
            subtitle:
                '${plural(a.albumCount, 'album')} · ${plural(a.trackCount, 'song')}',
            onTap: () => context.openArtist(a.id),
          );
        },
      ),
    );
  }
}

class _Songs extends ConsumerWidget {
  const _Songs();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paged = ref.watch(songsProvider);
    return _paged<TrackSummary>(
      context: context,
      paged: paged,
      more: ref.read(songsProvider.notifier).more,
      retry: () => ref.invalidate(songsProvider),
      empty: const EmptyState(
        icon: HiveIcons.music,
        title: 'No songs yet',
        text: 'Songs appear as music is added at home.',
      ),
      builder: (items) => ListView.builder(
        padding: const EdgeInsets.only(bottom: HiveSpace.xl),
        itemCount: items.length,
        itemBuilder: (context, i) => TrackRow(
          track: items[i],
          showAlbum: true,
          onTap: () => ref
              .read(playerProvider.notifier)
              .playTracks(
                items,
                start: i,
                source: const PlaySource(
                  kind: 'songs',
                  id: 'all',
                  name: 'All songs',
                ),
              ),
        ),
      ),
    );
  }
}
