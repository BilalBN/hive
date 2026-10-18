import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/api/hive_api.g.dart';
import 'package:hive/app.dart';
import 'package:hive/core/home_connection.dart';
import 'package:hive/core/startup.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_home.dart';

Health health(String name) => Health(
  status: 'ok',
  homeName: name,
  serverVersion: '0.1.0',
  apiVersion: '0.1.0',
  minAppVersion: '0.1.0',
  serverTime: DateTime.utc(2026, 10, 18),
);

/// Starts the app against a fake home (see support/fake_home.dart).
Future<void> pumpHive(
  WidgetTester tester, {
  String? savedAddress,
  required HealthCheck check,
  Size size = const Size(390, 844),
  FakeHomeAdapter? adapter,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final overrides = await fakeHomeOverrides(
    check: check,
    adapter: adapter,
    connected: savedAddress != null,
  );
  await tester.pumpWidget(
    ProviderScope(overrides: overrides, child: const HiveApp()),
  );
  await tester.pumpAndSettle();
}

Future<Health> unreachable(Uri _) async =>
    throw HiveApiException(null, null, 'connection refused');

void main() {
  group('parseHomeAddress', () {
    test('adds http and the default port to a bare address', () {
      expect(
        parseHomeAddress('100.84.12.7').toString(),
        'http://100.84.12.7:8443',
      );
    });
    test('keeps an explicit scheme and port', () {
      expect(
        parseHomeAddress(' https://hive-pc.tail1234.ts.net:9000/x ').toString(),
        'https://hive-pc.tail1234.ts.net:9000',
      );
    });
    test('rejects nonsense', () {
      expect(parseHomeAddress(''), isNull);
      expect(parseHomeAddress('ftp://home'), isNull);
      expect(parseHomeAddress('http://'), isNull);
    });
  });

  testWidgets('asks for the home address on first run', (tester) async {
    await pumpHive(tester, check: (_) async => health('Arun\'s home'));
    expect(find.text('Connect to home'), findsOneWidget);
  });

  testWidgets('connecting saves the address and opens Home', (tester) async {
    Uri? asked;
    await pumpHive(
      tester,
      check: (uri) async {
        asked = uri;
        return health("Arun's home");
      },
    );
    await tester.enterText(find.byKey(const Key('address')), '100.84.12.7');
    await tester.enterText(
      find.byKey(const Key('dev-key')),
      'hive-dev-aaaa-bbbb-cccc-dddd',
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(asked.toString(), 'http://100.84.12.7:8443');
    expect(find.text('Connected to home'), findsOneWidget);
    expect(find.text("Arun's home"), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('home.address'), 'http://100.84.12.7:8443');
    expect(
      prefs.getString('home.developmentKey'),
      'hive-dev-aaaa-bbbb-cccc-dddd',
    );
  });

  testWidgets('shows a plain explanation when the address is wrong', (
    tester,
  ) async {
    await pumpHive(tester, check: unreachable);
    await tester.enterText(find.byKey(const Key('address')), '100.84.12.7');
    await tester.enterText(
      find.byKey(const Key('dev-key')),
      'hive-dev-aaaa-bbbb-cccc-dddd',
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.textContaining('may be asleep'), findsOneWidget);
    expect(find.text('Connect to home'), findsOneWidget);
  });

  testWidgets('Home says when home is unreachable, and can try again', (
    tester,
  ) async {
    var up = false;
    await pumpHive(
      tester,
      savedAddress: 'http://100.84.12.7:8443',
      check: (_) async =>
          up ? health("Arun's home") : throw HiveApiException(null, null),
    );
    expect(find.text("Can't reach home right now"), findsOneWidget);
    up = true;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Connected to home'), findsOneWidget);
  });

  testWidgets('tabs switch between Home, Search, Library and Listen', (
    tester,
  ) async {
    await pumpHive(
      tester,
      savedAddress: 'http://100.84.12.7:8443',
      check: (_) async => health('H'),
    );
    await tester.tap(find.bySemanticsLabel('Search'));
    await tester.pumpAndSettle();
    expect(find.text('Songs, albums, artists, playlists'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Library'));
    await tester.pumpAndSettle();
    expect(find.text('Liked songs'), findsOneWidget);
    expect(find.text('Road trip'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Listen'));
    await tester.pumpAndSettle();
    expect(find.text('Arrives in M3'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Home'));
    await tester.pumpAndSettle();
    expect(find.text('Connected to home'), findsOneWidget);
  });

  testWidgets('Settings shows the home connection', (tester) async {
    await pumpHive(
      tester,
      savedAddress: 'http://100.84.12.7:8443',
      check: (_) async => health("Arun's home"),
    );
    expect(find.bySemanticsLabel('Settings'), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text("Arun's home · connected"), findsOneWidget);
    expect(find.text('http://100.84.12.7:8443'), findsOneWidget);
  });

  testWidgets('wide windows get the desktop sidebar and player bar', (
    tester,
  ) async {
    await pumpHive(
      tester,
      savedAddress: 'http://100.84.12.7:8443',
      check: (_) async => health("Arun's home"),
      size: const Size(1280, 800),
    );
    expect(find.text('Hive'), findsOneWidget);
    expect(find.bySemanticsLabel('Settings'), findsWidgets);
    expect(find.text('Nothing playing'), findsOneWidget);
    expect(find.text('Connected to home'), findsOneWidget);
  });

  testWidgets('a startup failure is shown instead of a frozen launch screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      StartupFailedApp(error: TimeoutException('settings took too long')),
    );
    expect(find.text("Hive couldn't start"), findsOneWidget);
    expect(find.textContaining('settings took too long'), findsOneWidget);
  });
}
