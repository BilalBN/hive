import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/hive_api.g.dart';
import '../core/api.dart';
import '../design/icons.g.dart';
import '../downloads/downloads.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../library/library_providers.dart';
import '../player/player_controller.dart';
import '../player/quality.dart';
import 'artwork.dart';
import 'nav.dart';

class _Action {
  const _Action(this.icon, this.label, this.run);
  final IconData icon;
  final String label;
  final Future<void> Function() run;
}

List<_Action> _actionsFor(
  BuildContext context,
  WidgetRef ref,
  TrackSummary track, {
  VoidCallback? onRemoveFromPlaylist,
}) {
  final player = ref.read(playerProvider.notifier);
  final liked = ref.read(likesProvider.notifier).isLiked(track);
  final downloads = ref.read(downloadsProvider);
  final single =
      downloads.tracks[track.id]?.single ??
      downloads.jobs[track.id]?.single ??
      false;
  return [
    _Action(HiveIcons.listStart, 'Play next', () async {
      player.playNext(track);
      _toast(context, 'Playing next');
    }),
    _Action(HiveIcons.listEnd, 'Add to queue', () async {
      player.addToQueue(track);
      _toast(context, 'Added to queue');
    }),
    _Action(
      HiveIcons.listPlus,
      'Add to playlist…',
      () => showAddToPlaylist(context, ref, [track.id]),
    ),
    _Action(
      liked ? HiveIcons.heartOff : HiveIcons.heart,
      liked ? 'Remove from liked' : 'Like',
      () async {
        try {
          await ref.read(likesProvider.notifier).toggle(track);
        } catch (e) {
          if (context.mounted) _toast(context, describeError(e));
        }
      },
    ),
    if (single)
      _Action(HiveIcons.circleX, 'Remove download', () async {
        await ref.read(downloadsProvider.notifier).removeTrack(track.id);
        if (context.mounted) _toast(context, 'Download removed');
      })
    else if (!downloads.has(track.id))
      _Action(HiveIcons.circleArrowDown, 'Download', () async {
        await ref.read(downloadsProvider.notifier).downloadTrack(track);
        if (context.mounted) _toast(context, 'Downloading');
      }),
    _Action(
      HiveIcons.discAlbum,
      'Go to album',
      () async => context.openAlbum(track.albumId),
    ),
    if (track.artistId != null)
      _Action(
        HiveIcons.micVocal,
        'Go to artist',
        () async => context.openArtist(track.artistId!),
      ),
    if (onRemoveFromPlaylist != null)
      _Action(
        HiveIcons.trash2,
        'Remove from this playlist',
        () async => onRemoveFromPlaylist(),
      ),
  ];
}

void _toast(BuildContext context, String text) {
  final p = HiveTheme.of(context);
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          text,
          style: HiveType.callout.copyWith(color: p.textPrimary),
        ),
        backgroundColor: p.raised,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
}

void showToast(BuildContext context, String text) => _toast(context, text);

/// The song's actions: a sheet on phones, a menu at the pointer on computers.
Future<void> showTrackActions(
  BuildContext context,
  WidgetRef ref,
  TrackSummary track, {
  Offset? at,
  VoidCallback? onRemoveFromPlaylist,
}) async {
  final actions = _actionsFor(
    context,
    ref,
    track,
    onRemoveFromPlaylist: onRemoveFromPlaylist,
  );
  final p = HiveTheme.of(context);
  if (isDesktop && at != null) {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final chosen = await showMenu<_Action>(
      context: context,
      color: p.raised,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final a in actions)
          PopupMenuItem(
            value: a,
            height: 36,
            child: Row(
              children: [
                Icon(a.icon, size: 16, color: p.textSecondary),
                const SizedBox(width: HiveSpace.sm),
                Text(
                  a.label,
                  style: HiveType.callout.copyWith(color: p.textPrimary),
                ),
              ],
            ),
          ),
      ],
    );
    await chosen?.run();
    return;
  }
  final chosen = await showModalBottomSheet<_Action>(
    context: context,
    backgroundColor: p.surface,
    showDragHandle: true,
    useRootNavigator: true,
    // Taller than the default when needed, and scrolls on small phones.
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.85,
    ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(HiveRadius.sheet),
      ),
    ),
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HiveSpace.md,
                0,
                HiveSpace.md,
                HiveSpace.sm,
              ),
              child: Row(
                children: [
                  Artwork(
                    artworkId: track.artworkId,
                    title: track.albumTitle,
                    size: 48,
                    pixels: 96,
                  ),
                  const SizedBox(width: HiveSpace.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: HiveType.body.copyWith(
                            color: p.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          track.artistName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HiveType.callout.copyWith(
                            color: p.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: p.border),
            for (final a in actions)
              ListTile(
                leading: Icon(a.icon, size: 20, color: p.textSecondary),
                title: Text(
                  a.label,
                  style: HiveType.body.copyWith(color: p.textPrimary),
                ),
                onTap: () => Navigator.of(sheet).pop(a),
              ),
          ],
        ),
      ),
    ),
  );
  await chosen?.run();
}

/// Pick one of your playlists (or make a new one) and add songs to it.
Future<void> showAddToPlaylist(
  BuildContext context,
  WidgetRef ref,
  List<String> trackIds,
) async {
  final p = HiveTheme.of(context);
  final actions = ref.read(playlistActionsProvider);
  final picked = await showModalBottomSheet<Object>(
    context: context,
    backgroundColor: p.surface,
    showDragHandle: true,
    useRootNavigator: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(HiveRadius.sheet),
      ),
    ),
    builder: (sheet) =>
        _PlaylistPicker(onPick: (v) => Navigator.of(sheet).pop(v)),
  );
  if (picked == null || !context.mounted) return;
  try {
    if (picked == _newPlaylist) {
      final name = await askForName(
        context,
        title: 'New playlist',
        action: 'Create',
      );
      if (name == null) return;
      await actions.create(name, trackIds: trackIds);
      if (context.mounted) _toast(context, 'Added to $name');
    } else if (picked is PlaylistSummary) {
      await actions.add(picked.id, trackIds);
      if (context.mounted) _toast(context, 'Added to ${picked.name}');
    }
  } catch (e) {
    if (context.mounted) _toast(context, describeError(e));
  }
}

const _newPlaylist = Object();

class _PlaylistPicker extends ConsumerWidget {
  const _PlaylistPicker({required this.onPick});
  final void Function(Object) onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final lists = ref.watch(playlistsProvider);
    final mine =
        lists.value?.where((l) => l.mine).toList() ?? const <PlaylistSummary>[];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HiveSpace.md,
                0,
                HiveSpace.md,
                HiveSpace.sm,
              ),
              child: Text(
                'Add to playlist',
                style: HiveType.headline.copyWith(color: p.textPrimary),
              ),
            ),
            ListTile(
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: p.raised,
                  borderRadius: BorderRadius.circular(HiveRadius.art),
                ),
                child: Icon(HiveIcons.plus, color: p.accentText),
              ),
              title: Text(
                'New playlist',
                style: HiveType.body.copyWith(color: p.textPrimary),
              ),
              onTap: () => onPick(_newPlaylist),
            ),
            if (lists.isLoading && !lists.hasValue)
              const Padding(
                padding: EdgeInsets.all(HiveSpace.md),
                child: Center(child: CircularProgressIndicator()),
              ),
            for (final l in mine)
              ListTile(
                leading: Mosaic(
                  artworkIds: l.artworkIds,
                  title: l.name,
                  size: 44,
                  pixels: 96,
                ),
                title: Text(
                  l.name,
                  style: HiveType.body.copyWith(color: p.textPrimary),
                ),
                subtitle: Text(
                  '${l.trackCount} songs',
                  style: HiveType.caption.copyWith(color: p.textSecondary),
                ),
                onTap: () => onPick(l),
              ),
          ],
        ),
      ),
    );
  }
}

/// A small dialog asking for a name (new playlist, rename).
Future<String?> askForName(
  BuildContext context, {
  required String title,
  required String action,
  String initial = '',
}) {
  final p = HiveTheme.of(context);
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    useRootNavigator: true,
    builder: (dialog) => AlertDialog(
      backgroundColor: p.surface,
      title: Text(
        title,
        style: HiveType.headline.copyWith(color: p.textPrimary),
      ),
      content: TextField(
        key: const Key('name-field'),
        controller: controller,
        autofocus: true,
        maxLength: 120,
        textCapitalization: TextCapitalization.sentences,
        style: HiveType.body.copyWith(color: p.textPrimary),
        decoration: InputDecoration(
          hintText: 'Name',
          hintStyle: HiveType.body.copyWith(color: p.textTertiary),
        ),
        onSubmitted: (v) =>
            v.trim().isEmpty ? null : Navigator.of(dialog).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(),
          child: Text('Cancel', style: TextStyle(color: p.textSecondary)),
        ),
        TextButton(
          onPressed: () {
            final v = controller.text.trim();
            if (v.isNotEmpty) Navigator.of(dialog).pop(v);
          },
          child: Text(
            action,
            style: TextStyle(color: p.accentText, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}
