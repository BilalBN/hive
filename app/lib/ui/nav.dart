import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/player/side_panel.dart';

/// Matches the shell's desktop breakpoint.
const _wide = 840.0;

/// Albums, artists and playlists open inside the tab you're in, so the tabs
/// and the mini player stay put.
extension HiveNav on BuildContext {
  String get _branch {
    final path = GoRouter.of(this).routerDelegate.currentConfiguration.uri.path;
    final first = path.split('/').where((s) => s.isNotEmpty).firstOrNull;
    return const {'home', 'search', 'library'}.contains(first)
        ? first!
        : 'library';
  }

  void openAlbum(String id) =>
      push('/$_branch/album/${Uri.encodeComponent(id)}');
  void openArtist(String id) =>
      push('/$_branch/artist/${Uri.encodeComponent(id)}');
  void openPlaylist(String id) =>
      push('/$_branch/playlist/${Uri.encodeComponent(id)}');
  void openLiked() => push('/$_branch/liked');
  void openNowPlaying() => push('/now-playing');

  /// On computers the queue and lyrics open in the right-hand panel.
  void openQueue() => _panelOr(SidePanel.queue, '/queue');
  void openLyrics() => _panelOr(SidePanel.lyrics, '/lyrics');

  void _panelOr(SidePanel panel, String route) {
    if (MediaQuery.sizeOf(this).width >= _wide) {
      ProviderScope.containerOf(
        this,
        listen: false,
      ).read(sidePanelProvider.notifier).show(panel);
      if (GoRouter.of(this).routerDelegate.currentConfiguration.uri.path ==
          '/now-playing') {
        pop();
      }
    } else {
      push(route);
    }
  }
}
