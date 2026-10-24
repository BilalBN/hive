// M6: moving playback between devices and using a phone as a remote.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/api/hive_api.g.dart';
import 'package:hive/app.dart';
import 'package:hive/player/player_controller.dart';
import 'package:hive/sync/continuity.dart';
import 'package:hive/sync/remote.dart';

import 'app_test.dart' show health;
import 'support/fake_home.dart';
import 'support/fakes.dart';

const mac = 'mac-install-01';

Device theMac({bool playing = false, TrackSummary? track, int position = 0}) =>
    Device(
      installId: mac,
      deviceName: "Bilal's MacBook",
      playing: playing,
      track: track,
      positionMs: track == null ? null : position,
    );

Future<(FakeSessionLink, ProviderContainer)> pumpApp(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final link = FakeSessionLink()..open = [theMac()];
  final overrides = await fakeHomeOverrides(
    check: (_) async => health("Arun's home"),
    sessions: link,
    engine: FakeEngine(),
  );
  await tester.pumpWidget(
    ProviderScope(overrides: overrides, child: const HiveApp()),
  );
  await tester.pumpAndSettle();
  return (
    link,
    ProviderScope.containerOf(tester.element(find.byType(HiveApp))),
  );
}

void main() {
  testWidgets('another device can tell this one what to play', (tester) async {
    final (link, c) = await pumpApp(tester);
    link.say(
      CommandReceived(
        "Bilal's Pixel",
        RemoteCommand(
          action: 'load',
          queue: premam.tracks,
          index: 1,
          positionMs: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(c.read(playerProvider).track!.id, premam.tracks[1].id);
    expect(c.read(playerProvider).playing, isTrue);

    link.say(
      const CommandReceived("Bilal's Pixel", RemoteCommand(action: 'pause')),
    );
    await tester.pumpAndSettle();
    expect(c.read(playerProvider).playing, isFalse);
    link.say(
      const CommandReceived("Bilal's Pixel", RemoteCommand(action: 'next')),
    );
    await tester.pumpAndSettle();
    expect(c.read(playerProvider).track!.id, premam.tracks[2].id);
  });

  testWidgets('move what plays here to the Mac, use the phone as its remote, '
      'then bring it back', (tester) async {
    final (link, c) = await pumpApp(tester);
    await c.read(playerProvider.notifier).playTracks(premam.tracks, start: 1);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel(RegExp('^Now playing:')));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Play on another device'));
    await tester.pumpAndSettle();
    expect(find.text('Play on'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(RegExp("^Bilal's MacBook")));
    await tester.pumpAndSettle();

    final (to, load) = link.sent.single;
    expect(to, mac);
    expect(load.action, 'load');
    expect(load.queue, [for (final t in premam.tracks) t.id]);
    expect(load.index, 1);
    expect(c.read(playerProvider).playing, isFalse); // paused here
    expect(find.text("Playing on Bilal's MacBook"), findsWidgets);

    // The Mac says it's playing; the remote follows and controls it.
    link.say(
      DeviceChanged(
        theMac(playing: true, track: premam.tracks[1], position: 5000),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(premam.tracks[1].title), findsWidgets);
    await tester.tap(find.byTooltip('Pause').first);
    await tester.pumpAndSettle();
    expect(link.sent.last.$2.action, 'pause');
    await tester.tap(find.byTooltip('Next').first);
    expect(link.sent.last.$2.action, 'next');

    // Back here, from where the Mac was; the Mac pauses.
    link.say(
      DeviceChanged(
        theMac(playing: true, track: premam.tracks[1], position: 30000),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play here instead'));
    await tester.pumpAndSettle();
    final p = c.read(playerProvider);
    expect(p.track!.id, premam.tracks[1].id);
    expect(p.position.inSeconds, greaterThanOrEqualTo(30));
    expect(link.sent.last.$2.action, 'pause');
    expect(c.read(remoteProvider).target, isNull);
  });

  testWidgets('the remote bar shows while controlling another device', (
    tester,
  ) async {
    final (link, c) = await pumpApp(tester);
    await c.read(remoteProvider.notifier).refresh();
    c.read(remoteProvider.notifier).control(mac);
    link.say(DeviceChanged(theMac(playing: true, track: premam.tracks[0])));
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel(RegExp("^Playing on Bilal's MacBook: ")),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Pause'));
    await tester.pumpAndSettle();
    expect(link.sent.single.$2.action, 'pause');

    // The Mac closes Hive: no longer controlled.
    link.open = [];
    link.say(const DevicesChanged());
    await tester.pumpAndSettle();
    expect(c.read(remoteProvider).target, isNull);
    expect(
      find.bySemanticsLabel(RegExp("^Playing on Bilal's MacBook")),
      findsNothing,
    );
  });
}
