import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../library/library_providers.dart';
import '../../player/player_controller.dart';
import '../../sync/continuity.dart';
import '../player/continuity_bar.dart';
import '../player/mini_player.dart';
import '../player/side_panel.dart';
import '../search/search_screen.dart';

import '../../design/glass.dart';
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

  Widget _mobile(BuildContext context) => _MobileFrame(
    shell: shell,
    selected: shell.currentIndex,
    onSelect: _select,
  );

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
          if (ref.watch(continuityOfferProvider) != null)
            const Padding(
              padding: EdgeInsets.fromLTRB(
                HiveSpace.md,
                0,
                HiveSpace.md,
                HiveSpace.xs,
              ),
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(width: 420, child: ContinuityBar()),
              ),
            ),
          const PlayerBar(),
        ],
      ),
    );
  }
}

/// Phones: the tab's page fills the screen and scrolls under a floating
/// glass tab bar, with the mini player floating just above it.
class _MobileFrame extends ConsumerWidget {
  const _MobileFrame({
    required this.shell,
    required this.selected,
    required this.onSelect,
  });

  final Widget shell;
  final int selected;
  final ValueChanged<int> onSelect;

  static const _barHeight = 62.0;
  static const _gap = 8.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final mq = MediaQuery.of(context);
    final playing = ref.watch(playerProvider.select((s) => s.track != null));
    final offered = ref.watch(continuityOfferProvider) != null;
    // While typing, the keyboard takes the bottom of the screen; the tab
    // bar and mini player step aside rather than ride on top of it.
    final typing = mq.viewInsets.bottom > 0;
    final safe = mq.padding.bottom;
    final bottom = safe > 0 ? safe : _gap + 4;
    final chrome = typing
        ? safe
        : bottom +
              _barHeight +
              (playing ? miniPlayerHeight + _gap : 0) +
              (offered ? continuityBarHeight + _gap : 0) +
              _gap;

    return Scaffold(
      body: Stack(
        children: [
          // Pages see the floating chrome as part of the bottom inset, so
          // their last rows can scroll clear of it.
          MediaQuery(
            data: mq.copyWith(
              padding: mq.padding.copyWith(bottom: chrome),
              viewPadding: mq.viewPadding.copyWith(bottom: chrome),
            ),
            child: shell,
          ),
          if (!typing) ...[
            // A soft fade so busy pages calm down behind the chrome.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: chrome + 24,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        p.bg.withValues(alpha: 0),
                        p.bg.withValues(alpha: 0.85),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: HiveSpace.sm,
              right: HiveSpace.sm,
              bottom: bottom,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (offered) ...[
                    const ContinuityBar(),
                    const SizedBox(height: _gap),
                  ],
                  if (playing) ...[
                    const MiniPlayer(),
                    const SizedBox(height: _gap),
                  ],
                  Glass(
                    borderRadius: BorderRadius.circular(_barHeight / 2),
                    shadow: true,
                    child: SizedBox(
                      height: _barHeight,
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: Row(
                          children: [
                            for (var i = 0; i < _tabs.length; i++)
                              Expanded(
                                child: _TabButton(
                                  tab: _tabs[i],
                                  selected: i == selected,
                                  onTap: () => onSelect(i),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
    final color = selected ? p.accentText : p.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: HiveMotion.screen,
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: selected
                ? p.accent.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(tab.icon, size: 22, color: color),
              const SizedBox(height: 2),
              Text(
                tab.label,
                style: HiveType.caption.copyWith(
                  color: color,
                  fontSize: 10.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      button: true,
      selected: selected,
      label: tab.label,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Material(
          color: selected
              ? (dark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.06))
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HiveSpace.sm - 2,
                vertical: 7,
              ),
              child: Row(
                children: [
                  Icon(tab.icon, size: 17, color: p.accentText),
                  const SizedBox(width: HiveSpace.sm - 2),
                  Text(
                    tab.label,
                    style: HiveType.callout.copyWith(
                      color: p.textPrimary,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
