import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/home_connection.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../design/widgets.dart';
import '../shell/app_shell.dart' show desktopBreakpoint;

String greeting(DateTime now) {
  final h = now.hour;
  if (h < 5) return 'Good evening';
  if (h < 12) return 'Good morning';
  if (h < 17) return 'Good afternoon';
  return 'Good evening';
}

/// Home. In M0 it only proves the link to home; shelves of music arrive in M1.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final status = ref.watch(homeStatusProvider);

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          HiveSpace.md,
          HiveSpace.md,
          HiveSpace.md,
          120,
        ),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  greeting(DateTime.now()),
                  style: HiveType.title1.copyWith(color: p.textPrimary),
                ),
              ),
              // On computers Settings sits at the foot of the sidebar instead.
              if (MediaQuery.sizeOf(context).width < desktopBreakpoint)
                Semantics(
                  key: const Key('open-settings'),
                  label: 'Settings',
                  button: true,
                  container: true,
                  excludeSemantics: true,
                  child: InkResponse(
                    onTap: () => context.push('/settings'),
                    radius: 28,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: p.raised,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        HiveIcons.settings,
                        size: 20,
                        color: p.textSecondary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: HiveSpace.sm),
          switch (status) {
            HomeChecking() => const StatusLine(
              ok: true,
              text: 'Checking home…',
            ),
            HomeConnected(:final health) => StatusLine(
              ok: true,
              text: 'Connected to home',
              detail: health.homeName,
            ),
            HomeUnreachable(:final reason) => HiveBanner(
              title: "Can't reach home right now",
              body: reason,
              action: TextButton(
                onPressed: () => ref.read(homeStatusProvider.notifier).check(),
                child: Text(
                  'Try again',
                  style: HiveType.callout.copyWith(
                    color: p.accentText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          },
          const SizedBox(height: HiveSpace.xxl),
          const ComingSoon(
            icon: HiveIcons.libraryBig,
            title: 'Your music arrives in M1',
            text:
                'Quick picks, new at home and your playlists will appear here.',
          ),
        ],
      ),
    );
  }
}
