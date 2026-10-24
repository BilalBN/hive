import 'dart:math' as math;
import 'dart:typed_data';

/// Song landmarks made on the device (M6), the same way home makes them
/// (server/hive/library/fingerprint.py), so Listen sends home only these
/// numbers and never the sound. Each landmark is a pair of loud points in
/// the sound's spectrogram: two frequencies and the time between them, with
/// the frame it starts at.

const landmarkRate = 11025; // samples per second, as home uses
const _nFft = 512;
const _hop = 256;
const _minBin = 4;
const _hpPole = 0.98;
const _spreadBins = 3.0;
const _decay = 0.985;
const _peaksPerFrame = 6;
const _fanOut = 6;
const _pairMin = 1;
const _pairMax = 63;
const _maxDf = 63;
const _freqShift = 1;

/// Landmark numbers and the frame each starts at.
class Landmarks {
  const Landmarks(this.hashes, this.starts);
  final List<int> hashes;
  final List<int> starts;
  int get length => hashes.length;
}

/// 16-bit little-endian mono samples to floats in -1..1.
Float64List pcm16ToFloat(Uint8List pcm) {
  final data = ByteData.sublistView(pcm);
  final out = Float64List(pcm.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// [samples] at [from] samples per second to [landmarkRate], with a
/// windowed-sinc filter that also removes what's above the new Nyquist.
Float64List resample(Float64List samples, int from, {int to = landmarkRate}) {
  if (from == to) return samples;
  final ratio = to / from;
  final cutoff = math.min(1.0, ratio) * 0.95; // fraction of the input Nyquist
  const half = 16; // taps either side
  final n = (samples.length * ratio).floor();
  final out = Float64List(n);
  for (var i = 0; i < n; i++) {
    final centre = i / ratio;
    final lo = centre.floor() - half + 1;
    var acc = 0.0;
    var norm = 0.0;
    for (var j = lo; j < lo + 2 * half; j++) {
      if (j < 0 || j >= samples.length) continue;
      final x = centre - j;
      final sinc = x == 0
          ? 1.0
          : math.sin(math.pi * cutoff * x) / (math.pi * cutoff * x);
      // Hann window over the kernel.
      final w = 0.5 + 0.5 * math.cos(math.pi * x / half);
      final k = sinc * w;
      acc += samples[j] * k;
      norm += k;
    }
    out[i] = norm == 0 ? 0 : acc / norm;
  }
  return out;
}

/// In-place radix-2 FFT of [re] + i[im] (length a power of two).
void _fft(Float64List re, Float64List im) {
  final n = re.length;
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2 * math.pi / len;
    final wr = math.cos(ang), wi = math.sin(ang);
    for (var i = 0; i < n; i += len) {
      var cr = 1.0, ci = 0.0;
      for (var k = 0; k < len ~/ 2; k++) {
        final a = i + k, b = a + len ~/ 2;
        final xr = re[b] * cr - im[b] * ci;
        final xi = re[b] * ci + im[b] * cr;
        re[b] = re[a] - xr;
        im[b] = im[a] - xi;
        re[a] += xr;
        im[a] += xi;
        final nr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = nr;
      }
    }
  }
}

/// Log loudness per frame and band with each band's steady part taken out.
List<Float64List> _onsetSpectrogram(Float64List samples) {
  if (samples.length < _nFft) return const [];
  const bins = _nFft ~/ 2 + 1;
  final frames = (samples.length - _nFft) ~/ _hop + 1;
  final window = Float64List(_nFft);
  for (var i = 0; i < _nFft; i++) {
    window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (_nFft - 1));
  }
  final mags = <Float64List>[];
  var maxMag = 0.0;
  final re = Float64List(_nFft), im = Float64List(_nFft);
  for (var f = 0; f < frames; f++) {
    for (var i = 0; i < _nFft; i++) {
      re[i] = samples[f * _hop + i] * window[i];
      im[i] = 0;
    }
    _fft(re, im);
    final m = Float64List(bins);
    for (var b = 0; b < bins; b++) {
      m[b] = math.sqrt(re[b] * re[b] + im[b] * im[b]);
      if (m[b] > maxMag) maxMag = m[b];
    }
    mags.add(m);
  }
  final floor = maxMag / 1e6 + 1e-12;
  var sum = 0.0;
  for (final m in mags) {
    for (var b = 0; b < bins; b++) {
      m[b] = math.log(math.max(m[b], floor));
      sum += m[b];
    }
  }
  final mean = sum / (frames * bins);
  final out = <Float64List>[];
  var prevX = Float64List(bins);
  final prevY = Float64List(bins);
  for (var f = 0; f < frames; f++) {
    final s = mags[f];
    for (var b = 0; b < bins; b++) {
      s[b] -= mean;
    }
    if (f == 0) prevX = Float64List.fromList(s);
    final y = Float64List(bins);
    for (var b = 0; b < bins; b++) {
      y[b] = s[b] - prevX[b] + _hpPole * prevY[b];
      prevY[b] = y[b];
    }
    prevX = s;
    out.add(y);
  }
  return out;
}

/// (frame, bin) of the peaks above a threshold each peak raises and that
/// then decays.
List<(int, int)> _onsetPeaks(List<Float64List> spec) {
  if (spec.isEmpty) return const [];
  final nBins = spec[0].length;
  final spread = List.generate(
    nBins,
    (i) => Float64List.fromList([
      for (var j = 0; j < nBins; j++)
        math.exp(-0.5 * math.pow((i - j) / _spreadBins, 2)),
    ]),
  );
  // The starting threshold: the loudest of the first frames, spread.
  final first = Float64List(nBins)
    ..fillRange(0, nBins, double.negativeInfinity);
  for (var t = 0; t < math.min(10, spec.length); t++) {
    for (var b = 0; b < nBins; b++) {
      if (spec[t][b] > first[b]) first[b] = spec[t][b];
    }
  }
  var thresh = Float64List(nBins)..fillRange(0, nBins, double.negativeInfinity);
  for (var i = 0; i < nBins; i++) {
    for (var j = 0; j < nBins; j++) {
      final v = spread[i][j] * first[j];
      if (v > thresh[i]) thresh[i] = v;
    }
  }
  final out = <(int, int)>[];
  final diff = Float64List(nBins);
  for (var t = 0; t < spec.length; t++) {
    final col = spec[t];
    for (var b = 0; b < nBins; b++) {
      diff[b] = math.max(0, col[b] - thresh[b]);
    }
    final cand = <int>[];
    for (var b = 1; b < nBins - 1; b++) {
      if (diff[b] > diff[b - 1] && diff[b] >= diff[b + 1] && b >= _minBin) {
        cand.add(b);
      }
    }
    if (cand.isNotEmpty) {
      // Loudest first (stable, as numpy's argsort of the negated values).
      final order = [for (var i = 0; i < cand.length; i++) i]
        ..sort((a, b) {
          final c = col[cand[b]].compareTo(col[cand[a]]);
          return c != 0 ? c : a.compareTo(b);
        });
      var taken = 0;
      for (final i in order) {
        final b = cand[i];
        if (col[b] > thresh[b]) {
          out.add((t, b));
          final s = spread[b];
          for (var k = 0; k < nBins; k++) {
            final v = col[b] * s[k];
            if (v > thresh[k]) thresh[k] = v;
          }
          taken++;
          if (taken >= _peaksPerFrame) break;
        }
      }
    }
    for (var k = 0; k < nBins; k++) {
      thresh[k] *= _decay;
    }
  }
  return out;
}

Landmarks _landmarks(List<(int, int)> pk) {
  final hashes = <int>[], starts = <int>[];
  if (pk.length < 2) return Landmarks(hashes, starts);
  // In the same order as home: by fan-out step, then by peak.
  for (var k = 1; k <= _fanOut; k++) {
    if (k >= pk.length) break;
    for (var i = 0; i + k < pk.length; i++) {
      final (t1, f1) = pk[i];
      final (t2, f2) = pk[i + k];
      final dt = t2 - t1;
      if (dt < _pairMin || dt > _pairMax || (f2 - f1).abs() > _maxDf) continue;
      hashes.add(((f1 >> _freqShift) << 16) | ((f2 >> _freqShift) << 6) | dt);
      starts.add(t1);
    }
  }
  return Landmarks(hashes, starts);
}

/// Landmarks of [samples] (mono floats at [landmarkRate]).
Landmarks landmarksOf(Float64List samples) =>
    _landmarks(_onsetPeaks(_onsetSpectrogram(samples)));

/// Landmarks of 16-bit mono [pcm] recorded at [rate]. Heavy: run it off
/// the main thread (compute()).
Landmarks landmarksOfPcm((Uint8List, int) clip) {
  final (pcm, rate) = clip;
  return landmarksOf(resample(pcm16ToFloat(pcm), rate));
}
