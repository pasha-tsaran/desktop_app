import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Flags are drawn directly: Windows does not reliably render flag emoji.
final class CountryFlag extends StatelessWidget {
  const CountryFlag({required this.countryCode, required this.size, super.key});
  final String countryCode;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
        label: countryCode,
        child: Container(
          width: size,
          height: size,
          decoration:
              BoxDecoration(shape: BoxShape.circle, boxShadow: <BoxShadow>[
            BoxShadow(color: Colors.black.withValues(alpha: .18), blurRadius: 8)
          ]),
          child: ClipOval(
              child: CustomPaint(
                  painter: _FlagPainter(countryCode.toUpperCase()))),
        ),
      );
}

final class _FlagPainter extends CustomPainter {
  const _FlagPainter(this.code);
  final String code;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final full = Offset.zero & size;
    void fill(Color color) => canvas.drawRect(full, Paint()..color = color);
    void bars(List<Color> colors, {bool vertical = false}) {
      for (var i = 0; i < colors.length; i++) {
        canvas.drawRect(
            vertical
                ? Rect.fromLTWH(
                    w * i / colors.length, 0, w / colors.length + .5, h)
                : Rect.fromLTWH(
                    0, h * i / colors.length, w, h / colors.length + .5),
            Paint()..color = colors[i]);
      }
    }

    void star(Offset c, double radius, Color color) {
      final path = Path();
      for (var i = 0; i < 10; i++) {
        final r = i.isEven ? radius : radius * .42;
        final a = i * math.pi / 5 - math.pi / 2;
        final p = c + Offset(math.cos(a) * r, math.sin(a) * r);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(path..close(), Paint()..color = color);
    }

    const red = Color(0xFFEC0738);
    const blue = Color(0xFF073DA8);
    switch (code) {
      case 'AM':
        bars(const <Color>[
          Color(0xFFE70831),
          Color(0xFF073CB3),
          Color(0xFFFFBA12)
        ]);
      case 'DE':
        bars(const <Color>[
          Color(0xFF080A10),
          Color(0xFFE70928),
          Color(0xFFFFC534)
        ]);
      case 'NL':
        bars(const <Color>[Color(0xFFCE1739), Colors.white, Color(0xFF2965C8)]);
      case 'FR':
        bars(const <Color>[blue, Colors.white, red], vertical: true);
      case 'RU':
        bars(const <Color>[Colors.white, blue, red]);
      case 'FI':
        fill(Colors.white);
        canvas.drawRect(
            Rect.fromLTWH(w * .29, 0, w * .20, h), Paint()..color = blue);
        canvas.drawRect(
            Rect.fromLTWH(0, h * .4, w, h * .20), Paint()..color = blue);
      case 'JP':
        fill(Colors.white);
        canvas.drawCircle(
            size.center(Offset.zero), w * .24, Paint()..color = red);
      case 'US':
        bars(List<Color>.generate(13, (i) => i.isEven ? red : Colors.white));
        canvas.drawRect(
            Rect.fromLTWH(0, 0, w * .55, h * .57), Paint()..color = blue);
        for (var row = 0; row < 5; row++) {
          for (var col = 0; col < 5; col++) {
            star(Offset(w * (.055 + col * .10), h * (.06 + row * .10)),
                w * .033, Colors.white);
          }
        }
      case 'GB':
      case 'UK':
        fill(blue);
        final pen = Paint()
          ..color = Colors.white
          ..strokeWidth = w * .19;
        canvas.drawLine(Offset.zero, Offset(w, h), pen);
        canvas.drawLine(Offset(w, 0), Offset(0, h), pen);
        pen
          ..color = red
          ..strokeWidth = w * .075;
        canvas.drawLine(Offset.zero, Offset(w, h), pen);
        canvas.drawLine(Offset(w, 0), Offset(0, h), pen);
        canvas.drawRect(Rect.fromLTWH(w * .34, 0, w * .32, h),
            Paint()..color = Colors.white);
        canvas.drawRect(Rect.fromLTWH(0, h * .34, w, h * .32),
            Paint()..color = Colors.white);
        canvas.drawRect(
            Rect.fromLTWH(w * .40, 0, w * .20, h), Paint()..color = red);
        canvas.drawRect(
            Rect.fromLTWH(0, h * .40, w, h * .20), Paint()..color = red);
      case 'SG':
        bars(const <Color>[red, Colors.white]);
        canvas.drawCircle(
            Offset(w * .30, h * .25), w * .16, Paint()..color = Colors.white);
        canvas.drawCircle(
            Offset(w * .36, h * .23), w * .14, Paint()..color = red);
        for (var i = 0; i < 5; i++) {
          final a = i * math.pi * 2 / 5 - math.pi / 2;
          star(
              Offset(w * .49 + math.cos(a) * w * .09,
                  h * .25 + math.sin(a) * h * .09),
              w * .035,
              Colors.white);
        }
      case 'CA':
        fill(Colors.white);
        canvas.drawRect(Rect.fromLTWH(0, 0, w * .24, h), Paint()..color = red);
        canvas.drawRect(
            Rect.fromLTWH(w * .76, 0, w * .24, h), Paint()..color = red);
        final leaf = Path()
          ..moveTo(w * .50, h * .15)
          ..lineTo(w * .56, h * .34)
          ..lineTo(w * .66, h * .29)
          ..lineTo(w * .62, h * .47)
          ..lineTo(w * .72, h * .46)
          ..lineTo(w * .66, h * .63)
          ..lineTo(w * .53, h * .67)
          ..lineTo(w * .52, h * .83)
          ..lineTo(w * .48, h * .83)
          ..lineTo(w * .47, h * .67)
          ..lineTo(w * .34, h * .63)
          ..lineTo(w * .28, h * .46)
          ..lineTo(w * .38, h * .47)
          ..lineTo(w * .34, h * .29)
          ..lineTo(w * .44, h * .34)
          ..close();
        canvas.drawPath(leaf, Paint()..color = red);
      default:
        fill(const Color(0xFF545CC4));
        final text = TextPainter(
            text: TextSpan(
                text: code,
                style: TextStyle(
                    color: Colors.white,
                    fontSize: w * .32,
                    fontWeight: FontWeight.w700)),
            textDirection: TextDirection.ltr)
          ..layout(maxWidth: w);
        text.paint(canvas, Offset((w - text.width) / 2, (h - text.height) / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _FlagPainter old) => old.code != code;
}
