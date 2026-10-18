import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../player/player_controller.dart';
import '../../ui/artwork.dart';
import '../../ui/nav.dart';
import 'player_parts.dart';
import 'side_panel.dart';

/// The bar above the tabs on phones: what's playing, play/pause and next.
/// Tap it for Now playing. Hidden until something has played.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final track = ref.watch(playerProvider.select((s) => s.track));
    if (track == null) return const SizedBox.shrink();
    final position = ref.watch(playerProvider.select((s) => s.position));
    final total = ref.watch(playerProvider.select((s) => s.total));
    final error = ref.watch(playerProvider.select((s) => s.error));
    final progress = total.inMilliseconds <= 0
        ? 0.0
        : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HiveSpace.xs,
        0,
        HiveSpace.xs,
        HiveSpace.xs,
      ),
      child: Material(
        color: p.raised,
        borderRadius: BorderRadius.circular(HiveRadius.card),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: context.openNowPlaying,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(HiveSpace.xs),
                child: Row(
                  children: [
                    Artwork(
                      artworkId: track.artworkId,
                      title: track.albumTitle,
                      size: 44,
                      pixels: 96,
                    ),
                    const SizedBox(width: HiveSpace.sm),
                    Expanded(
                      child: Semantics(
                        label:
                            'Now playing: ${track.title}, ${track.artistName}. Open Now playing',
                        excludeSemantics: true,
                        button: true,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HiveType.callout.copyWith(
                                color: p.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              error ?? track.artistName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HiveType.caption.copyWith(
                                color: error != null
                                    ? p.danger
                                    : p.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const PlayPauseButton(size: 40, filled: false),
                    IconButton(
                      tooltip: 'Next',
                      icon: Icon(
                        HiveIcons.skipForward,
                        size: 22,
                        color: p.textPrimary,
                      ),
                      onPressed: () => ref.read(playerProvider.notifier).next(),
                    ),
                  ],
                ),
              ),
              LinearProgressIndicator(
                value: progress,
                minHeight: 2,
                backgroundColor: Colors.transparent,
                color: p.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The player bar along the bottom of the window on computers.
class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final track = ref.watch(playerProvider.select((s) => s.track));
    final error = ref.watch(playerProvider.select((s) => s.error));
    final panel = ref.watch(sidePanelProvider);

    final left = track == null
        ? Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: p.raised,
                  borderRadius: BorderRadius.circular(HiveRadius.art),
                ),
                child: Icon(HiveIcons.music, size: 20, color: p.textTertiary),
              ),
              const SizedBox(width: HiveSpace.sm),
              Text(
                'Nothing playing',
                style: HiveType.callout.copyWith(color: p.textSecondary),
              ),
            ],
          )
        : Row(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(HiveRadius.art),
                onTap: context.openNowPlaying,
                child: Artwork(
                  artworkId: track.artworkId,
                  title: track.albumTitle,
                  size: 52,
                  pixels: 192,
                ),
              ),
              const SizedBox(width: HiveSpace.sm),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      onTap: () => context.openAlbum(track.albumId),
                      child: Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HiveType.callout.copyWith(
                          color: p.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    InkWell(
                      onTap: track.artistId == null
                          ? null
                          : () => context.openArtist(track.artistId!),
                      child: Text(
                        error ?? track.artistName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HiveType.caption.copyWith(
                          color: error != null ? p.danger : p.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const LikeButton(size: 18),
            ],
          );

    return Container(
      height: 84,
      padding: const EdgeInsets.symmetric(horizontal: HiveSpace.md),
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(top: BorderSide(color: p.border)),
      ),
      child: Row(
        children: [
          Expanded(flex: 3, child: left),
          Expanded(
            flex: 4,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [TransportControls(size: 40), SeekBar(dense: true)],
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Flexible(child: BadgeButton(showDetail: false)),
                const SizedBox(width: HiveSpace.xs),
                IconButton(
                  tooltip: 'Lyrics',
                  visualDensity: VisualDensity.compact,
                  isSelected: panel == SidePanel.lyrics,
                  icon: Icon(
                    HiveIcons.micVocal,
                    size: 18,
                    color: panel == SidePanel.lyrics
                        ? p.accentText
                        : p.textSecondary,
                  ),
                  onPressed: () => ref
                      .read(sidePanelProvider.notifier)
                      .toggle(SidePanel.lyrics),
                ),
                IconButton(
                  tooltip: 'Queue',
                  visualDensity: VisualDensity.compact,
                  isSelected: panel == SidePanel.queue,
                  icon: Icon(
                    HiveIcons.listMusic,
                    size: 18,
                    color: panel == SidePanel.queue
                        ? p.accentText
                        : p.textSecondary,
                  ),
                  onPressed: () => ref
                      .read(sidePanelProvider.notifier)
                      .toggle(SidePanel.queue),
                ),
                const _Volume(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Volume extends ConsumerStatefulWidget {
  const _Volume();

  @override
  ConsumerState<_Volume> createState() => _VolumeState();
}

class _VolumeState extends ConsumerState<_Volume> {
  late double _value = ref.read(playerProvider.notifier).userVolume;
  double _beforeMute = 1;

  void _set(double v) {
    setState(() => _value = v);
    ref.read(playerProvider.notifier).setUserVolume(v);
  }

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final icon = _value == 0
        ? HiveIcons.volumeX
        : _value < 0.5
        ? HiveIcons.volume1
        : HiveIcons.volume2;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: _value == 0 ? 'Unmute' : 'Mute',
          visualDensity: VisualDensity.compact,
          icon: Icon(icon, size: 18, color: p.textSecondary),
          onPressed: () {
            if (_value == 0) {
              _set(_beforeMute == 0 ? 1 : _beforeMute);
            } else {
              _beforeMute = _value;
              _set(0);
            }
          },
        ),
        SizedBox(
          width: 84,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: p.textPrimary,
              inactiveTrackColor: p.border,
              thumbColor: p.textPrimary,
            ),
            child: Slider(
              value: _value,
              semanticFormatterCallback: (v) => 'Volume ${(v * 100).round()}%',
              onChanged: _set,
            ),
          ),
        ),
      ],
    );
  }
}
