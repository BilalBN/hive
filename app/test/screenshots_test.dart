@Tags(['screenshots'])
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/app.dart';
import 'package:hive/core/home_connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_test.dart' show health;

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

void main() {
  setUpAll(loadFonts);

  for (final dark in [true, false]) {
    for (final (name, size, saved) in [
      ('phone-home', const Size(390, 844), true),
      ('phone-connect', const Size(390, 844), false),
      ('desktop-home', const Size(1280, 800), true),
    ]) {
      final label = '$name-${dark ? 'dark' : 'light'}';
      testWidgets(label, (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.platformBrightnessTestValue = dark
            ? Brightness.dark
            : Brightness.light;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        SharedPreferences.setMockInitialValues(
          saved ? {'home.address': 'http://100.84.12.7:8443'} : {},
        );
        final prefs = await SharedPreferences.getInstance();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              healthCheckProvider.overrideWithValue(
                (_) async => health("Arun's home"),
              ),
            ],
            child: const HiveApp(),
          ),
        );
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(HiveApp),
          matchesGoldenFile('goldens/$label.png'),
        );
      });
    }
  }
}
