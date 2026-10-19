@Tags(['screenshots'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/app.dart';

import 'app_test.dart' show health;
import 'screens_test.dart' show openLibraryAlbum;
import 'support/fake_home.dart';

/// Renders key screens with the real fonts into test/goldens/ for visual review.
/// Run with: flutter test --tags screenshots --update-goldens
Future<void> loadFonts() async {
  final families = <String, List<String>>{
    'Inter': [
      'Inter_400Regular',
      'Inter_500Medium',
      'Inter_600SemiBold',
      'Inter_700Bold',
    ],
    'NotoSansMalayalam': [
      'NotoSansMalayalam_400Regular',
      'NotoSansMalayalam_600SemiBold',
    ],
    'NotoSansDevanagari': [
      'NotoSansDevanagari_400Regular',
      'NotoSansDevanagari_600SemiBold',
    ],
    'Lucide': ['Lucide'],
  };
  for (final entry in families.entries) {
    final loader = FontLoader(entry.key);
    for (final file in entry.value) {
      final bytes = File('assets/fonts/$file.ttf').readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
  }
}

/// Where to go after start-up, before the screenshot.
typedef Steps = Future<void> Function(WidgetTester tester);

Future<void> _play(WidgetTester tester, String album) async {
  await openLibraryAlbum(tester, album);
  await tester.tap(find.text('Play'));
  await tester.pumpAndSettle();
}

final Map<String, (Size, bool, Steps?)> _shots = {
  'phone-connect': (const Size(390, 844), false, null),
  'phone-home': (const Size(390, 844), true, null),
  'phone-search': (
    const Size(390, 844),
    true,
    (t) async {
      await t.tap(find.bySemanticsLabel('Search'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'a');
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
    },
  ),
  'phone-library': (
    const Size(390, 844),
    true,
    (t) async {
      await t.tap(find.bySemanticsLabel('Library'));
      await t.pumpAndSettle();
    },
  ),
  'phone-album': (const Size(390, 844), true, (t) => _play(t, 'Premam')),
  'phone-now-playing': (
    const Size(390, 844),
    true,
    (t) async {
      await _play(t, 'Premam');
      await t.tap(find.bySemanticsLabel(RegExp('^Now playing: ')));
      await t.pumpAndSettle();
    },
  ),
  'phone-signal-path': (
    const Size(390, 844),
    true,
    (t) async {
      await _play(t, 'लगान');
      await t.tap(find.bySemanticsLabel(RegExp('^Now playing: ')));
      await t.pumpAndSettle();
      await t.tap(find.bySemanticsLabel(RegExp('^Quality: ')));
      await t.pumpAndSettle();
    },
  ),
  'phone-queue': (
    const Size(390, 844),
    true,
    (t) async {
      await _play(t, 'Premam');
      await t.tap(find.bySemanticsLabel(RegExp('^Now playing: ')));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Queue'));
      await t.pumpAndSettle();
    },
  ),
  'phone-lyrics': (
    const Size(390, 844),
    true,
    (t) async {
      await _play(t, 'Premam');
      await t.tap(find.bySemanticsLabel(RegExp('^Now playing: ')));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Lyrics'));
      await t.pumpAndSettle();
    },
  ),
  'phone-artist': (
    const Size(390, 844),
    true,
    (t) async {
      await openLibraryAlbum(t, 'Premam');
      await t.tap(find.text('Nivin Pauly'));
      await t.pumpAndSettle();
    },
  ),
  'phone-settings': (
    const Size(390, 844),
    true,
    (t) async {
      await t.tap(find.byKey(const Key('open-settings')));
      await t.pumpAndSettle();
    },
  ),
  'desktop-home': (const Size(1280, 800), true, null),
  'desktop-album-queue': (
    const Size(1280, 800),
    true,
    (t) async {
      await _play(t, 'लगान');
      await t.tap(find.byTooltip('Queue'));
      await t.pumpAndSettle();
    },
  ),
  'desktop-now-playing': (
    const Size(1280, 800),
    true,
    (t) async {
      await _play(t, 'Premam');
      await t.tap(find.byTooltip('Lyrics'));
      await t.pumpAndSettle();
    },
  ),
  'desktop-full-lyrics': (
    const Size(1280, 800),
    true,
    (t) async {
      await _play(t, 'Premam');
      await t.tap(find.byTooltip('Open Now playing'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Lyrics'));
      await t.pumpAndSettle();
    },
  ),
  'desktop-full-player': (
    const Size(1280, 800),
    true,
    (t) async {
      await _play(t, 'Premam');
      await t.tap(find.byTooltip('Open Now playing'));
      await t.pumpAndSettle();
    },
  ),
};

void main() {
  setUpAll(loadFonts);

  for (final dark in [true, false]) {
    for (final MapEntry(key: name, value: (size, saved, steps))
        in _shots.entries) {
      final label = '$name-${dark ? 'dark' : 'light'}';
      testWidgets(label, (tester) async {
        // Tests draw shadows as solid blocks unless told to draw them for real.
        debugDisableShadows = false;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.platformBrightnessTestValue = dark
            ? Brightness.dark
            : Brightness.light;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final overrides = await fakeHomeOverrides(
          check: (_) async => health("Arun's home"),
          connected: saved,
        );
        await tester.pumpWidget(
          ProviderScope(overrides: overrides, child: const HiveApp()),
        );
        await tester.pumpAndSettle();
        try {
          if (steps != null) await steps(tester);
          await expectLater(
            find.byType(HiveApp),
            matchesGoldenFile('goldens/$label.png'),
          );
        } finally {
          debugDisableShadows = true;
        }
      });
    }
  }
}
