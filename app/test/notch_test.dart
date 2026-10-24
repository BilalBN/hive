// M6: song controls by the Mac's notch: the panel hears what's playing and
// its buttons control the player. (The panel itself is the Mac's own code.)
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/app.dart';
import 'package:hive/desktop/desktop.dart';
import 'package:hive/desktop/notch.dart';
import 'package:hive/player/player_controller.dart';

import 'app_test.dart' show health;
import 'support/fake_home.dart';
import 'support/fakes.dart';

void main() {
  testWidgets('the notch panel follows the song and controls it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const channel = MethodChannel('hive/notch');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final overrides = await fakeHomeOverrides(
      check: (_) async => health("Arun's home"),
      engine: FakeEngine(),
    );
    await tester.pumpWidget(
      ProviderScope(overrides: overrides, child: const HiveApp()),
    );
    await tester.pumpAndSettle();
    final c = ProviderScope.containerOf(tester.element(find.byType(HiveApp)));
    await c.read(notchBridgeProvider).start(force: true);
    expect(calls.last.method, 'hide'); // nothing playing

    await c.read(playerProvider.notifier).playTracks(premam.tracks);
    await tester.pumpAndSettle();
    final shown = calls.lastWhere((m) => m.method == 'update');
    final args = (shown.arguments as Map).cast<String, Object?>();
    expect(args['title'], premam.tracks[0].title);
    expect(args['artist'], premam.tracks[0].artistName);
    expect(args['playing'], isTrue);

    // The panel's buttons.
    Future<void> press(String action) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'hive/notch',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('command', action),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    await press('toggle');
    expect(c.read(playerProvider).playing, isFalse);
    expect(
      ((calls.last.arguments as Map)['playing']),
      isFalse,
    ); // the panel shows Play
    await press('next');
    expect(c.read(playerProvider).track!.id, premam.tracks[1].id);

    // Turned off in Settings: the panel goes.
    final settings = c.read(desktopSettingsProvider.notifier);
    await settings.update(
      c.read(desktopSettingsProvider).copyWith(notchControls: false),
    );
    await tester.pumpAndSettle();
    expect(calls.last.method, 'hide');
  });
}
