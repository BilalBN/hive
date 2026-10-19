import 'dart:ui';

import 'package:flutter/material.dart';

import 'theme.dart';

/// Frosted glass: whatever scrolls underneath shows through, blurred.
/// Used for the floating chrome (tab bar, mini player, player bar).
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.tint,
    this.opacity = 0.72,
    this.blur = 28,
    this.border = true,
    this.shadow = false,
  });

  final Widget child;
  final BorderRadius borderRadius;

  /// The glass colour; the theme's raised surface when null.
  final Color? tint;
  final double opacity;
  final double blur;
  final bool border;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = tint ?? (dark ? p.raised : p.surface);
    final rim = dark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.07);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.45 : 0.12),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: base.withValues(alpha: opacity),
              borderRadius: borderRadius,
              border: border ? Border.all(color: rim, width: 0.5) : null,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// A round, see-through button for icons over artwork-coloured backgrounds
/// (Now playing's like and more buttons).
class GlassCircleButton extends StatelessWidget {
  const GlassCircleButton({
    super.key,
    required this.tooltip,
    required this.child,
    required this.onPressed,
    this.size = 34,
    this.color,
  });

  final String tooltip;
  final Widget child;
  final VoidCallback? onPressed;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        child: Material(
          color: color ?? Colors.white.withValues(alpha: 0.14),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox.square(
              dimension: size,
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }
}
