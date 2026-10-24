import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/app.dart';
import 'package:hive/player/player_controller.dart';
import 'package:hive/ui/preferences.dart';

import 'app_test.dart' show health;
import 'support/fake_home.dart';

Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  Map<String, Object> prefs = const {},
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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

void main() {
  testWidgets('Simple mode: big buttons that start music at once', (
    tester,
  ) async {
    final c = await pumpApp(tester, prefs: {'app.simpleMode': true});
    expect(find.bySemanticsLabel('Play my favourites'), findsOneWidget);
    expect(find.text('Recently played'), findsNothing); // no rows to browse
    await tester.tap(find.bySemanticsLabel('Play my favourites'));
    await tester.pumpAndSettle();
    final player = c.read(playerProvider);
    expect(player.track!.id, premam.tracks[0].id); // the one liked song
    expect(player.source?.kind, 'liked');
  });

  testWidgets('a "Play again" tile plays it, without opening a page', (
    tester,
  ) async {
    final c = await pumpApp(tester, prefs: {'app.simpleMode': true});
    final tile = find.bySemanticsLabel(RegExp(r'^Play Premam$'));
    await tester.scrollUntilVisible(
      tile,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(c.read(playerProvider).queue.length, premam.tracks.length);
  });

  testWidgets('Settings: Simple mode and appearance on this device', (
    tester,
  ) async {
    final c = await pumpApp(tester);
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    final simple = find.widgetWithText(SwitchListTile, 'Simple mode');
    await tester.scrollUntilVisible(
      simple,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(simple);
    await tester.pumpAndSettle();
    expect(c.read(simpleModeProvider), isTrue);

    await tester.scrollUntilVisible(
      find.text('Appearance'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(c.read(appearanceProvider), Appearance.dark);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);
  });
}
