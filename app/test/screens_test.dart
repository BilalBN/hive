import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/app.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/core/home_connection.dart';
import 'package:hive/player/player_controller.dart';

import 'app_test.dart' show health, pumpHive;
import 'support/fake_home.dart';

Future<void> openLibraryAlbum(WidgetTester tester, String title) async {
  await tester.tap(find.bySemanticsLabel('Library'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Albums'));
  await tester.pumpAndSettle();
  await tester.tap(
    find.bySemanticsLabel(RegExp('^Album: ${RegExp.escape(title)}')),
  );
  await tester.pumpAndSettle();
}

Future<void> pumpConnected(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  FakeHomeAdapter? adapter,
}) => pumpHive(
  tester,
  savedAddress: 'http://100.84.12.7:8443',
  check: (_) async => health("Arun's home"),
  size: size,
  adapter: adapter,
);

ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(HiveApp)));

void main() {
  testWidgets('Home shows what you played, new albums and playlists', (
    tester,
  ) async {
    await pumpConnected(tester);
    expect(find.text('Premam'), findsWidgets);
    expect(find.text('Road trip'), findsWidgets);
  });

  testWidgets('Home is never bare: songs you played, picks, films, artists', (
    tester,
  ) async {
    await pumpConnected(tester);
    expect(find.text('Recently played'), findsOneWidget);
    expect(find.text('Picked for you'), findsOneWidget);
    final home = find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Artists'),
      300,
      scrollable: home,
    );
    expect(find.text('From the movies'), findsOneWidget);
    expect(find.text('Artists'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Recently played'),
      -300,
      scrollable: home,
    );
    // A recently played song plays from Home, with the rest of the row next.
    await tester.tap(find.bySemanticsLabel(RegExp('^Song: മലരേ')));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('^Now playing: മലരേ')), findsOneWidget);
    final s = containerOf(tester).read(playerProvider);
    expect(s.upNext.map((e) => e.track.title), ['मितवा']);
    expect(s.source!.name, 'Recently played');
  });

  testWidgets('search finds a Malayalam song and plays it', (tester) async {
    await pumpConnected(tester);
    await tester.tap(find.bySemanticsLabel('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'മലരേ');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Songs'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel(RegExp('^മലരേ, Rajesh Murugesan')));
    await tester.pumpAndSettle();
    // The mini player appears with the song.
    expect(find.bySemanticsLabel(RegExp('^Now playing: മലരേ')), findsOneWidget);
  });

  testWidgets('search says plainly when nothing matches', (tester) async {
    await pumpConnected(tester);
    await tester.tap(find.bySemanticsLabel('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Nothing found for "zzzz"'), findsOneWidget);
  });

  testWidgets('album → play → Now playing shows the badge, queue and lyrics', (
    tester,
  ) async {
    await pumpConnected(tester);
    await openLibraryAlbum(tester, 'Premam');
    expect(find.text('Rajesh Murugesan'), findsWidgets);
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel(RegExp('^Now playing: മലരേ')));
    await tester.pumpAndSettle();
    expect(find.text('PLAYING FROM'), findsOneWidget);
    expect(find.text('LOSSLESS 16/44.1'), findsOneWidget);

    // The badge explains how the song reaches you.
    await tester.tap(find.bySemanticsLabel(RegExp('^Quality: Lossless')));
    await tester.pumpAndSettle();
    expect(find.text('How this song reaches you'), findsOneWidget);
    expect(find.text("You're hearing the original file."), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();
    expect(find.text('NEXT FROM PREMAM'), findsOneWidget);
    expect(find.text('ആലുവ പുഴ'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Lyrics'));
    await tester.pumpAndSettle();
    expect(find.text('മലരേ നിന്നെ കാണാതിരുന്നാൽ'), findsOneWidget);
  });

  testWidgets('Play next puts a song right after the current one', (
    tester,
  ) async {
    await pumpConnected(tester);
    await openLibraryAlbum(tester, 'Premam');
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    // ⋯ on the last song → Play next.
    await tester.ensureVisible(find.byTooltip('More').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play next'));
    await tester.pumpAndSettle();
    final container = containerOf(tester);
    final s = container.read(playerProvider);
    expect(s.upNext.first.track.title, 'Kalippu');
    expect(s.upNext.first.fromYou, isTrue);
  });

  testWidgets('computers: player bar, queue panel and keyboard', (
    tester,
  ) async {
    await pumpConnected(tester, size: const Size(1280, 800));
    await openLibraryAlbum(tester, 'लगान');
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(find.text('घनन घनन'), findsWidgets);

    await tester.tap(find.byTooltip('Queue'));
    await tester.pumpAndSettle();
    expect(find.text('NEXT FROM लगान'), findsOneWidget);

    final container = containerOf(tester);
    expect(container.read(playerProvider).playing, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(container.read(playerProvider).playing, isFalse);
    expect(container.read(playerProvider).repeat, RepeatMode.off);
  });

  testWidgets('Settings lets you choose quality per network', (tester) async {
    await pumpConnected(tester);
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    expect(find.text('On Wi-Fi'), findsOneWidget);
    expect(find.text('Lossless'), findsOneWidget);
    await tester.tap(find.text('On mobile data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Data saver'));
    await tester.pumpAndSettle();
    expect(find.text('Data saver'), findsOneWidget);
  });

  testWidgets('language chips filter Home, and the choice is remembered', (
    tester,
  ) async {
    await pumpConnected(tester);
    expect(find.text('All'), findsOneWidget);
    expect(find.text('Malayalam'), findsOneWidget);
    expect(find.text('Picked for you'), findsOneWidget);
    expect(find.text('Premam'), findsWidgets);
    await tester.tap(find.text('Hindi'));
    await tester.pumpAndSettle();
    expect(find.text('Premam'), findsNothing);
    expect(find.text('लगान'), findsWidgets);
    final prefs = containerOf(tester).read(sharedPreferencesProvider);
    expect(prefs.getString('library.language'), 'hi');
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(find.text('Premam'), findsWidgets);
    expect(prefs.getString('library.language'), isNull);
  });

  testWidgets('album pages show the film, cast and music, and open people', (
    tester,
  ) async {
    await pumpConnected(tester);
    await openLibraryAlbum(tester, 'Premam');
    expect(find.text('FILM SOUNDTRACK'), findsOneWidget);
    expect(find.textContaining('Malayalam'), findsWidgets);
    expect(find.text('Directed by '), findsOneWidget);
    expect(find.text('Alphonse Puthren'), findsOneWidget);
    expect(find.text('Starring '), findsOneWidget);
    expect(find.text('Lyrics by '), findsOneWidget);
    await tester.tap(find.text('Nivin Pauly'));
    await tester.pumpAndSettle();
    expect(find.text('ACTOR'), findsOneWidget);
    expect(find.text('Films'), findsOneWidget);
  });
}
