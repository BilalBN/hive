import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/hive_api.g.dart';
import '../../auth/device_auth.dart';
import '../../core/api.dart';
import '../../core/app_info.dart';
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
            if (ref.watch(deviceAuthProvider).signedIn) ...[
              const SizedBox(height: HiveSpace.lg),
              const _YourDevices(),
            ],
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
                  value: 'App $appVersion · API $hiveApiVersion',
                ),
              ],
            ),
            const SizedBox(height: HiveSpace.md),
            Text(
              'Listen and appearance arrive with the milestones that build them.',
              style: HiveType.caption.copyWith(color: p.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

final myDevicesProvider = FutureProvider.autoDispose<MyDevices>(
  (ref) => ref.watch(hiveApiProvider).listMyDevices(),
);

/// You, your devices (up to the home's limit), and leaving on this one.
class _YourDevices extends ConsumerWidget {
  const _YourDevices();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final auth = ref.watch(deviceAuthProvider);
    final devices = ref.watch(myDevicesProvider);
    final me = auth.me;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading('You'),
        _Group(
          children: [
            _Row(
              icon: HiveIcons.userRound,
              title: me?.name ?? 'You',
              value: me?.email ?? '',
            ),
          ],
        ),
        const SizedBox(height: HiveSpace.lg),
        _Heading(
          devices.value == null
              ? 'Your devices'
              : 'Your devices (${devices.value!.items.length} of ${devices.value!.limit})',
        ),
        _Group(
          children: [
            ...switch (devices) {
              AsyncData(:final value) => [
                for (final d in value.items)
                  _DeviceRow(device: d, swapsLeft: value.swapsLeft),
              ],
              AsyncError(:final error) => [
                Padding(
                  padding: const EdgeInsets.all(HiveSpace.md),
                  child: Text(
                    describeError(error),
                    style: HiveType.callout.copyWith(color: p.danger),
                  ),
                ),
              ],
              _ => [
                const Padding(
                  padding: EdgeInsets.all(HiveSpace.md),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ],
            },
            InkWell(
              onTap: () => _leave(context, ref),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HiveSpace.md,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Icon(HiveIcons.logOut, size: 20, color: p.danger),
                    const SizedBox(width: HiveSpace.md),
                    Text(
                      'Sign out on this device',
                      style: HiveType.body.copyWith(color: p.danger),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (devices.value != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HiveSpace.xs,
              HiveSpace.xs,
              HiveSpace.xs,
              0,
            ),
            child: Text(
              devices.value!.swapsLeft > 0
                  ? 'You can remove a device and add another ${devices.value!.swapsLeft == 1 ? 'once more' : '${devices.value!.swapsLeft} more times'} this month.'
                  : 'No device swaps left this month. Whoever runs Hive can still remove one for you.',
              style: HiveType.caption.copyWith(color: p.textSecondary),
            ),
          ),
      ],
    );
  }

  Future<void> _leave(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Sign out on this device?'),
        content: const Text(
          'To use Hive here again you join with your email. Your likes and playlists stay at home.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final auth = ref.read(deviceAuthProvider);
    final id = auth.deviceId;
    if (id != null) {
      try {
        await ref.read(hiveApiProvider).removeMyDevice(deviceId: id);
      } catch (_) {
        // Home unreachable: the device is forgotten here all the same.
      }
    }
    await auth.forget();
  }
}

class _DeviceRow extends ConsumerWidget {
  const _DeviceRow({required this.device, required this.swapsLeft});
  final MyDevice device;
  final int swapsLeft;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HiveSpace.md,
        vertical: 10,
      ),
      child: Row(
        children: [
          Icon(
            switch (device.platform) {
              'macos' || 'windows' || 'linux' => HiveIcons.laptop,
              _ => HiveIcons.smartphone,
            },
            size: 20,
            color: p.textSecondary,
          ),
          const SizedBox(width: HiveSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.name,
                  style: HiveType.body.copyWith(color: p.textPrimary),
                ),
                Text(
                  device.current
                      ? 'This device'
                      : (device.appVersion == null
                            ? device.platform
                            : '${device.platform} · Hive ${device.appVersion}'),
                  style: HiveType.caption.copyWith(
                    color: device.current ? p.accentText : p.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (!device.current)
            TextButton(
              onPressed: swapsLeft <= 0
                  ? null
                  : () async {
                      try {
                        await ref
                            .read(hiveApiProvider)
                            .removeMyDevice(deviceId: device.id);
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(describeError(e))),
                          );
                        }
                      }
                      ref.invalidate(myDevicesProvider);
                    },
              child: const Text('Remove'),
            ),
        ],
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
