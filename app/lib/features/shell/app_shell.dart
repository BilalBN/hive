import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../library/library_providers.dart';
import '../../player/player_controller.dart';
import '../player/mini_player.dart';
import '../player/side_panel.dart';
import '../search/search_screen.dart';

import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';

class _Tab {
  const _Tab(this.label, this.icon);
  final String label;
  final IconData icon;
}

const _tabs = [
  _Tab('Home', HiveIcons.house),
  _Tab('Search', HiveIcons.search),
  _Tab('Library', HiveIcons.libraryBig),
  _Tab('Listen', HiveIcons.audioWaveform),
];

/// Windows wider than this get the desktop layout: sidebar plus player bar.
const desktopBreakpoint = 840.0;

/// The frame around every tab: bottom tabs and mini player on phones,
/// sidebar and player bar on computers (as in the Hive designs).
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  void _select(int index) =>
      shell.goBranch(index, initialLocation: index == shell.currentIndex);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = MediaQuery.sizeOf(context).width >= desktopBreakpoint;
    final bindings = _shortcuts(ref);
    return Focus(
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        for (final MapEntry(key: activator, value: run) in bindings.entries) {
          if (!activator.accepts(event, HardwareKeyboard.instance)) continue;
          // Typing wins: Space, arrows and Shift/⌘ arrows belong to the text
          // field (a space in the search box, moving the cursor).
          if (_typing() && !_alwaysOn.contains(activator)) {
            return KeyEventResult.ignored;
          }
          run();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Focus(
        autofocus: true,
        child: wide ? _desktop(context, ref) : _mobile(context),
      ),
    );
  }

  /// A text field has the keyboard.
  static bool _typing() {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return false;
    return focused.widget is EditableText ||
        focused.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// Shortcuts that work even while typing.
  static const _alwaysOn = <ShortcutActivator>{
    SingleActivator(LogicalKeyboardKey.mediaPlayPause),
    SingleActivator(LogicalKeyboardKey.keyF, meta: true),
    SingleActivator(LogicalKeyboardKey.keyF, control: true),
  };

  /// Keyboard: Space play/pause, ⌘/Ctrl ← → previous/next, Shift ← → seek 10
  /// seconds, ⌘/Ctrl F search, ⌘/Ctrl L like. Typing in a text field wins.
  Map<ShortcutActivator, VoidCallback> _shortcuts(WidgetRef ref) {
    final player = ref.read(playerProvider.notifier);
    void seekBy(int seconds) {
      final s = ref.read(playerProvider);
      if (s.isEmpty) return;
      final to = s.position + Duration(seconds: seconds);
      player.seek(
        to < Duration.zero ? Duration.zero : (to > s.total ? s.total : to),
      );
    }

    void like() {
      final t = ref.read(playerProvider).track;
      if (t != null) ref.read(likesProvider.notifier).toggle(t).ignore();
    }

    void search() {
      _select(1);
      ref.read(searchFocusProvider).requestFocus();
    }

    return {
      const SingleActivator(LogicalKeyboardKey.space): player.toggle,
      const SingleActivator(LogicalKeyboardKey.mediaPlayPause): player.toggle,
      const SingleActivator(LogicalKeyboardKey.arrowRight, meta: true):
          player.next,
      const SingleActivator(LogicalKeyboardKey.arrowRight, control: true):
          player.next,
      const SingleActivator(LogicalKeyboardKey.arrowLeft, meta: true):
          player.previous,
      const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true):
          player.previous,
      const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): () =>
          seekBy(10),
      const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): () =>
          seekBy(-10),
      const SingleActivator(LogicalKeyboardKey.keyF, meta: true): search,
      const SingleActivator(LogicalKeyboardKey.keyF, control: true): search,
      const SingleActivator(LogicalKeyboardKey.keyL, meta: true): like,
      const SingleActivator(LogicalKeyboardKey.keyL, control: true): like,
    };
  }

  Widget _mobile(BuildContext context) {
    final p = HiveTheme.of(context);
    return Scaffold(
      body: Column(
        children: [
          Expanded(child: shell),
          const MiniPlayer(),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: p.bg,
          border: Border(top: BorderSide(color: p.border, width: 0.5)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 58,
            child: Row(
              children: [
                for (var i = 0; i < _tabs.length; i++)
                  Expanded(
                    child: _TabButton(
                      tab: _tabs[i],
                      selected: i == shell.currentIndex,
                      onTap: () => _select(i),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _desktop(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final panel = ref.watch(sidePanelProvider);
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Container(
                  width: 232,
                  color: p.surface,
                  padding: const EdgeInsets.all(HiveSpace.sm),
                  child: SafeArea(
                    right: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            HiveSpace.xs,
                            HiveSpace.xs,
                            0,
                            HiveSpace.md,
                          ),
                          child: Text(
                            'Hive',
                            style: HiveType.title2.copyWith(
                              color: p.textPrimary,
                            ),
                          ),
                        ),
                        for (var i = 0; i < _tabs.length; i++)
                          _SidebarItem(
                            tab: _tabs[i],
                            selected: i == shell.currentIndex,
                            onTap: () => _select(i),
                          ),
                        const Spacer(),
                        _SidebarItem(
                          tab: const _Tab('Settings', HiveIcons.settings),
                          selected: false,
                          onTap: () => context.push('/settings'),
                        ),
                      ],
                    ),
                  ),
                ),
                VerticalDivider(width: 1, color: p.border),
                Expanded(child: shell),
                if (panel != SidePanel.none) ...[
                  VerticalDivider(width: 1, color: p.border),
                  const SidePanelView(),
                ],
              ],
            ),
          ),
          const PlayerBar(),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final _Tab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final color = selected ? p.accent : p.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(tab.icon, size: 24, color: color),
            const SizedBox(height: 2),
            Text(
              tab.label,
              style: HiveType.caption.copyWith(color: color, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final _Tab tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      excludeSemantics: true,
      child: Material(
        color: selected ? p.raised : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HiveSpace.sm,
              vertical: 10,
            ),
            child: Row(
              children: [
                Icon(
                  tab.icon,
                  size: 18,
                  color: selected ? p.accent : p.textSecondary,
                ),
                const SizedBox(width: HiveSpace.sm),
                Text(
                  tab.label,
                  style: HiveType.callout.copyWith(
                    color: selected ? p.textPrimary : p.textSecondary,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
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
