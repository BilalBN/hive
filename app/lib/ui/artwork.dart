import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../design/theme.dart';
import '../design/tokens.g.dart';

/// Initials for a title, skipping brackets and little words:
/// "Jaane Tu Ya Jaane Na" → "JJ", "മലരേ (Malare)" → "മ".
String initialsOf(String title) {
  final cleaned = title.replaceAll(RegExp(r'\(.*?\)'), ' ');
  const small = {'the', 'of', 'a', 'vol', 'ya', 'tu'};
  final words = cleaned
      .split(RegExp(r'[\s\-–.]+'))
      .where((w) => w.isNotEmpty && RegExp(r'\p{L}', unicode: true).hasMatch(w))
      .where((w) => !small.contains(w.toLowerCase()))
      .take(2)
      .map((w) => w.characters.first.toUpperCase())
      .join();
  return words.isEmpty ? '♪' : words;
}

int _hue(String s) {
  var h = 7;
  for (final c in s.runes) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h % 360;
}

/// The design's placeholder art: a gradient from the title, with initials.
class PlaceholderArt extends StatelessWidget {
  const PlaceholderArt({super.key, required this.title, this.round = false});

  final String title;
  final bool round;

  @override
  Widget build(BuildContext context) {
    final hue = _hue(title).toDouble();
    return LayoutBuilder(
      builder: (context, c) {
        final size = c.biggest.shortestSide.isFinite
            ? c.biggest.shortestSide
            : 48.0;
        return DecoratedBox(
          decoration: BoxDecoration(
            shape: round ? BoxShape.circle : BoxShape.rectangle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                HSLColor.fromAHSL(1, hue, 0.45, 0.55).toColor(),
                HSLColor.fromAHSL(1, (hue + 40) % 360, 0.4, 0.3).toColor(),
              ],
            ),
          ),
          child: Center(
            child: Text(
              initialsOf(title),
              maxLines: 1,
              style: TextStyle(
                fontFamily: HiveType.family,
                fontFamilyFallback: HiveType.fallbacks,
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: (size * 0.36).clamp(10, 120),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Cover art from home, or the placeholder while loading or when there's none.
class Artwork extends ConsumerWidget {
  const Artwork({
    super.key,
    required this.artworkId,
    required this.title,
    this.size,
    this.radius = HiveRadius.art,
    this.round = false,
    this.pixels = 300,
  });

  final String? artworkId;
  final String title;
  final double? size;
  final double radius;
  final bool round;

  /// Requested image size; the server snaps to its nearest size.
  final int pixels;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final image = artworkImage(ref, artworkId, size: pixels);
    final placeholder = PlaceholderArt(title: title, round: round);
    Widget child = image == null
        ? placeholder
        : Image(
            image: image,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            frameBuilder: (context, child, frame, sync) =>
                frame == null && !sync ? placeholder : child,
            errorBuilder: (_, _, _) => placeholder,
          );
    // A hairline edge keeps dark covers from melting into a dark page.
    final rim = Theme.of(context).brightness == Brightness.dark
        ? Colors.white.withValues(alpha: 0.07)
        : Colors.black.withValues(alpha: 0.06);
    child = round
        ? ClipOval(child: child)
        : DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: radius == 0 ? null : Border.all(color: rim, width: 0.5),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: child,
            ),
          );
    return ExcludeSemantics(
      child: size == null
          ? AspectRatio(aspectRatio: 1, child: child)
          : SizedBox.square(dimension: size, child: child),
    );
  }
}

/// Up to four covers in a 2×2 grid, for playlists.
class Mosaic extends StatelessWidget {
  const Mosaic({
    super.key,
    required this.artworkIds,
    required this.title,
    this.size,
    this.pixels = 300,
  });

  final List<String> artworkIds;
  final String title;
  final double? size;
  final int pixels;

  @override
  Widget build(BuildContext context) {
    if (artworkIds.length < 4) {
      return Artwork(
        artworkId: artworkIds.isEmpty ? null : artworkIds.first,
        title: title,
        size: size,
        pixels: pixels,
      );
    }
    final p = HiveTheme.of(context);
    Widget grid = ClipRRect(
      borderRadius: BorderRadius.circular(HiveRadius.art),
      child: ColoredBox(
        color: p.raised,
        child: GridView.count(
          crossAxisCount: 2,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          children: [
            for (final id in artworkIds.take(4))
              Artwork(
                artworkId: id,
                title: title,
                radius: 0,
                pixels: pixels ~/ 2,
              ),
          ],
        ),
      ),
    );
    grid = ExcludeSemantics(child: grid);
    return size == null
        ? AspectRatio(aspectRatio: 1, child: grid)
        : SizedBox.square(dimension: size, child: grid);
  }
}
