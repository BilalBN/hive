import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/hive_api.g.dart';
import '../core/api.dart';
import 'engine.dart';
import 'quality.dart';

enum RepeatMode { off, all, one }

/// Where a run of songs came from, for "Playing from …" and Jump back in.
@immutable
class PlaySource {
  const PlaySource({required this.kind, required this.id, required this.name});

  /// album, playlist, artist, liked, or search/songs (not sent to the server).
  final String kind;
  final String id;
  final String name;

  PlayContext? get context =>
      const {'album', 'playlist', 'artist', 'liked'}.contains(kind)
      ? PlayContext(kind: kind, id: id)
      : null;
}

/// One place in the queue. The same song can be in the queue twice.
@immutable
class QueueEntry {
  const QueueEntry({
    required this.id,
    required this.track,
    this.fromYou = false,
  });

  final int id;
  final TrackSummary track;

  /// Added with Play next / Add to queue ("Next from you").
  final bool fromYou;
}

@immutable
class PlayerState {
  const PlayerState({
    this.queue = const [],
    this.index = -1,
    this.playing = false,
    this.loading = false,
    this.position = Duration.zero,
    this.duration,
    this.buffered = Duration.zero,
    this.repeat = RepeatMode.off,
    this.shuffled = false,
    this.ticket,
    this.mode = QualityMode.lossless,
    this.source,
    this.error,
  });

  final List<QueueEntry> queue;
  final int index;
  final bool playing;

  /// Waiting for the stream (or the first High/Data saver encode).
  final bool loading;
  final Duration position;
  final Duration? duration;
  final Duration buffered;
  final RepeatMode repeat;
  final bool shuffled;

  /// The current song's stream: what is sent, the original, loudness.
  final StreamTicket? ticket;
  final QualityMode mode;
  final PlaySource? source;
  final String? error;

  QueueEntry? get current =>
      index >= 0 && index < queue.length ? queue[index] : null;
  TrackSummary? get track => current?.track;
  bool get isEmpty => current == null;

  List<QueueEntry> get upNext =>
      index < 0 ? queue : queue.sublist(math.min(index + 1, queue.length));
  List<QueueEntry> get history =>
      index <= 0 ? const [] : queue.sublist(0, index);

  Duration get total =>
      duration ?? Duration(milliseconds: track?.durationMs ?? 0);

  PlayerState copyWith({
    List<QueueEntry>? queue,
    int? index,
    bool? playing,
    bool? loading,
    Duration? position,
    Duration? duration,
    Duration? buffered,
    RepeatMode? repeat,
    bool? shuffled,
    StreamTicket? ticket,
    QualityMode? mode,
    PlaySource? source,
    String? error,
    bool clearError = false,
    bool clearTicket = false,
    bool clearDuration = false,
  }) => PlayerState(
    queue: queue ?? this.queue,
    index: index ?? this.index,
    playing: playing ?? this.playing,
    loading: loading ?? this.loading,
    position: position ?? this.position,
    duration: clearDuration ? null : (duration ?? this.duration),
    buffered: buffered ?? this.buffered,
    repeat: repeat ?? this.repeat,
    shuffled: shuffled ?? this.shuffled,
    ticket: clearTicket ? null : (ticket ?? this.ticket),
    mode: mode ?? this.mode,
    source: source ?? this.source,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Asks home for a stream of one song. Replaced in tests.
typedef TicketFetcher = Future<StreamTicket> Function(
  String trackId,
  QualityMode mode, {
  required bool play,
  PlayContext? context,
});

final ticketFetcherProvider = Provider<TicketFetcher>((ref) {
  return (trackId, mode, {required play, context}) => ref
      .read(hiveApiProvider)
      .createStreamTicket(
        trackId: trackId,
        body: StreamRequest(
          quality: mode.wire,
          player: isApplePlayer ? 'apple' : 'other',
          purpose: play ? 'play' : 'prefetch',
          context: context,
        ),
      );
});

final audioEngineProvider = Provider<AudioEngine>((ref) {
  final engine = JustAudioEngine();
  ref.onDispose(engine.dispose);
  return engine;
});

/// The queue and playback, for every screen and the lock screen.
///
/// The engine only ever holds two songs: the one playing and the next. That
/// keeps playback gapless (the next song is already loaded) while stream links
/// stay fresh, however long the queue is.
class PlayerController extends Notifier<PlayerState> {
  late AudioEngine _engine;
  final _subs = <StreamSubscription<Object?>>[];
  final _tickets = <int, StreamTicket>{};
  int _nextEntryId = 1;

  /// Engine slot 0 plays this entry; slot 1 (if any) is the next.
  int? _slot0;
  int? _slot1;
  List<QueueEntry> _unshuffled = const [];
  int _generation = 0;
  double _userVolume = 1.0;

  @override
  PlayerState build() {
    _engine = ref.watch(audioEngineProvider);
    _subs
      ..add(
        _engine.playingStream.listen((p) => state = state.copyWith(playing: p)),
      )
      ..add(
        _engine.positionStream.listen(
          (p) => state = state.copyWith(position: p),
        ),
      )
      ..add(
        _engine.bufferedStream.listen(
          (b) => state = state.copyWith(buffered: b),
        ),
      )
      ..add(
        _engine.durationStream.listen((d) {
          if (d != null) state = state.copyWith(duration: d);
        }),
      )
      ..add(_engine.indexStream.listen(_onEngineIndex))
      ..add(_engine.processingStream.listen(_onProcessing));
    // A quality change (Settings, or Wi-Fi ↔ mobile data) applies from the
    // next song; the one playing carries on uninterrupted.
    ref.listen(currentQualityProvider, (_, mode) {
      _tickets.removeWhere((id, _) => id != _slot0);
      state = state.copyWith(mode: mode);
      _refillNext(force: true);
    });
    ref.onDispose(() {
      for (final s in _subs) {
        s.cancel();
      }
    });
    return PlayerState(mode: ref.read(currentQualityProvider));
  }

  TicketFetcher get _fetch => ref.read(ticketFetcherProvider);

  // ------------------------------------------------------------ commands

  /// Play [tracks] starting at [start]; the queue becomes this run of songs
  /// (keeping anything you added with Play next / Add to queue after it).
  Future<void> playTracks(
    List<TrackSummary> tracks, {
    int start = 0,
    PlaySource? source,
    bool shuffle = false,
  }) async {
    if (tracks.isEmpty) return;
    final fromYou = state.upNext.where((e) => e.fromYou).toList();
    var entries = [
      for (final t in tracks) QueueEntry(id: _nextEntryId++, track: t),
    ];
    var startAt = start.clamp(0, entries.length - 1);
    _unshuffled = entries;
    if (shuffle) {
      final first = entries[startAt];
      final rest = [...entries]..removeAt(startAt);
      rest.shuffle();
      entries = [first, ...rest];
      startAt = 0;
    }
    final queue = [
      ...entries.sublist(0, startAt + 1),
      ...fromYou,
      ...entries.sublist(startAt + 1),
    ];
    state = state.copyWith(
      queue: queue,
      index: startAt,
      shuffled: shuffle,
      source: source,
      clearError: true,
      position: Duration.zero,
      clearDuration: true,
    );
    await _loadCurrent(autoplay: true);
  }

  Future<void> toggle() async {
    if (state.isEmpty) return;
    if (state.playing) {
      await _engine.pause();
    } else {
      if (_slot0 == null) {
        await _loadCurrent(autoplay: true, position: state.position);
      } else {
        unawaited(_engine.play());
      }
    }
  }

  Future<void> pause() => _engine.pause();

  Future<void> play() async {
    if (!state.playing) await toggle();
  }

  Future<void> next() async {
    final n = _nextIndex();
    if (n == null) return;
    state = state.copyWith(
      index: n,
      position: Duration.zero,
      clearDuration: true,
    );
    await _loadCurrent(autoplay: true);
  }

  /// Back to the start of the song, or the previous song in its first 3 seconds.
  Future<void> previous() async {
    if (state.position > const Duration(seconds: 3) || state.index <= 0) {
      await seek(Duration.zero);
      return;
    }
    state = state.copyWith(
      index: state.index - 1,
      position: Duration.zero,
      clearDuration: true,
    );
    await _loadCurrent(autoplay: true);
  }

  Future<void> skipTo(int queueIndex) async {
    if (queueIndex < 0 || queueIndex >= state.queue.length) return;
    state = state.copyWith(
      index: queueIndex,
      position: Duration.zero,
      clearDuration: true,
    );
    await _loadCurrent(autoplay: true);
  }

  Future<void> seek(Duration position) async {
    state = state.copyWith(position: position);
    await _engine.seek(position);
  }

  /// Play right after the current song.
  void playNext(TrackSummary track) {
    final entry = QueueEntry(id: _nextEntryId++, track: track, fromYou: true);
    if (state.isEmpty) {
      unawaited(playTracks([track]));
      return;
    }
    final q = [...state.queue]..insert(state.index + 1, entry);
    state = state.copyWith(queue: q);
    _refillNext();
  }

  /// Add to the end of "Next from you".
  void addToQueue(TrackSummary track) {
    if (state.isEmpty) {
      unawaited(playTracks([track]));
      return;
    }
    final entry = QueueEntry(id: _nextEntryId++, track: track, fromYou: true);
    var at = state.index + 1;
    while (at < state.queue.length && state.queue[at].fromYou) {
      at++;
    }
    final q = [...state.queue]..insert(at, entry);
    state = state.copyWith(queue: q);
    _refillNext();
  }

  /// Remove an upcoming entry (swipe left in the queue).
  void removeAt(int queueIndex) {
    if (queueIndex <= state.index || queueIndex >= state.queue.length) return;
    final q = [...state.queue]..removeAt(queueIndex);
    state = state.copyWith(queue: q);
    _refillNext();
  }

  /// Drag an upcoming entry to a new place among the upcoming ones.
  void move(int from, int to) {
    if (from <= state.index || to <= state.index) return;
    if (from >= state.queue.length) return;
    final q = [...state.queue];
    final e = q.removeAt(from);
    q.insert(math.min(to, q.length), e);
    state = state.copyWith(queue: q);
    _refillNext();
  }

  /// Clear "Next from you".
  void clearFromYou() {
    final q = [
      for (var i = 0; i < state.queue.length; i++)
        if (i <= state.index || !state.queue[i].fromYou) state.queue[i],
    ];
    state = state.copyWith(queue: q);
    _refillNext();
  }

  void setRepeat(RepeatMode mode) {
    state = state.copyWith(repeat: mode);
    unawaited(_engine.setRepeatOne(mode == RepeatMode.one));
    _refillNext();
  }

  void cycleRepeat() => setRepeat(
    RepeatMode.values[(state.repeat.index + 1) % RepeatMode.values.length],
  );

  /// Shuffle what's left (the current song stays), or go back to the order it
  /// came in.
  void toggleShuffle() {
    final current = state.current;
    if (current == null) {
      state = state.copyWith(shuffled: !state.shuffled);
      return;
    }
    final upcoming = state.upNext;
    final fromYou = upcoming.where((e) => e.fromYou).toList();
    final rest = upcoming.where((e) => !e.fromYou).toList();
    List<QueueEntry> ordered;
    if (!state.shuffled) {
      rest.shuffle();
      ordered = rest;
    } else {
      // Back to the original order, continuing after the current song.
      final ids = rest.map((e) => e.id).toSet();
      final pos = _unshuffled.indexWhere((e) => e.id == current.id);
      final after = pos < 0 ? _unshuffled : _unshuffled.sublist(pos + 1);
      ordered = [
        ...after.where((e) => ids.contains(e.id)),
        ...rest.where((e) => !after.any((a) => a.id == e.id)),
      ];
    }
    final q = [...state.history, current, ...fromYou, ...ordered];
    state = state.copyWith(
      queue: q,
      index: state.history.length,
      shuffled: !state.shuffled,
    );
    _refillNext();
  }

  /// Volume from the desktop slider (0–1), applied on top of levelling.
  Future<void> setUserVolume(double v) async {
    _userVolume = v.clamp(0.0, 1.0);
    await _applyVolume();
  }

  double get userVolume => _userVolume;

  /// The song's like changed somewhere; keep the queue's copy in step.
  void updateTrack(TrackSummary track) {
    var changed = false;
    final q = [
      for (final e in state.queue)
        if (e.track.id == track.id)
          (() {
            changed = true;
            return QueueEntry(id: e.id, track: track, fromYou: e.fromYou);
          })()
        else
          e,
    ];
    if (changed) state = state.copyWith(queue: q);
  }

  Future<void> stop() async {
    _generation++;
    await _engine.stop();
    _slot0 = _slot1 = null;
    state = PlayerState(mode: state.mode, repeat: state.repeat);
  }

  // ------------------------------------------------------------ internals

  int? _nextIndex() {
    if (state.queue.isEmpty) return null;
    if (state.index + 1 < state.queue.length) return state.index + 1;
    if (state.repeat == RepeatMode.all) return 0;
    return null;
  }

  Future<StreamTicket> _ticketFor(QueueEntry e, {required bool play}) async {
    final cached = _tickets[e.id];
    final fresh =
        cached != null &&
        cached.expiresAt.isAfter(
          DateTime.now().add(const Duration(minutes: 3)),
        );
    if (fresh && !play) return cached;
    final t = await _fetch(
      e.track.id,
      state.mode,
      play: play,
      context: state.source?.context,
    );
    _tickets[e.id] = t;
    return t;
  }

  Uri _uriOf(StreamTicket t) =>
      ref.read(homeConfigProvider)!.address.resolve(t.url);

  Future<void> _loadCurrent({
    required bool autoplay,
    Duration position = Duration.zero,
  }) async {
    final entry = state.current;
    if (entry == null) return;
    final gen = ++_generation;
    state = state.copyWith(loading: true, clearError: true, clearTicket: true);
    try {
      final ticket = await _ticketFor(entry, play: true);
      if (gen != _generation) return;
      final sources = [EngineSource(uri: _uriOf(ticket), entryId: entry.id)];
      _slot0 = entry.id;
      _slot1 = null;
      final n = _nextIndex();
      if (n != null && state.repeat != RepeatMode.one) {
        final nextEntry = state.queue[n];
        try {
          final nt = await _ticketFor(nextEntry, play: false);
          if (gen != _generation) return;
          sources.add(EngineSource(uri: _uriOf(nt), entryId: nextEntry.id));
          _slot1 = nextEntry.id;
        } catch (_) {
          // The next song is fetched again when it's needed.
        }
      }
      state = state.copyWith(
        ticket: ticket,
        duration: Duration(milliseconds: ticket.durationMs),
      );
      await _engine.setSources(sources, position: position);
      await _applyVolume();
      if (gen != _generation) return;
      state = state.copyWith(loading: false);
      if (autoplay) unawaited(_engine.play());
    } catch (e) {
      if (gen != _generation) return;
      state = state.copyWith(
        loading: false,
        playing: false,
        error: describeError(e),
      );
    }
  }

  /// The engine moved on by itself (gapless): slot 1 is now playing.
  Future<void> _onEngineIndex(int? engineIndex) async {
    if (engineIndex == null || engineIndex == 0 || _slot1 == null) return;
    // A song chosen meanwhile replaces the engine's list; then slot 0 is no
    // longer the finished song and must not be removed.
    final gen = _generation;
    final playingId = _slot1!;
    final i = state.queue.indexWhere((e) => e.id == playingId);
    if (i < 0) return;
    _slot0 = playingId;
    _slot1 = null;
    final ticket = _tickets[playingId];
    state = state.copyWith(
      index: i,
      position: Duration.zero,
      ticket: ticket,
      duration: ticket == null
          ? null
          : Duration(milliseconds: ticket.durationMs),
    );
    await _applyVolume();
    if (gen != _generation) return;
    // Count it as played (the stream was fetched ahead as a prefetch).
    unawaited(
      _fetch(
        state.queue[i].track.id,
        state.mode,
        play: true,
        context: state.source?.context,
      ).then((t) => _tickets[playingId] = t, onError: (_) => null),
    );
    try {
      await _engine.removeAt(0);
    } catch (_) {
      return; // the list was replaced under us
    }
    if (gen != _generation) return;
    await _refillNext();
  }

  void _onProcessing(EngineProcessing p) {
    if (p == EngineProcessing.completed && _slot1 == null) {
      // The end of the queue: stop on the last song, ready to play again.
      state = state.copyWith(playing: false, position: state.total);
      _slot0 = null;
    }
  }

  /// Make sure engine slot 1 holds whatever is next in the queue now.
  Future<void> _refillNext({bool force = false}) async {
    if (_slot0 == null) return;
    final gen = _generation;
    final n = _nextIndex();
    final wanted = (n == null || state.repeat == RepeatMode.one)
        ? null
        : state.queue[n];
    if (wanted?.id == _slot1 && !force) return;
    if (_slot1 != null && _engine.length > 1) {
      try {
        await _engine.removeAt(1);
      } catch (_) {
        return; // the list was replaced under us
      }
      if (gen != _generation) return;
      _slot1 = null;
    }
    if (wanted == null) return;
    try {
      final t = await _ticketFor(wanted, play: false);
      if (gen != _generation || _slot1 != null) return;
      _slot1 = wanted.id;
      await _engine.addSource(EngineSource(uri: _uriOf(t), entryId: wanted.id));
    } catch (_) {
      // Tried again on the next queue change or skip.
    }
  }

  Future<void> _applyVolume() async {
    final levelling = ref.read(playbackSettingsProvider).levelling;
    final gain = levelling ? levellingGain(state.ticket?.loudness) : 1.0;
    await _engine.setVolume(gain * _userVolume);
  }
}

final playerProvider = NotifierProvider<PlayerController, PlayerState>(
  PlayerController.new,
);
