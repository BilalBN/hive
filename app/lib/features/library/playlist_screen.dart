import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/hive_api.g.dart';
import '../../core/api.dart';
import '../../design/icons.g.dart';
import '../../downloads/downloads.dart';
import '../downloads/downloads_screen.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../library/library_providers.dart';
import '../../player/player_controller.dart';
import '../../ui/artwork.dart';
import '../../ui/states.dart';
import '../../ui/tiles.dart';
import '../../ui/track_actions.dart';
import 'detail_scaffold.dart';

class PlaylistScreen extends ConsumerWidget {
  const PlaylistScreen({super.key, required this.playlistId});
  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlist = ref.watch(playlistProvider(playlistId));
    return AsyncView<Playlist>(
      value: playlist,
      onRetry: () => ref.invalidate(playlistProvider(playlistId)),
      data: (pl) => _PlaylistPage(playlist: pl),
    );
  }
}

class _PlaylistPage extends ConsumerStatefulWidget {
  const _PlaylistPage({required this.playlist});
  final Playlist playlist;

  @override
  ConsumerState<_PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends ConsumerState<_PlaylistPage> {
  /// While editing: the order being arranged, saved with Done.
  List<PlaylistItem>? _editing;
  bool _saving = false;

  Playlist get pl => widget.playlist;

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) showToast(context, describeError(e));
    }
  }

  Future<void> _saveOrder() async {
    final items = _editing;
    if (items == null) return;
    setState(() => _saving = true);
    await _run(() async {
      await ref
          .read(playlistActionsProvider)
          .setTracks(pl.id, items.map((i) => i.track.id).toList());
      if (mounted) setState(() => _editing = null);
    });
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _menu() async {
    final p = HiveTheme.of(context);
    final actions = ref.read(playlistActionsProvider);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: p.surface,
      showDragHandle: true,
      useRootNavigator: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(HiveIcons.arrowUpDown, color: p.textSecondary),
              title: Text(
                'Edit order',
                style: HiveType.body.copyWith(color: p.textPrimary),
              ),
              onTap: () => Navigator.of(sheet).pop('edit'),
            ),
            ListTile(
              leading: Icon(HiveIcons.pencil, color: p.textSecondary),
              title: Text(
                'Rename',
                style: HiveType.body.copyWith(color: p.textPrimary),
              ),
              onTap: () => Navigator.of(sheet).pop('rename'),
            ),
            SwitchListTile(
              secondary: Icon(HiveIcons.users, color: p.textSecondary),
              title: Text(
                'Share with the family',
                style: HiveType.body.copyWith(color: p.textPrimary),
              ),
              subtitle: Text(
                'Everyone at home can see and play it; only you can change it.',
                style: HiveType.caption.copyWith(color: p.textSecondary),
              ),
              value: pl.shared,
              activeThumbColor: p.accent,
              onChanged: (_) => Navigator.of(sheet).pop('share'),
            ),
            ListTile(
              leading: Icon(HiveIcons.trash2, color: p.danger),
              title: Text(
                'Delete playlist',
                style: HiveType.body.copyWith(color: p.danger),
              ),
              onTap: () => Navigator.of(sheet).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'edit':
        setState(() => _editing = [...pl.items]);
      case 'rename':
        final name = await askForName(
          context,
          title: 'Rename playlist',
          action: 'Save',
          initial: pl.name,
        );
        if (name != null) await _run(() => actions.rename(pl.id, name));
      case 'share':
        await _run(() => actions.setShared(pl.id, !pl.shared));
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          useRootNavigator: true,
          builder: (d) => AlertDialog(
            backgroundColor: p.surface,
            title: Text(
              'Delete "${pl.name}"?',
              style: HiveType.headline.copyWith(color: p.textPrimary),
            ),
            content: Text(
              'The songs stay in the library.',
              style: HiveType.body.copyWith(color: p.textSecondary),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(d).pop(false),
                child: Text('Cancel', style: TextStyle(color: p.textSecondary)),
              ),
              TextButton(
                onPressed: () => Navigator.of(d).pop(true),
                child: Text('Delete', style: TextStyle(color: p.danger)),
              ),
            ],
          ),
        );
        if (ok == true) {
          await _run(() async {
            await actions.delete(pl.id);
            if (mounted) {
              context.canPop() ? context.pop() : context.go('/library');
            }
          });
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final player = ref.read(playerProvider.notifier);
    final tracks = pl.items.map((i) => i.track).toList();
    final editing = _editing;
    final facts = [
      if (!pl.mine) pl.ownerName,
      plural(pl.trackCount, 'song'),
      if (pl.durationMs > 0) formatLength(pl.durationMs),
      if (pl.shared) 'Shared with the family',
    ].join(' · ');

    if (editing != null) {
      return Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                HiveSpace.md,
                HiveSpace.sm,
                HiveSpace.xs,
                HiveSpace.xs,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Edit ${pl.name}',
                      style: HiveType.headline.copyWith(color: p.textPrimary),
                    ),
                  ),
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => setState(() => _editing = null),
                    child: Text(
                      'Cancel',
                      style: TextStyle(color: p.textSecondary),
                    ),
                  ),
                  TextButton(
                    onPressed: _saving ? null : _saveOrder,
                    child: Text(
                      'Done',
                      style: TextStyle(
                        color: p.accentText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom + HiveSpace.md,
              ),
              itemCount: editing.length,
              onReorderItem: (from, to) => setState(() {
                editing.insert(to, editing.removeAt(from));
              }),
              itemBuilder: (context, i) {
                final item = editing[i];
                return Dismissible(
                  key: ValueKey(item.itemId),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: p.danger,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: HiveSpace.lg),
                    child: Text(
                      'Remove',
                      style: HiveType.callout.copyWith(
                        color: p.onDanger,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  onDismissed: (_) => setState(() => editing.removeAt(i)),
                  child: ListTile(
                    leading: Artwork(
                      artworkId: item.track.artworkId,
                      title: item.track.albumTitle,
                      size: 40,
                      pixels: 96,
                    ),
                    title: Text(
                      item.track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HiveType.body.copyWith(color: p.textPrimary),
                    ),
                    subtitle: Text(
                      item.track.artistName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HiveType.caption.copyWith(color: p.textSecondary),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Remove ${item.track.title}',
                          icon: Icon(
                            HiveIcons.circleMinus,
                            color: p.danger,
                            size: 20,
                          ),
                          onPressed: () => setState(() => editing.removeAt(i)),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: Icon(
                            HiveIcons.gripVertical,
                            color: p.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );
    }

    return DetailScaffold(
      actions: [
        DownloadSetButton(
          kind: 'playlist',
          id: pl.id,
          name: pl.name,
          onDownload: tracks.isEmpty
              ? null
              : () => ref.read(downloadsProvider.notifier).downloadPlaylist(pl),
        ),
        if (pl.mine)
          IconButton(
            tooltip: 'Playlist options',
            icon: Icon(HiveIcons.ellipsis, color: p.textSecondary),
            onPressed: _menu,
          ),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: DetailHeader(
            art: Mosaic(artworkIds: pl.artworkIds, title: pl.name, pixels: 600),
            kicker: 'Playlist',
            title: pl.name,
            facts: facts,
            buttons: PlayButtons(
              onPlay: tracks.isEmpty ? null : () => player.playPlaylist(pl),
              onShuffle: tracks.isEmpty
                  ? null
                  : () => player.playPlaylist(pl, shuffle: true),
            ),
          ),
        ),
        if (tracks.isEmpty)
          const SliverToBoxAdapter(
            child: EmptyState(
              icon: HiveIcons.listMusic,
              title: 'No songs yet',
              text:
                  'Add songs from any album or search: ⋯ then Add to playlist.',
            ),
          ),
        SliverList.builder(
          itemCount: tracks.length,
          itemBuilder: (context, i) => TrackRow(
            track: tracks[i],
            onTap: () => player.playPlaylist(pl, start: i),
            onRemoveFromPlaylist: pl.mine
                ? () => _run(() async {
                    final ids = [...tracks.map((t) => t.id)]..removeAt(i);
                    await ref
                        .read(playlistActionsProvider)
                        .setTracks(pl.id, ids);
                  })
                : null,
          ),
        ),
      ],
    );
  }
}

/// Liked songs, newest first.
class LikedSongsScreen extends ConsumerWidget {
  const LikedSongsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final liked = ref.watch(likedSongsProvider);
    final player = ref.read(playerProvider.notifier);
    const source = PlaySource(kind: 'liked', id: 'liked', name: 'Liked songs');
    return AsyncView<List<TrackSummary>>(
      value: liked,
      onRetry: () => ref.invalidate(likedSongsProvider),
      data: (tracks) => DetailScaffold(
        slivers: [
          SliverToBoxAdapter(
            child: DetailHeader(
              art: Container(
                decoration: BoxDecoration(
                  color: p.accent,
                  borderRadius: BorderRadius.circular(HiveRadius.art),
                ),
                child: Icon(HiveIcons.heart, size: 64, color: p.onAccent),
              ),
              title: 'Liked songs',
              facts: plural(tracks.length, 'song'),
              buttons: PlayButtons(
                onPlay: tracks.isEmpty
                    ? null
                    : () => player.playTracks(tracks, source: source),
                onShuffle: tracks.isEmpty
                    ? null
                    : () => player.playTracks(
                        tracks,
                        source: source,
                        shuffle: true,
                      ),
              ),
            ),
          ),
          if (tracks.isEmpty)
            const SliverToBoxAdapter(
              child: EmptyState(
                icon: HiveIcons.heart,
                title: 'No liked songs yet',
                text: 'Tap the heart on Now playing to keep a song here.',
              ),
            ),
          SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (context, i) => TrackRow(
              track: tracks[i],
              showAlbum: true,
              onTap: () => player.playTracks(tracks, start: i, source: source),
            ),
          ),
        ],
      ),
    );
  }
}
