import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/hive_api.g.dart';
import '../core/api.dart';
import '../player/player_controller.dart';

/// Library data from home. Screens watch these; mutations invalidate them.

final homeShelvesProvider = FutureProvider.autoDispose<Home>(
  (ref) => ref.watch(hiveApiProvider).getHome(),
);

final albumProvider = FutureProvider.autoDispose.family<Album, String>(
  (ref, id) => ref.watch(hiveApiProvider).getAlbum(albumId: id),
);

final artistProvider = FutureProvider.autoDispose.family<Artist, String>(
  (ref, id) => ref.watch(hiveApiProvider).getArtist(artistId: id),
);

final playlistProvider = FutureProvider.autoDispose.family<Playlist, String>(
  (ref, id) => ref.watch(hiveApiProvider).getPlaylist(playlistId: id),
);

final playlistsProvider = FutureProvider.autoDispose<List<PlaylistSummary>>(
  (ref) async => (await ref.watch(hiveApiProvider).listPlaylists()).items,
);

final likedSongsProvider = FutureProvider.autoDispose<List<TrackSummary>>(
  (ref) async =>
      (await ref.watch(hiveApiProvider).listTracks(liked: true, limit: 500))
          .items,
);

final lyricsProvider = FutureProvider.autoDispose.family<Lyrics, String>(
  (ref, id) => ref.watch(hiveApiProvider).getLyrics(trackId: id),
);

final searchProvider = FutureProvider.autoDispose.family<SearchResults, String>(
  (ref, q) async {
    // Wait for typing to pause; a newer query cancels this one.
    var cancelled = false;
    ref.onDispose(() => cancelled = true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (cancelled) throw StateError('cancelled');
    return ref.watch(hiveApiProvider).search(q: q, limit: 12);
  },
);

enum AlbumSort {
  recent('recent', 'Recently added'),
  title('title', 'Title'),
  artist('artist', 'Artist'),
  year('year', 'Year');

  const AlbumSort(this.wire, this.label);
  final String wire;
  final String label;
}

/// A long list loaded a page at a time as it scrolls.
class Paged<T> {
  const Paged({
    this.items = const [],
    this.total,
    this.loading = false,
    this.error,
  });
  final List<T> items;
  final int? total;
  final bool loading;
  final Object? error;
  bool get done => total != null && items.length >= total!;
}

abstract class PagedNotifier<T> extends Notifier<Paged<T>> {
  static const pageSize = 100;
  int _token = 0;

  Future<({List<T> items, int total})> fetch(int offset);

  @override
  Paged<T> build() {
    _token++;
    Future.microtask(more);
    return const Paged(loading: true);
  }

  Future<void> more() async {
    final s = state;
    if (s.done || (s.loading && s.items.isNotEmpty)) return;
    final token = _token;
    state = Paged(items: s.items, total: s.total, loading: true);
    try {
      final page = await fetch(s.items.length);
      if (token != _token) return;
      state = Paged(items: [...s.items, ...page.items], total: page.total);
    } catch (e) {
      if (token != _token) return;
      state = Paged(items: s.items, total: s.total, error: e);
    }
  }
}

class AlbumsNotifier extends PagedNotifier<AlbumSummary> {
  AlbumsNotifier(this.sort);
  final AlbumSort sort;

  @override
  Future<({List<AlbumSummary> items, int total})> fetch(int offset) async {
    final p = await ref
        .read(hiveApiProvider)
        .listAlbums(
          offset: offset,
          limit: PagedNotifier.pageSize,
          sort: sort.wire,
        );
    return (items: p.items, total: p.total);
  }

  @override
  Paged<AlbumSummary> build() {
    ref.watch(hiveApiProvider);
    return super.build();
  }
}

final albumsProvider = NotifierProvider.autoDispose
    .family<AlbumsNotifier, Paged<AlbumSummary>, AlbumSort>(AlbumsNotifier.new);

class ArtistsNotifier extends PagedNotifier<ArtistSummary> {
  @override
  Future<({List<ArtistSummary> items, int total})> fetch(int offset) async {
    final p = await ref
        .read(hiveApiProvider)
        .listArtists(offset: offset, limit: PagedNotifier.pageSize);
    return (items: p.items, total: p.total);
  }

  @override
  Paged<ArtistSummary> build() {
    ref.watch(hiveApiProvider);
    return super.build();
  }
}

final artistsProvider =
    NotifierProvider.autoDispose<ArtistsNotifier, Paged<ArtistSummary>>(
      ArtistsNotifier.new,
    );

class SongsNotifier extends PagedNotifier<TrackSummary> {
  @override
  Future<({List<TrackSummary> items, int total})> fetch(int offset) async {
    final p = await ref
        .read(hiveApiProvider)
        .listTracks(
          offset: offset,
          limit: PagedNotifier.pageSize,
          sort: 'title',
        );
    return (items: p.items, total: p.total);
  }

  @override
  Paged<TrackSummary> build() {
    ref.watch(hiveApiProvider);
    return super.build();
  }
}

final songsProvider =
    NotifierProvider.autoDispose<SongsNotifier, Paged<TrackSummary>>(
      SongsNotifier.new,
    );

/// Likes changed on this device since lists were loaded (so every list shows
/// the heart the same way without reloading).
class LikesNotifier extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() => const {};

  bool isLiked(TrackSummary t) => state[t.id] ?? t.liked;

  Future<void> toggle(TrackSummary t) async {
    final liked = !isLiked(t);
    state = {...state, t.id: liked};
    try {
      final api = ref.read(hiveApiProvider);
      if (liked) {
        await api.likeTrack(trackId: t.id);
      } else {
        await api.unlikeTrack(trackId: t.id);
      }
      ref.invalidate(likedSongsProvider);
      ref.invalidate(homeShelvesProvider);
    } catch (_) {
      state = {...state, t.id: !liked};
      rethrow;
    }
  }
}

final likesProvider = NotifierProvider<LikesNotifier, Map<String, bool>>(
  LikesNotifier.new,
);

/// Playlist changes, each refreshing what shows it.
class PlaylistActions {
  PlaylistActions(this.ref);
  final Ref ref;

  HiveApi get _api => ref.read(hiveApiProvider);

  void _refresh([String? id]) {
    ref.invalidate(playlistsProvider);
    ref.invalidate(homeShelvesProvider);
    if (id != null) ref.invalidate(playlistProvider(id));
  }

  Future<Playlist> create(
    String name, {
    bool shared = false,
    List<String> trackIds = const [],
  }) async {
    final p = await _api.createPlaylist(
      body: PlaylistCreate(name: name, shared: shared, trackIds: trackIds),
    );
    _refresh();
    return p;
  }

  Future<void> rename(String id, String name) async {
    await _api.updatePlaylist(
      playlistId: id,
      body: PlaylistUpdate(name: name),
    );
    _refresh(id);
  }

  Future<void> setShared(String id, bool shared) async {
    await _api.updatePlaylist(
      playlistId: id,
      body: PlaylistUpdate(shared: shared),
    );
    _refresh(id);
  }

  Future<void> delete(String id) async {
    await _api.deletePlaylist(playlistId: id);
    _refresh();
  }

  Future<Playlist> setTracks(String id, List<String> trackIds) async {
    final p = await _api.setPlaylistItems(
      playlistId: id,
      body: PlaylistItemsUpdate(trackIds: trackIds),
    );
    _refresh(id);
    return p;
  }

  Future<Playlist> add(String id, List<String> trackIds) async {
    final current = await _api.getPlaylist(playlistId: id);
    return setTracks(id, [
      ...current.items.map((i) => i.track.id),
      ...trackIds,
    ]);
  }
}

final playlistActionsProvider = Provider<PlaylistActions>(PlaylistActions.new);

/// Helpers screens use to start playback.
extension PlayFrom on PlayerController {
  Future<void> playAlbum(Album a, {int start = 0, bool shuffle = false}) =>
      playTracks(
        a.tracks,
        start: start,
        shuffle: shuffle,
        source: PlaySource(kind: 'album', id: a.id, name: a.title),
      );

  Future<void> playPlaylist(
    Playlist p, {
    int start = 0,
    bool shuffle = false,
  }) => playTracks(
    p.items.map((i) => i.track).toList(),
    start: start,
    shuffle: shuffle,
    source: PlaySource(kind: 'playlist', id: p.id, name: p.name),
  );
}
