import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Stylized regional map in longitude/latitude coordinates (not navigation data).
final class NetherlandsMap extends CustomPainter {
  const NetherlandsMap();

  @override
  void paint(Canvas canvas, Size size) {
    Offset project(double lon, double lat) => Offset(
        ((lon - 1.5) / 8 * .65 + .30) * size.width,
        (54.0 - lat) / 5 * .65 * size.height);
    Path polygon(List<(double, double)> points) {
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final p = project(points[i].$1, points[i].$2);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      return path..close();
    }

    final land = polygon(const [
      (-3.0, 44.0),
      (2.3, 50.0),
      (2.55, 51.1),
      (3.35, 51.4),
      (3.7, 51.65),
      (4.1, 51.95),
      (4.6, 52.5),
      (4.75, 53.0),
      (5.4, 53.4),
      (6.5, 53.55),
      (7.2, 53.3),
      (7.4, 53.7),
      (8.5, 53.6),
      (8.7, 54.3),
      (9.5, 54.8),
      (14.0, 54.8),
      (14.0, 44.0)
    ]);
    canvas.drawPath(land, Paint()..color = const Color(0xFF101B49));
    canvas.drawPath(
        land,
        Paint()
          ..color = const Color(0xFF4045BD)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
    final random = math.Random(17);
    for (var i = 0; i < 1600; i++) {
      final p = Offset(
          random.nextDouble() * size.width, random.nextDouble() * size.height);
      if (land.contains(p)) {
        canvas.drawCircle(
            p,
            random.nextDouble() * 1.2,
            Paint()
              ..color = const Color(0xFF7366FF)
                  .withValues(alpha: .15 + random.nextDouble() * .5));
      }
    }
    final country = polygon(const [
      (3.36, 51.37),
      (3.7, 51.3),
      (4.23, 51.38),
      (4.45, 51.48),
      (4.8, 51.41),
      (5.05, 51.48),
      (5.85, 51.15),
      (5.7, 50.76),
      (6.03, 50.75),
      (6.2, 51.05),
      (6.08, 51.48),
      (6.22, 51.87),
      (6.7, 51.9),
      (6.85, 52.23),
      (7.06, 52.39),
      (6.7, 52.48),
      (6.72, 52.65),
      (7.05, 52.65),
      (7.2, 53.25),
      (6.85, 53.45),
      (6.1, 53.45),
      (5.5, 53.4),
      (5.1, 53.1),
      (4.75, 52.98),
      (4.65, 52.55),
      (4.1, 51.98),
      (3.7, 51.72),
      (3.45, 51.55)
    ]);
    canvas.drawPath(country,
        Paint()..color = const Color(0xFF6C28E8).withValues(alpha: .35));
    for (final width in [12.0, 4.0, 1.5]) {
      canvas.drawPath(
          country,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = width
            ..color = const Color(0xFFC077FF)
            ..maskFilter =
                (width > 2 ? MaskFilter.blur(BlurStyle.normal, width) : null));
    }
  }

  @override
  bool shouldRepaint(covariant NetherlandsMap oldDelegate) => false;
}
