import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/hive_api.g.dart' show hiveApiVersion;
import '../../core/home_connection.dart';
import '../../player/quality.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';

/// Settings: home connection and playback quality. Devices, Listen,
/// continuity, appearance and Simple mode arrive in M2–M4.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final address = ref.watch(homeAddressStoreProvider).address;
    final status = ref.watch(homeStatusProvider);
    final playback = ref.watch(playbackSettingsProvider);
    final settings = ref.read(playbackSettingsProvider.notifier);
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
            _Heading('Playback'),
            _Group(
              children: [
                _Row(
                  icon: HiveIcons.wifi,
                  title: 'On Wi-Fi',
                  value: playback.onWifi.label,
                  onTap: () async {
                    final m = await _pickQuality(
                      context,
                      'Quality on Wi-Fi',
                      playback.onWifi,
                    );
                    if (m != null) {
                      await settings.update(playback.copyWith(onWifi: m));
                    }
                  },
                ),
                _Row(
                  icon: HiveIcons.signal,
                  title: 'On mobile data',
                  value: playback.onMobile.label,
                  onTap: () async {
                    final m = await _pickQuality(
                      context,
                      'Quality on mobile data',
                      playback.onMobile,
                    );
                    if (m != null) {
                      await settings.update(playback.copyWith(onMobile: m));
                    }
                  },
                ),
                SwitchListTile(
                  secondary: Icon(
                    HiveIcons.slidersHorizontal,
                    size: 20,
                    color: p.textSecondary,
                  ),
                  title: Text(
                    'Volume levelling',
                    style: HiveType.body.copyWith(color: p.textPrimary),
                  ),
                  subtitle: Text(
                    'Songs play at a similar loudness. Turn off for bit-perfect output.',
                    style: HiveType.caption.copyWith(color: p.textSecondary),
                  ),
                  value: playback.levelling,
                  activeThumbColor: p.accent,
                  onChanged: (v) =>
                      settings.update(playback.copyWith(levelling: v)),
                ),
                SwitchListTile(
                  secondary: Icon(
                    HiveIcons.infinity,
                    size: 20,
                    color: p.textSecondary,
                  ),
                  title: Text(
                    'Autoplay',
                    style: HiveType.body.copyWith(color: p.textPrimary),
                  ),
                  subtitle: Text(
                    'When the queue ends, carry on with songs like the last one.',
                    style: HiveType.caption.copyWith(color: p.textSecondary),
                  ),
                  value: playback.autoplay,
                  activeThumbColor: p.accent,
                  onChanged: (v) =>
                      settings.update(playback.copyWith(autoplay: v)),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HiveSpace.xs,
                HiveSpace.xs,
                HiveSpace.xs,
                0,
              ),
              child: Text(
                'Changes apply from the next song. Bluetooth headphones always receive High quality: Bluetooth can\'t carry lossless.',
                style: HiveType.caption.copyWith(color: p.textSecondary),
              ),
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
              'Your devices, Listen and appearance arrive with the milestones that build them.',
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
    return Material(
      color: p.surface,
      borderRadius: BorderRadius.circular(HiveRadius.card),
      clipBehavior: Clip.antiAlias,
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
              child: Row(
                children: [
                  Text(
                    title,
                    style: HiveType.body.copyWith(color: p.textPrimary),
                  ),
                  const SizedBox(width: HiveSpace.sm),
                  Expanded(
                    child: Text(
                      value,
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HiveType.callout.copyWith(color: p.textSecondary),
                    ),
                  ),
                ],
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

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(HiveSpace.xs, 0, 0, HiveSpace.xs),
      child: Text(
        text.toUpperCase(),
        style: HiveType.overline.copyWith(color: p.textSecondary),
      ),
    );
  }
}

Future<QualityMode?> _pickQuality(
  BuildContext context,
  String title,
  QualityMode current,
) {
  final p = HiveTheme.of(context);
  return showModalBottomSheet<QualityMode>(
    context: context,
    backgroundColor: p.surface,
    constraints: const BoxConstraints(maxWidth: 560),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(HiveRadius.sheet),
      ),
    ),
    builder: (context) => SafeArea(
      child: RadioGroup<QualityMode>(
        groupValue: current,
        onChanged: (m) => Navigator.of(context).pop(m),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HiveSpace.lg,
                HiveSpace.lg,
                HiveSpace.lg,
                HiveSpace.xs,
              ),
              child: Text(
                title,
                style: HiveType.headline.copyWith(color: p.textPrimary),
              ),
            ),
            for (final m in QualityMode.values)
              RadioListTile<QualityMode>(
                value: m,
                activeColor: p.accent,
                title: Text(
                  m.label,
                  style: HiveType.body.copyWith(color: p.textPrimary),
                ),
                subtitle: Text(
                  '${m.detail} · ${m.perHour}',
                  style: HiveType.caption.copyWith(color: p.textSecondary),
                ),
              ),
            const SizedBox(height: HiveSpace.sm),
          ],
        ),
      ),
    ),
  );
}
