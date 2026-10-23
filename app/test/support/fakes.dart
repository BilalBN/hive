import 'dart:async';

import 'package:hive/api/hive_api.g.dart';
import 'package:hive/downloads/downloads.dart';
import 'package:hive/sync/continuity.dart';
import 'package:hive/player/engine.dart';
import 'package:hive/player/quality.dart';

const flac1644 = AudioFormat(
  codec: 'flac',
  lossless: true,
  sampleRate: 44100,
  channels: 2,
  bitDepth: 16,
  tier: 'lossless',
  label: 'Lossless 16/44.1',
);

const flac2496 = AudioFormat(
  codec: 'flac',
  lossless: true,
  sampleRate: 96000,
  channels: 2,
  bitDepth: 24,
  tier: 'hires',
  label: 'Hi-Res 24/96',
);

const opus256 = AudioFormat(
  codec: 'opus',
  lossless: false,
  sampleRate: 48000,
  channels: 2,
  bitrateKbps: 256,
  tier: 'lossy',
  label: 'Opus 256',
);

TrackSummary track(
  String id, {
  String? title,
  String artist = 'Vijay Yesudas',
  String album = 'Premam',
  int ms = 240000,
  AudioFormat format = flac1644,
  bool liked = false,
}) => TrackSummary(
  id: id,
  title: title ?? 'Song $id',
  artistName: artist,
  albumId: 'album-$album',
  albumTitle: album,
  durationMs: ms,
  format: format,
  liked: liked,
  artistId: 'artist-$artist',
  artworkId: 'art-$album',
);

StreamTicket ticket(
  String trackId, {
  AudioFormat format = flac1644,
  AudioFormat? source,
  bool transcoded = false,
  Loudness? loudness,
}) => StreamTicket(
  url: '/api/v1/media/stream/$trackId',
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
  format: format,
  source: source,
  mimeType: 'audio/flac',
  durationMs: 240000,
  transcoded: transcoded,
  loudness: loudness,
);

/// Records ticket requests: (trackId, quality, play?).
class FakeTickets {
  final calls = <(String, QualityMode, bool)>[];
  bool fail = false;

  Future<StreamTicket> call(
    String id,
    QualityMode mode, {
    required bool play,
    PlayContext? context,
  }) async {
    calls.add((id, mode, play));
    if (fail) throw HiveApiException(null, null, "down");
    return ticket(id);
  }
}

/// An audio engine without audio: holds sources, and lets tests move it on.
class FakeEngine implements AudioEngine {
  final sources = <EngineSource>[];
  final _index = StreamController<int?>.broadcast(sync: true);
  final _playing = StreamController<bool>.broadcast(sync: true);
  final _processing = StreamController<EngineProcessing>.broadcast(sync: true);
  bool _isPlaying = false;
  double volume = 1;
  bool repeatOne = false;
  Duration _position = Duration.zero;

  /// The track ids (from stream URLs) currently loaded, in order.
  List<String> get loaded => [for (final s in sources) s.uri.pathSegments.last];

  /// Gapless move to the next loaded song, as the real engine does.
  Future<void> advance() async {
    _index.add(1);
    await pump();
  }

  void complete() => _processing.add(EngineProcessing.completed);

  @override
  Stream<int?> get indexStream => _index.stream;
  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<Duration> get bufferedStream => const Stream.empty();
  @override
  Stream<EngineProcessing> get processingStream => _processing.stream;
  @override
  int? get index => sources.isEmpty ? null : 0;
  @override
  Duration get position => _position;
  @override
  bool get playing => _isPlaying;
  @override
  int get length => sources.length;

  @override
  Future<void> setSources(
    List<EngineSource> s, {
    Duration position = Duration.zero,
  }) async {
    sources
      ..clear()
      ..addAll(s);
    _position = position;
  }

  @override
  Future<void> addSource(EngineSource s) async => sources.add(s);
  @override
  Future<void> removeAt(int i) async => sources.removeAt(i);
  @override
  Future<void> play() async {
    _isPlaying = true;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    _isPlaying = false;
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration p) async => _position = p;
  @override
  Future<void> setVolume(double v) async => volume = v;
  @override
  Future<void> setRepeatOne(bool on) async => repeatOne = on;
  @override
  Future<void> stop() async => sources.clear();
  @override
  Future<void> dispose() async {}
}

/// Let pending futures and microtasks run.
Future<void> pump() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Home's side of downloads without a network: tickets, the audio bytes
/// (each song is its id repeated), check-ins and playlists.
class FakeDownloadTransport implements DownloadTransport {
  final tickets = <String>[];
  final checks = <List<String>>[];
  Set<String> gone = {};
  bool down = false;
  DateTime validUntil = DateTime.now().add(const Duration(days: 30));
  final playlists = <String, Playlist>{};

  static List<int> bytesOf(String id) =>
      List<int>.generate(70000, (i) => id.codeUnitAt(i % id.length));

  @override
  Future<DownloadTicket> ticket(String trackId, QualityMode quality) async {
    if (down) throw HiveApiException(null, null, 'down');
    tickets.add('$trackId@${quality.wire}');
    return DownloadTicket(
      url: '/api/v1/media/file/$trackId',
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      format: opus256,
      mimeType: 'audio/ogg',
      sizeBytes: 70000,
      durationMs: 240000,
      transcoded: true,
      validUntil: validUntil,
    );
  }

  @override
  Future<Stream<List<int>>> fetch(
    String url, {
    void Function(int total)? onTotal,
  }) async {
    final b = bytesOf(url.split('/').last);
    onTotal?.call(b.length);
    return Stream.fromIterable([b.sublist(0, 30000), b.sublist(30000)]);
  }

  @override
  Future<DownloadCheck> check(List<String> trackIds) async {
    if (down) throw HiveApiException(null, null, 'down');
    checks.add(trackIds);
    return DownloadCheck(
      validUntil: validUntil,
      gone: trackIds.where(gone.contains).toList(),
    );
  }

  @override
  Future<List<int>?> art(String artworkId) async => [1, 2, 3];

  @override
  Future<Playlist> playlist(String playlistId) async =>
      playlists[playlistId] ?? (throw HiveApiException(404, null, 'gone'));
}

/// Home's side of continuity without a network.
class FakeSessionLink implements SessionLink {
  PlaySession? session;
  final reports = <PlaySessionUpdate>[];
  final _changes = StreamController<PlaySession?>.broadcast();

  /// Another device changed something (as the WebSocket would say).
  void push(PlaySession? s) {
    session = s;
    _changes.add(s);
  }

  @override
  Future<PlaySession?> fetch() async => session;
  @override
  Future<void> report(PlaySessionUpdate update) async => reports.add(update);
  @override
  Stream<PlaySession?> changes() => _changes.stream;
}
