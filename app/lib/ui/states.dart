import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../design/icons.g.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';

/// Loading, error (with Try again) and data, the same way on every screen.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    super.key,
    required this.value,
    required this.data,
    this.onRetry,
    this.sliver = false,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final VoidCallback? onRetry;

  /// Wrap the loading and error states for use inside a CustomScrollView.
  final bool sliver;

  @override
  Widget build(BuildContext context) {
    final v = value;
    if (v.hasValue) return data(v.requireValue);
    final Widget child = v.hasError
        ? ErrorState(message: describeError(v.error!), onRetry: onRetry)
        : const LoadingState();
    return sliver
        ? SliverFillRemaining(hasScrollBody: false, child: child)
        : child;
  }
}

class LoadingState extends StatelessWidget {
  const LoadingState({super.key});

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HiveSpace.xl),
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: p.accent,
            semanticsLabel: 'Loading',
          ),
        ),
      ),
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HiveSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(HiveIcons.cloudOff, size: 28, color: p.textSecondary),
            const SizedBox(height: HiveSpace.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: HiveType.callout.copyWith(color: p.textSecondary),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: HiveSpace.md),
              OutlinedButton(
                onPressed: onRetry,
                style: OutlinedButton.styleFrom(
                  foregroundColor: p.textPrimary,
                  side: BorderSide(color: p.border),
                  shape: const StadiumBorder(),
                ),
                child: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.text,
    this.action,
  });

  final IconData icon;
  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HiveSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: p.raised,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 28, color: p.textSecondary),
            ),
            const SizedBox(height: HiveSpace.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: HiveType.headline.copyWith(color: p.textPrimary),
            ),
            const SizedBox(height: HiveSpace.xxs),
            Text(
              text,
              textAlign: TextAlign.center,
              style: HiveType.callout.copyWith(color: p.textSecondary),
            ),
            if (action != null) ...[
              const SizedBox(height: HiveSpace.md),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// "1:23", "1:02:03".
String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// "27 min", "1 hr 12 min".
String formatLength(int ms) {
  final minutes = (ms / 60000).round();
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h hr' : '$h hr $m min';
}

/// "820 KB", "1.4 GB".
String formatBytes(int bytes) {
  const units = ['bytes', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  if (u == 0) return '$bytes bytes';
  return '${v >= 100 || u == 1 ? v.round() : v.toStringAsFixed(1)} ${units[u]}';
}

String plural(int n, String one, [String? many]) =>
    '$n ${n == 1 ? one : (many ?? '${one}s')}';

/// A small all-caps quality label: teal for lossless, quiet for lossy.
class QualityChip extends StatelessWidget {
  const QualityChip({
    super.key,
    required this.label,
    required this.lossless,
    this.icon,
    this.onArt = false,
  });

  final String label;
  final bool lossless;
  final IconData? icon;

  /// A soft see-through pill for the artwork backdrop (Now playing).
  final bool onArt;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final color = onArt
        ? Colors.white.withValues(alpha: 0.86)
        : (lossless ? p.lossless : p.textSecondary);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: onArt ? 8 : 6, vertical: 2),
      decoration: BoxDecoration(
        color: onArt ? Colors.white.withValues(alpha: 0.14) : null,
        border: onArt ? null : Border.all(color: color),
        borderRadius: BorderRadius.circular(HiveRadius.badge),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HiveType.overline.copyWith(color: color, fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }
}

String tierLabel(String tier) => switch (tier) {
  'hires' => 'Hi-Res',
  'lossless' => 'Lossless',
  _ => 'Lossy',
};
