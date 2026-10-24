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
import 'package:hive/listen/shazam.dart';

import 'app_test.dart' show health;
import 'support/fake_home.dart';

/// A microphone that hears a tenth of a second of sound every 100 ms.
class FakeRecorder implements ClipRecorder {
  bool allowed = true;
  int starts = 0;
  bool on = false;
  StreamController<Uint8List>? _out;
  Timer? _t;

  @override
  Future<bool> permission() async => allowed;

  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    on = true;
    _out = StreamController<Uint8List>();
    _t = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _out?.add(Uint8List(listenRate * 2 ~/ 10)),
    );
    return _out!.stream;
  }

  @override
  Future<void> stop() async {
    on = false;
    _t?.cancel();
    await _out?.close();
  }
}

/// Answers each check in turn; the last answer repeats. Records the clip
/// lengths (seconds) and whether each was the last try.
class Checks {
  Checks(this.answers);
  final List<ListenResult> answers;
  final asked = <(double, bool)>[];

  Future<ListenResult> call(Uint8List clip, {required bool last}) async {
    asked.add(((clip.length - 44) / (listenRate * 2), last));
    return answers[(asked.length - 1).clamp(0, answers.length - 1)];
  }
}

const miss = ListenResult(matched: false, source: 'library');

/// Shazam on the device: knows [hit] (or nothing).
class FakeShazam implements ShazamLink {
  FakeShazam({this.hit, this.here = true});
  final ShazamHit? hit;
  final bool here;
  int asked = 0;

  @override
  Future<bool> available() async => here;

  @override
  Future<ShazamHit?> match(Uint8List pcm, {required int rate}) async {
    asked++;
    return hit;
  }
}

Future<void> pumpListen(
  WidgetTester tester, {
  required ClipMatcher matcher,
  FakeRecorder? recorder,
  FakeHomeAdapter? adapter,
  bool shazamOn = false,
  ShazamLink? shazam,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = adapter ?? FakeHomeAdapter();
  fake.extra['GET /api/v1/listen/history'] ??= (o) =>
      const ListenHistory(items: []).toJson();
  fake.extra['GET /api/v1/listen/options'] ??= (o) =>
      ListenOptions(shazam: shazamOn, shazamAndroid: shazamOn).toJson();
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
        shazamLinkProvider.overrideWithValue(shazam ?? FakeShazam()),
      ],
      child: const HiveApp(),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.bySemanticsLabel('Listen'));
  await tester.pumpAndSettle();
}

Future<void> listenFor(WidgetTester tester, Duration d) async {
  await tester.tap(find.bySemanticsLabel('Start listening'));
  await tester.pump();
  expect(find.text('Listening…'), findsOneWidget);
  for (var t = Duration.zero; t < d; t += const Duration(milliseconds: 250)) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  await tester.pump(const Duration(seconds: 1));
}

/// Long enough for Listen to give up and make its last try.
Future<void> listenUntilDone(WidgetTester tester) =>
    listenFor(tester, giveUpAfter + const Duration(seconds: 1));

void main() {
  testWidgets('a song at home is found, and plays from where it is', (
    tester,
  ) async {
    await pumpListen(
      tester,
      matcher: (clip, {required last}) async => ListenResult(
        id: 1,
        matched: true,
        source: 'library',
        track: premam.tracks[0],
        positionMs: 102000,
        confidence: 0.9,
      ),
    );
    expect(find.text('Tap to listen'), findsOneWidget);
    await listenUntilDone(tester);
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
      matcher: (clip, {required last}) async =>
          const ListenResult(id: 7, matched: false, source: 'library'),
    );
    await listenUntilDone(tester);
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

  testWidgets('a found song can go straight into a playlist', (tester) async {
    await pumpListen(
      tester,
      matcher: (clip, {required last}) async => ListenResult(
        id: 1,
        matched: true,
        source: 'library',
        track: premam.tracks[0],
        positionMs: 1000,
      ),
    );
    await listenUntilDone(tester);
    expect(find.text('Play from 1:42'), findsNothing); // too early to offer
    await tester.tap(find.text('Add to playlist'));
    await tester.pumpAndSettle();
    expect(find.text('Road trip'), findsWidgets);
  });

  testWidgets('Shazam stays off until the admin turns it on', (tester) async {
    final shazam = FakeShazam(
      hit: const ShazamHit(title: 'Pesamale', artist: 'Koshal'),
    );
    await pumpListen(
      tester,
      matcher: (clip, {required last}) async => last
          ? const ListenResult(id: 4, matched: false, source: 'library')
          : miss,
      shazam: shazam,
    );
    await listenUntilDone(tester);
    expect(find.text('Not in your music yet'), findsOneWidget);
    expect(find.textContaining('Identified by Shazam'), findsNothing);
    expect(shazam.asked, 0);
  });

  testWidgets('a song not at home is asked of Shazam and asked for by name', (
    tester,
  ) async {
    final adapter = FakeHomeAdapter();
    Map<String, dynamic>? saved;
    adapter.extra['POST /api/v1/listen/history'] = (o) {
      saved = (o.data as Map).cast<String, dynamic>();
      return const ListenResult(
        id: 4,
        matched: true,
        source: 'shazam',
        title: 'Pesamale',
        artist: 'Koshal',
      ).toJson();
    };
    final shazam = FakeShazam(
      hit: const ShazamHit(title: 'Pesamale', artist: 'Koshal'),
    );
    await pumpListen(
      tester,
      matcher: (clip, {required last}) async => last
          ? const ListenResult(id: 4, matched: false, source: 'library')
          : miss,
      adapter: adapter,
      shazamOn: true,
      shazam: shazam,
    );
    await listenUntilDone(tester);
    expect(shazam.asked, 1);
    expect(saved, {
      'title': 'Pesamale',
      'artist': 'Koshal',
      'listenEventId': 4,
    });
    expect(find.text('Pesamale'), findsOneWidget);
    expect(find.textContaining('Identified by Shazam'), findsOneWidget);
    await tester.tap(find.text('Ask to add it'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('request-artist')))
          .controller!
          .text,
      'Koshal',
    );
  });

  testWidgets("when Shazam doesn't know it either, it's not found", (
    tester,
  ) async {
    final shazam = FakeShazam();
    await pumpListen(
      tester,
      matcher: (clip, {required last}) async => last
          ? const ListenResult(id: 4, matched: false, source: 'library')
          : miss,
      shazamOn: true,
      shazam: shazam,
    );
    await listenUntilDone(tester);
    expect(shazam.asked, 1);
    expect(find.text('Not in your music yet'), findsOneWidget);
  });

  testWidgets('it checks as it listens and stops as soon as it knows', (
    tester,
  ) async {
    final found = ListenResult(
      id: 3,
      matched: true,
      source: 'library',
      track: premam.tracks[0],
      positionMs: 102000,
    );
    final recorder = FakeRecorder();
    final checks = Checks([miss, miss, found]);
    await pumpListen(tester, matcher: checks.call, recorder: recorder);
    await listenFor(tester, const Duration(seconds: 9));
    // At 4, 6 and 8 seconds, each with everything heard so far.
    expect(checks.asked.map((a) => a.$1.round()), [4, 6, 8]);
    expect(checks.asked.every((a) => !a.$2), isTrue);
    expect(find.text('Play from 1:42'), findsOneWidget);
    expect(recorder.on, isFalse); // the microphone is off once found
  });

  testWidgets('a match from the first few seconds waits for the next check', (
    tester,
  ) async {
    // The song changed: the first check hears the end of the old one.
    final old = ListenResult(
      id: 1,
      matched: true,
      source: 'library',
      track: premam.tracks[1],
      positionMs: 200000,
    );
    final now = ListenResult(
      id: 2,
      matched: true,
      source: 'library',
      track: premam.tracks[0],
      positionMs: 9000,
    );
    final checks = Checks([old, now]);
    await pumpListen(tester, matcher: checks.call);
    await listenFor(tester, const Duration(seconds: 7));
    expect(find.text(premam.tracks[0].title), findsWidgets);
    expect(find.text('Play from 0:09'), findsOneWidget);
    expect(find.text(premam.tracks[1].title), findsNothing);
  });

  testWidgets('only the last 12 seconds are checked; then it gives up', (
    tester,
  ) async {
    final checks = Checks([miss]);
    await pumpListen(tester, matcher: checks.call);
    await listenUntilDone(tester);
    final lengths = checks.asked.map((a) => a.$1.round()).toList();
    expect(lengths.first, 4);
    expect(lengths.reduce((a, b) => a > b ? a : b), 12);
    expect(checks.asked.last.$2, isTrue); // the last try is kept
    expect(checks.asked.where((a) => a.$2).length, 1);
    expect(find.text('Not in your music yet'), findsOneWidget);
  });

  testWidgets('Stop stops at once, even while home is checking', (
    tester,
  ) async {
    final recorder = FakeRecorder();
    final slow = Completer<ListenResult>();
    await pumpListen(
      tester,
      recorder: recorder,
      matcher: (clip, {required last}) => slow.future,
    );
    await listenFor(tester, const Duration(seconds: 5));
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(find.text('Tap to listen'), findsOneWidget);
    expect(recorder.on, isFalse);
    // The answer arriving late changes nothing.
    slow.complete(
      ListenResult(
        id: 1,
        matched: true,
        source: 'library',
        track: premam.tracks[0],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Tap to listen'), findsOneWidget);
  });

  testWidgets('without the microphone it says how to allow it', (tester) async {
    await pumpListen(
      tester,
      recorder: FakeRecorder()..allowed = false,
      matcher: (clip, {required last}) async => throw StateError('not called'),
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
      matcher: (clip, {required last}) async => throw HiveApiException(
        null,
        null,
        DioException(requestOptions: RequestOptions()),
      ),
    );
    await listenUntilDone(tester);
    expect(find.text("That didn't work"), findsOneWidget);
    expect(find.textContaining("Can't reach home"), findsOneWidget);
  });
}
