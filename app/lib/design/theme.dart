import 'package:flutter/material.dart';

import 'tokens.g.dart';

/// Hive's colours, reachable from any widget: `HiveTheme.of(context).accent`.
@immutable
class HiveTheme extends ThemeExtension<HiveTheme> {
  const HiveTheme(this.palette);

  final HivePalette palette;

  static HivePalette of(BuildContext context) =>
      Theme.of(context).extension<HiveTheme>()!.palette;

  @override
  HiveTheme copyWith({HivePalette? palette}) =>
      HiveTheme(palette ?? this.palette);

  @override
  HiveTheme lerp(covariant HiveTheme? other, double t) =>
      t < 0.5 ? this : (other ?? this);
}

/// Builds the app theme from the generated tokens. Material widgets are used
/// only for plumbing (text selection, scroll physics); everything visible is
/// styled from [HivePalette] and [HiveType].
ThemeData buildHiveTheme(Brightness brightness) {
  final p = brightness == Brightness.dark
      ? HivePalette.dark
      : HivePalette.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.accent,
    onPrimary: p.onAccent,
    secondary: p.accent,
    onSecondary: p.onAccent,
    error: p.danger,
    onError: p.onDanger,
    surface: p.bg,
    onSurface: p.textPrimary,
    surfaceContainerHighest: p.raised,
    outline: p.border,
  );
  final text = TextTheme(
    displayLarge: HiveType.display.copyWith(color: p.textPrimary),
    headlineLarge: HiveType.title1.copyWith(color: p.textPrimary),
    headlineMedium: HiveType.title2.copyWith(color: p.textPrimary),
    titleMedium: HiveType.headline.copyWith(color: p.textPrimary),
    bodyLarge: HiveType.body.copyWith(color: p.textPrimary),
    bodyMedium: HiveType.callout.copyWith(color: p.textPrimary),
    bodySmall: HiveType.caption.copyWith(color: p.textSecondary),
    labelSmall: HiveType.overline.copyWith(color: p.textSecondary),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    fontFamily: HiveType.family,
    fontFamilyFallback: HiveType.fallbacks,
    textTheme: text,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    dividerColor: p.border,
    // Sheets: a handle to drag them away, and no wider than a phone on an
    // iPad or a computer.
    bottomSheetTheme: const BottomSheetThemeData(
      showDragHandle: true,
      constraints: BoxConstraints(maxWidth: 560),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accent,
      selectionColor: p.accent.withValues(alpha: 0.3),
      selectionHandleColor: p.accent,
    ),
    extensions: [HiveTheme(p)],
  );
}
