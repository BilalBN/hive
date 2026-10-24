// M6: landmarks made on the device find the song the way home's own do
// (server/hive/library/fingerprint.py), so Listen can send home landmarks
// instead of sound. test/fixtures/landmarks.json comes from
// tools/gen_landmark_fixture.py: home's landmarks of a made-up song, and how
// well home matched a noisy recording of it.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/listen/landmarks.dart';

const rate = 16000;
const clipFrom = 2.0;
const clipSeconds = 6;
const notes = [
  0,
  4,
  7,
  12,
  7,
  4,
  2,
  5,
  9,
  12,
  14,
  9,
  5,
  2,
  0,
  -3,
  0,
  7,
  3,
  10,
  15,
  10,
  3,
  -2,
];

/// The made-up song at time t (as in tools/gen_landmark_fixture.py).
double tune(double t) {
  const noteLen = 0.25;
  final k = (t / noteLen).floor();
  final f = 220.0 * math.pow(2, notes[k % notes.length] / 12);
  final tn = t - k * noteLen;
  var x = 0.0;
  for (final h in [1, 2, 3]) {
    x += (0.5 / h) * math.sin(2 * math.pi * f * h * t);
  }
  return x * 0.6 * math.exp(-3 * tn);
}

/// The song across a room: quieter, an echo, and hiss.
Uint8List clipPcm() {
  final out = ByteData(rate * clipSeconds * 2);
  var seed = 12345;
  for (var n = 0; n < rate * clipSeconds; n++) {
    final t = clipFrom + n / rate;
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
    final hiss = (seed / 0x7FFFFFFF - 0.5) * 0.2;
    final x = 0.5 * tune(t) + 0.25 * tune(t - 0.06) + hiss;
    out.setInt16(n * 2, (x.clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return out.buffer.asUint8List();
}

void main() {
  final fixture = jsonDecode(
    File('test/fixtures/landmarks.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final song = fixture['song'] as Map<String, dynamic>;
  final home = fixture['home'] as Map<String, dynamic>;
  final ref = <int, List<int>>{};
  final hs = (song['hashes'] as List).cast<int>();
  final ts = (song['starts'] as List).cast<int>();
  for (var i = 0; i < hs.length; i++) {
    ref.putIfAbsent(hs[i], () => []).add(ts[i]);
  }

  test('the resampler keeps a tone a tone', () {
    final x = Float64List(rate);
    for (var i = 0; i < rate; i++) {
      x[i] = math.sin(2 * math.pi * 1000 * i / rate);
    }
    final y = resample(x, rate);
    expect(y.length, landmarkRate);
    var crossings = 0;
    for (var i = 1; i < y.length; i++) {
      if ((y[i - 1] < 0) != (y[i] < 0)) crossings++;
    }
    expect(crossings, inInclusiveRange(1990, 2010));
  });

  test('made on the device, they find the song and the moment like home', () {
    final mine = landmarksOfPcm((clipPcm(), rate));
    final votes = <int, int>{};
    for (var i = 0; i < mine.length; i++) {
      for (final rt in ref[mine.hashes[i]] ?? const <int>[]) {
        votes.update(rt - mine.starts[i], (v) => v + 1, ifAbsent: () => 1);
      }
    }
    int near(int o) =>
        (votes[o] ?? 0) + (votes[o - 1] ?? 0) + (votes[o + 1] ?? 0);
    final best = votes.keys.reduce((a, b) => near(a) >= near(b) ? a : b);
    final homeAligned = home['aligned'] as int;
    // The same moment (2 s in), and nearly as many landmarks agreeing as
    // home's own (it needs 6 to name a song).
    expect((best - (home['offset'] as int)).abs(), lessThanOrEqualTo(1));
    expect(
      near(best),
      greaterThanOrEqualTo((homeAligned * 0.6).ceil()),
      reason: 'device ${near(best)}, home $homeAligned',
    );
  });
}
