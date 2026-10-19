import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../player/player_controller.dart';
import '../../player/quality.dart';
import '../../ui/artwork.dart';
import '../../ui/states.dart';

/// Queue as its own screen (phones).
class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          tooltip: 'Close',
          icon: Icon(HiveIcons.chevronDown, color: p.textPrimary),
          onPressed: () => context.pop(),
        ),
        title: Text(
          'Queue',
          style: HiveType.headline.copyWith(color: p.textPrimary),
        ),
      ),
      body: const QueueList(),
    );
  }
}

/// Now playing, then what's next: songs you added first ("Next from you"),
/// then the rest of the album or playlist. Drag to reorder, swipe to remove.
class QueueList extends ConsumerWidget {
  const QueueList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final s = ref.watch(playerProvider);
    final player = ref.read(playerProvider.notifier);
    final current = s.current;
    if (current == null) {
      return const EmptyState(
        icon: HiveIcons.listMusic,
        title: 'Nothing queued',
        text: 'Play an album or playlist, or use Play next on any song.',
      );
    }
    final upNext = s.upNext;
    final fromYou = upNext.where((e) => e.fromYou).length;
    final base = s.index + 1;

    Widget header(String text, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.fromLTRB(
        HiveSpace.md,
        HiveSpace.md,
        HiveSpace.xs,
        HiveSpace.xxs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                text,
                style: HiveType.headline.copyWith(color: p.textPrimary),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: header('Now playing')),
        SliverToBoxAdapter(child: _EntryRow(entry: current, current: true)),
        const SliverToBoxAdapter(child: _Modes()),
        SliverToBoxAdapter(
          child: header(
            fromYou > 0
                ? 'Next from you'
                : (s.source == null ? 'Next' : 'Next from ${s.source!.name}'),
            trailing: fromYou > 0
                ? TextButton(
                    onPressed: player.clearFromYou,
                    child: Text(
                      'Clear',
                      style: HiveType.callout.copyWith(color: p.accentText),
                    ),
                  )
                : null,
          ),
        ),
        if (upNext.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HiveSpace.md,
                vertical: HiveSpace.xs,
              ),
              child: Text(
                s.repeat == RepeatMode.all
                    ? 'The queue starts again after this song.'
                    : ref.watch(playbackSettingsProvider).autoplay
                    ? 'Songs like this one follow (autoplay).'
                    : 'Nothing after this song.',
                style: HiveType.callout.copyWith(color: p.textSecondary),
              ),
            ),
          )
        else
          SliverReorderableList(
            itemCount: upNext.length,
            onReorderItem: (from, to) => player.move(base + from, base + to),
            itemBuilder: (context, i) {
              final e = upNext[i];
              final showSourceHeader =
                  fromYou > 0 && i == fromYou && s.source != null;
              // Where autoplay's songs start.
              final showAutoplayHeader =
                  e.autoplay && (i == 0 || !upNext[i - 1].autoplay);
              return ReorderableDelayedDragStartListener(
                key: ValueKey(e.id),
                index: i,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (showSourceHeader) header('Next from ${s.source!.name}'),
                    if (showAutoplayHeader)
                      header('Songs like this (autoplay)'),
                    Dismissible(
                      key: ValueKey('d${e.id}'),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        color: p.danger,
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: HiveSpace.lg),
                        child: Icon(HiveIcons.trash2, color: p.onDanger),
                      ),
                      onDismissed: (_) => player.removeAt(base + i),
                      child: _EntryRow(
                        entry: e,
                        onTap: () => player.skipTo(base + i),
                        onRemove: () => player.removeAt(base + i),
                        dragIndex: i,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        const SliverToBoxAdapter(child: SizedBox(height: HiveSpace.xl)),
      ],
    );
  }
}

/// Shuffle, Repeat and Autoplay as three equal toggles under the song.
class _Modes extends ConsumerWidget {
  const _Modes();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(playerProvider);
    final player = ref.read(playerProvider.notifier);
    final settings = ref.watch(playbackSettingsProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HiveSpace.md,
        HiveSpace.xs,
        HiveSpace.md,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: _Toggle(
              label: 'Shuffle',
              icon: HiveIcons.shuffle,
              on: s.shuffled,
              onTap: player.toggleShuffle,
            ),
          ),
          const SizedBox(width: HiveSpace.xs),
          Expanded(
            child: _Toggle(
              label: s.repeat == RepeatMode.one ? 'Repeat 1' : 'Repeat',
              icon: s.repeat == RepeatMode.one
                  ? HiveIcons.repeat1
                  : HiveIcons.repeat,
              on: s.repeat != RepeatMode.off,
              onTap: player.cycleRepeat,
            ),
          ),
          const SizedBox(width: HiveSpace.xs),
          Expanded(
            child: _Toggle(
              label: 'Autoplay',
              icon: HiveIcons.infinity,
              on: settings.autoplay,
              onTap: () => ref
                  .read(playbackSettingsProvider.notifier)
                  .update(settings.copyWith(autoplay: !settings.autoplay)),
            ),
          ),
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.icon,
    required this.on,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final off = dark
        ? Colors.white.withValues(alpha: 0.07)
        : Colors.black.withValues(alpha: 0.05);
    return Semantics(
      button: true,
      toggled: on,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: on ? p.accent : off,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: SizedBox(
            height: 38,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 16, color: on ? p.onAccent : p.textSecondary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HiveType.caption.copyWith(
                      color: on ? p.onAccent : p.textSecondary,
                      fontWeight: FontWeight.w600,
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

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    this.current = false,
    this.onTap,
    this.onRemove,
    this.dragIndex,
  });
  final QueueEntry entry;
  final bool current;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  final int? dragIndex;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final t = entry.track;
    return Semantics(
      label: '${t.title}, ${t.artistName}${current ? ', playing now' : ''}',
      button: onTap != null,
      excludeSemantics: true,
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Remove from queue'): ?onRemove,
      },
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HiveSpace.md,
            vertical: 6,
          ),
          child: Row(
            children: [
              Artwork(
                artworkId: t.artworkId,
                title: t.albumTitle,
                size: 40,
                pixels: 96,
              ),
              const SizedBox(width: HiveSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HiveType.body.copyWith(
                        color: current ? p.accentText : p.textPrimary,
                        fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    Text(
                      t.artistName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HiveType.caption.copyWith(color: p.textSecondary),
                    ),
                  ],
                ),
              ),
              if (current)
                Icon(HiveIcons.audioLines, size: 16, color: p.accentText)
              else ...[
                Text(
                  formatDuration(Duration(milliseconds: t.durationMs)),
                  style: HiveType.caption.copyWith(color: p.textSecondary),
                ),
                if (dragIndex != null)
                  ReorderableDragStartListener(
                    index: dragIndex!,
                    child: Padding(
                      padding: const EdgeInsets.only(left: HiveSpace.sm),
                      child: Icon(
                        HiveIcons.gripVertical,
                        size: 18,
                        color: p.textTertiary,
                        semanticLabel: 'Drag to reorder',
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
