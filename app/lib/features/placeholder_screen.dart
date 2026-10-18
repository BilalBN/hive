import 'package:flutter/material.dart';

import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../design/widgets.dart';

/// A tab whose content arrives in a later milestone.
class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({
    super.key,
    required this.title,
    required this.icon,
    required this.milestone,
    required this.text,
  });

  final String title;
  final IconData icon;
  final String milestone;
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HiveSpace.md,
              HiveSpace.md,
              HiveSpace.md,
              0,
            ),
            child: Text(
              title,
              style: HiveType.title1.copyWith(color: p.textPrimary),
            ),
          ),
          Expanded(
            child: ComingSoon(
              icon: icon,
              title: 'Arrives in $milestone',
              text: text,
            ),
          ),
        ],
      ),
    );
  }
}
