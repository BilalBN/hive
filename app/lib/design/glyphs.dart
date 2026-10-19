import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Solid, softly rounded transport shapes. The icon font only has outlines,
/// and the player's main controls read better as filled shapes.
enum Glyph { play, pause, next, previous }

class HiveGlyph extends StatelessWidget {
  const HiveGlyph(this.glyph, {super.key, this.size = 24, required this.color});

  final Glyph glyph;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _GlyphPainter(glyph, color)),
  );
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);
  final Glyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    switch (glyph) {
      case Glyph.play:
        // Optically centred: a triangle's weight sits left of its box.
        canvas.drawPath(
          _triangle(Offset(s * 0.24, s * 0.12), s * 0.66, s * 0.76, s * 0.09),
          paint,
        );
      case Glyph.pause:
        final w = s * 0.24, h = s * 0.72, r = Radius.circular(s * 0.06);
        final top = (s - h) / 2;
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(s * 0.2, top, w, h), r),
          paint,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(s * 0.56, top, w, h), r),
          paint,
        );
      case Glyph.next:
      case Glyph.previous:
        canvas.save();
        if (glyph == Glyph.previous) {
          canvas.translate(s, 0);
          canvas.scale(-1, 1);
        }
        final w = s * 0.46, h = s * 0.56, top = (s - h) / 2;
        canvas.drawPath(
          _triangle(Offset(s * 0.06, top), w, h, s * 0.06),
          paint,
        );
        canvas.drawPath(
          _triangle(Offset(s * 0.06 + w * 0.98, top), w, h, s * 0.06),
          paint,
        );
        canvas.restore();
    }
  }

  /// A right-pointing triangle in the box at [origin], corners rounded by [r].
  Path _triangle(Offset origin, double w, double h, double r) {
    final a = origin;
    final b = origin + Offset(w, h / 2);
    final c = origin + Offset(0, h);
    return _rounded([a, b, c], r);
  }

  Path _rounded(List<Offset> pts, double r) {
    final path = Path();
    for (var i = 0; i < pts.length; i++) {
      final prev = pts[(i - 1 + pts.length) % pts.length];
      final cur = pts[i];
      final next = pts[(i + 1) % pts.length];
      final d1 = (prev - cur), d2 = (next - cur);
      final l1 = d1.distance, l2 = d2.distance;
      final cut = math.min(r * 1.6, math.min(l1, l2) / 2);
      final p1 = cur + d1 / l1 * cut;
      final p2 = cur + d2 / l2 * cut;
      if (i == 0) {
        path.moveTo(p1.dx, p1.dy);
      } else {
        path.lineTo(p1.dx, p1.dy);
      }
      path.quadraticBezierTo(cur.dx, cur.dy, p2.dx, p2.dy);
    }
    return path..close();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}
