// M6: a song's music video plays from where the song was, and the song
// carries on from where the video got to.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/api/hive_api.g.dart';
import 'package:hive/app.dart';
import 'package:hive/features/video/video_screen.dart';
import 'package:hive/player/player_controller.dart';

import 'app_test.dart' show health;
import 'support/fake_home.dart';
import 'support/fakes.dart';

class FakeVideo extends ChangeNotifier implements VideoHandle {
  FakeVideo(this.url);
  final Uri url;
  Duration at = Duration.zero;
  bool on = false;

  @override
  Future<void> start(Duration from) async {
    at = from;
    on = true;
    notifyListeners();
  }

  @override
  Future<void> play() async => on = true;
  @override
  Future<void> pause() async => on = false;
  @override
  Future<void> seek(Duration to) async => at = to;
  @override
  Duration get position => at;
  @override
  Duration get duration => const Duration(minutes: 4);
  @override
  bool get playing => on;
  @override
  double get aspectRatio => 16 / 9;
  @override
  Listenable get changes => this;
  @override
  Widget view() => const ColoredBox(color: Colors.blue, key: Key('the-video'));
  @override
  Future<void> dispose() async => super.dispose();
}

TrackSummary withVideo(TrackSummary t) =>
    TrackSummary.fromJson({...t.toJson(), 'videoId': 'video-1'});

void main() {
  testWidgets('watch the video from where the song is, then back to the song', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final adapter = FakeHomeAdapter();
    final song = withVideo(premam.tracks[0]);
    adapter.extra['POST /api/v1/media/tracks/${song.id}/video'] = (o) =>
        VideoTicket(
          url: '/api/v1/media/video/ticket-1',
          expiresAt: DateTime.utc(2026, 10, 24, 12),
          mimeType: 'video/mp4',
          sizeBytes: 1000,
          durationMs: 240000,
        ).toJson();
    FakeVideo? video;
    final overrides = await fakeHomeOverrides(
      check: (_) async => health("Arun's home"),
      adapter: adapter,
      engine: FakeEngine(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...overrides,
          videoHandleFactory.overrideWithValue((url) => video = FakeVideo(url)),
        ],
        child: const HiveApp(),
      ),
    );
    await tester.pumpAndSettle();
    final c = ProviderScope.containerOf(tester.element(find.byType(HiveApp)));
    final player = c.read(playerProvider.notifier);
    await player.playTracks([song, premam.tracks[1]]);
    await player.seek(const Duration(seconds: 42));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel(RegExp('^Now playing:')));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Watch the video'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('the-video')), findsOneWidget);
    expect(video!.url.path, '/api/v1/media/video/ticket-1');
    expect(video!.at, const Duration(seconds: 42)); // from where the song was
    expect(c.read(playerProvider).playing, isFalse); // the song waits

    video!.at = const Duration(seconds: 80);
    await tester.tap(find.byTooltip('Back to the song'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('the-video')), findsNothing);
    expect(c.read(playerProvider).position, const Duration(seconds: 80));
    expect(c.read(playerProvider).playing, isTrue);
  });

  testWidgets('no video, no button', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final overrides = await fakeHomeOverrides(
      check: (_) async => health("Arun's home"),
      engine: FakeEngine(),
    );
    await tester.pumpWidget(
      ProviderScope(overrides: overrides, child: const HiveApp()),
    );
    await tester.pumpAndSettle();
    final c = ProviderScope.containerOf(tester.element(find.byType(HiveApp)));
    await c.read(playerProvider.notifier).playTracks(premam.tracks);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel(RegExp('^Now playing:')));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Watch the video'), findsNothing);
  });
}
