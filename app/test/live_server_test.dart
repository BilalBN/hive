@Tags(['live'])
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/api/hive_api.g.dart';
import 'package:hive/core/api.dart';

/// Every call the app makes in M1, against a real server: proves the
/// generated client and the server agree on every shape, not just the
/// contract on paper.
void main() {
  final url = Platform.environment['HIVE_LIVE_URL'] ?? 'http://127.0.0.1:8443';
  final key = Platform.environment['HIVE_LIVE_KEY'];
  late HiveApi api;
  late Dio dio;

  setUpAll(() {
    dio = dioForHome(HomeConfig(Uri.parse(url), key));
    api = HiveApi(dio);
  });

  test('library, search, playlists, likes, streams and lyrics', () async {
    // The scan may still be running; wait for albums.
    Home home = await api.getHome();
    for (var i = 0; i < 30 && home.newAtHome.isEmpty; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      home = await api.getHome();
    }
    expect(home.newAtHome, isNotEmpty);

    final albums = await api.listAlbums(limit: 50, sort: 'title');
    expect(albums.total, greaterThan(0));
    for (final s in albums.items) {
      final a = await api.getAlbum(albumId: s.id);
      expect(a.tracks, isNotEmpty, reason: a.title);
      for (final t in a.tracks) {
        // Every quality on every song: the ticket parses and the audio starts.
        for (final (q, player) in [
          for (final q in ['lossless', 'high', 'dataSaver'])
            for (final player in ['apple', 'other']) (q, player),
        ]) {
          final ticket = await api.createStreamTicket(
            trackId: t.id,
            body: StreamRequest(quality: q, player: player),
          );
          final audio = await dio.get<List<int>>(
            ticket.url,
            options: Options(
              responseType: ResponseType.bytes,
              headers: {'Range': 'bytes=0-1023'},
            ),
          );
          expect(
            audio.statusCode,
            anyOf(200, 206),
            reason: '${t.title} $q $player',
          );
          expect(audio.data, isNotEmpty);
        }
        final lyrics = await api.getLyrics(trackId: t.id);
        expect(['synced', 'plain', 'none'], contains(lyrics.kind));
      }
    }

    // M1.5: languages, filters, credits.
    final langs = await api.listLanguages();
    expect(langs.items.map((l) => l.code), contains('ml'));
    final ml = await api.listAlbums(language: 'ml', limit: 50);
    expect(ml.items, isNotEmpty);
    expect(ml.items.every((a) => a.language == 'ml'), isTrue);
    await api.getHome(language: 'ml');
    await api.listTracks(language: 'ml', limit: 10);
    final roman = await api.search(q: 'malare', language: 'ml');
    expect(roman.tracks, isNotEmpty);

    final artists = await api.listArtists(limit: 50);
    for (final s in artists.items) {
      final a = await api.getArtist(artistId: s.id);
      expect(a.name, s.name);
    }

    final tracks = await api.listTracks(limit: 50);
    expect(tracks.items, isNotEmpty);
    final t = tracks.items.first;

    for (final q in ['malare', 'മലരേ', 'rahman', 'ar rahman', 'zzzz']) {
      final r = await api.search(q: q, limit: 12);
      expect(
        r.tracks.length +
            r.albums.length +
            r.artists.length +
            r.playlists.length,
        q == 'zzzz' ? 0 : greaterThan(0),
        reason: q,
      );
    }

    final pl = await api.createPlaylist(
      body: PlaylistCreate(name: 'Live test', shared: false, trackIds: [t.id]),
    );
    final updated = await api.setPlaylistItems(
      playlistId: pl.id,
      body: PlaylistItemsUpdate(
        trackIds: [for (final x in tracks.items.take(3)) x.id],
      ),
    );
    expect(updated.items.length, 3);
    await api.updatePlaylist(
      playlistId: pl.id,
      body: PlaylistUpdate(name: 'Live test 2', shared: true),
    );
    final lists = await api.listPlaylists();
    expect(lists.items.map((p) => p.name), contains('Live test 2'));
    await api.deletePlaylist(playlistId: pl.id);

    await api.likeTrack(trackId: t.id);
    final liked = await api.listTracks(liked: true);
    expect(liked.items.map((x) => x.id), contains(t.id));
    await api.unlikeTrack(trackId: t.id);

    final art = home.newAtHome.firstWhere(
      (a) => a.artworkId != null,
      orElse: () => home.newAtHome.first,
    );
    if (art.artworkId != null) {
      final img = await dio.get<List<int>>(
        '/api/v1/media/artwork/${art.artworkId}?size=300',
        options: Options(responseType: ResponseType.bytes),
      );
      expect(img.statusCode, 200);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
