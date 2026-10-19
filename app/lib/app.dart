import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'auth/device_auth.dart';
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

/// Whether this device may use home yet: an address, plus either M1's
/// development key (while home still uses it) or its own sign-in.
bool readyForHome(HomeAddressStore store, DeviceAuth auth, HomeStatus status) {
  if (store.address == null) return false;
  if (auth.signedIn) return auth.problem != SignInProblem.suspended;
  if (store.key == null) return false;
  // Home switched to invites: the old key is no use any more.
  return !(status is HomeConnected && status.health.access == 'invites');
}

GoRouter buildRouter(
  HomeAddressStore store,
  DeviceAuth auth,
  HomeStatus Function() status,
  Listenable statusChanges,
) => GoRouter(
  initialLocation: '/home',
  refreshListenable: Listenable.merge([store, auth, statusChanges]),
  redirect: (context, state) {
    final atConnectNow = state.matchedLocation == '/connect';
    if (!auth.loaded) {
      return store.address == null && !atConnectNow ? '/connect' : null;
    }
    final ready = readyForHome(store, auth, status());
    final atConnect = state.matchedLocation == '/connect';
    if (!ready && !atConnect) return '/connect';
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
  final statusChanges = ValueNotifier<HomeStatus>(ref.read(homeStatusProvider));
  ref.listen(homeStatusProvider, (_, s) => statusChanges.value = s);
  final router = buildRouter(
    ref.watch(homeAddressStoreProvider),
    ref.watch(deviceAuthProvider),
    () => ref.read(homeStatusProvider),
    statusChanges,
  );
  ref.onDispose(() {
    router.dispose();
    statusChanges.dispose();
  });
  return router;
});

/// Reads this device's saved sign-in once, at start-up.
final authLoadedProvider = FutureProvider<void>(
  (ref) => ref.watch(deviceAuthProvider).load(),
);

class HiveApp extends ConsumerWidget {
  const HiveApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep the home check running for as long as the app is open.
    ref.watch(homeStatusProvider);
    ref.watch(authLoadedProvider);
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
