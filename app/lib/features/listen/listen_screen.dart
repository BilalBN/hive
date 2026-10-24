import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/hive_api.g.dart';
import '../../core/api.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../listen/listen.dart';
import '../../player/player_controller.dart';
import '../../ui/artwork.dart';
import '../../ui/track_actions.dart';

/// Listen: what's this song? Hive listens for a few seconds and checks the
/// family's music at home; a song that isn't there can be asked for.
class ListenScreen extends ConsumerWidget {
  const ListenScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final s = ref.watch(listenProvider);
    final history = ref.watch(listenHistoryProvider);
    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              HiveSpace.md,
              HiveSpace.md,
              HiveSpace.md,
              0,
            ),
            sliver: SliverToBoxAdapter(
              child: Semantics(
                header: true,
                child: Text(
                  'Listen',
                  style: HiveType.title1.copyWith(color: p.textPrimary),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HiveSpace.lg,
                vertical: HiveSpace.lg,
              ),
              child: AnimatedSwitcher(
                duration: HiveMotion.screen,
                child: switch (s.phase) {
                  ListenPhase.found when s.result!.track == null => _Identified(
                    key: const ValueKey('identified'),
                    result: s.result!,
                  ),
                  ListenPhase.found => _Found(
                    key: const ValueKey('found'),
                    result: s.result!,
                  ),
                  ListenPhase.notFound => _NotFound(
                    key: const ValueKey('notFound'),
                    eventId: s.result?.id,
                  ),
                  _ => _Listener(key: const ValueKey('listen'), state: s),
                },
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                HiveSpace.md,
                HiveSpace.md,
                HiveSpace.md,
                HiveSpace.xs,
              ),
              child: Text(
                'Heard lately',
                style: HiveType.title2.copyWith(color: p.textPrimary),
              ),
            ),
          ),
          ...switch (history) {
            AsyncData(:final value) when value.isEmpty => [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: HiveSpace.md),
                  child: Text(
                    'Songs you ask Hive about show here.',
                    style: HiveType.callout.copyWith(color: p.textSecondary),
                  ),
                ),
              ),
            ],
            AsyncData(:final value) => [
              SliverList.builder(
                itemCount: value.length,
                itemBuilder: (_, i) => _HistoryRow(event: value[i]),
              ),
            ],
            AsyncError() => [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: HiveSpace.md),
                  child: Text(
                    "Couldn't load what you heard lately.",
                    style: HiveType.callout.copyWith(color: p.textSecondary),
                  ),
                ),
              ),
            ],
            _ => [const SliverToBoxAdapter(child: SizedBox.shrink())],
          },
          SliverToBoxAdapter(
            child: SizedBox(
              height: MediaQuery.paddingOf(context).bottom + HiveSpace.lg,
            ),
          ),
        ],
      ),
    );
  }
}

/// The big button, and what it's doing.
class _Listener extends ConsumerWidget {
  const _Listener({super.key, required this.state});
  final ListenState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final c = ref.read(listenProvider.notifier);
    final (title, text) = switch (state.phase) {
      ListenPhase.listening when state.askingShazam => (
        'Asking Shazam…',
        "It isn't in your music at home. Shazam gets a fingerprint of the sound, never the sound.",
      ),
      ListenPhase.listening => (
        'Listening…',
        state.heard < const Duration(seconds: 12)
            ? 'Hold the phone near the music. Hive checks as it listens.'
            : 'Still listening. Closer to the speaker helps.',
      ),
      ListenPhase.micDenied => (
        'Hive needs the microphone',
        'Allow it for Hive in your device settings, then tap to listen.',
      ),
      ListenPhase.failed => ("That didn't work", state.error ?? 'Try again.'),
      _ => (
        'Tap to listen',
        'Hive listens until it knows the song (usually a few seconds) and checks the music at home. Nothing is kept.',
      ),
    };
    return Column(
      children: [
        const SizedBox(height: HiveSpace.md),
        Semantics(
          button: true,
          label: state.busy ? 'Stop listening' : 'Start listening',
          excludeSemantics: true,
          child: GestureDetector(
            onTap: state.busy ? c.cancel : c.listen,
            child: _Pulse(
              active: state.phase == ListenPhase.listening,
              color: p.accent,
              child: Container(
                width: 148,
                height: 148,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.lerp(p.accent, Colors.white, 0.15)!,
                      Color.lerp(p.accent, Colors.black, 0.15)!,
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: p.accent.withValues(alpha: 0.35),
                      blurRadius: 30,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Center(
                  child: state.busy
                      ? Icon(HiveIcons.square, size: 40, color: p.onAccent)
                      : Icon(
                          HiveIcons.audioWaveform,
                          size: 56,
                          color: p.onAccent,
                        ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: HiveSpace.lg),
        Text(
          title,
          textAlign: TextAlign.center,
          style: HiveType.title2.copyWith(color: p.textPrimary),
        ),
        const SizedBox(height: HiveSpace.xxs),
        Text(
          text,
          textAlign: TextAlign.center,
          style: HiveType.callout.copyWith(color: p.textSecondary),
        ),
        if (state.busy) ...[
          const SizedBox(height: HiveSpace.sm),
          TextButton(onPressed: c.cancel, child: const Text('Stop')),
        ],
      ],
    );
  }
}

/// Rings that grow out of the button while it listens.
class _Pulse extends StatefulWidget {
  const _Pulse({
    required this.active,
    required this.color,
    required this.child,
  });
  final bool active;
  final Color color;
  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  @override
  void didUpdateWidget(_Pulse old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.active && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 240,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, child) => Stack(
          alignment: Alignment.center,
          children: [
            if (widget.active)
              for (final offset in const [0.0, 0.33, 0.66])
                Builder(
                  builder: (_) {
                    final t = (_c.value + offset) % 1.0;
                    return Container(
                      width: 148 + 92 * t,
                      height: 148 + 92 * t,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.color.withValues(alpha: 0.22 * (1 - t)),
                      ),
                    );
                  },
                ),
            child!,
          ],
        ),
        child: widget.child,
      ),
    );
  }
}

String _clock(int ms) {
  final d = Duration(milliseconds: ms);
  final s = d.inSeconds % 60;
  return '${d.inMinutes}:${s.toString().padLeft(2, '0')}';
}

Future<void> _playFrom(WidgetRef ref, TrackSummary t, int? positionMs) async {
  final player = ref.read(playerProvider.notifier);
  await player.playTracks([t]);
  if (positionMs != null && positionMs > 0) {
    await player.seek(Duration(milliseconds: positionMs));
  }
}

class _Found extends ConsumerWidget {
  const _Found({super.key, required this.result});
  final ListenResult result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final t = result.track!;
    final at = result.positionMs;
    return Column(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(HiveRadius.art),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 30,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Artwork(
            artworkId: t.artworkId,
            title: t.albumTitle,
            size: 200,
            pixels: 600,
          ),
        ),
        const SizedBox(height: HiveSpace.lg),
        Text(
          t.title,
          textAlign: TextAlign.center,
          style: HiveType.title2.copyWith(color: p.textPrimary),
        ),
        Text(
          '${t.artistName} · ${t.albumTitle}',
          textAlign: TextAlign.center,
          style: HiveType.body.copyWith(color: p.textSecondary),
        ),
        const SizedBox(height: HiveSpace.xxs),
        Text(
          'At home in your music',
          style: HiveType.caption.copyWith(color: p.accentText),
        ),
        const SizedBox(height: HiveSpace.lg),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (at != null && at > 3000) ...[
                FilledButton(
                  onPressed: () => _playFrom(ref, t, at),
                  style: FilledButton.styleFrom(
                    backgroundColor: p.accent,
                    foregroundColor: p.onAccent,
                    minimumSize: const Size(0, 48),
                    textStyle: HiveType.headline,
                  ),
                  child: Text('Play from ${_clock(at)}'),
                ),
                const SizedBox(height: HiveSpace.xs),
              ],
              TextButton(
                onPressed: () => _playFrom(ref, t, null),
                style: TextButton.styleFrom(
                  backgroundColor: p.raised,
                  foregroundColor: p.accentText,
                  minimumSize: const Size(0, 48),
                  textStyle: HiveType.headline,
                ),
                child: const Text('Play from the start'),
              ),
            ],
          ),
        ),
        const SizedBox(height: HiveSpace.xs),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: HiveSpace.xs,
          children: [
            TextButton.icon(
              onPressed: () => showAddToPlaylist(context, ref, [t.id]),
              icon: const Icon(HiveIcons.listPlus, size: 18),
              label: const Text('Add to playlist'),
            ),
            TextButton(
              onPressed: ref.read(listenProvider.notifier).listen,
              child: const Text('Listen again'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Not at home, but Shazam knows it (M5): ask for it by name.
class _Identified extends ConsumerWidget {
  const _Identified({super.key, required this.result});
  final ListenResult result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    return Column(
      children: [
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(color: p.raised, shape: BoxShape.circle),
          child: Icon(HiveIcons.music, size: 40, color: p.accentText),
        ),
        const SizedBox(height: HiveSpace.lg),
        Text(
          result.title!,
          textAlign: TextAlign.center,
          style: HiveType.title2.copyWith(color: p.textPrimary),
        ),
        if (result.artist != null)
          Text(
            result.artist!,
            textAlign: TextAlign.center,
            style: HiveType.body.copyWith(color: p.textSecondary),
          ),
        const SizedBox(height: HiveSpace.xxs),
        Text(
          'Identified by Shazam · not in your music yet',
          style: HiveType.caption.copyWith(color: p.textSecondary),
        ),
        const SizedBox(height: HiveSpace.lg),
        FilledButton.icon(
          onPressed: () => askForSong(
            context,
            ref,
            listenEventId: result.id,
            title: result.title,
            artist: result.artist,
          ),
          style: FilledButton.styleFrom(
            backgroundColor: p.accent,
            foregroundColor: p.onAccent,
            minimumSize: const Size(220, 48),
            textStyle: HiveType.headline,
          ),
          icon: const Icon(HiveIcons.messageSquarePlus, size: 18),
          label: const Text('Ask to add it'),
        ),
        const SizedBox(height: HiveSpace.xs),
        TextButton(
          onPressed: ref.read(listenProvider.notifier).listen,
          child: const Text('Listen again'),
        ),
      ],
    );
  }
}

class _NotFound extends ConsumerWidget {
  const _NotFound({super.key, required this.eventId});
  final int? eventId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    return Column(
      children: [
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(color: p.raised, shape: BoxShape.circle),
          child: Icon(HiveIcons.music, size: 40, color: p.textSecondary),
        ),
        const SizedBox(height: HiveSpace.lg),
        Text(
          'Not in your music yet',
          style: HiveType.title2.copyWith(color: p.textPrimary),
        ),
        const SizedBox(height: HiveSpace.xxs),
        Text(
          'Hive didn\'t find this song at home. Ask for it and whoever runs Hive can add it.',
          textAlign: TextAlign.center,
          style: HiveType.callout.copyWith(color: p.textSecondary),
        ),
        const SizedBox(height: HiveSpace.lg),
        FilledButton.icon(
          onPressed: () => askForSong(context, ref, listenEventId: eventId),
          style: FilledButton.styleFrom(
            backgroundColor: p.accent,
            foregroundColor: p.onAccent,
            minimumSize: const Size(220, 48),
            textStyle: HiveType.headline,
          ),
          icon: const Icon(HiveIcons.messageSquarePlus, size: 18),
          label: const Text('Ask to add it'),
        ),
        const SizedBox(height: HiveSpace.xs),
        TextButton(
          onPressed: ref.read(listenProvider.notifier).listen,
          child: const Text('Listen again'),
        ),
      ],
    );
  }
}

/// A sheet to ask for a song: what it might be called, and a note.
Future<void> askForSong(
  BuildContext context,
  WidgetRef ref, {
  int? listenEventId,
  String? title,
  String? artist,
}) async {
  final p = HiveTheme.of(context);
  final titleC = TextEditingController(text: title);
  final artistC = TextEditingController(text: artist);
  final noteC = TextEditingController();
  InputDecoration field(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: HiveType.body.copyWith(color: p.textTertiary),
    filled: true,
    fillColor: p.raised,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(HiveRadius.card),
      borderSide: BorderSide.none,
    ),
  );
  final sent = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: p.surface,
    constraints: const BoxConstraints(maxWidth: 560),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(HiveRadius.sheet),
      ),
    ),
    builder: (sheet) {
      var busy = false;
      String? error;
      return StatefulBuilder(
        builder: (sheet, setState) => Padding(
          padding: EdgeInsets.fromLTRB(
            HiveSpace.lg,
            HiveSpace.lg,
            HiveSpace.lg,
            MediaQuery.viewInsetsOf(sheet).bottom + HiveSpace.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Ask to add a song',
                style: HiveType.title2.copyWith(color: p.textPrimary),
              ),
              const SizedBox(height: HiveSpace.xxs),
              Text(
                listenEventId != null
                    ? 'Whoever runs Hive sees when you heard it. Anything you know helps.'
                    : 'Whoever runs Hive sees your request.',
                style: HiveType.callout.copyWith(color: p.textSecondary),
              ),
              const SizedBox(height: HiveSpace.md),
              TextField(
                key: const Key('request-title'),
                controller: titleC,
                textInputAction: TextInputAction.next,
                decoration: field('Song name, if you know it'),
              ),
              const SizedBox(height: HiveSpace.xs),
              TextField(
                key: const Key('request-artist'),
                controller: artistC,
                textInputAction: TextInputAction.next,
                decoration: field('Singer, band or film'),
              ),
              const SizedBox(height: HiveSpace.xs),
              TextField(
                key: const Key('request-note'),
                controller: noteC,
                maxLines: 2,
                decoration: field('A note (where you heard it, a line of it)'),
              ),
              if (error != null) ...[
                const SizedBox(height: HiveSpace.xs),
                Text(error!, style: HiveType.callout.copyWith(color: p.danger)),
              ],
              const SizedBox(height: HiveSpace.md),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        setState(() => busy = true);
                        try {
                          await ref
                              .read(hiveApiProvider)
                              .createSongRequest(
                                body: SongRequestCreate(
                                  source: listenEventId != null
                                      ? 'listen'
                                      : 'search',
                                  listenEventId: listenEventId,
                                  title: titleC.text.trim().isEmpty
                                      ? null
                                      : titleC.text.trim(),
                                  artist: artistC.text.trim().isEmpty
                                      ? null
                                      : artistC.text.trim(),
                                  note: noteC.text.trim().isEmpty
                                      ? null
                                      : noteC.text.trim(),
                                ),
                              );
                          if (sheet.mounted) Navigator.pop(sheet, true);
                        } catch (e) {
                          setState(() {
                            busy = false;
                            error = describeError(e);
                          });
                        }
                      },
                style: FilledButton.styleFrom(
                  backgroundColor: p.accent,
                  foregroundColor: p.onAccent,
                  minimumSize: const Size(0, 48),
                  textStyle: HiveType.headline,
                ),
                child: const Text('Send request'),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (sent == true && context.mounted) {
    ref.invalidate(listenHistoryProvider);
    showToast(context, 'Asked. Whoever runs Hive will see it.');
  }
}

class _HistoryRow extends ConsumerWidget {
  const _HistoryRow({required this.event});
  final ListenEvent event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final t = event.track;
    final when = _ago(event.at);
    final title = t?.title ?? event.title ?? 'Not found at home';
    final sub = t != null
        ? '${t.artistName} · $when'
        : event.requested == true
        ? 'Asked to add · $when'
        : when;
    return Semantics(
      button: t != null,
      label: '$title, $sub',
      excludeSemantics: true,
      child: InkWell(
        onTap: t == null ? null : () => _playFrom(ref, t, null),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HiveSpace.md,
            vertical: 6,
          ),
          child: Row(
            children: [
              t != null
                  ? Artwork(
                      artworkId: t.artworkId,
                      title: t.albumTitle,
                      size: 44,
                      pixels: 96,
                      radius: 6,
                    )
                  : Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: p.raised,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(
                        HiveIcons.circleHelp,
                        size: 20,
                        color: p.textTertiary,
                      ),
                    ),
              const SizedBox(width: HiveSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HiveType.body.copyWith(
                        color: t != null ? p.textPrimary : p.textSecondary,
                      ),
                    ),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HiveType.caption.copyWith(color: p.textSecondary),
                    ),
                  ],
                ),
              ),
              if (t == null && event.requested != true)
                TextButton(
                  onPressed: () =>
                      askForSong(context, ref, listenEventId: event.id),
                  child: const Text('Ask'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _ago(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} hr ago';
    if (d.inDays == 1) return 'yesterday';
    return '${d.inDays} days ago';
  }
}
