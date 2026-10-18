import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:hive/api/hive_api.g.dart';
import 'package:hive/core/api.dart';
import 'package:hive/core/home_connection.dart';
import 'package:hive/player/player_controller.dart';
import 'package:hive/player/quality.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// A small family library: a Malayalam album, a Hindi album and an English
/// single, a playlist, and timed lyrics for one song.
final premam = Album(
  id: 'album-premam',
  title: 'Premam',
  artistId: 'artist-rajesh',
  artistName: 'Rajesh Murugesan',
  year: 2015,
  artworkId: null,
  trackCount: 4,
  tier: 'lossless',
  addedAt: DateTime.utc(2026, 10, 1),
  durationMs: 4 * 240000,
  tracks: [
    for (final (i, t) in [
      'മലരേ',
      'ആലുവ പുഴ',
      'Scene Contra',
      'Kalippu',
    ].indexed)
      track(
        'p${i + 1}',
        title: t,
        artist: 'Rajesh Murugesan',
        album: 'Premam',
      ).withNumber(i + 1),
  ],
);

final lagaan = Album(
  id: 'album-lagaan',
  title: 'लगान',
  artistId: 'artist-rahman',
  artistName: 'A.R. Rahman',
  year: 2001,
  artworkId: null,
  trackCount: 2,
  tier: 'hires',
  addedAt: DateTime.utc(2026, 9, 20),
  durationMs: 2 * 300000,
  tracks: [
    track(
      'l1',
      title: 'घनन घनन',
      artist: 'A.R. Rahman',
      album: 'लगान',
      format: flac2496,
    ).withNumber(1),
    track(
      'l2',
      title: 'मितवा',
      artist: 'A.R. Rahman',
      album: 'लगान',
      format: flac2496,
    ).withNumber(2),
  ],
);

AlbumSummary summaryOf(Album a) => AlbumSummary(
  id: a.id,
  title: a.title,
  artistId: a.artistId,
  artistName: a.artistName,
  year: a.year,
  artworkId: a.artworkId,
  trackCount: a.trackCount,
  tier: a.tier,
  addedAt: a.addedAt,
);

final roadTrip = Playlist(
  id: 'pl-road',
  name: 'Road trip',
  ownerName: 'Bilal',
  mine: true,
  shared: true,
  trackCount: 3,
  durationMs: 3 * 240000,
  artworkIds: const [],
  updatedAt: DateTime.utc(2026, 10, 10),
  items: [
    for (final t in [premam.tracks[0], lagaan.tracks[1], premam.tracks[2]])
      PlaylistItem(
        itemId: 'i-${t.id}',
        track: t,
        addedAt: DateTime.utc(2026, 10, 10),
      ),
  ],
);

PlaylistSummary playlistSummary(Playlist p) => PlaylistSummary(
  id: p.id,
  name: p.name,
  ownerName: p.ownerName,
  mine: p.mine,
  shared: p.shared,
  trackCount: p.trackCount,
  durationMs: p.durationMs,
  artworkIds: p.artworkIds,
  updatedAt: p.updatedAt,
);

const malaraeLyrics = Lyrics(
  kind: 'synced',
  lines: [
    LyricsLine(timeMs: 0, text: 'മലരേ നിന്നെ കാണാതിരുന്നാൽ'),
    LyricsLine(timeMs: 5000, text: 'മിഴിവേകിയ നിറമെല്ലാം മായുന്ന പോലെ'),
    LyricsLine(timeMs: 10000, text: 'ഇടനെഞ്ചിലെ മോഹം'),
  ],
);

extension on TrackSummary {
  TrackSummary withNumber(int n) => TrackSummary(
    id: id,
    title: title,
    artistId: artistId,
    artistName: artistName,
    albumId: albumId,
    albumTitle: albumTitle,
    trackNumber: n,
    discNumber: 1,
    durationMs: durationMs,
    artworkId: artworkId,
    format: format,
    liked: liked,
    hasLyrics: id == 'p1',
  );
}

/// Answers the app's API calls from the library above.
class FakeHomeAdapter implements HttpClientAdapter {
  final requests = <String>[];
  bool empty = false;

  Object? _route(RequestOptions o) {
    final path = o.uri.path;
    final albums = [premam, lagaan];
    final albumSummaries = albums.map(summaryOf).toList();
    final artists = [
      const ArtistSummary(
        id: 'artist-rajesh',
        name: 'Rajesh Murugesan',
        albumCount: 1,
        trackCount: 4,
      ),
      const ArtistSummary(
        id: 'artist-rahman',
        name: 'A.R. Rahman',
        albumCount: 1,
        trackCount: 2,
      ),
    ];
    final allTracks = [...premam.tracks, ...lagaan.tracks];
    if (path == '/api/v1/library/home') {
      return Home(
        jumpBackIn: empty
            ? const []
            : [
                const HomeTile(
                  kind: 'album',
                  id: 'album-premam',
                  title: 'Premam',
                  subtitle: 'Rajesh Murugesan',
                ),
                const HomeTile(
                  kind: 'playlist',
                  id: 'pl-road',
                  title: 'Road trip',
                  subtitle: 'Playlist',
                ),
                const HomeTile(
                  kind: 'liked',
                  id: 'liked',
                  title: 'Liked songs',
                ),
                const HomeTile(
                  kind: 'album',
                  id: 'album-lagaan',
                  title: 'लगान',
                  subtitle: 'A.R. Rahman',
                ),
              ],
        newAtHome: empty ? const [] : albumSummaries,
        playlists: empty ? const [] : [playlistSummary(roadTrip)],
        libraryEmpty: empty,
      ).toJson();
    }
    if (path == '/api/v1/library/albums') {
      return AlbumPage(
        items: albumSummaries,
        total: albumSummaries.length,
        offset: 0,
      ).toJson();
    }
    if (path.startsWith('/api/v1/library/albums/')) {
      final id = Uri.decodeComponent(path.split('/').last);
      return albums.firstWhere((a) => a.id == id).toJson();
    }
    if (path == '/api/v1/library/artists') {
      return ArtistPage(
        items: artists,
        total: artists.length,
        offset: 0,
      ).toJson();
    }
    if (path.startsWith('/api/v1/library/artists/')) {
      final id = Uri.decodeComponent(path.split('/').last);
      final a = artists.firstWhere((a) => a.id == id);
      final own = albums.where((x) => x.artistId == id).toList();
      return Artist(
        id: a.id,
        name: a.name,
        albumCount: a.albumCount,
        trackCount: a.trackCount,
        albums: own.map(summaryOf).toList(),
        topTracks: own.expand((x) => x.tracks).take(5).toList(),
      ).toJson();
    }
    if (path == '/api/v1/library/tracks') {
      final liked = o.uri.queryParameters['liked'] == 'true';
      final items = liked ? [premam.tracks[0]] : allTracks;
      return TrackPage(items: items, total: items.length, offset: 0).toJson();
    }
    if (path == '/api/v1/library/search') {
      final q = (o.uri.queryParameters['q'] ?? '').toLowerCase();
      bool hit(String s) => s.toLowerCase().contains(q);
      return SearchResults(
        tracks: allTracks
            .where((t) => hit(t.title) || hit(t.artistName))
            .toList(),
        albums: albumSummaries
            .where((a) => hit(a.title) || hit(a.artistName))
            .toList(),
        artists: artists.where((a) => hit(a.name)).toList(),
        playlists: hit(roadTrip.name) ? [playlistSummary(roadTrip)] : const [],
      ).toJson();
    }
    if (path == '/api/v1/library/playlists') {
      return PlaylistList(items: [playlistSummary(roadTrip)]).toJson();
    }
    if (path.startsWith('/api/v1/library/playlists/')) return roadTrip.toJson();
    if (path.endsWith('/lyrics')) {
      return path.contains('/p1/')
          ? malaraeLyrics.toJson()
          : const Lyrics(kind: 'none', lines: []).toJson();
    }
    if (path.startsWith('/api/v1/library/likes/')) return null;
    throw StateError('Fake home has no answer for ${o.method} $path');
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    requests.add(
      '${o.method} ${o.uri.path}${o.uri.hasQuery ? '?${o.uri.query}' : ''}',
    );
    try {
      final data = _route(o);
      if (data == null) return ResponseBody.fromString('', 204);
      return ResponseBody.fromString(
        jsonEncode(data),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    } on StateError catch (e) {
      return ResponseBody.fromString(
        jsonEncode({'title': 'Not found', 'status': 404, 'detail': e.message}),
        404,
        headers: {
          Headers.contentTypeHeader: ['application/problem+json'],
        },
      );
    }
  }

  @override
  void close({bool force = false}) {}
}

/// Overrides for a widget test of the whole app against [FakeHomeAdapter],
/// with a silent audio engine.
Future<List<Override>> fakeHomeOverrides({
  required HealthCheck check,
  FakeHomeAdapter? adapter,
  FakeEngine? engine,
  bool connected = true,
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    if (connected) 'home.address': 'http://100.84.12.7:8443',
    ...prefs,
  });
  final sp = await SharedPreferences.getInstance();
  final fake = adapter ?? FakeHomeAdapter();
  final tickets = FakeTickets();
  return [
    sharedPreferencesProvider.overrideWithValue(sp),
    healthCheckProvider.overrideWithValue(check),
    keyCheckProvider.overrideWithValue((_, _) async {}),
    hiveApiProvider.overrideWith((ref) {
      final config = ref.watch(homeConfigProvider);
      if (config == null) throw StateError('Not connected to a home yet');
      return HiveApi(dioForHome(config)..httpClientAdapter = fake);
    }),
    audioEngineProvider.overrideWithValue(engine ?? FakeEngine()),
    ticketFetcherProvider.overrideWithValue(tickets.call),
    networkKindProvider.overrideWith((ref) => Stream.value(NetworkKind.wifi)),
  ];
}
