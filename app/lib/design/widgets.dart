import 'package:flutter/material.dart';

import 'icons.g.dart';
import 'theme.dart';
import 'tokens.g.dart';

/// The big rounded accent button used for each screen's main action.
class HivePrimaryButton extends StatelessWidget {
  const HivePrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final enabled = onPressed != null && !busy;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: SizedBox(
        height: 52,
        width: double.infinity,
        child: TextButton(
          onPressed: enabled ? onPressed : null,
          style: TextButton.styleFrom(
            backgroundColor: enabled
                ? p.accent
                : p.accent.withValues(alpha: 0.5),
            foregroundColor: p.onAccent,
            shape: const StadiumBorder(),
            textStyle: HiveType.headline,
          ),
          child: busy
              ? SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: p.onAccent,
                  ),
                )
              : Text(label),
        ),
      ),
    );
  }
}

/// "● Connected to home", the quiet status line from the designs.
class StatusLine extends StatelessWidget {
  const StatusLine({
    super.key,
    required this.ok,
    required this.text,
    this.detail,
  });

  final bool ok;
  final String text;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: ok ? p.success : p.warning,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: HiveSpace.xs),
        Flexible(
          child: Text(
            text,
            style: HiveType.callout.copyWith(color: p.textSecondary),
          ),
        ),
        if (detail != null) ...[
          Text(
            '  ·  ',
            style: HiveType.callout.copyWith(color: p.textTertiary),
          ),
          Flexible(
            child: Text(
              detail!,
              overflow: TextOverflow.ellipsis,
              style: HiveType.callout.copyWith(color: p.textTertiary),
            ),
          ),
        ],
      ],
    );
  }
}

/// A calm banner for things like "Can't reach home right now".
class HiveBanner extends StatelessWidget {
  const HiveBanner({
    super.key,
    required this.title,
    required this.body,
    this.action,
  });

  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(HiveSpace.md),
      decoration: BoxDecoration(
        color: p.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(HiveRadius.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(HiveIcons.house, size: 20, color: p.warning),
          const SizedBox(width: HiveSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: HiveType.callout.copyWith(
                    color: p.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: HiveType.callout.copyWith(color: p.textSecondary),
                ),
              ],
            ),
          ),
          if (action != null) ...[const SizedBox(width: HiveSpace.sm), action!],
        ],
      ),
    );
  }
}

/// Empty state for screens whose milestone hasn't been built yet.
class ComingSoon extends StatelessWidget {
  const ComingSoon({
    super.key,
    required this.icon,
    required this.title,
    required this.text,
  });

  final IconData icon;
  final String title;
  final String text;

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
          ],
        ),
      ),
    );
  }
}
