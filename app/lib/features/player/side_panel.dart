import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import 'lyrics_view.dart';
import 'queue_view.dart';

/// The right-hand panel on computers.
enum SidePanel { none, queue, lyrics }

class SidePanelNotifier extends Notifier<SidePanel> {
  @override
  SidePanel build() => SidePanel.none;

  /// Open [panel], or close it if it's already open.
  void toggle(SidePanel panel) =>
      state = state == panel ? SidePanel.none : panel;
  void show(SidePanel panel) => state = panel;
  void close() => state = SidePanel.none;
}

final sidePanelProvider = NotifierProvider<SidePanelNotifier, SidePanel>(
  SidePanelNotifier.new,
);

class SidePanelView extends ConsumerWidget {
  const SidePanelView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final panel = ref.watch(sidePanelProvider);
    final notifier = ref.read(sidePanelProvider.notifier);
    Widget tab(SidePanel which, String label) {
      final on = panel == which;
      return TextButton(
        onPressed: () => notifier.show(which),
        child: Text(
          label,
          style: HiveType.callout.copyWith(
            color: on ? p.textPrimary : p.textSecondary,
            fontWeight: on ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      );
    }

    return Container(
      width: 340,
      color: p.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HiveSpace.xs,
              HiveSpace.xs,
              HiveSpace.xxs,
              0,
            ),
            child: Row(
              children: [
                tab(SidePanel.queue, 'Queue'),
                tab(SidePanel.lyrics, 'Lyrics'),
                const Spacer(),
                IconButton(
                  tooltip: 'Close panel',
                  icon: Icon(HiveIcons.x, size: 18, color: p.textSecondary),
                  onPressed: notifier.close,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: p.border),
          Expanded(
            child: panel == SidePanel.lyrics
                ? const LyricsView()
                : const QueueList(),
          ),
        ],
      ),
    );
  }
}
