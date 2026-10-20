import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/api/hive_api.g.dart';
import 'package:hive/app.dart';
import 'package:hive/listen/listen.dart';

import 'app_test.dart' show health;
import 'support/fake_home.dart';

class FakeRecorder implements ClipRecorder {
  bool allowed = true;
  int starts = 0;
  @override
  Future<bool> permission() async => allowed;
  @override
  Future<void> start() async => starts++;
  @override
  Future<Uint8List?> stop() async => Uint8List.fromList(List.filled(4096, 1));
  @override
  Future<void> cancel() async {}
  @override
  Stream<double> level() => const Stream.empty();
}

Future<void> pumpListen(
  WidgetTester tester, {
  required ClipMatcher matcher,
  FakeRecorder? recorder,
  FakeHomeAdapter? adapter,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = adapter ?? FakeHomeAdapter();
  fake.extra['GET /api/v1/listen/history'] ??= (o) =>
      const ListenHistory(items: []).toJson();
  final overrides = await fakeHomeOverrides(
    check: (_) async => health("Arun's home"),
    adapter: fake,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...overrides,
        clipRecorderProvider.overrideWithValue(recorder ?? FakeRecorder()),
        clipMatcherProvider.overrideWithValue(matcher),
      ],
      child: const HiveApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.bySemanticsLabel('Listen'));
  await tester.pumpAndSettle();
}

Future<void> listenFor8Seconds(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('Start listening'));
  await tester.pump();
  expect(find.text('Listening…'), findsOneWidget);
  for (var i = 0; i < 9; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a song at home is found, and plays from where it is', (
    tester,
  ) async {
    await pumpListen(
      tester,
      matcher: (clip) async => ListenResult(
        id: 1,
        matched: true,
        source: 'library',
        track: premam.tracks[0],
        positionMs: 102000,
        confidence: 0.9,
      ),
    );
    expect(find.text('Tap to listen'), findsOneWidget);
    await listenFor8Seconds(tester);
    expect(find.text('മലരേ'), findsWidgets);
    expect(find.text('Play from 1:42'), findsOneWidget);
    await tester.tap(find.text('Play from 1:42'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(RegExp('^Now playing: മലരേ')), findsOneWidget);
  });

  testWidgets('a song not at home can be asked for', (tester) async {
    final fake = FakeHomeAdapter();
    Map<String, dynamic>? asked;
    fake.extra['POST /api/v1/listen/requests'] = (o) {
      asked =
          (o.data is String ? jsonDecode(o.data as String) : o.data)
              as Map<String, dynamic>;
      return SongRequest(
        id: 'sr1',
        at: DateTime.utc(2026, 10, 20),
        source: 'listen',
        status: 'waiting',
      ).toJson();
    };
    await pumpListen(
      tester,
      adapter: fake,
      matcher: (clip) async =>
          const ListenResult(id: 7, matched: false, source: 'library'),
    );
    await listenFor8Seconds(tester);
    expect(find.text('Not in your music yet'), findsOneWidget);
    await tester.tap(find.text('Ask to add it'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('request-title')), 'Pesamale');
    await tester.enterText(
      find.byKey(const Key('request-note')),
      'On the radio',
    );
    await tester.tap(find.text('Send request'));
    await tester.pumpAndSettle();
    expect(asked, {
      'source': 'listen',
      'title': 'Pesamale',
      'note': 'On the radio',
      'listenEventId': 7,
    });
    expect(find.textContaining('Asked.'), findsOneWidget);
  });

  testWidgets('without the microphone it says how to allow it', (tester) async {
    await pumpListen(
      tester,
      recorder: FakeRecorder()..allowed = false,
      matcher: (clip) async => throw StateError('not called'),
    );
    await tester.tap(find.bySemanticsLabel('Start listening'));
    await tester.pumpAndSettle();
    expect(find.text('Hive needs the microphone'), findsOneWidget);
  });

  testWidgets('home unreachable while matching says so plainly', (
    tester,
  ) async {
    await pumpListen(
      tester,
      matcher: (clip) async => throw HiveApiException(
        null,
        null,
        DioException(requestOptions: RequestOptions()),
      ),
    );
    await listenFor8Seconds(tester);
    expect(find.text("That didn't work"), findsOneWidget);
    expect(find.textContaining("Can't reach home"), findsOneWidget);
  });
}
