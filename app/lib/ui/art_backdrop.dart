import 'dart:ui';

import 'package:flutter/material.dart';

import '../design/tokens.g.dart';
import 'artwork.dart';

/// The playing song's cover, blown up and blurred into a wash of its own
/// colours, with a shade so white text always reads. Now playing and the
/// lyrics sit on it, the way a record sleeve tints the room.
class ArtBackdrop extends StatelessWidget {
  const ArtBackdrop({
    super.key,
    required this.artworkId,
    required this.title,
    required this.child,
  });

  final String? artworkId;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF151413)),
        RepaintBoundary(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 600),
            child: ImageFiltered(
              key: ValueKey(artworkId ?? title),
              imageFilter: ImageFilter.blur(
                sigmaX: 70,
                sigmaY: 70,
                tileMode: TileMode.mirror,
              ),
              child: Transform.scale(
                scale: 1.6,
                child: Artwork(
                  artworkId: artworkId,
                  title: title,
                  pixels: 300,
                  radius: 0,
                ),
              ),
            ),
          ),
        ),
        // Shade: lighter at the top where the art sits, deeper behind the
        // controls.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.32),
                Colors.black.withValues(alpha: 0.52),
                Colors.black.withValues(alpha: 0.68),
              ],
              stops: const [0, 0.55, 1],
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// Colours for text and controls on [ArtBackdrop]: white at a few strengths.
abstract final class OnArt {
  static const primary = Colors.white;
  static final secondary = Colors.white.withValues(alpha: 0.8);
  static final tertiary = Colors.white.withValues(alpha: 0.42);
  static final track = Colors.white.withValues(alpha: 0.22);
  static final fill = Colors.white.withValues(alpha: 0.14);

  static TextStyle caption = HiveType.caption.copyWith(
    color: secondary,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}
