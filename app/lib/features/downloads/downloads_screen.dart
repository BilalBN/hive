import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/home_connection.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../design/widgets.dart';
import '../../downloads/downloads.dart';
import '../../player/player_controller.dart';
import '../../ui/artwork.dart';
import '../../ui/states.dart';
import '../../ui/tiles.dart';
import '../../ui/track_actions.dart';
import '../library/detail_scaffold.dart';

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _day(DateTime d) {
  final l = d.toLocal();
  return '${l.day} ${_months[l.month - 1]}';
}

/// Asks before removing a download (it takes a while to get back).
Future<bool> confirmRemoveDownload(BuildContext context, String what) async {
  final p = HiveTheme.of(context);
  final ok = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    backgroundColor: p.surface,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(HiveRadius.sheet),
      ),
    ),
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          HiveSpace.md,
          0,
          HiveSpace.md,
          HiveSpace.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Remove $what from this device?',
              style: HiveType.headline.copyWith(color: p.textPrimary),
            ),
            const SizedBox(height: HiveSpace.xxs),
            Text(
              "It stays at home; you can download it again whenever you're connected.",
              style: HiveType.callout.copyWith(color: p.textSecondary),
            ),
            const SizedBox(height: HiveSpace.md),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: p.danger),
              onPressed: () => Navigator.of(sheet).pop(true),
              child: const Text('Remove download'),
            ),
            TextButton(
              onPressed: () => Navigator.of(sheet).pop(false),
              child: Text('Keep it', style: TextStyle(color: p.accentText)),
            ),
          ],
        ),
      ),
    ),
  );
  return ok ?? false;
}

/// Download / downloading / downloaded, at the top of an album or playlist.
class DownloadSetButton extends ConsumerWidget {
  const DownloadSetButton({
    super.key,
    required this.kind,
    required this.id,
    required this.name,
    required this.onDownload,
  });

  final String kind;
  final String id;
  final String name;
  final Future<void> Function()? onDownload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final status = ref.watch(
      downloadsProvider.select((s) => s.statusOfSet(kind, id)),
    );
    final progress = ref.watch(
      downloadsProvider.select((s) {
        final set = s.setOf(kind, id);
        return set == null ? 0.0 : s.progressOfSet(set);
      }),
    );
    Future<void> remove() async {
      if (!await confirmRemoveDownload(context, name)) return;
      await ref.read(downloadsProvider.notifier).removeSet(kind, id);
    }

    return switch (status) {
      DownloadStatus.none => IconButton(
        tooltip: 'Download',
        icon: Icon(HiveIcons.circleArrowDown, color: p.textSecondary),
        onPressed: onDownload == null
            ? null
            : () async {
                await onDownload!();
                if (context.mounted) {
                  showToast(
                    context,
                    'Downloading. Find it in Library → Downloads',
                  );
                }
              },
      ),
      DownloadStatus.downloading => IconButton(
        tooltip: 'Downloading, ${(progress * 100).floor()}%',
        onPressed: remove,
        icon: SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(
            value: progress == 0 ? null : progress,
            strokeWidth: 2.4,
            color: p.accent,
            backgroundColor: p.border,
          ),
        ),
      ),
      DownloadStatus.done => IconButton(
        tooltip: 'Downloaded',
        onPressed: remove,
        icon: Icon(HiveIcons.circleCheck, color: p.accentText),
      ),
    };
  }
}

/// Everything kept on this device: albums, playlists and songs, what is
/// still downloading, the space used and how long they play offline.
List<Widget> downloadRows(
  BuildContext context,
  WidgetRef ref,
  DownloadsState s,
) {
  final p = HiveTheme.of(context);
  final dl = ref.read(downloadsProvider.notifier);
  if (!s.loaded) return const [LoadingState()];
  if (s.isEmpty) {
    return const [
      EmptyState(
        icon: HiveIcons.circleArrowDown,
        title: 'No downloads yet',
        text: 'Download albums and playlists to play them without home: on a plane, or when the music PC is off. Look for the download button at the top of any album or playlist.',
      ),
    ];
  }
  final reachable = ref.watch(homeStatusProvider) is HomeConnected;
  final waiting = s.jobs.values.where((j) => !j.failed).toList();
  final failed = s.failed;
  final songs = s.tracks.length;

  Widget padded(Widget child) => Padding(
    padding: const EdgeInsets.fromLTRB(
      HiveSpace.md,
      0,
      HiveSpace.md,
      HiveSpace.sm,
    ),
    child: child,
  );

  return [
    padded(
      Text(
        '${plural(songs, 'song')} · ${formatBytes(s.bytes)} on this device',
        style: HiveType.callout.copyWith(color: p.textSecondary),
      ),
    ),
    if (s.expired)
      padded(
        const HiveBanner(
          title: 'Connect to home to keep playing',
          body: "Downloads play offline for 30 days at a time. Connect to home once and they're good for another 30 days.",
        ),
      ),
    if (s.expiringSoon)
      padded(
        HiveBanner(
          title: 'Connect to home by ${_day(s.validUntil!)}',
          body: 'Downloads play offline for 30 days at a time. Connect to home before then to keep them playing.',
        ),
      ),
    if (failed.isNotEmpty)
      padded(
        HiveBanner(
          title: plural(
            failed.length,
            "song didn't download",
            "songs didn't download",
          ),
          body: failed.first.error ?? '',
          action: TextButton(
            onPressed: dl.retry,
            child: Text(
              'Try again',
              style: HiveType.callout.copyWith(
                color: p.accentText,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    if (waiting.isNotEmpty)
      padded(
        _Downloading(
          left: waiting.length,
          current: waiting.first,
          reachable: reachable,
        ),
      ),
    if (s.sets.isNotEmpty) ...[
      const SectionHeader('Albums and playlists'),
      for (final set in s.sets.reversed) _SetRow(set: set, state: s),
    ],
    if (s.singles.isNotEmpty) ...[
      const SectionHeader('Songs'),
      for (final (i, t) in s.singles.indexed)
        TrackRow(
          track: t.track,
          showAlbum: true,
          onTap: () => ref
              .read(playerProvider.notifier)
              .playTracks(
                [for (final x in s.singles) x.track],
                start: i,
                source: const PlaySource(
                  kind: 'downloads',
                  id: 'songs',
                  name: 'Downloads',
                ),
              ),
        ),
    ],
    Padding(
      padding: const EdgeInsets.fromLTRB(
        HiveSpace.md,
        HiveSpace.lg,
        HiveSpace.md,
        0,
      ),
      child: Text(
        s.validUntil == null
            ? 'Downloads are locked to this device. Signing out deletes them.'
            : 'Plays offline until ${_day(s.validUntil!)}; each time you connect to home adds 30 days. Downloads are locked to this device, and signing out deletes them.',
        style: HiveType.caption.copyWith(color: p.textSecondary),
      ),
    ),
    Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: HiveSpace.xs),
        child: TextButton(
          onPressed: () async {
            if (await confirmRemoveDownload(context, 'every download')) {
              await dl.removeAll();
            }
          },
          child: Text(
            'Remove all downloads',
            style: HiveType.callout.copyWith(color: p.danger),
          ),
        ),
      ),
    ),
  ];
}

class _Downloading extends StatelessWidget {
  const _Downloading({
    required this.left,
    required this.current,
    required this.reachable,
  });

  final int left;
  final DownloadJob current;
  final bool reachable;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(HiveSpace.sm),
      decoration: BoxDecoration(
        color: p.raised,
        borderRadius: BorderRadius.circular(HiveRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            reachable
                ? 'Downloading ${plural(left, 'song')}'
                : '${plural(left, 'song')} waiting for home',
            style: HiveType.headline.copyWith(color: p.textPrimary),
          ),
          const SizedBox(height: 2),
          Text(
            reachable
                ? current.track.title
                : 'They carry on by themselves when home is reachable.',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HiveType.caption.copyWith(color: p.textSecondary),
          ),
          if (reachable) ...[
            const SizedBox(height: HiveSpace.xs),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: current.fraction,
                minHeight: 4,
                color: p.accent,
                backgroundColor: p.border,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SetRow extends StatelessWidget {
  const _SetRow({required this.set, required this.state});
  final DownloadedSet set;
  final DownloadsState state;

  @override
  Widget build(BuildContext context) {
    final have = set.trackIds.where(state.tracks.containsKey).length;
    final done = have == set.trackIds.length;
    return ListRow(
      leading: set.kind == 'album'
          ? Artwork(
              artworkId: set.artworkIds.firstOrNull,
              title: set.name,
              size: 48,
              pixels: 96,
            )
          : Mosaic(
              artworkIds: set.artworkIds,
              title: set.name,
              size: 48,
              pixels: 96,
            ),
      title: set.name,
      subtitle: done
          ? '${set.subtitle} · ${plural(have, 'song')}'
          : 'Downloading ${(state.progressOfSet(set) * 100).floor()}% · $have of ${set.trackIds.length}',
      onTap: () => context.push(
        '/library/downloads/${set.kind}/${Uri.encodeComponent(set.id)}',
      ),
    );
  }
}

/// Library → Downloads, also reached from Home when home can't be reached.
class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(downloadsProvider);
    return DetailScaffold(
      title: 'Downloads',
      slivers: [SliverList.list(children: downloadRows(context, ref, s))],
    );
  }
}

/// A downloaded album or playlist, played from the device.
class DownloadedSetScreen extends ConsumerWidget {
  const DownloadedSetScreen({super.key, required this.kind, required this.id});
  final String kind;
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final s = ref.watch(downloadsProvider);
    final set = s.setOf(kind, id);
    if (set == null) {
      return const DetailScaffold(
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: HiveIcons.circleArrowDown,
              title: 'Not downloaded',
              text: 'This was removed from the device.',
            ),
          ),
        ],
      );
    }
    final tracks = [for (final tid in set.trackIds) ?s.tracks[tid]?.track];
    final bytes = [
      for (final tid in set.trackIds) s.tracks[tid]?.sizeBytes ?? 0,
    ].fold(0, (a, b) => a + b);
    final missing = set.trackIds.length - tracks.length;
    final player = ref.read(playerProvider.notifier);
    final source = PlaySource(kind: kind, id: id, name: set.name);
    return DetailScaffold(
      actions: [
        DownloadSetButton(kind: kind, id: id, name: set.name, onDownload: null),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: DetailHeader(
            art: kind == 'album'
                ? Artwork(
                    artworkId: set.artworkIds.firstOrNull,
                    title: set.name,
                    pixels: 600,
                  )
                : Mosaic(artworkIds: set.artworkIds, title: set.name),
            kicker: 'Downloaded',
            title: set.name,
            subtitle: set.subtitle,
            facts: '${plural(tracks.length, 'song')} · ${formatBytes(bytes)}',
            buttons: PlayButtons(
              onPlay: tracks.isEmpty || s.expired
                  ? null
                  : () => player.playTracks(tracks, source: source),
              onShuffle: tracks.isEmpty || s.expired
                  ? null
                  : () => player.playTracks(
                      tracks,
                      source: source,
                      shuffle: true,
                    ),
            ),
          ),
        ),
        if (s.expired)
          const SliverPadding(
            padding: EdgeInsets.all(HiveSpace.md),
            sliver: SliverToBoxAdapter(
              child: HiveBanner(
                title: 'Connect to home to keep playing',
                body: "Downloads play offline for 30 days at a time. Connect to home once and they're good for another 30 days.",
              ),
            ),
          ),
        if (missing > 0)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              HiveSpace.md,
              0,
              HiveSpace.md,
              HiveSpace.sm,
            ),
            sliver: SliverToBoxAdapter(
              child: Text(
                '${plural(missing, 'more song')} still downloading.',
                style: HiveType.callout.copyWith(color: p.textSecondary),
              ),
            ),
          ),
        SliverList.list(
          children: [
            for (final (i, t) in tracks.indexed)
              TrackRow(
                track: t,
                number: kind == 'album' ? (t.trackNumber ?? i + 1) : null,
                onTap: s.expired
                    ? () {}
                    : () => player.playTracks(tracks, start: i, source: source),
              ),
          ],
        ),
      ],
    );
  }
}
