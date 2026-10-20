import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/api/hive_api.g.dart';
import 'package:hive/app.dart';
import 'package:hive/core/home_connection.dart';
import 'package:hive/downloads/downloads.dart';
import 'package:hive/downloads/vault.dart';

import 'app_test.dart' show health;
import 'screens_test.dart' show openLibraryAlbum;
import 'support/fake_home.dart';
import 'support/fakes.dart';

/// The app with a fake home whose reachability the test switches.
Future<(MemoryVault, FakeDownloadTransport, FakeEngine, ValueNotifier<bool>)>
pumpWithDownloads(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final vault = MemoryVault();
  final net = FakeDownloadTransport();
  final engine = FakeEngine();
  final online = ValueNotifier(true);
  final overrides = await fakeHomeOverrides(
    check: (_) async => online.value
        ? health("Arun's home")
        : throw HiveApiException(null, null, 'connection refused'),
    vault: vault,
    downloads: net,
    engine: engine,
  );
  await tester.pumpWidget(
    ProviderScope(overrides: overrides, child: const HiveApp()),
  );
  await tester.pumpAndSettle();
  return (vault, net, engine, online);
}

Future<void> openDownloadsChip(WidgetTester tester) async {
  final chip = find.widgetWithText(ChoiceChip, 'Downloads');
  await tester.dragUntilVisible(
    chip,
    find.byType(ListView).first,
    const Offset(-150, 0),
  );
  await tester.pumpAndSettle();
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(HiveApp)));

void main() {
  testWidgets('an album downloads from its page and plays with home off', (
    tester,
  ) async {
    final (vault, net, engine, online) = await pumpWithDownloads(tester);
    await openLibraryAlbum(tester, 'Premam');
    await tester.tap(find.byTooltip('Download'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Downloaded'), findsOneWidget);
    expect(vault.songs.length, premam.tracks.length);
    expect(find.bySemanticsLabel(RegExp(', downloaded')), findsWidgets);

    // Home goes away.
    online.value = false;
    await containerOf(tester).read(homeStatusProvider.notifier).check();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await openDownloadsChip(tester);
    expect(
      find.textContaining('${premam.tracks.length} songs ·'),
      findsWidgets,
    );
    await tester.tap(find.text('Premam').last);
    await tester.pumpAndSettle();
    expect(find.text('DOWNLOADED'), findsOneWidget);
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(engine.sources.first.uri.scheme, downloadScheme);
    expect(
      find.bySemanticsLabel(RegExp('^Now playing: ${premam.tracks[0].title}')),
      findsOneWidget,
    );
  });

  testWidgets('Home points to downloads when home is unreachable', (
    tester,
  ) async {
    final (_, _, _, online) = await pumpWithDownloads(tester);
    final c = containerOf(tester);
    await c.read(downloadsProvider.notifier).downloadTrack(premam.tracks[1]);
    await tester.pumpAndSettle();
    online.value = false;
    await c.read(homeStatusProvider.notifier).check();
    await tester.pumpAndSettle();
    expect(find.textContaining('Your downloads still play.'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Downloads'));
    await tester.pumpAndSettle();
    expect(find.text('Songs'), findsOneWidget);
    expect(find.text(premam.tracks[1].title), findsOneWidget);
  });

  testWidgets('a song downloads from its actions, and is removed again', (
    tester,
  ) async {
    final (vault, _, _, _) = await pumpWithDownloads(tester);
    await openLibraryAlbum(tester, 'Premam');
    final song = premam.tracks[0];
    await tester.drag(
      find.byType(CustomScrollView).last,
      const Offset(0, -250),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text(song.title));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(vault.songs.keys, [song.id]);
    await tester.longPress(find.text(song.title));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove download'));
    await tester.pumpAndSettle();
    expect(vault.songs, isEmpty);
  });

  testWidgets('with nothing downloaded, Downloads says how to start', (
    tester,
  ) async {
    await pumpWithDownloads(tester);
    await tester.tap(find.bySemanticsLabel('Library'));
    await tester.pumpAndSettle();
    await openDownloadsChip(tester);
    expect(find.text('No downloads yet'), findsOneWidget);
  });
}
