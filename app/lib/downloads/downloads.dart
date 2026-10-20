import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/hive_api.g.dart';
import '../auth/device_auth.dart';
import '../core/api.dart';
import '../core/home_connection.dart';
import '../player/quality.dart';
import 'vault.dart';

/// Downloads play offline for 30 days from the last check-in with home.
const checkInEvery = Duration(hours: 6);

/// How early the app warns that downloads need home soon.
const warnBefore = Duration(days: 5);

/// A song kept on this device.
@immutable
class DownloadedTrack {
  const DownloadedTrack({
    required this.track,
    required this.sizeBytes,
    required this.mimeType,
    required this.format,
    required this.durationMs,
    required this.at,
    this.loudness,
    this.single = false,
  });

  final TrackSummary track;
  final int sizeBytes;
  final String mimeType;
  final AudioFormat format;
  final int durationMs;
  final DateTime at;
  final Loudness? loudness;

  /// Downloaded on its own, not only as part of an album or playlist.
  final bool single;

  DownloadedTrack copyWith({bool? single}) => DownloadedTrack(
    track: track,
    sizeBytes: sizeBytes,
    mimeType: mimeType,
    format: format,
    durationMs: durationMs,
    at: at,
    loudness: loudness,
    single: single ?? this.single,
  );

  Map<String, dynamic> toJson() => {
    'track': track.toJson(),
    'sizeBytes': sizeBytes,
    'mimeType': mimeType,
    'format': format.toJson(),
    'durationMs': durationMs,
    'at': at.toUtc().toIso8601String(),
    'loudness': ?loudness?.toJson(),
    'single': single,
  };

  factory DownloadedTrack.fromJson(Map<String, dynamic> j) => DownloadedTrack(
    track: TrackSummary.fromJson((j['track'] as Map).cast()),
    sizeBytes: j['sizeBytes'] as int,
    mimeType: j['mimeType'] as String,
    format: AudioFormat.fromJson((j['format'] as Map).cast()),
    durationMs: j['durationMs'] as int,
    at: DateTime.parse(j['at'] as String),
    loudness: j['loudness'] == null
        ? null
        : Loudness.fromJson((j['loudness'] as Map).cast()),
    single: j['single'] as bool? ?? false,
  );
}

/// An album or playlist kept on this device, in its order.
@immutable
class DownloadedSet {
  const DownloadedSet({
    required this.kind,
    required this.id,
    required this.name,
    required this.subtitle,
    required this.artworkIds,
    required this.trackIds,
    required this.at,
  });

  /// album or playlist.
  final String kind;
  final String id;
  final String name;
  final String subtitle;
  final List<String> artworkIds;
  final List<String> trackIds;
  final DateTime at;

  String get key => '$kind:$id';

  DownloadedSet copyWith({
    String? name,
    List<String>? trackIds,
    List<String>? artworkIds,
  }) => DownloadedSet(
    kind: kind,
    id: id,
    name: name ?? this.name,
    subtitle: subtitle,
    artworkIds: artworkIds ?? this.artworkIds,
    trackIds: trackIds ?? this.trackIds,
    at: at,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'id': id,
    'name': name,
    'subtitle': subtitle,
    'artworkIds': artworkIds,
    'trackIds': trackIds,
    'at': at.toUtc().toIso8601String(),
  };

  factory DownloadedSet.fromJson(Map<String, dynamic> j) => DownloadedSet(
    kind: j['kind'] as String,
    id: j['id'] as String,
    name: j['name'] as String,
    subtitle: j['subtitle'] as String? ?? '',
    artworkIds: (j['artworkIds'] as List).cast<String>(),
    trackIds: (j['trackIds'] as List).cast<String>(),
    at: DateTime.parse(j['at'] as String),
  );
}

/// A song waiting to download, downloading, or that didn't.
@immutable
class DownloadJob {
  const DownloadJob({
    required this.track,
    this.received = 0,
    this.total,
    this.error,
    this.single = false,
  });
  final TrackSummary track;
  final int received;
  final int? total;
  final String? error;
  final bool single;

  bool get failed => error != null;
  double? get fraction =>
      total == null || total == 0 ? null : (received / total!).clamp(0, 1);

  DownloadJob copyWith({
    int? received,
    int? total,
    String? error,
    bool clearError = false,
  }) => DownloadJob(
    track: track,
    received: received ?? this.received,
    total: total ?? this.total,
    error: clearError ? null : (error ?? this.error),
    single: single,
  );
}

/// How far along an album, playlist or song is.
enum DownloadStatus { none, downloading, done }

@immutable
class DownloadsState {
  const DownloadsState({
    this.loaded = false,
    this.tracks = const {},
    this.sets = const [],
    this.jobs = const {},
    this.validUntil,
    this.checkedAt,
    this.quality = QualityMode.high,
  });

  final bool loaded;
  final Map<String, DownloadedTrack> tracks;
  final List<DownloadedSet> sets;

  /// In the order they download.
  final Map<String, DownloadJob> jobs;
  final DateTime? validUntil;
  final DateTime? checkedAt;
  final QualityMode quality;

  bool get isEmpty => tracks.isEmpty && jobs.isEmpty && sets.isEmpty;

  /// Past the 30 days without checking in: kept, but not playable until home
  /// is reached again.
  bool get expired => validUntil != null && DateTime.now().isAfter(validUntil!);

  /// Within a few days of needing a check-in: time to warn.
  bool get expiringSoon =>
      tracks.isNotEmpty &&
      !expired &&
      validUntil != null &&
      validUntil!.difference(DateTime.now()) < warnBefore;

  int get bytes => tracks.values.fold(0, (n, t) => n + t.sizeBytes);

  bool has(String trackId) => tracks.containsKey(trackId);

  DownloadedSet? setOf(String kind, String id) {
    for (final s in sets) {
      if (s.kind == kind && s.id == id) return s;
    }
    return null;
  }

  DownloadStatus statusOfSet(String kind, String id) {
    final s = setOf(kind, id);
    if (s == null) return DownloadStatus.none;
    return s.trackIds.every(tracks.containsKey)
        ? DownloadStatus.done
        : DownloadStatus.downloading;
  }

  DownloadStatus statusOfTrack(String id) => tracks.containsKey(id)
      ? DownloadStatus.done
      : jobs.containsKey(id)
      ? DownloadStatus.downloading
      : DownloadStatus.none;

  /// 0–1 across a set's songs (partly-downloaded songs count in part).
  double progressOfSet(DownloadedSet s) {
    if (s.trackIds.isEmpty) return 1;
    var done = 0.0;
    for (final id in s.trackIds) {
      if (tracks.containsKey(id)) {
        done += 1;
      } else {
        done += jobs[id]?.fraction ?? 0;
      }
    }
    return done / s.trackIds.length;
  }

  /// Songs downloaded on their own, newest first.
  List<DownloadedTrack> get singles =>
      tracks.values.where((t) => t.single).toList()
        ..sort((a, b) => b.at.compareTo(a.at));

  List<DownloadJob> get failed => jobs.values.where((j) => j.failed).toList();

  DownloadsState copyWith({
    bool? loaded,
    Map<String, DownloadedTrack>? tracks,
    List<DownloadedSet>? sets,
    Map<String, DownloadJob>? jobs,
    DateTime? validUntil,
    DateTime? checkedAt,
    QualityMode? quality,
  }) => DownloadsState(
    loaded: loaded ?? this.loaded,
    tracks: tracks ?? this.tracks,
    sets: sets ?? this.sets,
    jobs: jobs ?? this.jobs,
    validUntil: validUntil ?? this.validUntil,
    checkedAt: checkedAt ?? this.checkedAt,
    quality: quality ?? this.quality,
  );
}

/// The calls downloads make to home. Replaced in tests.
abstract class DownloadTransport {
  Future<DownloadTicket> ticket(String trackId, QualityMode quality);

  /// The file behind a ticket; [onTotal] hears its size once known.
  Future<Stream<List<int>>> fetch(
    String url, {
    void Function(int total)? onTotal,
  });
  Future<DownloadCheck> check(List<String> trackIds);
  Future<List<int>?> art(String artworkId);
  Future<Playlist> playlist(String playlistId);
}

class HomeTransport implements DownloadTransport {
  HomeTransport(this._ref);
  final Ref _ref;

  HiveApi get _api => _ref.read(hiveApiProvider);

  @override
  Future<DownloadTicket> ticket(String trackId, QualityMode quality) =>
      _api.createDownloadTicket(
        trackId: trackId,
        body: DownloadRequest(
          quality: quality.wire,
          player: isApplePlayer ? 'apple' : 'other',
        ),
      );

  @override
  Future<Stream<List<int>>> fetch(
    String url, {
    void Function(int total)? onTotal,
  }) async {
    final config = _ref.read(homeConfigProvider);
    if (config == null) throw StateError('Not connected to a home yet');
    // The link itself is the permission: no sign-in header, like streaming.
    final dio = dioFor(config.address)
      ..options.receiveTimeout = const Duration(seconds: 60);
    final r = await dio.get<ResponseBody>(
      url,
      options: Options(responseType: ResponseType.stream),
    );
    final length = int.tryParse(r.headers.value('content-length') ?? '');
    if (length != null) onTotal?.call(length);
    return r.data!.stream;
  }

  @override
  Future<DownloadCheck> check(List<String> trackIds) =>
      _api.checkDownloads(body: TrackIds(trackIds: trackIds));

  @override
  Future<List<int>?> art(String artworkId) async {
    final config = _ref.read(homeConfigProvider);
    if (config == null) return null;
    final dio = dioForHome(config, auth: _ref.read(deviceAuthProvider));
    final r = await dio.get<List<int>>(
      '/api/v1/media/artwork/${Uri.encodeComponent(artworkId)}',
      queryParameters: {'size': 600},
      options: Options(responseType: ResponseType.bytes),
    );
    return r.data;
  }

  @override
  Future<Playlist> playlist(String playlistId) =>
      _api.getPlaylist(playlistId: playlistId);
}

final downloadTransportProvider = Provider<DownloadTransport>(
  HomeTransport.new,
);

/// Songs, albums and playlists kept on this device to play with home off.
///
/// One song downloads at a time, straight into the vault (locked as it
/// arrives). Whenever home is reachable the app checks in: that keeps
/// downloads playable for another 30 days and deletes songs no longer at
/// home. A device removed in Hive Admin deletes everything at once.
class DownloadsController extends Notifier<DownloadsState> {
  static const _qualityKey = 'downloads.quality';
  bool _pumping = false;
  bool _checking = false;
  Future<void>? _loading;

  DownloadVault get _vault => ref.read(downloadVaultProvider);
  DownloadTransport get _net => ref.read(downloadTransportProvider);

  @override
  DownloadsState build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final quality = prefs.getString(_qualityKey) == null
        ? QualityMode.high
        : QualityMode.fromWire(prefs.getString(_qualityKey));
    ref.listen(homeStatusProvider, (_, s) {
      if (s is HomeConnected) {
        unawaited(checkIn());
        unawaited(_pump());
      }
    });
    final auth = ref.watch(deviceAuthProvider);
    final store = ref.watch(homeAddressStoreProvider);
    void signedOut() {
      // Removed in Hive Admin, or this device left home: nothing stays.
      if (auth.loaded &&
          (auth.problem == SignInProblem.revoked || store.address == null)) {
        unawaited(wipe());
      }
    }

    auth.addListener(signedOut);
    store.addListener(signedOut);
    ref.onDispose(() {
      auth.removeListener(signedOut);
      store.removeListener(signedOut);
    });
    _loading = _load();
    return DownloadsState(quality: quality);
  }

  Future<void> ready() => _loading ?? Future.value();

  Future<void> _load() async {
    try {
      final raw = await _vault.readIndex();
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        final tracks = {
          for (final t in (j['tracks'] as List? ?? const []))
            (t['track']['id'] as String): DownloadedTrack.fromJson(
              (t as Map).cast(),
            ),
        };
        final sets = [
          for (final s in (j['sets'] as List? ?? const []))
            DownloadedSet.fromJson((s as Map).cast()),
        ];
        final queued = {
          for (final q in (j['queue'] as List? ?? const []))
            (q['track']['id'] as String): DownloadJob(
              track: TrackSummary.fromJson((q['track'] as Map).cast()),
              single: q['single'] as bool? ?? false,
            ),
        };
        state = state.copyWith(
          tracks: tracks,
          sets: sets,
          jobs: queued,
          validUntil: j['validUntil'] == null
              ? null
              : DateTime.parse(j['validUntil'] as String),
          checkedAt: j['checkedAt'] == null
              ? null
              : DateTime.parse(j['checkedAt'] as String),
        );
      }
    } catch (_) {
      // A damaged index: start again (the files are found and tidied later).
    }
    state = state.copyWith(loaded: true);
    await _refreshArt();
    if (ref.read(homeStatusProvider) is HomeConnected) {
      unawaited(checkIn());
      unawaited(_pump());
    }
  }

  Future<void> _save() async {
    final s = state;
    await _vault.writeIndex(
      jsonEncode({
        'tracks': [for (final t in s.tracks.values) t.toJson()],
        'sets': [for (final x in s.sets) x.toJson()],
        'queue': [
          for (final j in s.jobs.values)
            {'track': j.track.toJson(), 'single': j.single},
        ],
        'validUntil': ?s.validUntil?.toUtc().toIso8601String(),
        'checkedAt': ?s.checkedAt?.toUtc().toIso8601String(),
      }),
    );
  }

  Future<void> _refreshArt() async {
    final ids = <String>{
      for (final t in state.tracks.values) ?t.track.artworkId,
      for (final s in state.sets) ...s.artworkIds,
    };
    final paths = <String, String>{};
    for (final id in ids) {
      final p = await _vault.artPath(id);
      if (p != null) paths[id] = p;
    }
    ref.read(downloadedArtProvider.notifier).set(paths);
  }

  // ------------------------------------------------------------ commands

  Future<void> setQuality(QualityMode q) async {
    await ref.read(sharedPreferencesProvider).setString(_qualityKey, q.wire);
    state = state.copyWith(quality: q);
  }

  Future<void> downloadAlbum(Album album) => _downloadSet(
    DownloadedSet(
      kind: 'album',
      id: album.id,
      name: album.title,
      subtitle: album.artistName,
      artworkIds: [?album.artworkId],
      trackIds: [for (final t in album.tracks) t.id],
      at: DateTime.now(),
    ),
    album.tracks,
  );

  Future<void> downloadPlaylist(Playlist pl) => _downloadSet(
    DownloadedSet(
      kind: 'playlist',
      id: pl.id,
      name: pl.name,
      subtitle: pl.mine ? 'Your playlist' : 'By ${pl.ownerName}',
      artworkIds: pl.artworkIds.take(4).toList(),
      trackIds: [for (final i in pl.items) i.track.id],
      at: DateTime.now(),
    ),
    [for (final i in pl.items) i.track],
  );

  Future<void> _downloadSet(
    DownloadedSet set,
    List<TrackSummary> tracks,
  ) async {
    await ready();
    state = state.copyWith(
      sets: [
        for (final s in state.sets)
          if (s.key != set.key) s,
        set,
      ],
      jobs: {
        ...state.jobs,
        for (final t in tracks)
          if (!state.tracks.containsKey(t.id) && !state.jobs.containsKey(t.id))
            t.id: DownloadJob(track: t),
      },
    );
    await _save();
    unawaited(_keepArt(set.artworkIds));
    unawaited(_pump());
  }

  Future<void> downloadTrack(TrackSummary t) async {
    await ready();
    final have = state.tracks[t.id];
    if (have != null) {
      state = state.copyWith(
        tracks: {...state.tracks, t.id: have.copyWith(single: true)},
      );
    } else {
      state = state.copyWith(
        jobs: {
          ...state.jobs,
          t.id: DownloadJob(track: t, single: true),
        },
      );
    }
    await _save();
    unawaited(_pump());
  }

  /// Remove an album or playlist; songs another download needs stay.
  Future<void> removeSet(String kind, String id) async {
    await ready();
    final sets = [
      for (final s in state.sets)
        if (!(s.kind == kind && s.id == id)) s,
    ];
    state = state.copyWith(sets: sets);
    await _tidy();
  }

  Future<void> removeTrack(String trackId) async {
    await ready();
    final t = state.tracks[trackId];
    final jobs = {...state.jobs};
    if (jobs[trackId]?.single ?? false) jobs.remove(trackId);
    state = state.copyWith(
      jobs: jobs,
      tracks: t == null
          ? null
          : {...state.tracks, trackId: t.copyWith(single: false)},
    );
    await _tidy();
  }

  Future<void> removeAll() async {
    await ready();
    for (final id in state.tracks.keys) {
      await _vault.remove(id);
    }
    for (final id in ref.read(downloadedArtProvider).keys) {
      await _vault.removeArt(id);
    }
    state = state.copyWith(tracks: const {}, sets: const [], jobs: const {});
    ref.read(downloadedArtProvider.notifier).set(const {});
    await _save();
  }

  /// Try the songs that didn't download again.
  void retry() {
    state = state.copyWith(
      jobs: {
        for (final e in state.jobs.entries)
          e.key: e.value.copyWith(clearError: true, received: 0),
      },
    );
    unawaited(_pump());
  }

  /// Everything deleted, the key too (signed out or removed).
  Future<void> wipe() async {
    await ready();
    if (state.isEmpty) return;
    await _vault.wipe();
    state = DownloadsState(loaded: true, quality: state.quality);
    ref.read(downloadedArtProvider.notifier).set(const {});
  }

  /// A stream ticket for a downloaded song, or null when it isn't here (or
  /// the 30 days ran out without checking in).
  StreamTicket? ticketFor(String trackId) {
    final t = state.tracks[trackId];
    if (t == null || state.expired) return null;
    return StreamTicket(
      url: '$downloadScheme:${Uri.encodeComponent(trackId)}',
      expiresAt: DateTime.now().add(const Duration(days: 1)),
      format: t.format,
      mimeType: t.mimeType,
      sizeBytes: t.sizeBytes,
      durationMs: t.durationMs,
      transcoded: false,
      loudness: t.loudness,
    );
  }

  /// A downloaded song's bytes, unlocked, for the player.
  Stream<List<int>> open(String trackId, int start, [int? end]) =>
      _vault.open(trackId, start, end);

  // ------------------------------------------------------------ check-in

  /// Tell home which songs are here: moves the 30 days on, deletes songs no
  /// longer at home, and brings downloaded playlists up to date.
  Future<void> checkIn({bool force = false}) async {
    await ready();
    if (_checking) return;
    if (state.tracks.isEmpty && state.sets.isEmpty) return;
    final last = state.checkedAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < checkInEvery &&
        !state.expired) {
      return;
    }
    _checking = true;
    try {
      final r = await _net.check(state.tracks.keys.toList());
      final gone = r.gone.toSet();
      state = state.copyWith(
        validUntil: r.validUntil,
        checkedAt: DateTime.now(),
        tracks: {
          for (final e in state.tracks.entries)
            if (!gone.contains(e.key)) e.key: e.value,
        },
        sets: [
          for (final s in state.sets)
            s.copyWith(
              trackIds: s.trackIds.where((id) => !gone.contains(id)).toList(),
            ),
        ],
      );
      for (final id in gone) {
        await _vault.remove(id);
      }
      await _followPlaylists();
      await _tidy();
    } catch (_) {
      // Tried again the next time home is reachable.
    } finally {
      _checking = false;
    }
  }

  Future<void> _followPlaylists() async {
    for (final s in state.sets.where((s) => s.kind == 'playlist').toList()) {
      try {
        final pl = await _net.playlist(s.id);
        final fresh = s.copyWith(
          name: pl.name,
          trackIds: [for (final i in pl.items) i.track.id],
          artworkIds: pl.artworkIds.take(4).toList(),
        );
        state = state.copyWith(
          sets: [for (final x in state.sets) x.key == s.key ? fresh : x],
          jobs: {
            ...state.jobs,
            for (final i in pl.items)
              if (!state.tracks.containsKey(i.track.id) &&
                  !state.jobs.containsKey(i.track.id))
                i.track.id: DownloadJob(track: i.track),
          },
        );
      } on HiveApiException catch (e) {
        if (e.status == 404) {
          // The playlist was deleted at home.
          state = state.copyWith(
            sets: [
              for (final x in state.sets)
                if (x.key != s.key) x,
            ],
          );
        }
      } catch (_) {}
    }
    unawaited(_pump());
  }

  // ------------------------------------------------------------ internals

  /// Delete songs nothing needs any more, and their covers.
  Future<void> _tidy() async {
    final needed = <String>{
      for (final s in state.sets) ...s.trackIds,
      for (final t in state.tracks.values)
        if (t.single) t.track.id,
    };
    final drop = state.tracks.keys.where((id) => !needed.contains(id)).toList();
    for (final id in drop) {
      await _vault.remove(id);
    }
    final tracks = {
      for (final e in state.tracks.entries)
        if (needed.contains(e.key)) e.key: e.value,
    };
    final jobs = {
      for (final e in state.jobs.entries)
        if (needed.contains(e.key) || e.value.single) e.key: e.value,
    };
    final art = <String>{
      for (final t in tracks.values) ?t.track.artworkId,
      for (final s in state.sets) ...s.artworkIds,
    };
    for (final id in ref.read(downloadedArtProvider).keys) {
      if (!art.contains(id)) await _vault.removeArt(id);
    }
    state = state.copyWith(tracks: tracks, jobs: jobs);
    await _save();
    await _refreshArt();
  }

  Future<void> _keepArt(Iterable<String> ids) async {
    var added = false;
    for (final id in ids) {
      if (ref.read(downloadedArtProvider).containsKey(id)) continue;
      try {
        final bytes = await _net.art(id);
        if (bytes == null || bytes.isEmpty) continue;
        await _vault.storeArt(id, bytes);
        added = true;
      } catch (_) {}
    }
    if (added) await _refreshArt();
  }

  /// Download whatever is waiting, one song at a time.
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        final next = state.jobs.values
            .where((j) => !j.failed)
            .cast<DownloadJob?>()
            .firstWhere((_) => true, orElse: () => null);
        if (next == null) break;
        if (ref.read(homeStatusProvider) is! HomeConnected) break;
        if (!await _downloadOne(next)) break;
      }
    } finally {
      _pumping = false;
    }
  }

  /// False when home stopped answering (the rest wait for it to come back).
  Future<bool> _downloadOne(DownloadJob job) async {
    final id = job.track.id;
    void update(DownloadJob Function(DownloadJob j) f) {
      final j = state.jobs[id];
      if (j == null) return;
      state = state.copyWith(jobs: {...state.jobs, id: f(j)});
    }

    try {
      final ticket = await _net.ticket(id, state.quality);
      if (ticket.sizeBytes != null) {
        update((j) => j.copyWith(total: ticket.sizeBytes));
      }
      final bytes = await _net.fetch(
        ticket.url,
        onTotal: (n) => update((j) => j.copyWith(total: n)),
      );
      var lastShown = 0;
      final size = await _vault.store(
        id,
        bytes,
        progress: (n) {
          // A screenful of progress is plenty: every 256 KB.
          if (n - lastShown < 256 * 1024) return;
          lastShown = n;
          update((j) => j.copyWith(received: n));
        },
      );
      final current = state.jobs[id];
      if (current == null) {
        await _vault.remove(id); // removed while it downloaded
        return true;
      }
      state = state.copyWith(
        validUntil: ticket.validUntil,
        checkedAt: state.checkedAt ?? DateTime.now(),
        tracks: {
          ...state.tracks,
          id: DownloadedTrack(
            track: job.track,
            sizeBytes: size,
            mimeType: ticket.mimeType,
            format: ticket.format,
            durationMs: ticket.durationMs,
            at: DateTime.now(),
            loudness: ticket.loudness,
            single: current.single,
          ),
        },
        jobs: {...state.jobs}..remove(id),
      );
      await _save();
      final art = job.track.artworkId;
      if (art != null) unawaited(_keepArt([art]));
      return true;
    } on HiveApiException catch (e) {
      if (e.unreachable) return false;
      if (e.status == 404) {
        // No longer at home: drop it quietly.
        state = state.copyWith(jobs: {...state.jobs}..remove(id));
        await _save();
        return true;
      }
      update((j) => j.copyWith(error: describeError(e)));
      return true;
    } on DioException {
      return false;
    } catch (e) {
      update((j) => j.copyWith(error: describeError(e)));
      return true;
    }
  }
}

/// Stream-ticket URLs for downloaded songs start with this.
const downloadScheme = 'hive-download';

final downloadsProvider = NotifierProvider<DownloadsController, DownloadsState>(
  DownloadsController.new,
);
