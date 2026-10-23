import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/api/hive_api.g.dart';
import 'package:hive/app.dart';
import 'package:hive/player/player_controller.dart';
import 'package:hive/sync/continuity.dart';

import 'app_test.dart' show health;
import 'support/fake_home.dart';
import 'support/fakes.dart';

PlaySession fromTheMac({
  bool playing = false,
  String install = 'mac-install-01',
}) => PlaySession(
  installId: install,
  deviceName: "Bilal's MacBook",
  track: premam.tracks[1],
  positionMs: 102000,
  playing: playing,
  queue: premam.tracks,
  index: 1,
  source: SessionSource(kind: 'album', id: premam.id, name: premam.title),
  updatedAt: DateTime.now().toUtc(),
  offer: true,
);

Future<(FakeSessionLink, FakeEngine)> pumpApp(
  WidgetTester tester, {
  PlaySession? session,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final link = FakeSessionLink()..session = session;
  final engine = FakeEngine();
  final overrides = await fakeHomeOverrides(
    check: (_) async => health("Arun's home"),
    sessions: link,
    engine: engine,
  );
  await tester.pumpWidget(
    ProviderScope(overrides: overrides, child: const HiveApp()),
  );
  await tester.pumpAndSettle();
  return (link, engine);
}

ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(HiveApp)));

void main() {
  testWidgets('another device\'s song is offered, and carries on from there', (
    tester,
  ) async {
    final (_, engine) = await pumpApp(tester, session: fromTheMac());
    expect(find.textContaining("From Bilal's MacBook · 1:42"), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    final player = containerOf(tester).read(playerProvider);
    expect(player.track!.id, premam.tracks[1].id);
    expect(player.queue.length, premam.tracks.length);
    expect(engine.position, const Duration(milliseconds: 102000));
    expect(player.source?.name, premam.title);
    expect(find.text('Continue'), findsNothing);
  });

  testWidgets('not offered from this device, nor once dismissed', (
    tester,
  ) async {
    final (link, _) = await pumpApp(tester, session: fromTheMac());
    await tester.tap(find.byTooltip('Not now'));
    await tester.pumpAndSettle();
    expect(find.text('Continue'), findsNothing);
    // This app's own session isn't offered back to it.
    final mine = containerOf(tester).read(installIdProvider);
    link.push(fromTheMac(install: mine));
    await tester.pumpAndSettle();
    expect(find.text('Continue'), findsNothing);
  });

  testWidgets('a change on another device shows up straight away', (
    tester,
  ) async {
    final (link, _) = await pumpApp(tester);
    expect(find.text('Continue'), findsNothing);
    link.push(fromTheMac(playing: true));
    await tester.pumpAndSettle();
    expect(find.textContaining("Playing on Bilal's MacBook"), findsOneWidget);
  });

  testWidgets('what plays here is reported for your other devices', (
    tester,
  ) async {
    final (link, _) = await pumpApp(tester);
    final c = containerOf(tester);
    await c.read(playerProvider.notifier).playTracks(premam.tracks, start: 2);
    await tester.pump(const Duration(seconds: 2));
    final last = link.reports.last;
    expect(last.trackId, premam.tracks[2].id);
    expect(last.playing, isTrue);
    expect(last.queue, [for (final t in premam.tracks) t.id]);
    expect(last.index, 2);
    expect(last.installId, c.read(installIdProvider));
    // Nothing is offered while something plays here.
    link.push(fromTheMac());
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Continue'), findsNothing);
    await c.read(playerProvider.notifier).stop();
    await tester.pumpAndSettle();
  });
}
