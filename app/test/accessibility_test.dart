// The VoiceOver / TalkBack pass (M5): every main screen, on a phone, an iPad
// and with large text, meets Flutter's accessibility guidelines: everything
// you can tap says what it is, tap targets are big enough for fingers, text
// has enough contrast in light and dark, and nothing overflows.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/app.dart';
import 'package:hive/player/player_controller.dart';

import 'app_test.dart' show health;
import 'support/fake_home.dart';

const phone = Size(390, 844);
const ipad = Size(834, 1194);
const ipadLandscape = Size(1194, 834);

Future<ProviderContainer> pumpAt(
  WidgetTester tester,
  Size size, {
  double textScale = 1,
  Map<String, Object> prefs = const {},
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final overrides = await fakeHomeOverrides(
    check: (_) async => health("Arun's home"),
    prefs: prefs,
  );
  await tester.pumpWidget(
    ProviderScope(overrides: overrides, child: const HiveApp()),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(HiveApp)));
}

Future<void> go(WidgetTester tester, String path) async {
  GoRouter.of(tester.element(find.byType(Navigator).first)).go(path);
  await tester.pumpAndSettle();
}

/// Problems found, all reported at the end of a test.
final problems = <String>[];

Future<void> meetsAll(WidgetTester tester, String where) async {
  final handle = tester.ensureSemantics();
  for (final (name, guideline) in [
    ('labelled', labeledTapTargetGuideline),
    ('tap size', iOSTapTargetGuideline),
    ('contrast', textContrastGuideline),
  ]) {
    final result = await guideline.evaluate(tester);
    if (!result.passed) problems.add('$where · $name:\n${result.reason}');
  }
  handle.dispose();
}

void reportProblems() {
  final found = [...problems];
  problems.clear();
  expect(found, isEmpty, reason: found.join('\n\n'));
}

const screens = ['/home', '/search', '/library', '/listen', '/settings'];

void main() {
  for (final (label, size, scale) in [
    ('phone', phone, 1.0),
    ('iPad', ipad, 1.0),
    ('iPad landscape', ipadLandscape, 1.0),
    ('phone, large text', phone, 1.6),
  ]) {
    testWidgets('main screens: $label', (tester) async {
      final c = await pumpAt(tester, size, textScale: scale);
      for (final path in screens) {
        await go(tester, path);
        expect(tester.takeException(), isNull, reason: '$label $path');
        await meetsAll(tester, '$label $path');
      }
      // Something playing: the mini player / player bar, then Now playing.
      await c.read(playerProvider.notifier).playTracks(premam.tracks);
      await tester.pumpAndSettle();
      await go(tester, '/home');
      await meetsAll(tester, '$label home, playing');
      await go(tester, '/now-playing');
      expect(tester.takeException(), isNull, reason: '$label now playing');
      await meetsAll(tester, '$label now playing');
      reportProblems();
    });
  }

  testWidgets('dark appearance: contrast', (tester) async {
    await pumpAt(tester, phone, prefs: {'app.appearance': 'dark'});
    for (final path in screens) {
      await go(tester, path);
      final result = await textContrastGuideline.evaluate(tester);
      if (!result.passed) problems.add('dark $path:\n${result.reason}');
    }
    reportProblems();
  });

  testWidgets('Simple mode: phone and large text', (tester) async {
    await pumpAt(tester, phone, textScale: 1.6, prefs: {'app.simpleMode': true});
    expect(tester.takeException(), isNull);
    await meetsAll(tester, 'simple home');
    reportProblems();
  });
}
