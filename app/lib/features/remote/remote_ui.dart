import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_info.dart';
import '../../design/glass.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../player/player_controller.dart';
import '../../sync/remote.dart';
import '../../ui/artwork.dart';
import '../../ui/track_actions.dart' show showToast;

const remoteBarHeight = 60.0;

String _clock(Duration d) =>
    '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

IconData deviceIcon(String name) {
  final n = name.toLowerCase();
  if (n.contains('mac') ||
      n.contains('pc') ||
      n.contains('windows') ||
      n.contains('laptop')) {
    return HiveIcons.laptop;
  }
  if (n.contains('ipad') || n.contains('tablet')) return HiveIcons.tablet;
  return HiveIcons.smartphone;
}

/// "Play on": this device and the person's others with Hive open. Choosing
/// another moves what's playing there and makes this one its remote.
Future<void> showDevicesSheet(BuildContext context, WidgetRef ref) async {
  unawaited(ref.read(remoteProvider.notifier).refresh());
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    builder: (sheet) => const _DevicesSheet(),
  );
}

class _DevicesSheet extends ConsumerWidget {
  const _DevicesSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final r = ref.watch(remoteProvider);
    final here = ref.watch(playerProvider.select((s) => s.track));
    final c = ref.read(remoteProvider.notifier);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          HiveSpace.md,
          0,
          HiveSpace.md,
          HiveSpace.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Play on',
              style: HiveType.title2.copyWith(color: p.textPrimary),
            ),
            const SizedBox(height: HiveSpace.sm),
            _DeviceRow(
              icon: deviceIcon(defaultDeviceName),
              name: 'This device',
              detail: here == null
                  ? 'Nothing playing'
                  : '${here.title} · ${here.artistName}',
              selected: r.target == null,
              onTap: () {
                c.stopControlling();
                Navigator.of(context).pop();
              },
            ),
            for (final d in r.devices)
              _DeviceRow(
                icon: deviceIcon(d.deviceName),
                name: d.deviceName,
                detail: d.track == null
                    ? 'Hive is open'
                    : '${d.playing ? 'Playing' : 'Paused'}: ${d.track!.title}',
                selected: r.target == d.installId,
                onTap: () async {
                  final nav = Navigator.of(context);
                  final router = GoRouter.of(context);
                  var ok = true;
                  if (here != null) {
                    ok = await c.moveTo(d.installId);
                  } else {
                    c.control(d.installId);
                  }
                  if (!ok) {
                    if (context.mounted) {
                      showToast(
                        context,
                        ref.read(remoteProvider).error ??
                            "That device didn't answer.",
                      );
                    }
                    return;
                  }
                  nav.pop();
                  unawaited(router.push('/remote'));
                },
              ),
            if (r.devices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: HiveSpace.sm),
                child: Text(
                  'Open Hive on your other phone or computer and it shows here.',
                  style: HiveType.callout.copyWith(color: p.textSecondary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.icon,
    required this.name,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String name;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: '$name. $detail',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(HiveRadius.card),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            children: [
              Icon(
                icon,
                size: 22,
                color: selected ? p.accentText : p.textSecondary,
              ),
              const SizedBox(width: HiveSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      style: HiveType.body.copyWith(color: p.textPrimary),
                    ),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HiveType.caption.copyWith(color: p.textSecondary),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(HiveIcons.check, size: 18, color: p.accentText),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Playing on Bilal's MacBook": this device is the remote for another.
class RemoteBar extends ConsumerWidget {
  const RemoteBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(remoteProvider.select((r) => r.controlled));
    if (d == null) return const SizedBox.shrink();
    final p = HiveTheme.of(context);
    final c = ref.read(remoteProvider.notifier);
    final t = d.track;
    return Semantics(
      container: true,
      label: 'Playing on ${d.deviceName}${t == null ? '' : ': ${t.title}'}',
      child: Glass(
        borderRadius: BorderRadius.circular(HiveRadius.card),
        shadow: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(HiveRadius.card),
            onTap: () => context.push('/remote'),
            child: SizedBox(
              height: remoteBarHeight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
                child: Row(
                  children: [
                    Artwork(
                      artworkId: t?.artworkId,
                      title: t?.albumTitle ?? d.deviceName,
                      size: 44,
                      pixels: 96,
                      radius: 8,
                    ),
                    const SizedBox(width: HiveSpace.sm),
                    Expanded(
                      child: MediaQuery.withClampedTextScaling(
                        maxScaleFactor: 1.2,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t?.title ?? 'Nothing playing',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HiveType.callout.copyWith(
                                color: p.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Row(
                              children: [
                                Icon(
                                  deviceIcon(d.deviceName),
                                  size: 12,
                                  color: p.accentText,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    'Playing on ${d.deviceName}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: HiveType.caption.copyWith(
                                      color: p.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: d.playing ? 'Pause' : 'Play',
                      icon: Icon(
                        d.playing ? HiveIcons.pause : HiveIcons.play,
                        size: 22,
                        color: p.textPrimary,
                      ),
                      onPressed: () => c.send(d.playing ? 'pause' : 'play'),
                    ),
                    IconButton(
                      tooltip: 'Next',
                      icon: Icon(
                        HiveIcons.skipForward,
                        size: 20,
                        color: p.textPrimary,
                      ),
                      onPressed: () => c.send('next'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The remote: what the other device is playing, its controls and volume,
/// and bringing it back here.
class RemoteScreen extends ConsumerStatefulWidget {
  const RemoteScreen({super.key});

  @override
  ConsumerState<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends ConsumerState<RemoteScreen> {
  Timer? _tick;
  double? _drag;
  double _volume = 1;

  @override
  void initState() {
    super.initState();
    // The position counts on between the device's reports.
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final r = ref.watch(remoteProvider);
    final c = ref.read(remoteProvider.notifier);
    final d = r.controlled;
    if (d == null) {
      return Scaffold(
        backgroundColor: p.bg,
        appBar: AppBar(backgroundColor: p.bg, foregroundColor: p.textPrimary),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(HiveSpace.lg),
            child: Text(
              "That device isn't open any more.",
              style: HiveType.body.copyWith(color: p.textSecondary),
            ),
          ),
        ),
      );
    }
    final t = d.track;
    final total = Duration(milliseconds: t?.durationMs ?? 0);
    final pos = r.positionOf(d);
    final fraction = total.inMilliseconds <= 0
        ? 0.0
        : (_drag ?? pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        foregroundColor: p.textPrimary,
        title: Text(
          'Playing on ${d.deviceName}',
          style: HiveType.headline.copyWith(color: p.textPrimary),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(HiveSpace.lg),
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: Artwork(
                    artworkId: t?.artworkId,
                    title: t?.albumTitle ?? d.deviceName,
                    radius: 16,
                  ),
                ),
                const SizedBox(height: HiveSpace.lg),
                Text(
                  t?.title ?? 'Nothing playing',
                  style: HiveType.title2.copyWith(color: p.textPrimary),
                ),
                if (t != null)
                  Text(
                    t.artistName,
                    style: HiveType.headline.copyWith(color: p.textSecondary),
                  ),
                const SizedBox(height: HiveSpace.md),
                Semantics(
                  label: 'Position',
                  value: '${_clock(pos)} of ${_clock(total)}',
                  child: Slider(
                    value: fraction,
                    activeColor: p.accent,
                    onChanged: t == null
                        ? null
                        : (v) => setState(() => _drag = v),
                    onChangeEnd: (v) {
                      setState(() => _drag = null);
                      unawaited(c.send('seek', position: total * v));
                    },
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _clock(total * fraction),
                      style: HiveType.caption.copyWith(color: p.textSecondary),
                    ),
                    Text(
                      _clock(total),
                      style: HiveType.caption.copyWith(color: p.textSecondary),
                    ),
                  ],
                ),
                const SizedBox(height: HiveSpace.sm),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: 'Previous',
                      iconSize: 32,
                      icon: Icon(HiveIcons.skipBack, color: p.textPrimary),
                      onPressed: () => c.send('previous'),
                    ),
                    const SizedBox(width: HiveSpace.lg),
                    IconButton.filled(
                      tooltip: d.playing ? 'Pause' : 'Play',
                      iconSize: 36,
                      style: IconButton.styleFrom(
                        backgroundColor: p.accent,
                        foregroundColor: p.onAccent,
                      ),
                      icon: Icon(d.playing ? HiveIcons.pause : HiveIcons.play),
                      onPressed: () => c.send(d.playing ? 'pause' : 'play'),
                    ),
                    const SizedBox(width: HiveSpace.lg),
                    IconButton(
                      tooltip: 'Next',
                      iconSize: 32,
                      icon: Icon(HiveIcons.skipForward, color: p.textPrimary),
                      onPressed: () => c.send('next'),
                    ),
                  ],
                ),
                const SizedBox(height: HiveSpace.md),
                Row(
                  children: [
                    Icon(HiveIcons.volume1, size: 18, color: p.textSecondary),
                    Expanded(
                      child: Slider(
                        value: _volume,
                        activeColor: p.accent,
                        semanticFormatterCallback: (v) =>
                            'Volume ${(v * 100).round()}%',
                        onChanged: (v) => setState(() => _volume = v),
                        onChangeEnd: (v) => c.send('volume', volume: v),
                      ),
                    ),
                    Icon(HiveIcons.volume2, size: 18, color: p.textSecondary),
                  ],
                ),
                const SizedBox(height: HiveSpace.lg),
                FilledButton.icon(
                  onPressed: t == null
                      ? null
                      : () async {
                          final router = GoRouter.of(context);
                          await c.bringHere();
                          if (router.canPop()) router.pop();
                        },
                  style: FilledButton.styleFrom(
                    backgroundColor: p.raised,
                    foregroundColor: p.textPrimary,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  icon: Icon(deviceIcon(defaultDeviceName), size: 18),
                  label: const Text('Play here instead'),
                ),
                const SizedBox(height: HiveSpace.xs),
                TextButton(
                  onPressed: () {
                    c.stopControlling();
                    final router = GoRouter.of(context);
                    if (router.canPop()) router.pop();
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: p.textSecondary,
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: const Text('Stop being the remote'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
