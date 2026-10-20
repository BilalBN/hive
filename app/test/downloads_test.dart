import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/api/hive_api.g.dart';
import 'package:hive/auth/device_auth.dart';
import 'package:hive/auth/secret_store.dart';
import 'package:hive/core/home_connection.dart';
import 'package:hive/downloads/downloads.dart';
import 'package:hive/downloads/vault.dart';
import 'package:hive/player/player_controller.dart';
import 'package:hive/player/quality.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_test.dart' show health;
import 'support/fakes.dart';

Album albumOf(String id, List<TrackSummary> tracks) => Album(
  id: id,
  title: 'Album $id',
  artistName: 'Vijay Yesudas',
  artworkId: 'art-$id',
  trackCount: tracks.length,
  durationMs: tracks.fold(0, (n, t) => n + t.durationMs),
  tier: 'lossless',
  addedAt: DateTime.utc(2026, 10, 1),
  tracks: tracks,
);

Playlist playlistOf(String id, List<TrackSummary> tracks) => Playlist(
  id: id,
  name: 'Road trip',
  ownerName: 'Arun',
  mine: true,
  shared: false,
  trackCount: tracks.length,
  durationMs: 0,
  artworkIds: const [],
  updatedAt: DateTime.utc(2026, 10, 1),
  items: [
    for (final t in tracks)
      PlaylistItem(itemId: 'i-${t.id}', track: t, addedAt: DateTime.utc(2026)),
  ],
);

Future<(ProviderContainer, MemoryVault, FakeDownloadTransport, FakeEngine)>
setUpDownloads({bool online = true}) async {
  SharedPreferences.setMockInitialValues({
    'home.address': 'http://100.84.12.7:8443',
    'home.developmentKey': 'hive-dev-test-test-test-test',
  });
  final prefs = await SharedPreferences.getInstance();
  final vault = MemoryVault();
  final net = FakeDownloadTransport();
  final engine = FakeEngine();
  final tickets = FakeTickets();
  final c = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      secretStoreProvider.overrideWithValue(MemorySecretStore()),
      downloadVaultProvider.overrideWithValue(vault),
      downloadTransportProvider.overrideWithValue(net),
      audioEngineProvider.overrideWithValue(engine),
      ticketFetcherProvider.overrideWithValue(tickets.call),
      networkKindProvider.overrideWith((ref) => Stream.value(NetworkKind.wifi)),
      healthCheckProvider.overrideWithValue(
        (_) async => online
            ? health("Arun's home")
            : throw HiveApiException(null, null, 'offline'),
      ),
    ],
  );
  addTearDown(c.dispose);
  await c.read(deviceAuthProvider).load();
  c.read(homeStatusProvider);
  c.read(downloadsProvider);
  await c.read(downloadsProvider.notifier).ready();
  await pump();
  return (c, vault, net, engine);
}

void main() {
  group('the vault on disk', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('hive-dl'));
    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('songs are locked on disk and any part unlocks on its own', () async {
      final secrets = MemorySecretStore();
      final vault = FileVault(() async => dir, secrets);
      final r = Random(4);
      final song = List<int>.generate(300001, (_) => r.nextInt(256));
      // Pieces of odd sizes, as they arrive from the network.
      final pieces = <List<int>>[];
      for (var at = 0; at < song.length;) {
        final n = min(1 + r.nextInt(90000), song.length - at);
        pieces.add(song.sublist(at, at + n));
        at += n;
      }
      final kept = await vault.store('t1/ü', Stream.fromIterable(pieces));
      expect(kept, song.length);
      expect(await vault.sizeOf('t1/ü'), song.length);

      final onDisk = dir
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('.hive'))
          .readAsBytesSync();
      expect(onDisk.length, song.length + 12);
      // Nothing recognisable: no long run matches the song.
      expect(onDisk.sublist(12, 4108), isNot(song.sublist(0, 4096)));

      Future<List<int>> read(int start, [int? end]) async =>
          (await vault.open('t1/ü', start, end).toList())
              .expand((b) => b)
              .toList();
      expect(await read(0), song);
      expect(await read(100003, 200001), song.sublist(100003, 200001));
      expect(await read(299990), song.sublist(299990));

      // Another vault with the same key reads it; a new key can't.
      final again = FileVault(() async => dir, secrets);
      expect(await (again.open('t1/ü', 5, 9).first), song.sublist(5, 9));

      await vault.wipe();
      expect(await dir.exists(), isFalse);
      expect(await secrets.read('downloads.key'), isNull);
    });
  });

  group('downloads', () {
    final songs = [for (var i = 1; i <= 3; i++) track('t$i')];

    test('an album downloads and plays from the device', () async {
      final (c, vault, net, engine) = await setUpDownloads();
      final dl = c.read(downloadsProvider.notifier);
      await dl.downloadAlbum(albumOf('a1', songs));
      await pump();
      final s = c.read(downloadsProvider);
      expect(s.tracks.keys, ['t1', 't2', 't3']);
      expect(s.statusOfSet('album', 'a1'), DownloadStatus.done);
      expect(net.tickets, ['t1@high', 't2@high', 't3@high']);
      expect(vault.songs['t2'], FakeDownloadTransport.bytesOf('t2'));
      expect(s.bytes, 3 * 70000);
      expect(vault.art.keys, contains('art-a1'));

      await c.read(playerProvider.notifier).playTracks(songs);
      expect(engine.sources.first.uri.scheme, 'hive-download');
      expect(engine.sources.first.sizeBytes, 70000);
      final bytes = await dl.open('t1', 10, 20).first;
      expect(bytes, FakeDownloadTransport.bytesOf('t1').sublist(10, 20));
    });

    test('removing an album keeps a song downloaded on its own', () async {
      final (c, vault, _, _) = await setUpDownloads();
      final dl = c.read(downloadsProvider.notifier);
      await dl.downloadAlbum(albumOf('a1', songs));
      await dl.downloadTrack(songs[1]);
      await pump();
      await dl.removeSet('album', 'a1');
      final s = c.read(downloadsProvider);
      expect(s.tracks.keys, ['t2']);
      expect(s.singles.single.track.id, 't2');
      expect(vault.songs.keys, ['t2']);
    });

    test('the queue waits for home and carries on when it is back', () async {
      final (c, _, net, _) = await setUpDownloads();
      net.down = true;
      final dl = c.read(downloadsProvider.notifier);
      await dl.downloadAlbum(albumOf('a1', songs));
      await pump();
      expect(c.read(downloadsProvider).tracks, isEmpty);
      expect(c.read(downloadsProvider).jobs.length, 3);
      expect(c.read(downloadsProvider).failed, isEmpty); // waiting, not failed
      net.down = false;
      await c.read(homeStatusProvider.notifier).check();
      await pump();
      expect(c.read(downloadsProvider).tracks.length, 3);
    });

    test(
      'checking in moves the 30 days on and deletes songs gone from home',
      () async {
        final (c, vault, net, _) = await setUpDownloads();
        final dl = c.read(downloadsProvider.notifier);
        await dl.downloadAlbum(albumOf('a1', songs));
        await pump();
        net.gone = {'t3'};
        net.validUntil = DateTime.now().add(const Duration(days: 30));
        await dl.checkIn(force: true);
        final s = c.read(downloadsProvider);
        expect(s.tracks.keys, ['t1', 't2']);
        expect(s.setOf('album', 'a1')!.trackIds, ['t1', 't2']);
        expect(vault.songs.containsKey('t3'), isFalse);
        expect(s.validUntil, net.validUntil);
      },
    );

    test('past 30 days without home, downloads wait for a check-in', () async {
      final (c, _, net, _) = await setUpDownloads();
      net.validUntil = DateTime.now().subtract(const Duration(minutes: 1));
      final dl = c.read(downloadsProvider.notifier);
      await dl.downloadTrack(songs[0]);
      await pump();
      expect(c.read(downloadsProvider).expired, isTrue);
      expect(dl.ticketFor('t1'), isNull);
      net.validUntil = DateTime.now().add(const Duration(days: 30));
      await dl.checkIn();
      expect(dl.ticketFor('t1'), isNotNull);
    });

    test('a few days before, it warns that downloads need home', () async {
      final (c, _, net, _) = await setUpDownloads();
      net.validUntil = DateTime.now().add(const Duration(days: 3));
      await c.read(downloadsProvider.notifier).downloadTrack(songs[0]);
      await pump();
      final s = c.read(downloadsProvider);
      expect(s.expiringSoon, isTrue);
      expect(s.expired, isFalse);
      expect(c.read(downloadsProvider.notifier).ticketFor('t1'), isNotNull);
    });

    test('a downloaded playlist follows changes at home', () async {
      final (c, _, net, _) = await setUpDownloads();
      final dl = c.read(downloadsProvider.notifier);
      await dl.downloadPlaylist(playlistOf('p1', songs.take(2).toList()));
      await pump();
      net.playlists['p1'] = playlistOf('p1', [songs[1], songs[2]]);
      await dl.checkIn(force: true);
      await pump();
      final s = c.read(downloadsProvider);
      expect(s.setOf('playlist', 'p1')!.trackIds, ['t2', 't3']);
      expect(s.tracks.keys.toSet(), {'t2', 't3'});
    });

    test('leaving home deletes every download', () async {
      final (c, vault, _, _) = await setUpDownloads();
      await c.read(downloadsProvider.notifier).downloadTrack(songs[0]);
      await pump();
      expect(vault.songs, isNotEmpty);
      await c.read(homeAddressStoreProvider).forget();
      await pump();
      expect(vault.songs, isEmpty);
      expect(c.read(downloadsProvider).tracks, isEmpty);
    });

    test('downloads survive the app closing', () async {
      final (c, vault, _, _) = await setUpDownloads();
      await c
          .read(downloadsProvider.notifier)
          .downloadAlbum(albumOf('a1', songs));
      await pump();
      final index = vault.index;
      c.invalidate(downloadsProvider);
      vault.index = index;
      c.read(downloadsProvider);
      await c.read(downloadsProvider.notifier).ready();
      final s = c.read(downloadsProvider);
      expect(s.tracks.length, 3);
      expect(s.sets.single.name, 'Album a1');
    });
  });
}
