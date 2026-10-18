import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

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
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  void _select(int index) =>
      shell.goBranch(index, initialLocation: index == shell.currentIndex);

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= desktopBreakpoint;
    return wide ? _desktop(context) : _mobile(context);
  }

  Widget _mobile(BuildContext context) {
    final p = HiveTheme.of(context);
    return Scaffold(
      body: Column(
        children: [
          Expanded(child: shell),
          const Padding(
            padding: EdgeInsets.fromLTRB(
              HiveSpace.xs,
              0,
              HiveSpace.xs,
              HiveSpace.xs,
            ),
            child: _NowPlayingBar(compact: true),
          ),
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

  Widget _desktop(BuildContext context) {
    final p = HiveTheme.of(context);
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
              ],
            ),
          ),
          const _NowPlayingBar(compact: false),
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

/// Mini player (phones) or player bar (computers). Playback arrives in M1, so
/// for now it says so.
class _NowPlayingBar extends StatelessWidget {
  const _NowPlayingBar({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final content = Row(
      children: [
        Container(
          width: compact ? 44 : 52,
          height: compact ? 44 : 52,
          decoration: BoxDecoration(
            color: p.raised,
            borderRadius: BorderRadius.circular(HiveRadius.art),
          ),
          child: Icon(HiveIcons.music, size: 20, color: p.textTertiary),
        ),
        const SizedBox(width: HiveSpace.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Nothing playing',
                style: HiveType.callout.copyWith(
                  color: p.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                'Playback arrives in M1',
                style: HiveType.caption.copyWith(color: p.textSecondary),
              ),
            ],
          ),
        ),
        Icon(
          HiveIcons.play,
          size: 24,
          color: p.textTertiary,
          semanticLabel: 'Play (not available yet)',
        ),
        const SizedBox(width: HiveSpace.xs),
      ],
    );
    if (compact) {
      return Container(
        padding: const EdgeInsets.all(HiveSpace.xs),
        decoration: BoxDecoration(
          color: p.raised,
          borderRadius: BorderRadius.circular(HiveRadius.card),
        ),
        child: content,
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HiveSpace.md,
        vertical: HiveSpace.sm,
      ),
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(top: BorderSide(color: p.border)),
      ),
      child: SafeArea(top: false, child: content),
    );
  }
}
