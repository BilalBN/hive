import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/home_connection.dart';
import 'design/icons.g.dart';
import 'design/theme.dart';
import 'design/tokens.g.dart';
import 'features/connect/connect_screen.dart';
import 'features/home/home_screen.dart';
import 'features/library/album_screen.dart';
import 'features/library/artist_screen.dart';
import 'features/library/library_screen.dart';
import 'features/library/playlist_screen.dart';
import 'features/player/lyrics_view.dart';
import 'features/player/now_playing_screen.dart';
import 'features/player/queue_view.dart';
import 'features/search/search_screen.dart';
import 'features/placeholder_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/shell/app_shell.dart';

/// Albums, artists and playlists open inside whichever tab you're in.
List<RouteBase> _details() => [
  GoRoute(
    path: 'album/:id',
    builder: (_, s) => AlbumScreen(albumId: s.pathParameters['id']!),
  ),
  GoRoute(
    path: 'artist/:id',
    builder: (_, s) => ArtistScreen(artistId: s.pathParameters['id']!),
  ),
  GoRoute(
    path: 'playlist/:id',
    builder: (_, s) => PlaylistScreen(playlistId: s.pathParameters['id']!),
  ),
  GoRoute(path: 'liked', builder: (_, _) => const LikedSongsScreen()),
];

/// Now playing, the queue and lyrics slide up over everything.
Page<void> _sheetPage(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      child: child,
      transitionDuration: HiveMotion.sheet,
      reverseTransitionDuration: HiveMotion.sheet,
      transitionsBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(animation),
        child: child,
      ),
    );

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
    GoRoute(
      path: '/now-playing',
      pageBuilder: (_, s) => _sheetPage(s, const NowPlayingScreen()),
    ),
    GoRoute(
      path: '/queue',
      pageBuilder: (_, s) => _sheetPage(s, const QueueScreen()),
    ),
    GoRoute(
      path: '/lyrics',
      pageBuilder: (_, s) => _sheetPage(s, const LyricsScreen()),
    ),
    StatefulShellRoute.indexedStack(
      builder: (_, _, shell) => AppShell(shell: shell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/home',
              builder: (_, _) => const HomeScreen(),
              routes: _details(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/search',
              builder: (_, _) => const SearchScreen(),
              routes: _details(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/library',
              builder: (_, _) => const LibraryScreen(),
              routes: _details(),
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
