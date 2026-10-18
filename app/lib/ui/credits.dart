import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/hive_api.g.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../library/library_providers.dart';
import 'nav.dart';

/// A language code's name, from the languages at home ("ml" → "Malayalam").
String? languageName(WidgetRef ref, String? code) {
  if (code == null) return null;
  final langs = ref.watch(languagesProvider).value ?? const <Language>[];
  for (final l in langs) {
    if (l.code == code) return l.name;
  }
  return null;
}

const _roleLines = [
  ('director', 'Directed by'),
  ('actor', 'Starring'),
  ('musicDirector', 'Music by'),
  ('composer', 'Music by'),
  ('lyricist', 'Lyrics by'),
];

/// "Directed by … · Starring … · Music by … · Lyrics by …", each name opening
/// that person's page.
class CreditLines extends StatelessWidget {
  const CreditLines({super.key, required this.credits, this.maxPerLine = 4});
  final List<Credit> credits;
  final int maxPerLine;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final lines = <Widget>[];
    final shown = <String>{};
    for (final (role, label) in _roleLines) {
      if (shown.contains(label)) continue;
      final people = [
        for (final c in credits)
          if (c.role == role ||
              (label == 'Music by' &&
                  (c.role == 'musicDirector' || c.role == 'composer')))
            c,
      ];
      final unique = <String, Credit>{};
      for (final c in people) {
        unique.putIfAbsent(c.name, () => c);
      }
      if (unique.isEmpty) continue;
      shown.add(label);
      final names = unique.values.take(maxPerLine).toList();
      lines.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '$label ',
                style: HiveType.callout.copyWith(color: p.textSecondary),
              ),
              for (var i = 0; i < names.length; i++) ...[
                _Name(credit: names[i]),
                if (i < names.length - 1)
                  Text(
                    ', ',
                    style: HiveType.callout.copyWith(color: p.textSecondary),
                  ),
              ],
            ],
          ),
        ),
      );
    }
    if (lines.isEmpty) return const SizedBox.shrink();
    return Column(mainAxisSize: MainAxisSize.min, children: lines);
  }
}

class _Name extends StatelessWidget {
  const _Name({required this.credit});
  final Credit credit;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final text = Text(
      credit.name,
      style: HiveType.callout.copyWith(
        color: credit.artistId == null ? p.textPrimary : p.accentText,
        fontWeight: FontWeight.w600,
      ),
    );
    if (credit.artistId == null) return text;
    return InkWell(
      borderRadius: BorderRadius.circular(HiveRadius.badge),
      onTap: () => context.openArtist(credit.artistId!),
      child: text,
    );
  }
}

/// What an artist does at home, in words: "Singer · Music director".
String rolesLine(List<String>? roles) {
  const names = {
    'singer': 'Singer',
    'composer': 'Composer',
    'lyricist': 'Lyricist',
    'musicDirector': 'Music director',
    'actor': 'Actor',
    'director': 'Director',
  };
  final out = <String>[];
  for (final r in roles ?? const <String>[]) {
    final n = names[r];
    if (n != null && !out.contains(n)) out.add(n);
  }
  return out.take(3).join(' · ');
}
