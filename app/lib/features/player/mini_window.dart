import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../desktop/desktop.dart';
import '../../design/glyphs.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../player/player_controller.dart';
import '../../ui/artwork.dart';
import 'player_parts.dart';

/// The computer's mini player: a small window that stays on top, with the
/// song and its controls. "Full window" brings Hive back.
class MiniWindowView extends ConsumerWidget {
  const MiniWindowView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = HiveTheme.of(context);
    final track = ref.watch(playerProvider.select((s) => s.track));
    final player = ref.read(playerProvider.notifier);
    return Material(
      color: p.surface,
      child: Padding(
        padding: const EdgeInsets.all(HiveSpace.xs),
        child: Row(
          children: [
            Artwork(
              artworkId: track?.artworkId,
              title: track?.albumTitle ?? 'Hive',
              size: 80,
              pixels: 192,
              radius: 8,
            ),
            const SizedBox(width: HiveSpace.sm),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track?.title ?? 'Nothing playing',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HiveType.callout.copyWith(
                      color: p.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    track?.artistName ?? 'Choose something in Hive',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HiveType.caption.copyWith(color: p.textSecondary),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      GlyphButton(
                        tooltip: 'Previous',
                        glyph: Glyph.previous,
                        size: 18,
                        color: p.textPrimary,
                        onPressed: track == null
                            ? null
                            : () => player.previous(),
                      ),
                      PlayPauseButton(size: 34, color: p.textPrimary),
                      GlyphButton(
                        tooltip: 'Next',
                        glyph: Glyph.next,
                        size: 18,
                        color: p.textPrimary,
                        onPressed: track == null ? null : () => player.next(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Full window',
              icon: Icon(HiveIcons.maximize2, size: 18, color: p.textSecondary),
              onPressed: () => ref.read(miniWindowProvider.notifier).set(false),
            ),
          ],
        ),
      ),
    );
  }
}
