import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../library/library_providers.dart';

/// "All · Malayalam · Hindi · English": browse home's music in one language.
/// The choice is shared by Home, Library and Search. Hidden while home has
/// music in fewer than two languages.
class LanguageChips extends ConsumerWidget {
  const LanguageChips({
    super.key,
    this.padding = const EdgeInsets.symmetric(horizontal: HiveSpace.md),
  });
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final langs = ref.watch(languagesProvider).value ?? const [];
    if (langs.length < 2) return const SizedBox.shrink();
    final active = ref.watch(activeLanguageProvider);
    final filter = ref.read(languageFilterProvider.notifier);

    Widget chip(String? code, String label, String? native) {
      final on = code == active;
      return Padding(
        padding: const EdgeInsets.only(right: HiveSpace.xs),
        child: Tooltip(
          message: native ?? label,
          child: ChoiceChip(
            label: Text(label),
            selected: on,
            showCheckmark: false,
            onSelected: (_) => filter.set(on ? null : code),
            labelStyle: HiveType.callout.copyWith(
              color: on ? p.onAccent : p.textPrimary,
              fontWeight: FontWeight.w600,
            ),
            selectedColor: p.accent,
            backgroundColor: p.raised,
            side: BorderSide.none,
            shape: const StadiumBorder(),
            visualDensity: VisualDensity.compact,
          ),
        ),
      );
    }

    return Semantics(
      container: true,
      label: 'Language',
      child: SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: padding,
          children: [
            chip(null, 'All', 'All languages'),
            for (final l in langs) chip(l.code, l.name, l.nativeName),
          ],
        ),
      ),
    );
  }
}
