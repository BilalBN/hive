import 'package:flutter/semantics.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/hive_api.g.dart';
import '../design/glyphs.dart';
import '../design/icons.g.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';
import '../player/player_controller.dart';
import 'artwork.dart';
import 'states.dart';
import 'track_actions.dart';

/// One song in a list. Tap plays; the ⋯ button, a long press or a right-click
/// opens its actions. The playing song is shown in the accent colour.
class TrackRow extends ConsumerWidget {
  const TrackRow({
    super.key,
    required this.track,
    required this.onTap,
    this.number,
    this.showArt = true,
    this.showAlbum = false,
    this.onRemoveFromPlaylist,
    this.trailing,
  });

  final TrackSummary track;
  final VoidCallback onTap;

  /// Track number instead of artwork (album pages).
  final int? number;
  final bool showArt;
  final bool showAlbum;
  final VoidCallback? onRemoveFromPlaylist;
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final isCurrent = ref.watch(
      playerProvider.select((s) => s.track?.id == track.id),
    );
    final playing = ref.watch(playerProvider.select((s) => s.playing));
    final titleColor = isCurrent ? p.accentText : p.textPrimary;
    final subtitle = showAlbum
        ? '${track.artistName} · ${track.albumTitle}'
        : track.artistName;

    Widget leading;
    if (number != null) {
      leading = SizedBox(
        width: 28,
        child: isCurrent
            ? Icon(
                playing ? HiveIcons.audioLines : HiveIcons.pause,
                size: 16,
                color: p.accentText,
              )
            : Text(
                '$number',
                textAlign: TextAlign.center,
                style: HiveType.callout.copyWith(color: p.textSecondary),
              ),
      );
    } else if (showArt) {
      leading = Artwork(
        artworkId: track.artworkId,
        title: track.albumTitle,
        size: 44,
        pixels: 96,
        radius: 6,
      );
    } else {
      leading = const SizedBox.shrink();
    }

    void actions([Offset? at]) => showTrackActions(
      context,
      ref,
      track,
      at: at,
      onRemoveFromPlaylist: onRemoveFromPlaylist,
    );

    return Semantics(
      button: true,
      label:
          '${track.title}, ${track.artistName}${isCurrent ? ', playing' : ''}',
      excludeSemantics: true,
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'More actions'): () => actions(),
      },
      child: GestureDetector(
        onSecondaryTapUp: (d) => actions(d.globalPosition),
        child: InkWell(
          onTap: onTap,
          onLongPress: () => actions(),
          child: _Hairline(
            indent:
                HiveSpace.md +
                (number != null ? 28 : (showArt ? 44 : 0)) +
                (number != null || showArt ? HiveSpace.sm : 0),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HiveSpace.md,
                vertical: 6,
              ),
              child: Row(
                children: [
                  leading,
                  if (number != null || showArt)
                    const SizedBox(width: HiveSpace.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: HiveType.body.copyWith(
                            color: titleColor,
                            fontWeight: isCurrent
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HiveType.caption.copyWith(
                            color: p.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: HiveSpace.xs),
                  trailing ??
                      Text(
                        formatDuration(
                          Duration(milliseconds: track.durationMs),
                        ),
                        style: HiveType.caption.copyWith(
                          color: p.textSecondary,
                        ),
                      ),
                  Builder(
                    builder: (b) => IconButton(
                      tooltip: 'More',
                      icon: Icon(
                        HiveIcons.ellipsis,
                        size: 18,
                        color: p.textSecondary,
                      ),
                      onPressed: () {
                        final box = b.findRenderObject() as RenderBox?;
                        actions(
                          box?.localToGlobal(box.size.center(Offset.zero)),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An album, playlist or artist as a square tile with a caption (grids and rows).
class CoverTile extends StatelessWidget {
  const CoverTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.art,
    required this.onTap,
    this.width,
    this.semanticsKind = 'Album',
  });

  final String title;
  final String subtitle;
  final Widget art;
  final VoidCallback onTap;
  final double? width;
  final String semanticsKind;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final tile = Semantics(
      button: true,
      label: '$semanticsKind: $title, $subtitle',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(HiveRadius.art),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            art,
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HiveType.callout.copyWith(
                color: p.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HiveType.caption.copyWith(color: p.textSecondary),
            ),
          ],
        ),
      ),
    );
    return width == null ? tile : SizedBox(width: width, child: tile);
  }
}

/// A row for lists of albums, artists or playlists.
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.trailing,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return Semantics(
      button: true,
      label: [title, ?subtitle].join(', '),
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HiveSpace.md,
            vertical: 6,
          ),
          child: Row(
            children: [
              leading,
              const SizedBox(width: HiveSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: HiveType.body.copyWith(
                        color: p.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HiveType.caption.copyWith(
                          color: p.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              trailing ??
                  Icon(HiveIcons.chevronRight, size: 18, color: p.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

/// A section heading with an optional action on the right ("See all").
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.onAction});

  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HiveSpace.md,
        HiveSpace.lg,
        HiveSpace.md,
        HiveSpace.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: HiveType.title2.copyWith(color: p.textPrimary),
              ),
            ),
          ),
          if (action != null)
            TextButton(
              onPressed: onAction,
              child: Text(
                action!,
                style: HiveType.callout.copyWith(
                  color: p.accentText,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Play and Shuffle under album and playlist headers: two equal soft
/// buttons with the accent on the icon and word, not the fill.
class PlayButtons extends StatelessWidget {
  const PlayButtons({
    super.key,
    required this.onPlay,
    required this.onShuffle,
    this.extra,
  });

  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;
  final List<Widget>? extra;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final style = TextButton.styleFrom(
      backgroundColor: dark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.black.withValues(alpha: 0.05),
      foregroundColor: p.accentText,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      minimumSize: const Size(0, 48),
      textStyle: HiveType.headline,
    );
    return Row(
      children: [
        Expanded(
          child: TextButton.icon(
            onPressed: onPlay,
            style: style,
            icon: HiveGlyph(Glyph.play, size: 16, color: p.accentText),
            label: const Text('Play'),
          ),
        ),
        const SizedBox(width: HiveSpace.sm),
        Expanded(
          child: TextButton.icon(
            onPressed: onShuffle,
            style: style,
            icon: const Icon(HiveIcons.shuffle, size: 18),
            label: const Text('Shuffle'),
          ),
        ),
        ...?extra,
      ],
    );
  }
}

/// A hairline under a list row, starting where its text starts.
class _Hairline extends StatelessWidget {
  const _Hairline({required this.indent, required this.child});
  final double indent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return Stack(
      children: [
        child,
        Positioned(
          left: indent,
          right: HiveSpace.md,
          bottom: 0,
          height: 0.5,
          child: ColoredBox(color: p.border.withValues(alpha: 0.7)),
        ),
      ],
    );
  }
}

/// Keeps the pointer from scrolling a horizontal row with the mouse wheel.
class DragScrollBehavior extends MaterialScrollBehavior {
  const DragScrollBehavior();
  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
  };
}
