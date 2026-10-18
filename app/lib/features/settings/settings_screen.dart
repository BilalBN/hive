import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/hive_api.g.dart' show hiveApiVersion;
import '../../core/home_connection.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';

/// Settings. M0 shows the home connection; the full set (quality, devices,
/// Listen, continuity, appearance, Simple mode) is built in M1–M4.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final address = ref.watch(homeAddressStoreProvider).address;
    final status = ref.watch(homeStatusProvider);
    final homeLine = switch (status) {
      HomeConnected(:final health) => '${health.homeName} · connected',
      HomeChecking() => 'Checking…',
      HomeUnreachable() => "Can't reach home",
    };

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(HiveSpace.md),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    context.canPop() ? context.pop() : context.go('/home'),
                icon: Icon(
                  HiveIcons.chevronLeft,
                  size: 20,
                  color: p.accentText,
                ),
                label: Text(
                  'Home',
                  style: HiveType.body.copyWith(color: p.accentText),
                ),
              ),
            ),
            Text(
              'Settings',
              style: HiveType.title1.copyWith(color: p.textPrimary),
            ),
            const SizedBox(height: HiveSpace.lg),
            _Group(
              children: [
                _Row(
                  icon: HiveIcons.house,
                  title: 'Home connection',
                  value: homeLine,
                ),
                _Row(
                  icon: HiveIcons.link,
                  title: 'Address',
                  value: address?.toString() ?? 'Not set',
                  onTap: () => context.go('/connect'),
                ),
              ],
            ),
            const SizedBox(height: HiveSpace.lg),
            _Group(
              children: [
                _Row(
                  icon: HiveIcons.info,
                  title: 'About Hive',
                  value: 'App 0.1.0 · API $hiveApiVersion',
                ),
              ],
            ),
            const SizedBox(height: HiveSpace.md),
            Text(
              'Playback quality, your devices, Listen and appearance arrive with the milestones that build them.',
              style: HiveType.caption.copyWith(color: p.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(HiveRadius.card),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 52, color: p.border),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    required this.value,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(HiveRadius.card),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: HiveSpace.md,
          vertical: 14,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: p.textSecondary),
            const SizedBox(width: HiveSpace.md),
            Expanded(
              child: Text(
                title,
                style: HiveType.body.copyWith(color: p.textPrimary),
              ),
            ),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.end,
                overflow: TextOverflow.ellipsis,
                style: HiveType.callout.copyWith(color: p.textSecondary),
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: HiveSpace.xs),
              Icon(HiveIcons.chevronRight, size: 18, color: p.textTertiary),
            ],
          ],
        ),
      ),
    );
  }
}
