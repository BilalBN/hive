import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/api/hive_api.g.dart';
import 'package:hive/core/api.dart';
import 'package:hive/core/home_connection.dart';
import 'package:hive/player/engine.dart';
import 'package:hive/player/player_controller.dart';
import 'package:hive/player/quality.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

Future<(ProviderContainer, FakeEngine, FakeTickets)> setUpPlayer({
  QualityMode mode = QualityMode.lossless,
}) async {
  SharedPreferences.setMockInitialValues({'playback.onWifi': mode.wire});
  final prefs = await SharedPreferences.getInstance();
  final engine = FakeEngine();
  final tickets = FakeTickets();
  final c = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      audioEngineProvider.overrideWithValue(engine),
      ticketFetcherProvider.overrideWithValue(tickets.call),
      networkKindProvider.overrideWith((ref) => Stream.value(NetworkKind.wifi)),
      homeConfigProvider.overrideWithValue(
        HomeConfig(Uri.parse('http://100.84.12.7:8443'), 'k'),
      ),
    ],
  );
  addTearDown(c.dispose);
  c.read(playerProvider);
  await pump();
  return (c, engine, tickets);
}

final album = [for (var i = 1; i <= 5; i++) track('t$i')];

void main() {
  test(
    'playing an album loads the song and the next one, nothing more',
    () async {
      final (c, engine, tickets) = await setUpPlayer();
      await c.read(playerProvider.notifier).playTracks(album, start: 1);
      final s = c.read(playerProvider);
      expect(s.track!.id, 't2');
      expect(engine.loaded, ['t2', 't3']);
      expect(engine.playing, isTrue);
      expect(tickets.calls, [
        ('t2', QualityMode.lossless, true),
        ('t3', QualityMode.lossless, false),
      ]);
      expect(s.ticket!.format.label, 'Lossless 16/44.1');
    },
  );

  test('gapless: when the engine moves on, the window slides and the play is counted', () async {
    final (c, engine, tickets) = await setUpPlayer();
    await c.read(playerProvider.notifier).playTracks(album);
    await engine.advance();
    expect(c.read(playerProvider).track!.id, 't2');
    expect(engine.loaded, ['t2', 't3']);
    expect(
      tickets.calls.where((t) => t.$1 == 't2' && t.$3),
      isNotEmpty,
      reason: 'counted as played',
    );
  });

  test(
    'choosing a song while the next one takes over keeps the chosen song',
    () async {
      final (c, engine, _) = await setUpPlayer();
      final p = c.read(playerProvider.notifier);
      await p.playTracks(album);
      // The engine moves on to t2 by itself, and in the same moment a song is
      // tapped in a list: the tapped one must play, and stay loaded.
      final choosing = p.playTracks([track('x1'), track('x2')]);
      await engine.advance();
      await choosing;
      await pump();
      expect(c.read(playerProvider).track!.id, 'x1');
      expect(engine.loaded, ['x1', 'x2']);
    },
  );

  test('switching songs quickly lands on the last one chosen', () async {
    final (c, engine, _) = await setUpPlayer();
    final p = c.read(playerProvider.notifier);
    await p.playTracks(album);
    final first = p.playTracks(album, start: 2);
    final second = p.playTracks(album, start: 4);
    await Future.wait([first, second]);
    await pump();
    expect(c.read(playerProvider).track!.id, 't5');
    expect(engine.loaded, ['t5']);
  });

  test('next, previous and the 3-second rule', () async {
    final (c, engine, _) = await setUpPlayer();
    final p = c.read(playerProvider.notifier);
    await p.playTracks(album);
    await p.next();
    expect(c.read(playerProvider).track!.id, 't2');
    await p.seek(const Duration(seconds: 10));
    await p.previous();
    expect(c.read(playerProvider).track!.id, 't2', reason: 'restarts the song');
    expect(engine.position, Duration.zero);
    await p.previous();
    expect(c.read(playerProvider).track!.id, 't1');
  });

  test('play next goes right after the current song; add to queue after other picks', () async {
    final (c, engine, _) = await setUpPlayer();
    final p = c.read(playerProvider.notifier);
    await p.playTracks(album);
    p.addToQueue(track('x1'));
    await pump();
    p.addToQueue(track('x2'));
    await pump();
    p.playNext(track('x0'));
    await pump();
    final s = c.read(playerProvider);
    expect(s.upNext.map((e) => e.track.id).take(4), ['x0', 'x1', 'x2', 't2']);
    expect(s.upNext.take(3).every((e) => e.fromYou), isTrue);
    expect(engine.loaded, [
      't1',
      'x0',
    ], reason: 'the engine’s next follows the queue');
    p.clearFromYou();
    await pump();
    expect(c.read(playerProvider).upNext.first.track.id, 't2');
    expect(engine.loaded, ['t1', 't2']);
  });

  test('remove and reorder upcoming songs', () async {
    final (c, engine, _) = await setUpPlayer();
    final p = c.read(playerProvider.notifier);
    await p.playTracks(album);
    p.removeAt(1);
    await pump();
    expect(c.read(playerProvider).upNext.map((e) => e.track.id), [
      't3',
      't4',
      't5',
    ]);
    expect(engine.loaded, ['t1', 't3']);
    p.move(3, 1);
    await pump();
    expect(c.read(playerProvider).upNext.map((e) => e.track.id), [
      't5',
      't3',
      't4',
    ]);
    expect(engine.loaded, ['t1', 't5']);
    p.removeAt(0); // can't remove the song that's playing
    expect(c.read(playerProvider).track!.id, 't1');
  });

  test('repeat all wraps to the start; repeat one keeps one song', () async {
    final (c, engine, _) = await setUpPlayer();
    final p = c.read(playerProvider.notifier);
    await p.playTracks(album, start: 4);
    expect(engine.loaded, ['t5']);
    p.setRepeat(RepeatMode.all);
    await pump();
    expect(engine.loaded, ['t5', 't1']);
    p.setRepeat(RepeatMode.one);
    await pump();
    expect(engine.repeatOne, isTrue);
    expect(engine.loaded, ['t5']);
  });

  test('the end of the queue stops on the last song', () async {
    final (c, engine, _) = await setUpPlayer();
    final p = c.read(playerProvider.notifier);
    await p.playTracks(album, start: 4);
    engine.complete();
    expect(c.read(playerProvider).playing, isFalse);
    expect(c.read(playerProvider).track!.id, 't5');
  });

  test(
    'shuffle keeps the current song and can go back to the album order',
    () async {
      final (c, _, _) = await setUpPlayer();
      final p = c.read(playerProvider.notifier);
      await p.playTracks(album);
      p.toggleShuffle();
      var s = c.read(playerProvider);
      expect(s.shuffled, isTrue);
      expect(s.track!.id, 't1');
      expect(s.upNext.map((e) => e.track.id).toSet(), {'t2', 't3', 't4', 't5'});
      p.toggleShuffle();
      s = c.read(playerProvider);
      expect(s.upNext.map((e) => e.track.id), ['t2', 't3', 't4', 't5']);
    },
  );

  test('a quality change applies from the next song', () async {
    final (c, engine, tickets) = await setUpPlayer();
    await c.read(playerProvider.notifier).playTracks(album);
    final settings = c.read(playbackSettingsProvider.notifier);
    await settings.update(
      c.read(playbackSettingsProvider).copyWith(onWifi: QualityMode.dataSaver),
    );
    c.read(currentQualityProvider); // the app flushes providers every frame
    await pump();
    expect(c.read(playerProvider).mode, QualityMode.dataSaver);
    expect(
      tickets.calls,
      contains(('t2', QualityMode.dataSaver, false)),
      reason: tickets.calls.toString(),
    );
    expect(engine.loaded, ['t1', 't2']);
  });

  test('volume levelling turns loud songs down, never above full scale', () {
    expect(levellingGain(null), 1.0);
    const loud = Loudness(integratedLufs: -8, truePeakDbtp: 0.5);
    expect(levellingGain(loud), closeTo(0.501, 0.01)); // -6 dB
    const quiet = Loudness(integratedLufs: -20, truePeakDbtp: -3);
    expect(levellingGain(quiet), 1.0);
    const peaky = Loudness(integratedLufs: -15, truePeakDbtp: 2);
    expect(levellingGain(peaky), closeTo(0.794, 0.01)); // limited by the peak
  });

  test("a failed stream says why, in plain words", () async {
    final (c, _, tickets) = await setUpPlayer();
    tickets.fail = true;
    await c.read(playerProvider.notifier).playTracks(album);
    final s = c.read(playerProvider);
    expect(s.playing, isFalse);
    expect(s.error, contains("Can't reach home"));
  });

  test('engine source urls point at home', () async {
    final (c, engine, _) = await setUpPlayer();
    await c.read(playerProvider.notifier).playTracks(album);
    expect(
      engine.sources.first.uri.toString(),
      'http://100.84.12.7:8443/api/v1/media/stream/t1',
    );
    expect(engine.sources.first, isA<EngineSource>());
  });
}
