import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/home_connection.dart';
import 'design/icons.g.dart';
import 'design/theme.dart';
import 'features/connect/connect_screen.dart';
import 'features/home/home_screen.dart';
import 'features/placeholder_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/shell/app_shell.dart';

GoRouter buildRouter(HomeAddressStore store) => GoRouter(
  initialLocation: '/home',
  refreshListenable: store,
  redirect: (context, state) {
    final hasHome = store.address != null;
    final atConnect = state.matchedLocation == '/connect';
    if (!hasHome && !atConnect) return '/connect';
    return null;
  },
  routes: [
    GoRoute(path: '/connect', builder: (_, _) => const ConnectScreen()),
    GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
    StatefulShellRoute.indexedStack(
      builder: (_, _, shell) => AppShell(shell: shell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/search',
              builder: (_, _) => const PlaceholderScreen(
                title: 'Search',
                icon: HiveIcons.search,
                milestone: 'M1',
                text: 'Search songs, albums and artists in the family library.',
              ),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/library',
              builder: (_, _) => const PlaceholderScreen(
                title: 'Library',
                icon: HiveIcons.libraryBig,
                milestone: 'M1',
                text: 'Playlists, albums, artists, songs and downloads.',
              ),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/listen',
              builder: (_, _) => const PlaceholderScreen(
                title: 'Listen',
                icon: HiveIcons.audioWaveform,
                milestone: 'M3',
                text: 'Find out what song is playing near you.',
              ),
            ),
          ],
        ),
      ],
    ),
  ],
);

final routerProvider = Provider<GoRouter>((ref) {
  final router = buildRouter(ref.watch(homeAddressStoreProvider));
  ref.onDispose(router.dispose);
  return router;
});

class HiveApp extends ConsumerWidget {
  const HiveApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep the home check running for as long as the app is open.
    ref.watch(homeStatusProvider);
    return MaterialApp.router(
      title: 'Hive',
      debugShowCheckedModeBanner: false,
      theme: buildHiveTheme(Brightness.light),
      darkTheme: buildHiveTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      routerConfig: ref.watch(routerProvider),
    );
  }
}
