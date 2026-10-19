import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';

/// Album, artist and playlist pages: a back button and a menu over a
/// scrolling page, inside the tab you came from.
class DetailScaffold extends StatelessWidget {
  const DetailScaffold({
    super.key,
    required this.slivers,
    this.actions = const [],
    this.title,
  });

  final List<Widget> slivers;
  final List<Widget> actions;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: p.bg,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              tooltip: 'Back',
              icon: Icon(HiveIcons.chevronLeft, color: p.accentText),
              onPressed: () =>
                  context.canPop() ? context.pop() : context.go('/library'),
            ),
            title: title == null
                ? null
                : Text(
                    title!,
                    style: HiveType.headline.copyWith(color: p.textPrimary),
                  ),
            actions: actions,
          ),
          ...slivers,
          SliverToBoxAdapter(
            child: SizedBox(
              height: MediaQuery.paddingOf(context).bottom + HiveSpace.lg,
            ),
          ),
        ],
      ),
    );
  }
}

/// Centred header: big art, title, a tappable subtitle and facts (design 1k).
class DetailHeader extends StatelessWidget {
  const DetailHeader({
    super.key,
    required this.art,
    required this.title,
    this.kicker,
    this.subtitle,
    this.onSubtitle,
    this.facts,
    this.badge,
    this.buttons,
    this.roundArt = false,
  });

  final Widget art;

  /// The art is a circle (artists), so its shadow is too.
  final bool roundArt;
  final String title;
  final String? kicker;
  final String? subtitle;
  final VoidCallback? onSubtitle;
  final String? facts;
  final Widget? badge;
  final Widget? buttons;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final artSize = (width * 0.66).clamp(180.0, 280.0);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HiveSpace.md),
      child: Column(
        children: [
          const SizedBox(height: HiveSpace.xs),
          DecoratedBox(
            decoration: BoxDecoration(
              shape: roundArt ? BoxShape.circle : BoxShape.rectangle,
              borderRadius: roundArt
                  ? null
                  : BorderRadius.circular(HiveRadius.art),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: Theme.of(context).brightness == Brightness.dark
                        ? 0.5
                        : 0.18,
                  ),
                  blurRadius: 30,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: SizedBox.square(dimension: artSize, child: art),
          ),
          const SizedBox(height: HiveSpace.lg),
          if (kicker != null)
            Text(
              kicker!.toUpperCase(),
              style: HiveType.overline.copyWith(color: p.textSecondary),
            ),
          Semantics(
            header: true,
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: HiveType.title2.copyWith(color: p.textPrimary),
            ),
          ),
          if (subtitle != null)
            InkWell(
              onTap: onSubtitle,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  style: HiveType.title2.copyWith(
                    color: onSubtitle == null ? p.textSecondary : p.accentText,
                    fontWeight: FontWeight.w400,
                    fontSize: 20,
                  ),
                ),
              ),
            ),
          if (facts != null || badge != null)
            Padding(
              padding: const EdgeInsets.only(top: HiveSpace.xxs),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: HiveSpace.xs,
                children: [
                  if (facts != null)
                    Text(
                      facts!,
                      style: HiveType.caption.copyWith(
                        color: p.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ?badge,
                ],
              ),
            ),
          if (buttons != null) ...[
            const SizedBox(height: HiveSpace.lg),
            buttons!,
          ],
          const SizedBox(height: HiveSpace.sm),
        ],
      ),
    );
  }
}
